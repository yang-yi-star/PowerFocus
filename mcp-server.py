# -*- coding: utf-8 -*-
# ============================================================
# [DEPRECATED since v0.11.0 / 2026-11-14] 请勿再对外加载本文件。
# 替代：mcp/powerfocus_mcp/server.py（PowerFocus MCP 0.11.0，协议 2026-07-28）。
# 弃用原因（代码实证，非理论推测）：
#   1. 直写 versions/*/commands/in 命令总线，完全绕过 X-PF-Token、Host 校验、
#      动作白名单与限流；任何能加载本 MCP 的 AI 都能驱动本机内核。
#   2. 无二次确认、无审计，且把 229 项 REA 逆向引擎工具无门槛转发给任意客户端。
#   3. 超时不撤回命令文件：内核稍后启动会自动执行那条已超时的破坏性命令。
#   4. 强制 initialize 握手、畸形消息可打崩进程、硬编码 E:\PowerFocus。
# 本文件仅为历史兼容保留，不随 Release 分发、不进 CI、不推荐加载。
# ============================================================
# 电脑算力调度中心 v2 · 阶段五：MCP Server（mcp-server.py）
# 协议：MCP 2024-11-05 / stdio 传输 / JSON-RPC 2.0（逐行）
# 职责：让任何 AI 客户端（豆包/Claude/任意 LLM）通过 MCP 调用
#       调度中心——申请算力、释放算力、查状态、管理规则引擎。
# 架构：本文件只是【翻译层】：tools/call 收到参数后写入 v2 的
#       命令总线 commands\in\*.json，轮询 done\*.json.result.txt，
#       把 v2 的执行结果作为 text 返回。调度逻辑全部在 v2。
# 启动：python E:\PowerFocus\mcp-server.py  （客户端以子进程方式拉起）
# 自测：echo '{"jsonrpc":"2.0","id":1,"method":"initialize",...}' | python mcp-server.py
# ============================================================
import sys, os, json, time, atexit, shutil, subprocess, threading, re

POWERFOCUS = r"E:\PowerFocus"
# 内核已迁到 versions\<当前版本>\（由 versions\current.json 指针维护）。
# 命令总线必须跟随指针解析，否则 MCP 工具全部转发到不存在的目录、一律超时。
def _kernel_dir():
    vers = os.path.join(POWERFOCUS, "versions")
    ptr = os.path.join(vers, "current.json")
    try:
        with open(ptr, "r", encoding="utf-8-sig") as f:
            ver = str(json.load(f).get("version") or "")
        cand = os.path.join(vers, ver)
        if ver and os.path.isdir(cand):
            return cand
    except Exception:
        pass
    best, best_key = None, None
    if os.path.isdir(vers):
        for name in os.listdir(vers):
            m = re.match(r"v(\d+)\.(\d+)$", name)
            path = os.path.join(vers, name)
            if not m or not os.path.isdir(path):
                continue
            key = (int(m.group(1)), int(m.group(2)))
            if best_key is None or key > best_key:
                best, best_key = path, key
    return best or os.path.join(POWERFOCUS, "v3")

KERNEL_DIR = _kernel_dir()
BUS_ROOT = KERNEL_DIR
CMD_IN  = os.path.join(BUS_ROOT, "commands", "in")
CMD_OUT = os.path.join(BUS_ROOT, "commands", "out")
CMD_DONE= os.path.join(BUS_ROOT, "commands", "done")

SERVER_NAME = "powerfocus-mcp"
SERVER_VERSION = "1.1.0"
PROTOCOL_VERSION = "2024-11-05"
SUPPORTED_PROTOCOLS = ("2024-11-05", "2025-03-26", "2025-06-18")

# ---------- 内置 REA（Reverse Engineer Anything）逆向引擎 ----------
# 调度中心自带 REA MCP 客户端：任何连上本 MCP 的 AI 都能直接调用全部 REA 工具。
# 工具名统一加前缀 rea__，避免与调度中心原生工具冲突。
REA_PREFIX = "rea__"
REA_START_COOLDOWN = 60      # 启动失败后的冷却秒数，避免每次列工具都重试
REA_TOOL_TIMEOUT = 900       # 单个逆向任务最长等待秒数（Ghidra 反编译可能很久）

