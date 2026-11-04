# -*- coding: utf-8 -*-
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
import sys, os, json, time, re, uuid

POWERFOCUS = r"E:\PowerFocus"
CMD_IN  = os.path.join(POWERFOCUS, "commands", "in")
CMD_OUT = os.path.join(POWERFOCUS, "commands", "out")
CMD_DONE= os.path.join(POWERFOCUS, "commands", "done")

SERVER_NAME = "powerfocus-mcp"
SERVER_VERSION = "1.0.0"
PROTOCOL_VERSION = "2024-11-05"

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
        return False, "命令总线超时（v2 未响应 %s 秒）：请确认调度中心 v2 正在运行" % int(timeout)
    except Exception as e:
        return False, "命令总线调用异常: %s" % e

def read_json(path):
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            return json.load(f)
    except Exception:
        return None

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
    rules = read_json(os.path.join(POWERFOCUS, "rules_state.json")) or {}
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

def tool_list_apps(args):
    """只读：列出当前非系统关键进程（可申请/可聚焦的候选）。"""
    try:
        import subprocess
        ps = subprocess.run(
            ["powershell", "-NoProfile", "-Command",
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
        return {"jsonrpc": "2.0", "id": msg_id, "result": {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION}
        }}
    if not _initialized:
        return {"jsonrpc": "2.0", "id": msg_id, "error": {"code": -32000, "message": "Server not initialized"}}
    if method == "ping":
        return {"jsonrpc": "2.0", "id": msg_id, "result": {}}
    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": msg_id, "result": {"tools": TOOLS}}
    if method == "tools/call":
        params = msg.get("params") or {}
        name = params.get("name")
        args = params.get("arguments") or {}
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
