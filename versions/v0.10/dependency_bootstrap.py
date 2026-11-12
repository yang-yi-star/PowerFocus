# -*- coding: utf-8 -*-
"""
电脑算力调度中心 V0.10 · 启动依赖自检 / 用户同意后补齐
==========================================================

产品模型（2026-11-13 用户纠正后确认，不要写成别的意思）：
    应用「开头」自己检查它要用到的组件是否安装齐全 —— 卡巴斯基、Node
    以及后续任何新增组件，都是同一张清单里的一项。缺什么先列给用户看，
    用户同意之后，**由应用自己的进程**从官方源下载、校验、落到应用目录。
    这里不需要对话里的 AI 参与，也不在客户机系统层面安装任何东西。

    换句话说：产品「提供安装能力」，不是「随安装包预置第三方软件」，
    更不是「让外部工具替应用装」。

六条硬边界（全部写成代码约束，不是口头约定）：
  1. 默认只读。startup_check() / --check 不下载、不安装、不写系统目录、
     不改注册表、不注册服务或计划任务、不写任何文件。
  2. 显式同意。install() 必须由设置页在用户点击「同意下载」后传入
     CONSENT_TOKEN；模块自身永远不替用户同意，也不在启动时静默触发。
  3. 只落应用目录。download_to_app 只写 versions/v0.10/engines/，
     绝不写 Program Files；guided 项连下载都不做，只给官方入口。
  4. 先验签后可用。复用 kvrt_bundle.verify() / save_state()，校验不过
     一律标记不可用；未通过的文件只改名留档，不删除。
  5. 不随包预置。任何第三方二进制都不进安装包、不进 git 仓库
     （.gitignore 已排除 engines/ 与 reports/）。
  6. 缺能力不阻塞启动。required=False 的项只提示，不阻断主流程；
     required=True 的项由应用自己内嵌，正常情况下不会缺。

复用现有接口（不另造一套下载/验签/识别实现）：
  kvrt_bundle.status / download / verify / save_state
  engine_adapters.probe_all
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

ROOT = Path(__file__).resolve().parent
REPORT_DIR = ROOT / "reports"
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import kvrt_bundle  # noqa: E402  （必须先补 sys.path）

# 必须由 UI 在用户明确点击「同意下载」之后传入。
# 用字符串令牌而不是 True，避免调用方随手写个默认值就把下载放出去。
CONSENT_TOKEN = "USER_APPROVED_DOWNLOAD"


# ---------------------------------------------------------------------------
# 统一的组件描述
# ---------------------------------------------------------------------------

@dataclass
class Component:
    id: str
    name: str
    category: str                      # runtime / capability / devtool / detected
    required: bool                     # 缺失是否阻塞启动
    install_mode: str                  # bundled / download_to_app / guided / detect_only
    checker: Callable[[], Dict[str, Any]]
    source_url: str = ""
    official_page: str = ""
    target_dir: str = ""               # 允许写入的位置，空表示不写入
    license_note: str = ""
    note: str = ""


def _state(present: bool, ready: bool = False, version: str = "",
           path: str = "", detail: str = "") -> Dict[str, Any]:
    return {"present": present, "ready": ready, "version": version,
            "path": path, "detail": detail}


def _probe_executable(name: str, version_args: List[str]) -> Dict[str, Any]:
    """只做只读探测：找到可执行文件并读版本，不产生任何副作用。"""
    exe = shutil.which(name)
    if not exe:
        return _state(False, detail="未在 PATH 中找到 %s" % name)
    ver = ""
    try:
        r = subprocess.run([exe] + version_args, capture_output=True, timeout=20)
        ver = (r.stdout or r.stderr or b"").decode("utf-8", "replace").strip()[:60]
    except Exception as e:
        return _state(True, False, path=exe, detail="可执行但读取版本失败: %s" % type(e).__name__)
    return _state(True, True, version=ver, path=exe, detail="可执行")


def _check_python() -> Dict[str, Any]:
    return _state(True, True, version=sys.version.split()[0], path=sys.executable,
                  detail="应用主进程运行时；正式打包时由 PyInstaller 内嵌")


def _check_kvrt() -> Dict[str, Any]:
    """复用 kvrt_bundle.status()，不重新实现文件/验签判断。"""
    st = kvrt_bundle.status()
    present = bool(st.get("present"))
    ready = bool(st.get("ready"))
    sig = st.get("signature") or {}
    detail = ("已下载且验签通过，可直接扫描" if ready else
              ("已下载但尚无有效验签记录，需执行验签" if present else
               "应用目录内没有引擎文件"))
    return _state(present, ready, version=str(sig.get("file_version") or ""),
                  path=str(st.get("path") or ""), detail=detail)


def _check_browser() -> Dict[str, Any]:
    cands = [
        os.path.join(os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)"),
                     "Microsoft", "Edge", "Application", "msedge.exe"),
        os.path.join(os.environ.get("ProgramFiles", r"C:\Program Files"),
                     "Microsoft", "Edge", "Application", "msedge.exe"),
        os.path.join(os.environ.get("ProgramFiles", r"C:\Program Files"),
                     "Google", "Chrome", "Application", "chrome.exe"),
    ]
    for c in cands:
        if os.path.isfile(c):
            return _state(True, True, path=c, detail="可用于显示应用内页面")
    return _state(False, detail="未发现 Edge / Chrome，页面可能无法自动打开")


def _check_kaspersky_full() -> Dict[str, Any]:
    """只读目录探测：判断客户机是否已经装了卡巴斯基完整版。"""
    bases = [os.environ.get("ProgramFiles", r"C:\Program Files"),
             os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)"),
             os.environ.get("ProgramData", r"C:\ProgramData")]
    hits = []
    for b in bases:
        try:
            hits += [p for p in Path(b).glob("Kaspersky Lab*/**/avp.exe")][:1]
        except (OSError, TypeError):
            pass
    if hits:
        return _state(True, True, path=str(hits[0]), detail="检测到完整版安装")
    return _state(False, detail="未检测到完整版安装（目录探测，非权威）")


def _check_security_products() -> Dict[str, Any]:
    """复用 engine_adapters.probe_all()：识别客户机已装安全软件及其可调用性。"""
    try:
        import engine_adapters
        p = engine_adapters.probe_all()
        n = len(p.get("wmi_products") or [])
        a = int(p.get("available_count") or 0)
        detail = ("安全中心登记 %d 项，其中 %d 项可调用；%s"
                  % (n, a, p.get("note") or ""))
        return _state(n > 0, a > 0, detail=detail)
    except Exception as e:
        return _state(False, detail="识别失败（不影响启动）: %s: %s" % (type(e).__name__, e))


# ---------------------------------------------------------------------------
# 声明式清单：新增组件只需在这里加一行，不必改自检/下载/审计逻辑
# ---------------------------------------------------------------------------

COMPONENTS: List[Component] = [
    Component(
        id="python_runtime", name="Python 运行时", category="runtime",
        required=True, install_mode="bundled", checker=_check_python,
        note="随应用内嵌，客户机无需自行安装；缺失即说明安装包不完整。",
    ),
    Component(
        id="kvrt_engine", name="卡巴斯基免费病毒清除工具 KVRT", category="capability",
        required=False, install_mode="download_to_app", checker=_check_kvrt,
        source_url=kvrt_bundle.KVRT_URL,
        official_page=kvrt_bundle.OFFICIAL_PAGE,
        target_dir=str(kvrt_bundle.ENGINE_DIR),
        license_note=("KVRT 是免费专有软件（EULA 9.1: proprietary），不是开源软件。"
                      "用户同意后由应用从官方源即时下载，不随安装包预置、不进仓库；"
                      "EULA 2.2 允许复制分发，5.4 限制与商业第三方软件配合分发，"
                      "5.3 禁止用其创建检测/处置数据或软件，9.1 限制商标使用。"),
        note=("免安装绿色工具，下载到应用目录即用，不写系统驱动、不与已有杀软冲突。"
              "这是「应用内自带扫描能力」的默认实现。"),
    ),
    Component(
        id="kaspersky_free", name="卡巴斯基完整版（免费版）", category="capability",
        required=False, install_mode="guided", checker=_check_kaspersky_full,
        official_page="https://www.kaspersky.com/free-antivirus",
        license_note="厂商专有免费软件，非开源；安装会写入系统驱动与服务。",
        note=("完整版属于「在客户机系统层面安装杀毒软件」，可能与已有防护冲突。"
              "应用不静默安装，只在用户主动要求时提供官方下载入口。"),
    ),
    Component(
        id="nodejs", name="Node.js（含 npm）", category="devtool",
        required=False, install_mode="guided", checker=lambda: _probe_executable("node", ["-v"]),
        official_page="https://nodejs.org/",
        note=("当前前端是零依赖单文件 HTML，Node 并不是客户机运行时依赖，"
              "只用于开发期的构建与验证。因此不自动下载安装，避免逼客户装用不到的东西。"),
    ),
    Component(
        id="git", name="Git", category="devtool",
        required=False, install_mode="guided", checker=lambda: _probe_executable("git", ["--version"]),
        official_page="https://git-scm.com/downloads",
        note="仅开发/源码协作需要，客户机运行不依赖。",
    ),
    Component(
        id="browser", name="Edge / Chrome 浏览器", category="runtime",
        required=False, install_mode="guided", checker=_check_browser,
        official_page="https://www.microsoft.com/edge",
        note="用于显示应用内网页；缺失时给出提示，不自动安装浏览器。",
    ),
    Component(
        id="installed_security", name="客户机已装安全软件", category="detected",
        required=False, install_mode="detect_only", checker=_check_security_products,
        note="只读识别，不安装、不启用、不改服务状态；识别不等于可调用。",
    ),
]


# ---------------------------------------------------------------------------
# 自检（只读）
# ---------------------------------------------------------------------------

def _action(c: Component, s: Dict[str, Any]) -> str:
    if s.get("present"):
        return "无需处理" if s.get("ready") else "存在但不可用：需验签或查看原因"
    return {
        "download_to_app": "可经用户同意后从官方源下载到应用目录",
        "guided": "不自动安装，仅提供官方下载入口",
        "detect_only": "仅识别，不安装",
        "bundled": "随应用内嵌，异常需重装应用",
    }.get(c.install_mode, "未提供处理方式")


def check_all() -> Dict[str, Any]:
    """应用启动时调用：完整自检，只读，绝不触发下载或安装。"""
    items: List[Dict[str, Any]] = []
    for c in COMPONENTS:
        try:
            s = c.checker()
        except Exception as e:
            s = _state(False, detail="自检异常: %s: %s" % (type(e).__name__, e))
        items.append({
            "id": c.id, "name": c.name, "category": c.category,
            "required": c.required, "install_mode": c.install_mode,
            **s,
            "action": _action(c, s),
            "source_url": c.source_url, "official_page": c.official_page,
            "target_dir": c.target_dir, "license_note": c.license_note,
            "note": c.note,
        })
    missing = [x for x in items if not x["present"]]
    not_ready = [x for x in items if x["present"] and not x["ready"]]
    return {
        "checked_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "app_dir": str(ROOT),
        "summary": {
            "total": len(items),
            "present": len(items) - len(missing),
            "missing": len(missing),
            "not_ready": len(not_ready),
            "blocking": sum(1 for x in missing if x["required"]),
            "auto_installable_missing": sum(
                1 for x in missing if x["install_mode"] == "download_to_app"),
        },
        "components": items,
        "policy": {
            "consent_required": True,
            "consent_token": CONSENT_TOKEN,
            "writes_outside_app_dir": False,
            "silent_install": False,
            "bundles_third_party_binaries": False,
            "verify_before_enable": True,
            "startup_blocked_by_optional": False,
        },
    }


def startup_check() -> Dict[str, Any]:
    """给应用主进程的入口：一次调用拿到「能不能继续启动」和自检报告。"""
    report = check_all()
    report["startup_ok"] = report["summary"]["blocking"] == 0
    report["startup_note"] = (
        "必需组件齐全，可直接启动；可选能力缺失项交由设置页提示用户"
        if report["startup_ok"] else
        "存在必需组件缺失，需重装应用或修复安装包")
    return report


def plan() -> Dict[str, Any]:
    """给设置页用：只列需要用户决策的项，不执行任何动作。"""
    report = check_all()
    pending = [x for x in report["components"]
               if not x["present"] or not x["ready"]]
    return {
        "checked_at": report["checked_at"],
        "pending_count": len(pending),
        "auto_downloadable": [x["id"] for x in pending
                              if x["install_mode"] == "download_to_app"],
        "manual_only": [x["id"] for x in pending
                        if x["install_mode"] != "download_to_app"],
        "pending": [{k: x[k] for k in
                     ("id", "name", "category", "required", "install_mode",
                      "present", "ready", "detail", "action", "official_page",
                      "target_dir", "license_note", "note")}
                    for x in pending],
        "note": "本清单只是建议动作；任何下载必须等用户同意后再调用 install()。",
    }


# ---------------------------------------------------------------------------
# 补齐（必须显式同意）
# ---------------------------------------------------------------------------

def _audit(record: Dict[str, Any]) -> str:
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    p = REPORT_DIR / ("bootstrap-" + datetime.now().strftime("%Y%m%d-%H%M%S") + ".json")
    p.write_text(json.dumps(record, ensure_ascii=False, indent=2), encoding="utf-8")
    return str(p)


def install(component_id: str, consent: str = "", force: bool = False) -> Dict[str, Any]:
    """
    用户同意后由应用进程自己补齐组件。

    consent 必须严格等于 CONSENT_TOKEN；空值、布尔 True、随手写的值一律拒绝。
    目前只有 kvrt_engine 属于 download_to_app；其余组件不提供静默安装。
    """
    c = next((x for x in COMPONENTS if x.id == component_id), None)
    record: Dict[str, Any] = {
        "at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "component_id": component_id, "executed": False, "force": force,
    }
    if c is None:
        record["reason"] = "清单中不存在该组件"
        _audit(record)
        return record
    if consent != CONSENT_TOKEN:
        record["reason"] = "缺少用户显式同意，拒绝下载/安装"
        record["consent_received"] = bool(consent)
        _audit(record)
        return record
    record["consent"] = "verified"

    if c.install_mode != "download_to_app":
        record["reason"] = "该组件不提供应用内自动下载（不写系统、不静默安装）"
        record["official_page"] = c.official_page
        record["install_mode"] = c.install_mode
        _audit(record)
        return record

    before = c.checker()
    if before.get("ready") and not force:
        record["reason"] = "组件已齐全且验签通过，无需重复下载"
        record["path"] = before.get("path")
        _audit(record)
        return record

    try:
        dl = kvrt_bundle.download(force=force)
        record["download"] = dl
    except Exception as e:
        record["reason"] = "下载失败: %s: %s" % (type(e).__name__, e)
        record["retryable"] = True
        _audit(record)
        return record

    try:
        v = kvrt_bundle.verify()
    except Exception as e:
        v = {"ok": False, "reason": "验签异常: %s: %s" % (type(e).__name__, e)}
    record["verify"] = v

    if not v.get("ok"):
        # 不删除文件，改名留档供人工复核；不写入有效状态，绝不启用。
        exe = kvrt_bundle.ENGINE_EXE
        if exe.is_file():
            archived = exe.with_suffix(
                ".exe.unverified-" + datetime.now().strftime("%Y%m%d-%H%M%S"))
            try:
                exe.rename(archived)
                record["quarantined"] = str(archived)
            except OSError as e:
                record["quarantine_error"] = str(e)
        record["reason"] = "下载件未通过官方签名链/厂商标识校验，禁止启用"
        record["retryable"] = True
        _audit(record)
        return record

    kvrt_bundle.save_state(v)
    record["executed"] = True
    record["ready"] = True
    record["path"] = str(kvrt_bundle.ENGINE_EXE)
    record["target_dir"] = c.target_dir
    record["source_url"] = c.source_url
    record["audit_file"] = _audit(record)
    return record


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(
        description="V0.10 启动依赖自检 / 用户同意后补齐（默认只读）")
    ap.add_argument("--check", action="store_true", help="完整自检（默认动作，只读）")
    ap.add_argument("--plan", action="store_true", help="只列待办建议，不执行")
    ap.add_argument("--list", action="store_true", help="列出组件清单")
    ap.add_argument("--install", metavar="ID", default="", help="补齐指定组件")
    ap.add_argument("--consent", default="",
                    help="UI 在用户点击同意后传入 %s" % CONSENT_TOKEN)
    ap.add_argument("--force", action="store_true", help="配合 --install 强制重下")
    args = ap.parse_args(argv)

    if args.list:
        print(json.dumps([{k: getattr(c, k) for k in
                           ("id", "name", "category", "required", "install_mode",
                            "source_url", "official_page", "target_dir", "note")}
                          for c in COMPONENTS], ensure_ascii=False, indent=2))
        return 0

    if args.install:
        out = install(args.install, args.consent, args.force)
        print(json.dumps(out, ensure_ascii=False, indent=2))
        return 0 if (out.get("executed") or out.get("reason", "").startswith("组件已齐全")) else 2

    if args.plan:
        print(json.dumps(plan(), ensure_ascii=False, indent=2))
        return 0

    print(json.dumps(startup_check(), ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