def _find_rea():
    """定位 REA 可执行文件。

    优先级：POWERFOCUS_REA 环境变量 > 全局 npm 安装(%APPDATA%\\npm) > PATH。
    原因：PATH 可能被 agent 沙箱接管（...\\sandbox_runtime\\...），沙箱自带的 rea
    版本更旧、工具更少（实测 6.7.0 / 207 个，全局 6.8.0 / 229 个），
    会让 tools/list 静默缩水且不报错。
    """
    override = os.environ.get("POWERFOCUS_REA")
    if override and os.path.exists(override):
        return override

    npm_dir = os.path.join(os.environ.get("APPDATA", ""), "npm")
    for name in ("rea.cmd", "rea-agents.cmd", "rea.ps1", "rea-agents.ps1"):
        cand = os.path.join(npm_dir, name)
        if os.path.exists(cand):
            return cand

    # APPDATA 缺失时的兜底（用户目录固定安装位置）
    cand = r"C:\Users\Administrator.医院\AppData\Roaming\npm\rea.cmd"
    if os.path.exists(cand):
        return cand

    return shutil.which("rea") or shutil.which("rea-agents")


REA_EXE = _find_rea()

# ---------- stdio UTF-8 ----------
try:
    sys.stdin.reconfigure(encoding="utf-8")
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass

def emit(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()

# ---------- 命令总线转发 ----------
_seq = [0]
def bus_call(cmd_obj, timeout=15.0):
    """写入命令总线 in 目录，轮询 done 结果，返回 (ok, result_text)。"""
    _seq[0] += 1
    name = "mcp-%d-%d" % (int(time.time()), _seq[0])
    in_path  = os.path.join(CMD_IN, name + ".json")
    done_path = os.path.join(CMD_DONE, name + ".json.result.txt")
    try:
        os.makedirs(CMD_IN, exist_ok=True)
        with open(in_path, "w", encoding="utf-8") as f:
            json.dump(cmd_obj, f, ensure_ascii=False)
        deadline = time.time() + timeout
        while time.time() < deadline:
            if os.path.exists(done_path):
                with open(done_path, "r", encoding="utf-8-sig") as f:
                    return True, f.read().strip()
            time.sleep(0.3)
        return False, "命令总线超时（%s 未响应 %s 秒）：请确认调度中心内核正在运行" % (
            KERNEL_DIR, int(timeout))
    except Exception as e:
        return False, "命令总线调用异常: %s" % e

def read_json(path):
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            return json.load(f)
    except Exception:
        return None

# ---------- REA MCP 代理（stdio JSON-RPC 客户端） ----------
class ReaProxy:
    """把 rea --mcp 子进程当作后端，对外转发 tools/list 与 tools/call。"""

    def __init__(self):
        self.proc = None
        self.id_lock = threading.Lock()
        self.write_lock = threading.Lock()
        self.pending = {}
        self.next_id = 0
        self.dead = threading.Event()
        self.last_stderr = ""
        self.server_info = {}
        self.tool_count = 0
        self.start_error = ""
        self.last_fail_at = 0.0

    # --- 子进程 ---
    def _reader(self):
        proc = self.proc
        try:
            for line in proc.stdout:
                line = line.strip()
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                except Exception:
                    continue
                mid = msg.get("id")
                if mid is None:
                    continue
                slot = self.pending.pop(mid, None)
                if slot:
                    slot["resp"] = msg
                    slot["ev"].set()
        finally:
            self.dead.set()
            for slot in list(self.pending.values()):
                slot["ev"].set()
            self.pending.clear()

    def _stderr_reader(self):
        proc = self.proc
        try:
            for line in proc.stderr:
                line = line.strip()
                if line:
                    self.last_stderr = line[-400:]
        except Exception:
            pass

    def _alive(self):
        return self.proc is not None and self.proc.poll() is None

    def ensure_started(self):
        if self._alive():
            return True
        if not REA_EXE:
            self.start_error = "未找到 rea 可执行文件（请先执行 npm install --global rea-agents）"
            return False
        if time.time() - self.last_fail_at < REA_START_COOLDOWN:
            return False
        try:
            self.proc = subprocess.Popen(
                [REA_EXE, "--mcp"],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                text=True, encoding="utf-8", bufsize=1, shell=False)
        except Exception as e:
            self.start_error = "启动 rea --mcp 失败: %s" % e
            self.last_fail_at = time.time()
            return False
        self.dead.clear()
        threading.Thread(target=self._reader, daemon=True).start()
        threading.Thread(target=self._stderr_reader, daemon=True).start()
        resp = self.request("initialize", {
            "protocolVersion": "2025-06-18",
            "capabilities": {"roots": {"listChanged": False}, "sampling": {}},
            "clientInfo": {"name": "powerfocus-mcp", "version": SERVER_VERSION},
        }, timeout=60)
        if not resp or "result" not in resp:
            self.start_error = "REA 初始化失败: %s" % (self.last_stderr or "无响应")
            self.last_fail_at = time.time()
            self.stop()
            return False
        self.server_info = resp["result"].get("serverInfo") or {}
        self.start_error = ""
        self.last_fail_at = 0.0
        self.notify("notifications/initialized", {})
        return True

    def notify(self, method, params):
        if not self._alive():
            return
        try:
            with self.write_lock:
                self.proc.stdin.write(json.dumps(
                    {"jsonrpc": "2.0", "method": method, "params": params}, ensure_ascii=False) + "\n")
                self.proc.stdin.flush()
        except Exception:
            pass

    def request(self, method, params, timeout):
        if not self._alive():
            return None
        with self.id_lock:
            self.next_id += 1
            rid = self.next_id
            slot = {"ev": threading.Event(), "resp": None}
            self.pending[rid] = slot
        try:
            with self.write_lock:
                self.proc.stdin.write(json.dumps(
                    {"jsonrpc": "2.0", "id": rid, "method": method, "params": params},
                    ensure_ascii=False) + "\n")
                self.proc.stdin.flush()
        except Exception as e:
            self.pending.pop(rid, None)
            return {"error": {"code": -32000, "message": "写入 REA 失败: %s" % e}}
        if not slot["ev"].wait(timeout):
            self.pending.pop(rid, None)
            return {"error": {"code": -32000, "message": "REA 响应超时（%d 秒）" % timeout}}
        return slot["resp"]

    # --- 对外能力 ---
    def list_tools(self):
        if not self.ensure_started():
            return []
        resp = self.request("tools/list", {}, timeout=120)
        if not resp or "result" not in resp:
            self.start_error = "REA tools/list 失败: %s" % (self.last_stderr or "无响应")
            return []
        tools = resp["result"].get("tools") or []
        self.tool_count = len(tools)
        return tools

    def call_tool(self, name, args):
        if not self.ensure_started():
            return {"error": {"code": -32000, "message": "REA 不可用: %s" % (self.start_error or "未知原因")}}
        return self.request("tools/call", {"name": name, "arguments": args}, timeout=REA_TOOL_TIMEOUT)

    def status(self):
        started = self.ensure_started()
        return {
            "available": bool(started),
            "executable": REA_EXE,
            "server": self.server_info,
            "tool_count": self.tool_count,
            "error": self.start_error,
            "stderr_tail": self.last_stderr,
        }

    def stop(self):
        proc = self.proc
        self.proc = None
        if proc is None:
            return
        try:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(5)
                except Exception:
                    proc.kill()
        except Exception:
            pass

_rea = ReaProxy()
atexit.register(_rea.stop)

def rea_tool_name(original):
    return REA_PREFIX + original

def build_tools():
    """原生工具 + REA 全部工具（前缀 rea__）+ 状态探针。"""
    tools = list(TOOLS)
    for t in _rea.list_tools():
        name = t.get("name")
        if not name:
            continue
        nt = dict(t)
        nt["name"] = rea_tool_name(name)
        desc = t.get("description") or ""
        nt["description"] = "[REA 逆向] " + desc
        tools.append(nt)
    tools.append(REA_STATUS_TOOL)
    return tools

def rea_tools_call(msg_id, params):
    name = params.get("name") or ""
    real = name[len(REA_PREFIX):]
    args = params.get("arguments") or {}
    resp = _rea.call_tool(real, args)
    if resp is None:
        return {"jsonrpc": "2.0", "id": msg_id, "result": {
            "content": [{"type": "text", "text": "REA 子进程已退出，请重试或调用 rea_status 检查"}],
            "isError": True}}
    if "error" in resp:
        return {"jsonrpc": "2.0", "id": msg_id, "error": resp["error"]}
    return {"jsonrpc": "2.0", "id": msg_id, "result": resp.get("result") or {"content": [], "isError": False}}

def rea_status_text():
    st = _rea.status()
    lines = ["== REA 逆向引擎 =="]
    lines.append("状态: %s" % ("就绪" if st["available"] else "不可用"))
    si = st.get("server") or {}
    if si:
        lines.append("服务: %s %s" % (si.get("name"), si.get("version")))
    lines.append("可执行文件: %s" % (st.get("executable") or "未找到"))
    lines.append("工具数: %d" % (st.get("tool_count") or 0))
    if st.get("error"):
        lines.append("错误: %s" % st["error"])
    if st.get("stderr_tail"):
        lines.append("stderr: %s" % st["stderr_tail"])
    lines.append("提示: 调用以 rea__ 开头的工具即可使用逆向能力（如 rea__inspect_model_artifact）。")
    return "\n".join(lines)

REA_STATUS_TOOL = {
    "name": "rea_status",
    "description": "查询调度中心内置 REA（Reverse Engineer Anything）逆向引擎的状态：是否就绪、版本、可用工具数、Ghidra 提供者与错误信息。",
    "inputSchema": {"type": "object", "properties": {}},
}

# ---------- 工具实现 ----------
def tool_power_request(args):
    pid = args.get("pid")
    name = args.get("name")
    if not pid and not name:
        return "ERROR: 缺少申请目标（需 pid 或 name）"
    level = args.get("level", "gentle")
    if level not in ("gentle", "aggressive", "godmode"):
        return "ERROR: level 仅支持 gentle/aggressive/godmode"
    duration = int(args.get("duration", 300) or 300)
    reason = str(args.get("reason", "") or "")
    cmd = {"action": "request_power", "level": level, "duration": max(30, duration), "reason": reason}
    if pid: cmd["pid"] = int(pid)
    else:   cmd["process_name"] = name
    ok, text = bus_call(cmd)
    return text

def tool_power_release(args):
    ok, text = bus_call({"action": "release_power"})
    return text

def tool_power_status(args):
    ok, text = bus_call({"action": "status"})
    status = read_json(os.path.join(CMD_OUT, "status.json")) or {}
    rules = read_json(os.path.join(KERNEL_DIR, "rules_state.json")) or {}
    lines = []
    lines.append("== 调度中心状态 ==")
    if status:
        lines.append("时间: %s" % status.get("time"))
        if status.get("target_name"):
            lines.append("聚焦: %s (PID %s) mode=%s" % (status.get("target_name"), status.get("target_pid"), status.get("focus_mode")))
        pr = status.get("power_request")
        if pr:
            lines.append("算力申请: %s (PID %s) level=%s reason=%s 剩余%s秒 已压%s进程" % (
                pr.get("name"), pr.get("pid"), pr.get("level"), pr.get("reason"), pr.get("remaining_sec"), pr.get("demoted_count")))
        else:
            lines.append("算力申请: 无")
        lines.append("电源: %s" % (status.get("power_plan") or ""))
        lines.append("Top CPU:")
        for r in (status.get("top_cpu") or [])[:5]:
            lines.append("  - %s (PID %s) CPU%s%% 内存%sMB" % (r.get("name"), r.get("pid"), r.get("cpu_pct"), r.get("mem_mb")))
    if rules:
        lines.append("规则引擎: %s | 活动规则 %s | 前台 PID %s" % (
            "运行中" if rules.get("running") else "已停止",
            len(rules.get("rules_active") or []),
            rules.get("foreground_pid")))
    return "\n".join(lines)

def tool_power_list_requests(args):
    ok, text = bus_call({"action": "list_requests"})
    return text

def tool_rules_list(args):
    ok, text = bus_call({"action": "list_rules"})
    return text

def tool_rules_start(args):
    ok, text = bus_call({"action": "start_rules"})
    return text

def tool_rules_stop(args):
    ok, text = bus_call({"action": "stop_rules"})
    return text

def tool_focus(args):
    pid = args.get("pid")
    name = args.get("name")
    if not pid and not name:
        return "ERROR: 缺少聚焦目标（需 pid 或 name）"
    mode = args.get("mode", "aggressive")
    if mode not in ("gentle", "aggressive", "godmode"):
        return "ERROR: mode 仅支持 gentle/aggressive/godmode"
    cmd = {"action": "focus", "mode": mode}
    if pid: cmd["pid"] = int(pid)
    else:   cmd["process_name"] = name
    ok, text = bus_call(cmd)
    return text

def tool_unfocus(args):
    ok, text = bus_call({"action": "unfocus"})
    return text

# ---------- v3：模型路由 / 档位加速（需 POWERFOCUS_BUS=v3 且 v3 在运行） ----------
def tool_router_start(args):
    cmd = {"action": "start_router"}
    if args.get("model"): cmd["model"] = str(args["model"])
    if args.get("port"): cmd["port"] = int(args["port"])
    t = int(args.get("timeout_sec", 60) or 60)
    cmd["timeout_sec"] = t
    ok, text = bus_call(cmd, timeout=t + 45)
    return text

def tool_router_stop(args):
    return bus_call({"action": "stop_router"}, timeout=30)[1]

def tool_router_status(args):
    cmd = {"action": "router_status"}
    if args.get("port"): cmd["port"] = int(args["port"])
    return bus_call(cmd, timeout=30)[1]

def tool_list_model_profiles(args):
    return bus_call({"action": "list_model_profiles"}, timeout=30)[1]

def tool_boost_model(args):
    if not args.get("model"):
        return "ERROR: 缺少 model（gguf 路径或 models-preset.ini 中的模型名）"
    cmd = {"action": "boost_model", "model": str(args["model"])}
    if args.get("profile"): cmd["profile"] = str(args["profile"])
    if args.get("ctx"): cmd["ctx"] = int(args["ctx"])
    if args.get("ngl"): cmd["ngl"] = int(args["ngl"])
    apply = bool(args.get("apply"))
    cmd["apply"] = apply
    ok, text = bus_call(cmd, timeout=180 if apply else 60)
    return text

def tool_list_apps(args):
    """只读：列出当前非系统关键进程（可申请/可聚焦的候选）。"""
    try:
        import subprocess
        ps = subprocess.run(
            ["pwsh", "-NoProfile", "-Command",
             "Get-Process | Where-Object { $_.Id -ne $PID } | Select-Object -First 60 @{n='N';e={$_.ProcessName}},Id,@{n='M';e={[int]($_.WorkingSet64/1MB)}} | ConvertTo-Json -Compress"],
            capture_output=True, text=True, encoding="utf-8", timeout=15)
        data = json.loads(ps.stdout) if ps.stdout.strip() else []
        if isinstance(data, dict): data = [data]
        if not data: return "无可申请进程或枚举失败"
        lines = ["可申请算力的进程（PID 名 内存MB）:"]
        for d in data:
            lines.append("  %s  %s  %sMB" % (d.get("Id"), d.get("N"), d.get("M")))
        return "\n".join(lines[:62])
    except Exception as e:
        return "进程枚举失败: %s" % e

TOOLS = [
    {
        "name": "power_request",
        "description": "应用/游戏缺算力时向调度中心申请算力：调度中心会压低其他应用并把算力补给给申请者（DeepSeek/系统关键/授权/前台进程不受影响）。支持 name 或 pid。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "申请进程名（如 notepad、game.exe）"},
                "pid": {"type": "integer", "description": "申请进程 PID（与 name 二选一）"},
                "level": {"type": "string", "enum": ["gentle", "aggressive", "godmode"], "description": "补给强度：gentle=AboveNormal+压其他为BelowNormal；aggressive=High+压其他为Idle；godmode=High+提升IO+压其他"},
                "duration": {"type": "integer", "description": "持续秒数（默认300，超时自动释放）"},
                "reason": {"type": "string", "description": "申请原因（如 游戏缺帧）"}
            }
        }
    },
    {
        "name": "power_release",
        "description": "释放当前算力申请，还原申请者与所有被压低进程的原始优先级。",
        "inputSchema": {"type": "object", "properties": {}}
    },
    {
        "name": "power_status",
        "description": "查询调度中心实时状态：聚焦目标、算力申请、电源方案、Top CPU、规则引擎。",
        "inputSchema": {"type": "object", "properties": {}}
    },
    {
        "name": "power_list_requests",
        "description": "查询当前算力申请详情（申请者、剩余秒数、被压低进程数）。",
        "inputSchema": {"type": "object", "properties": {}}
    },
    {
        "name": "rules_list",
        "description": "列出规则引擎的规则清单（含启用状态）。",
        "inputSchema": {"type": "object", "properties": {}}
    },
    {
        "name": "rules_start",
        "description": "启动规则引擎（条件自动化：后台高CPU自动压制、推理自动GodMode）。",
        "inputSchema": {"type": "object", "properties": {}}
    },
    {
        "name": "rules_stop",
        "description": "停止规则引擎并还原全部规则状态。",
        "inputSchema": {"type": "object", "properties": {}}
    },
    {
        "name": "focus",
        "description": "显式聚焦一个进程（GodMode/激进/温和），其余进程自动让路。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string"},
                "pid": {"type": "integer"},
                "mode": {"type": "string", "enum": ["gentle", "aggressive", "godmode"]}
            }
        }
    },
    {
        "name": "unfocus",
        "description": "取消当前聚焦并还原所有进程优先级。",
        "inputSchema": {"type": "object", "properties": {}}
    },
    {
        "name": "list_apps",
        "description": "只读列出当前可申请算力的进程（PID + 名 + 内存）。",
        "inputSchema": {"type": "object", "properties": {}}
    },
    {
        "name": "router_start",
        "description": "启动本地模型路由服务（llama-server router 模式，读 v3\\models-preset.ini，OpenAI 兼容 /v1）。默认端口 8080，--models-max 1 保证 8GB 显存一次只驻留一个模型。需 v3 调度中心在运行且 POWERFOCUS_BUS=v3。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "model": {"type": "string", "description": "只加载指定模型（preset 中的 section 名，如 Qwen3-4B）；省略则用完整 preset"},
                "port": {"type": "integer", "description": "监听端口，默认 8080"},
                "timeout_sec": {"type": "integer", "description": "/health 等待秒数，默认 60"}
            }
        }
    },
    {
        "name": "router_stop",
        "description": "停止调度中心启动的模型路由服务（只停自己启动的进程，不动其他 llama-server）。",
        "inputSchema": {"type": "object", "properties": {}}
    },
    {
        "name": "router_status",
        "description": "查询模型路由状态：是否运行、PID、端口、health、已加载模型、显存占用。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "port": {"type": "integer", "description": "查询端口，默认 8080"}
            }
        }
    },
    {
        "name": "list_model_profiles",
        "description": "列出模型注册表：每个模型的身份（arch/层数/大小）与全部实测档位（ngl/fa/ctx/tps/显存余量）。",
        "inputSchema": {"type": "object", "properties": {}}
    },
    {
        "name": "boost_model",
        "description": "按 model-profiles.json 的实测档位加速指定模型。默认 dry-run 只输出计划；apply=true 才重启服务，失败自动按回滚记录还原。模型未命中档案时拒绝执行（硬约束）。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "model": {"type": "string", "description": "gguf 路径，或 models-preset.ini 中的模型名"},
                "profile": {"type": "string", "description": "档位名（如 speed_8k / safe_8k / long_64k_safe）；省略则按显存与上下文自动选"},
                "ctx": {"type": "integer", "description": "覆盖上下文长度（影响档位选择）"},
                "ngl": {"type": "integer", "description": "覆盖 GPU 层数"},
                "apply": {"type": "boolean", "description": "true 才真正重启服务；默认 false 仅 dry-run"}
            },
            "required": ["model"]
        }
    }
]

HANDLERS = {
    "power_request": tool_power_request,
    "power_release": tool_power_release,
    "power_status": tool_power_status,
    "power_list_requests": tool_power_list_requests,
    "rules_list": tool_rules_list,
    "rules_start": tool_rules_start,
    "rules_stop": tool_rules_stop,
    "focus": tool_focus,
    "unfocus": tool_unfocus,
    "list_apps": tool_list_apps,
    "router_start": tool_router_start,
    "router_stop": tool_router_stop,
    "router_status": tool_router_status,
    "list_model_profiles": tool_list_model_profiles,
    "boost_model": tool_boost_model,
}

# ---------- JSON-RPC 分发 ----------
_initialized = False

def handle(msg):
    global _initialized
    if not isinstance(msg, dict) or "jsonrpc" not in msg:
        return None
    method = msg.get("method")
    msg_id = msg.get("id")
    # 通知（无 id）不响应
    if msg_id is None:
        return None
    if method == "initialize":
        _initialized = True
        req_pv = (msg.get("params") or {}).get("protocolVersion")
        pv = req_pv if req_pv in SUPPORTED_PROTOCOLS else PROTOCOL_VERSION
        return {"jsonrpc": "2.0", "id": msg_id, "result": {
            "protocolVersion": pv,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
            "instructions": "电脑算力调度中心。原生工具负责算力调度；rea__ 开头的工具是内置 REA 逆向引擎（229 项，含 Ghidra 反编译、GGUF/safetensors 模型解析、Electron/JS 静态分析），任何连接本服务的 AI 都可直接调用。"
        }}
    if not _initialized:
        return {"jsonrpc": "2.0", "id": msg_id, "error": {"code": -32000, "message": "Server not initialized"}}
    if method == "ping":
        return {"jsonrpc": "2.0", "id": msg_id, "result": {}}
    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": msg_id, "result": {"tools": build_tools()}}
    if method == "tools/call":
        params = msg.get("params") or {}
        name = params.get("name")
        args = params.get("arguments") or {}
        if name == "rea_status":
            return {"jsonrpc": "2.0", "id": msg_id, "result": {
                "content": [{"type": "text", "text": rea_status_text()}], "isError": False}}
        if name and name.startswith(REA_PREFIX):
            return rea_tools_call(msg_id, params)
        handler = HANDLERS.get(name)
        if not handler:
            return {"jsonrpc": "2.0", "id": msg_id, "error": {"code": -32602, "message": "Unknown tool: %s" % name}}
        try:
            text = handler(args)
            return {"jsonrpc": "2.0", "id": msg_id, "result": {
                "content": [{"type": "text", "text": text}],
                "isError": text.startswith("ERROR:") or text.startswith("命令总线超时")
            }}
        except Exception as e:
            return {"jsonrpc": "2.0", "id": msg_id, "result": {
                "content": [{"type": "text", "text": "工具执行异常: %s" % e}], "isError": True
            }}
    if method.startswith("notifications/"):
        return None
    return {"jsonrpc": "2.0", "id": msg_id, "error": {"code": -32601, "message": "Method not found: %s" % method}}

def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except Exception:
            continue
        resp = handle(msg)
        if resp is not None:
            emit(resp)

if __name__ == "__main__":
    main()
