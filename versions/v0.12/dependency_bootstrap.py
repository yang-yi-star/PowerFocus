# -*- coding: utf-8 -*-
"""
电脑算力调度中心 · 启动依赖自检 / 用户同意后补齐
==========================================================

产品模型（2026-11-13 用户纠正后确认，不要写成别的意思）：
    应用「开头」自己检查它要用到的组件是否安装齐全 —— 卡巴斯基、Node
    以及后续任何新增组件，都是同一张清单里的一项。缺什么先列给用户看，
    用户同意之后，**由应用自己的进程**从官方源下载、校验、落到应用目录。
    这里不需要对话里的 AI 参与，也不在客户机系统层面安装任何东西。

    换句话说：产品「提供安装能力」，不是「随安装包预置第三方软件」，
    更不是「让外部工具替应用装」。

七条硬边界（全部写成代码约束，不是口头约定）：
  1. 默认只读。startup_check() / --check 不下载、不安装、不写系统目录、
     不改注册表、不注册服务或计划任务、不写任何文件。
  2. 显式同意。install() 必须由设置页在用户点击「同意下载」后传入
     CONSENT_TOKEN；模块自身永远不替用户同意，也不在启动时静默触发。
  3. 只落应用目录。download_to_app / on_demand 只写 versions/<当前内核版本>/engines/，
     绝不写 Program Files 或系统 PATH；guided 项连下载都不做，只给官方入口。
  4. 系统级安装是**唯一且受限的例外**（2026-11-13 用户指定「要个人能使用的完整版」）：
     kaspersky_free 属于 vendor_installer —— 应用只负责下载官方在线安装器到
     应用目录并验签；真正写系统驱动/服务这一步，必须由用户本人在厂商
     交互式向导里完成。应用不传 /s，不代填 /mybirthdate，不代接受
     AGREETOEULA / AGREETOPRIVACYPOLICY / JOINKSN_*，而且需要**第二道**令牌
     INSTALL_CONSENT_TOKEN 才允许启动向导。详见 policy.system_level_install。
  5. 先验签后可用。KVRT 复用 kvrt_bundle.verify() / save_state()；
     厂商安装器走通用 Authenticode 校验（签名链 + 签名者 + 产品名）。
     校验不过一律标记不可用；未通过的文件只改名留档，不删除。
  6. 不随包预置。任何第三方二进制都不进安装包、不进 git 仓库
     （.gitignore 已排除 engines/ 与 reports/）。
  7. 缺能力不阻塞启动。required=False 的项只提示，不阻断主流程；
     required=True 的项由应用自己内嵌，正常情况下不会缺。

通用制品（2026-11-13 扩展）：AcquireSpec 声明官方 URL、校验清单、锁定哈希与
    解包后的可执行路径，共用 acquire_zip() 的「下载 -> 官方校验 -> 安全解包 ->
    二次探测 -> 写状态」流程。以后新增 Node 一类组件只需加一行声明，不改流程。
    依据 2026-11-13 逐条查证的通行做法：Microsoft Learn bootstrapping（安装前
    检测必备组件并从厂商站点下载）、WiX Burn NetFx45Web（remote payload 按需
    下载 + 本地 payload 离线）、Node Corepack（packageManager 锁版本 + 哈希 +
    offline workflow）、Astral uv（自动下载缺失 Python 到用户目录、不写系统、
    不需管理员）、VS Code Remote-SSH（首次连接自动装 Server、失败回退本地传输）。

复用现有接口（不另造一套下载/验签/识别实现）：
  kvrt_bundle.status / download / verify / save_state / winverifytrust /
                      pe_version_info / authenticode_signer_hint / sha256_file
  engine_adapters.probe_all

卡巴完整版官方依据（2026-11-13 逐条查证，写死在代码里以免以后凭印象改）：
  * 产品形态：support.kaspersky.com/help/Kaspersky Free/Win21.24/zh-Hans/101565.htm
    「卡巴斯基免费版是卡巴斯基应用程式的有限免费版」—— 有实时文件防护/邮件
    防护/安全浏览/反钓鱼/系统监控，需连接 My Kaspersky 账号激活才工作。
    这与 KVRT（免安装绿色扫描工具、无实时防护）是两种东西。
  * 安装参数：support.kaspersky.com/help/Kaspersky Free/Win21.7/zh-Hans/
    all-in-one.htm?sectionUrl=226833.htm —— 默认交互式向导；/s 静默模式需
    /mybirthdate，且 /pAGREETOEULA=1 等参数等于**替用户接受协议**，本应用一律不用。
    安装要求管理员权限、会检查并可能要求卸载不兼容的安全软件、可能要求重启。
  * 官方分发域名：dm.s.kaspersky-labs.com/<locale>/Kaspersky4Win/<版本>/startup.exe
    （在线安装器，约 7 MB，运行后自行下载完整包）。实测 21.24.8.522 已 404、
    21.26.4.406 与 21.27.6.532 均 200，所以必须做候选版本探测 + 失效降级，
    不能把某个版本的 URL 写死当成永久直链。
  * 官方下载入口：https://www.kaspersky.com.cn/downloads#update-product
"""
from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import os
import shutil
import subprocess
import sys
import urllib.request
import zipfile
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

CODE_DIR = Path(__file__).resolve().parent
if str(CODE_DIR) not in sys.path:
    sys.path.insert(0, str(CODE_DIR))
try:
    import app_paths
except ImportError:
    sys.path.insert(0, str(CODE_DIR.parents[1]))
    import app_paths

DATA_ROOT = app_paths.data_root()
REPORT_DIR = DATA_ROOT / "reports"
ROOT = CODE_DIR                 # 兼容旧引用，语义为「代码目录」

import kvrt_bundle  # noqa: E402  （必须先补 sys.path）

# F8：用户同意改为「服务端收到明确意图后签发的一次性 nonce」。
# 旧实现把令牌写成源码常量，还经只读的 /api/bootstrap/check 下发给浏览器，
# 任何能读源码或调接口的人都能白拿；现在令牌不进源码、不进只读响应，
# 绑定 scope、短 TTL、用后即失效。
import secrets as _secrets
import time as _time

_CONSENT_NONCES: Dict[str, tuple] = {}
_CONSENT_TTL = 120.0


def mint_consent(scope: str) -> str:
    """签发一次性同意令牌；只在服务端确认用户已点击同意后调用。"""
    now = _time.time()
    for key, ent in list(_CONSENT_NONCES.items()):
        if ent[1] <= now:
            _CONSENT_NONCES.pop(key, None)
    token = _secrets.token_urlsafe(24)
    _CONSENT_NONCES[token] = (scope, now + _CONSENT_TTL)
    return token


def check_consent(token: str, scope: str) -> bool:
    """消费一次性同意令牌：scope 必须匹配、未过期、且只能用一次。"""
    if not token:
        return False
    ent = _CONSENT_NONCES.pop(token, None)
    return bool(ent and ent[0] == scope and ent[1] > _time.time())

# ---------------------------------------------------------------------------
# 通用「制品」声明：这就是「以后装别的东西也能这么干」的关键。
# 每个可补齐组件只需声明下面几项，共用同一套 下载 -> 校验 -> 解包 -> 二次探测。
# 依据业界通行做法（2026-11-13 逐条查证）：
#   * Microsoft Learn「bootstrapping」：安装前检测必备组件，缺了从厂商站点下载
#   * WiX Burn NetFx45Web：remote payload 按需下载，可选本地 payload 支持离线
#   * Node Corepack：packageManager 锁定版本 + sha224 校验 + offline workflow
#   * Astral uv：自动下载缺失 Python 到用户自有目录，不写系统、不需管理员
#   * VS Code Remote-SSH：首次连接自动装 VS Code Server，远端下载失败回退本地传输
# ---------------------------------------------------------------------------

# Node 官方 LTS 与校验值，2026-11-13 从 nodejs.org/dist/index.json 与
# /dist/v26.13.1/SHASUMS256.txt 实测取得。锁定版本是为了可复现，
# 不跟 Corepack 的 latest 直链那样每次拿到不同二进制。
NODE_LTS_VERSION = "v26.13.1"
NODE_ZIP = "node-%s-win-x64.zip" % NODE_LTS_VERSION
NODE_BASE = "https://nodejs.org/dist/%s/" % NODE_LTS_VERSION
NODE_ZIP_URL = NODE_BASE + NODE_ZIP
NODE_CHECKSUM_URL = NODE_BASE + "SHASUMS256.txt"
NODE_SHA256 = "e2edda75bfb089654705cf65a13b58933bfd5f57148e8ebda916f58a2474f1f7"
NODE_EXE_RELPATH = "node-%s-win-x64/node.exe" % NODE_LTS_VERSION

# 第二道同意：scope="install"，与 scope="download" 完全隔离，
# 保证「下载一个文件」和「在客户机系统层面装杀软」是两个不可合并的决策。

# 卡巴斯基个人完整版（免费层级）在线安装器。
# 候选版本按新 -> 旧排列：厂商会下线旧版本（实测 21.24.8.522 已 404），
# 所以运行时逐个 HEAD 探测，取第一个可达的；全部失败就降级到官方下载页。
KASPERSKY_LOCALE = "zh-Hans-CN"
KASPERSKY_VERSIONS = ["21.27.6.532", "21.26.4.406"]
KASPERSKY_URL_TEMPLATE = (
    "https://dm.s.kaspersky-labs.com/{locale}/Kaspersky4Win/{version}/startup.exe")
KASPERSKY_OFFICIAL_PAGE = "https://www.kaspersky.com.cn/downloads#update-product"
KASPERSKY_HELP = (
    "https://support.kaspersky.com/help/Kaspersky%20Free/Win21.24/zh-Hans/101565.htm")

ENGINE_DIR = DATA_ROOT / "engines"
NODE_DIR = ENGINE_DIR / "Node"
NODE_STATE = NODE_DIR / "artifact.json"
KASPERSKY_DIR = ENGINE_DIR / "KasperskyFull"
KASPERSKY_STATE = KASPERSKY_DIR / "artifact.json"
OFFLINE_DIR = ENGINE_DIR / "_offline"
DOWNLOAD_DIR = ENGINE_DIR / "_downloads"


@dataclass
class AcquireSpec:
    """一个可补齐组件的通用制品声明。"""
    kind: str                          # kvrt_exe / zip_artifact / vendor_installer
    version: str = ""                  # 锁定版本；空表示跟随 latest（不推荐）
    url: str = ""
    checksum_url: str = ""             # 官方校验清单，空表示用 Authenticode 验签
    checksum_filename: str = ""        # 清单里要匹配的文件名
    pinned_sha256: str = ""            # 与官方清单双重比对
    archive_name: str = ""
    exe_relpath: str = ""
    verify_args: List[str] = field(default_factory=list)
    license_note: str = ""
    # vendor_installer 专用：候选版本探测 + 通用 Authenticode 校验
    candidate_versions: List[str] = field(default_factory=list)
    url_template: str = ""
    locale: str = ""
    signer_must_contain: str = ""
    product_must_contain_any: List[str] = field(default_factory=list)


# ---------------------------------------------------------------------------
# 统一的组件描述
# ---------------------------------------------------------------------------

@dataclass
class Component:
    id: str
    name: str
    category: str                      # runtime / capability / devtool / detected
    required: bool                     # 缺失是否阻塞启动
    install_mode: str                  # bundled / download_to_app / on_demand / guided / detect_only / vendor_installer
    checker: Callable[[], Dict[str, Any]]
    source_url: str = ""
    official_page: str = ""
    target_dir: str = ""               # 允许写入的位置，空表示不写入
    license_note: str = ""
    note: str = ""
    acquire: Optional[AcquireSpec] = None
    system_impact: Dict[str, Any] = field(default_factory=dict)


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


def _check_nodejs() -> Dict[str, Any]:
    """优先认应用自己装的 Node；PATH 里的只能算「外部工具链」，不能当成客户机已装。"""
    node_state = app_paths.first_existing("engines/Node/artifact.json")
    if node_state.is_file():
        try:
            st = json.loads(node_state.read_text(encoding="utf-8"))
            exe = Path(str(st.get("exe") or ""))
            if exe.is_file():
                r = subprocess.run([str(exe), "-v"], capture_output=True, timeout=20)
                ver = (r.stdout or b"").decode("utf-8", "replace").strip()[:60]
                return _state(True, True, version=ver, path=str(exe),
                              detail="应用目录内自备（未写入系统 PATH）")
        except (OSError, ValueError, subprocess.SubprocessError):
            pass
    s = _probe_executable("node", ["-v"])
    if s["present"]:
        s["detail"] = "来自系统/外部 PATH，不是应用自备；客户机上未必存在"
    return s


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
    """
    只读探测客户机是否已装卡巴斯基完整版（Free / Standard / Plus / Premium）。

    两条证据都要看：卸载注册表项（权威）+ 安装目录 avp.exe（佐证）。
    纯 Python winreg，不依赖 reg.exe / sc.exe / PowerShell（本机沙箱会拦）。
    注意：KVRT 是免安装绿色工具，不写卸载项，所以不会被这里误判成完整版。
    """
    try:
        import winreg
    except ImportError:
        return _state(False, detail="非 Windows 平台，跳过注册表探测")

    uninstall_hits: List[Dict[str, str]] = []
    views = [
        (winreg.HKEY_LOCAL_MACHINE,
         r"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall", winreg.KEY_WOW64_64KEY),
        (winreg.HKEY_LOCAL_MACHINE,
         r"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall", winreg.KEY_WOW64_32KEY),
        (winreg.HKEY_CURRENT_USER,
         r"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall", 0),
    ]
    for hive, path, flag in views:
        try:
            parent = winreg.OpenKey(hive, path, 0, winreg.KEY_READ | flag)
        except OSError:
            continue
        i = 0
        while True:
            try:
                sub = winreg.EnumKey(parent, i)
                i += 1
            except OSError:
                break
            try:
                s = winreg.OpenKey(parent, sub)
                name = str(winreg.QueryValueEx(s, "DisplayName")[0])
            except OSError:
                continue
            low = name.lower()
            if "kaspersky" not in low and "卡巴斯基" not in name:
                continue
            # KVRT / Rescue Disk 之类工具不算「完整版」
            if any(w in low for w in ("virus removal tool", "rescue disk", "kvrt")):
                continue
            loc = ""
            ver = ""
            try:
                loc = str(winreg.QueryValueEx(s, "InstallLocation")[0])
            except OSError:
                pass
            try:
                ver = str(winreg.QueryValueEx(s, "DisplayVersion")[0])
            except OSError:
                pass
            uninstall_hits.append({"name": name, "location": loc, "version": ver})

    if uninstall_hits:
        h = uninstall_hits[0]
        return _state(True, True, version=h["version"], path=h["location"],
                      detail="卸载注册表项检测到完整版：%s" % h["name"])

    bases = [os.environ.get("ProgramFiles", r"C:\Program Files"),
             os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)"),
             os.environ.get("ProgramData", r"C:\ProgramData")]
    for b in bases:
        try:
            found = list(Path(b).glob("Kaspersky Lab*/**/avp.exe"))[:1]
        except (OSError, TypeError):
            found = []
        if found:
            return _state(True, True, path=str(found[0]),
                          detail="目录发现 avp.exe，但无卸载项；可能是残留，建议人工复核")
    return _state(False, detail="卸载注册表项与安装目录均未发现完整版（只读探测）")


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
        acquire=AcquireSpec(
            kind="kvrt_exe", version="", url=kvrt_bundle.KVRT_URL,
            license_note="免费专有软件；官方直链为 latest，未锁版本（见 policy.version_pinned）",
        ),
    ),
    Component(
        id="kaspersky_free", name="卡巴斯基完整版（个人免费层级）", category="capability",
        required=False, install_mode="vendor_installer", checker=_check_kaspersky_full,
        source_url=KASPERSKY_URL_TEMPLATE.format(
            locale=KASPERSKY_LOCALE, version=KASPERSKY_VERSIONS[0]),
        official_page=KASPERSKY_OFFICIAL_PAGE,
        target_dir=str(KASPERSKY_DIR),
        license_note=(
            "厂商专有免费软件（EULA 9.1 proprietary / trade secrets），不是开源软件。"
            "免费层级需连接 My Kaspersky 账号激活；应用只下载官方在线安装器并验签，"
            "不预置、不进仓库。EULA/隐私政策/KSN 声明一律由用户本人在官方向导中阅读并接受。"),
        note=(
            "与 KVRT 的区别：这是带实时防护的完整客户端（文件/邮件防护、安全浏览、"
            "反钓鱼、系统监控），会写入系统驱动与服务，要求管理员权限，"
            "可能要求卸载不兼容的安全软件或重启。"
            "应用不传 /s、不代填生日、不代接受协议；下载完成后需第二道同意才启动官方向导。"),
        acquire=AcquireSpec(
            kind="vendor_installer", version=KASPERSKY_VERSIONS[0],
            url=KASPERSKY_URL_TEMPLATE.format(
                locale=KASPERSKY_LOCALE, version=KASPERSKY_VERSIONS[0]),
            candidate_versions=KASPERSKY_VERSIONS,
            url_template=KASPERSKY_URL_TEMPLATE, locale=KASPERSKY_LOCALE,
            signer_must_contain="Kaspersky",
            product_must_contain_any=["Kaspersky", "卡巴斯基"],
            license_note="专有免费软件；官方在线安装器 startup.exe，Authenticode 验签",
        ),
        system_impact={
            "writes_outside_app_dir": True,
            "needs_admin": True,
            "writes_system_drivers": True,
            "may_conflict_with_existing_av": True,
            "may_require_reboot": True,
            "requires_vendor_account": True,
            "app_accepts_eula_on_behalf_of_user": False,
            "silent_install": False,
            "second_consent_required": True,
            "second_consent_note": "由服务端在用户确认后签发一次性令牌",
        },
    ),
    Component(
        id="nodejs", name="Node.js（含 npm）", category="devtool",
        required=False, install_mode="on_demand", checker=_check_nodejs,
        source_url=NODE_ZIP_URL,
        official_page="https://nodejs.org/",
        target_dir=str(NODE_DIR),
        license_note=("Node.js 为 MIT 许可的开源软件；官方分发包由 nodejs.org 提供，"
                      "下载到应用目录后不写系统 PATH、不需管理员权限。"),
        note=("当前前端是零依赖单文件 HTML，Node 并非客户机运行时依赖，所以启动自检"
              "不会主动要求安装；但整套「按需下载 → 官方校验 → 落到应用目录」能力已备好，"
              "以后真要用（例如换成需要构建的前端），用户主动点一下即可补齐，不必改代码。"),
        acquire=AcquireSpec(
            kind="zip_artifact", version=NODE_LTS_VERSION,
            url=NODE_ZIP_URL, checksum_url=NODE_CHECKSUM_URL,
            checksum_filename=NODE_ZIP, pinned_sha256=NODE_SHA256,
            archive_name=NODE_ZIP, exe_relpath=NODE_EXE_RELPATH,
            verify_args=["-v"],
            license_note="MIT；官方 SHASUMS256.txt 校验；离线包可放 engines/_offline/",
        ),
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
        "on_demand": "启动不主动安装；用户可在设置页主动补齐（同一套校验流程）",
        "vendor_installer": "可经用户同意下载并验签官方安装器；系统级安装须用户在官方向导中本人完成",
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
            "acquirable": c.acquire is not None,
            "pinned_version": (c.acquire.version if c.acquire else ""),
            "system_impact": dict(c.system_impact),
        })
    missing = [x for x in items if not x["present"]]
    not_ready = [x for x in items if x["present"] and not x["ready"]]
    return {
        "checked_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "app_dir": str(ROOT),
        "data_paths": app_paths.describe(),
        "summary": {
            "total": len(items),
            "present": len(items) - len(missing),
            "missing": len(missing),
            "not_ready": len(not_ready),
            "blocking": sum(1 for x in missing if x["required"]),
            "auto_installable_missing": sum(
                1 for x in missing if x["install_mode"] == "download_to_app"),
            "vendor_installer_missing": sum(
                1 for x in missing if x["install_mode"] == "vendor_installer"),
        },
        "components": items,
        "policy": {
            "consent_required": True,
            "consent_note": "由服务端在用户确认后签发一次性令牌，不下发浏览器",
            "writes_outside_app_dir": (
                "默认 False；唯一例外 kaspersky_free 的官方向导由用户本人操作"),
            "silent_install": False,
            "bundles_third_party_binaries": False,
            "verify_before_enable": True,
            "startup_blocked_by_optional": False,
            "version_pinned": {
                "nodejs": NODE_LTS_VERSION,
                "kvrt_engine": None,
                "kaspersky_free": KASPERSKY_VERSIONS[0] + "（候选列表，运行时探测可达版本）",
            },
            "checksum_source": {
                "nodejs": "官方 SHASUMS256.txt + 源码锁定哈希双重比对",
                "kvrt_engine": "Windows Authenticode 签名链 + 厂商标识",
                "kaspersky_free": "Windows Authenticode 签名链 + AO Kaspersky Lab 签名者 + 产品名",
            },
            "system_level_install": {
                "component": "kaspersky_free",
                "install_mode": "vendor_installer",
                "app_action": "只下载官方在线安装器到应用目录并验签，绝不运行安装",
                "user_action": "用户在厂商交互式向导中本人完成安装、阅读并接受 EULA/隐私政策/KSN、登录账号激活",
                "needs_admin": True,
                "writes_system_drivers": True,
                "may_conflict_with_existing_av": True,
                "may_require_reboot": True,
                "app_accepts_eula_on_behalf_of_user": False,
                "silent_install": False,
                "second_consent_required": True,
                "second_consent_note": "由服务端在用户确认后签发一次性令牌",
                "official_install_params_not_used": [
                    "/s", "/mybirthdate", "/pAGREETOEULA=1",
                    "/pAGREETOPRIVACYPOLICY=1", "/pJOINKSN_ENHANCE_PROTECTION=1",
                    "/pJOINKSN_MARKETING=1", "/pSKIPPRODUCTCHECK=1",
                ],
                "official_help": KASPERSKY_HELP,
            },
            "vendor_version_discovery": (
                "厂商会下线旧版本（实测 21.24.8.522 已 404），运行时对候选版本逐个 "
                "HEAD 探测取首个可达；全部失败则降级到官方下载页，不伪造 URL"),
            "official_page_fallback": KASPERSKY_OFFICIAL_PAGE,
            "offline_fallback": "把官方压缩包放到 engines/_offline/ 后用 --offline 安装",
            "on_demand_components": [x.id for x in COMPONENTS
                                     if x.install_mode == "on_demand"],
            "acquire_kinds": ["kvrt_exe", "zip_artifact", "vendor_installer"],
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
        "on_demand_installable": [x.id for x in COMPONENTS
                                  if x.install_mode == "on_demand" and x.acquire],
        "vendor_installer_downloadable": [x["id"] for x in pending
                                          if x["install_mode"] == "vendor_installer"],
        "pending": [{k: x[k] for k in
                     ("id", "name", "category", "required", "install_mode",
                      "present", "ready", "detail", "action", "official_page",
                      "target_dir", "license_note", "note", "acquirable",
                      "pinned_version", "system_impact")}
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


# ---------------------------------------------------------------------------
# 通用制品补齐：下载 -> 官方校验 -> 安全解包 -> 二次探测 -> 写状态
# 任何 zip 形态的官方制品都能走这一条，不必为每个组件重写下载/校验逻辑。
# ---------------------------------------------------------------------------

def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 512), b""):
            h.update(chunk)
    return h.hexdigest()


def _official_sha256(spec: AcquireSpec) -> str:
    """只认厂商官方校验清单里的哈希，不信任第三方博客或本地缓存值。"""
    req = urllib.request.Request(
        spec.checksum_url, headers={"User-Agent": "PowerFocus/1.0"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        text = resp.read().decode("utf-8", "replace")
    for line in text.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[-1].lstrip("*") == spec.checksum_filename:
            return parts[0].lower()
    raise RuntimeError("官方校验清单中找不到 %s" % spec.checksum_filename)


def _quarantine(path: Path, suffix: str) -> str:
    """校验失败的下载件只改名留档，不删除。"""
    if not path.is_file():
        return ""
    dest = path.with_name(path.name + "." + suffix + "-" +
                          datetime.now().strftime("%Y%m%d-%H%M%S"))
    try:
        path.rename(dest)
        return str(dest)
    except OSError:
        return ""


def _extract_zip_safely(zip_path: Path, target_dir: Path) -> int:
    """防路径穿越与体积异常：解包前逐条检查，绝不盲信压缩包内容。"""
    with zipfile.ZipFile(zip_path) as z:
        members = z.infolist()
        total = sum(m.file_size for m in members)
        if total > 600 * 1024 * 1024:
            raise RuntimeError("解压后体积异常: %d 字节" % total)
        for m in members:
            p = Path(m.filename)
            if p.is_absolute() or ".." in p.parts:
                raise RuntimeError("压缩包含非法路径: %s" % m.filename)
        target_dir.mkdir(parents=True, exist_ok=True)
        z.extractall(target_dir)
        return len(members)


def acquire_zip(spec: AcquireSpec, target_dir: Path,
                offline: bool = False) -> Dict[str, Any]:
    """通用补齐入口：落应用目录，不写系统 PATH、不改注册表、不需管理员。"""
    out: Dict[str, Any] = {"kind": spec.kind, "version": spec.version,
                           "executed": False, "offline": offline}
    exe = target_dir / spec.exe_relpath
    if not exe.is_file():
        # 历史数据目录里的已装组件只读复用，避免改路径后把用户已下载的
        # 41 MB Node 当成缺失而重下一遍；不搬迁、不删除。
        try:
            rel = target_dir.relative_to(DATA_ROOT) / spec.exe_relpath
        except ValueError:
            rel = Path(spec.exe_relpath)
        legacy_exe = app_paths.legacy_root() / rel
        if legacy_exe.is_file():
            out["reason"] = "已安装，幂等跳过（历史数据目录只读复用）"
            out["exe"] = str(legacy_exe)
            out["ok"] = True
            return out
    if exe.is_file():
        out["reason"] = "已安装，幂等跳过（不重复下载）"
        out["exe"] = str(exe)
        return out

    offline_zip = OFFLINE_DIR / spec.archive_name
    zip_path = offline_zip if offline else (DOWNLOAD_DIR / spec.archive_name)
    if offline:
        if not offline_zip.is_file():
            out["reason"] = "离线包不存在；请把官方压缩包放到该路径后用 --offline 安装"
            out["offline_path"] = str(offline_zip)
            out["official_url"] = spec.url
            return out
        out["source"] = "offline_local"
    else:
        if not zip_path.is_file():
            try:
                # 复用 kvrt_bundle.download 的分块下载 + .part + 原子改名实现，
                # 只换 url / dest，不另造一套下载器。进度文字重定向到 stderr，
                # 保证 stdout 只输出结构化 JSON，应用侧能直接解析。
                with contextlib.redirect_stdout(sys.stderr):
                    out["download"] = kvrt_bundle.download(
                        url=spec.url, dest=zip_path, force=False, timeout=900)
            except Exception as e:
                out["reason"] = "下载失败: %s: %s" % (type(e).__name__, e)
                out["offline_hint"] = str(offline_zip)
                out["retryable"] = True
                return out
        else:
            out["download"] = {"downloaded": False, "note": "复用本地缓存"}
        out["source"] = "official_url"

    try:
        actual = _sha256(zip_path)
        official = _official_sha256(spec)
    except Exception as e:
        out["reason"] = "校验失败: %s: %s" % (type(e).__name__, e)
        out["retryable"] = True
        return out
    out["sha256"] = actual
    out["official_sha256"] = official
    ok_official = (actual == official)
    ok_pinned = (not spec.pinned_sha256 or actual == spec.pinned_sha256)
    out["checks"] = {"官方清单一致": ok_official, "锁定哈希一致": ok_pinned}
    if not (ok_official and ok_pinned):
        out["quarantined"] = _quarantine(zip_path, "unverified")
        out["reason"] = "SHA256 与官方清单或锁定值不一致，禁止解包启用"
        return out

    try:
        out["extracted_files"] = _extract_zip_safely(zip_path, target_dir)
    except Exception as e:
        out["reason"] = "解包失败: %s: %s" % (type(e).__name__, e)
        return out
    if not exe.is_file():
        out["reason"] = "解包后未找到预期可执行文件: %s" % spec.exe_relpath
        return out
    try:
        r = subprocess.run([str(exe)] + list(spec.verify_args),
                           capture_output=True, timeout=30)
        out["verify_output"] = (r.stdout or b"").decode("utf-8", "replace").strip()[:80]
        out["verify_returncode"] = r.returncode
    except Exception as e:
        out["reason"] = "落地后二次探测失败: %s: %s" % (type(e).__name__, e)
        return out
    if r.returncode != 0:
        out["reason"] = "落地后二次探测返回非 0，禁止标记为可用"
        return out

    state = {"component_kind": spec.kind, "version": spec.version,
             "exe": str(exe), "sha256": actual, "source": out["source"],
             "official_url": spec.url, "checksum_url": spec.checksum_url,
             "installed_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
             "writes_system_path": False, "needs_admin": False}
    target_dir.mkdir(parents=True, exist_ok=True)
    state_file = target_dir / "artifact.json"
    state_file.write_text(json.dumps(state, ensure_ascii=False, indent=2),
                          encoding="utf-8")
    out["executed"] = True
    out["exe"] = str(exe)
    out["state_file"] = str(state_file)
    return out


# ---------------------------------------------------------------------------
# 厂商在线安装器（vendor_installer）：应用只负责「下载 + 验签」，绝不代装
# ---------------------------------------------------------------------------

def probe_vendor_versions(spec: AcquireSpec) -> List[Dict[str, Any]]:
    """
    只读 HEAD 探测候选版本的可达性。厂商会下线旧版本，写死单一 URL 必失效。
    依据实测：21.24.8.522 -> 404；21.26.4.406 / 21.27.6.532 -> 200。
    """
    rows: List[Dict[str, Any]] = []
    for version in list(spec.candidate_versions):
        url = spec.url_template.format(locale=spec.locale, version=version)
        row: Dict[str, Any] = {"version": version, "url": url}
        try:
            req = urllib.request.Request(
                url, method="HEAD", headers={"User-Agent": "PowerFocus/1.0"})
            with urllib.request.urlopen(req, timeout=20) as resp:
                row["status"] = resp.status
                row["size"] = resp.headers.get("Content-Length")
                row["available"] = (resp.status == 200)
        except Exception as e:
            row["available"] = False
            row["error"] = "%s: %s" % (type(e).__name__, str(e)[:80])
        rows.append(row)
    return rows


def verify_vendor_installer(path: Path, spec: AcquireSpec,
                            expected_version: str = "") -> Dict[str, Any]:
    """
    通用 Authenticode 校验：签名链 + 签名者 + 产品名 + 版本。

    刻意**不复用** kvrt_bundle.verify()：那个函数把 PRODUCT_MUST_CONTAIN
    写死成 "Virus Removal Tool"，用于完整版安装器必然误判。这里复用它的
    底层能力（WinVerifyTrust / PE 版本信息 / 证书表线索 / SHA256），不另造轮子。
    """
    p = str(path)
    info: Dict[str, Any] = {"path": p}
    if not path.is_file():
        return {"ok": False, "reason": "安装器文件不存在: %s" % p, **info}
    if not sys.platform.startswith("win"):
        return {"ok": False, "reason": "Authenticode 验签仅支持 Windows", **info}
    info["size"] = path.stat().st_size
    try:
        info["trust_hresult"] = "0x%08X" % kvrt_bundle.winverifytrust(p)
        info.update(kvrt_bundle.pe_version_info(p))
        info["signer_hint"] = kvrt_bundle.authenticode_signer_hint(p)
        info["sha256"] = kvrt_bundle.sha256_file(p)
    except Exception as e:
        return {"ok": False, "reason": "验签过程异常: %s: %s" % (type(e).__name__, e),
                **info}

    blob = " ".join(str(info.get(k) or "") for k in
                    ("company", "signer_hint", "description"))
    signer_ok = spec.signer_must_contain.lower() in blob.lower()
    product_name = str(info.get("product_name") or "")
    product_ok = any(w.lower() in product_name.lower()
                     for w in spec.product_must_contain_any)
    file_version = str(info.get("file_version") or "")
    version_ok = (not expected_version or
                  file_version == expected_version or
                  not file_version)
    info["ok"] = (info["trust_hresult"] == "0x00000000" and
                  signer_ok and product_ok and version_ok)
    info["checks"] = {
        "签名链有效": info["trust_hresult"] == "0x00000000",
        "签名者为卡巴斯基": signer_ok,
        "产品名匹配": product_ok,
        "版本与探测结果一致": version_ok,
    }
    info["verified_at"] = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    if not info["ok"]:
        info["reason"] = "官方签名链/厂商标识/版本校验未通过，禁止启动"
    return info


def acquire_vendor_installer(spec: AcquireSpec, target_dir: Path,
                             offline: bool = False) -> Dict[str, Any]:
    """
    下载厂商官方在线安装器到应用目录并验签。**绝不运行安装器**。

    与 zip_artifact 的区别：产物不是可执行的运行时组件，而是一个需要
    用户本人在交互式向导里操作、且会写系统驱动的安装入口。
    """
    out: Dict[str, Any] = {"kind": spec.kind, "executed": False,
                           "installed": False, "offline": offline,
                           "writes_system_drivers": False}
    target_dir.mkdir(parents=True, exist_ok=True)
    state_file = target_dir / "artifact.json"

    # 已有且仍有效的安装器：幂等跳过，不重复下载约 7 MB。
    # 状态文件可能在历史数据目录（路径改造前下载的），只读回退。
    cached_state = app_paths.first_existing("engines/KasperskyFull/artifact.json")
    if cached_state.is_file() and not offline:
        try:
            st = json.loads(cached_state.read_text(encoding="utf-8"))
            cached = Path(str(st.get("installer") or ""))
            if cached.is_file():
                v = verify_vendor_installer(cached, spec, str(st.get("version") or ""))
                if v.get("ok"):
                    out.update({"reason": "已下载且验签通过，幂等跳过",
                                "installer": str(cached), "verify": v,
                                "version": st.get("version"), "ok": True})
                    return out
        except (OSError, ValueError):
            pass

    if offline:
        offline_exe = OFFLINE_DIR / "startup.exe"
        if not offline_exe.is_file():
            out["reason"] = "离线安装器不存在；请把官方 startup.exe 放到该路径"
            out["offline_path"] = str(offline_exe)
            out["official_page"] = KASPERSKY_OFFICIAL_PAGE
            return out
        out["source"] = "offline_local"
        chosen_version = ""
        installer = offline_exe
    else:
        probes = probe_vendor_versions(spec)
        out["version_probes"] = probes
        usable = [x for x in probes if x.get("available")]
        if not usable:
            out["reason"] = "所有候选版本的官方直链均不可达，降级到官方下载页"
            out["official_page"] = KASPERSKY_OFFICIAL_PAGE
            out["retryable"] = True
            return out
        chosen = usable[0]
        chosen_version = chosen["version"]
        url = chosen["url"]
        installer = DOWNLOAD_DIR / ("startup-%s-%s.exe" % (chosen_version, spec.locale))
        DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)
        if not installer.is_file():
            try:
                with contextlib.redirect_stdout(sys.stderr):
                    out["download"] = kvrt_bundle.download(
                        url=url, dest=installer, force=False, timeout=300)
            except Exception as e:
                out["reason"] = "下载失败: %s: %s" % (type(e).__name__, e)
                out["retryable"] = True
                out["official_page"] = KASPERSKY_OFFICIAL_PAGE
                return out
        else:
            out["download"] = {"downloaded": False, "note": "复用本地缓存"}
        out["source"] = "official_url"
        out["official_url"] = url

    v = verify_vendor_installer(installer, spec, chosen_version)
    out["verify"] = v
    if not v.get("ok"):
        out["quarantined"] = _quarantine(installer, "unverified")
        out["reason"] = "安装器未通过官方签名校验，禁止启动"
        return out

    state = {
        "component_kind": spec.kind, "version": (chosen_version or v.get("file_version")),
        "installer": str(installer), "sha256": v.get("sha256"),
        "source": out["source"], "official_page": KASPERSKY_OFFICIAL_PAGE,
        "verified_at": v.get("verified_at"),
        "installed": False, "needs_admin": True,
        "writes_system_drivers": True,
        "app_accepts_eula_on_behalf_of_user": False,
        "silent_install": False,
    }
    state_file.write_text(json.dumps(state, ensure_ascii=False, indent=2),
                          encoding="utf-8")
    out.update({
        "executed": True, "ok": True, "installer": str(installer),
        "version": state["version"], "state_file": str(state_file),
        "next_step": ("安装器已备好但未运行。需用户本人确认系统级安装，"
                      "由服务端签发第二道一次性同意令牌后才启动官方交互式向导。"),
    })
    return out


def launch_vendor_wizard(component_id: str, install_consent: str = "") -> Dict[str, Any]:
    """
    第二道同意后，启动厂商**交互式**安装向导。

    关键：不传 /s，不传 /mybirthdate，不传任何 /pAGREETOEULA 之类参数。
    EULA / 隐私政策 / KSN / 账号激活全部由用户本人在向导里完成。
    启动前重新验签，防止安装器在下载后被替换。
    """
    record: Dict[str, Any] = {
        "at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "action": "launch_vendor_wizard", "component_id": component_id,
        "launched": False, "ok": False,
    }
    c = next((x for x in COMPONENTS if x.id == component_id), None)
    if c is None or c.install_mode != "vendor_installer" or not c.acquire:
        record["reason"] = "该组件不是厂商安装器类型"
        return record
    if not check_consent(install_consent, "install"):
        record["reason"] = "缺少用户对本机系统级安装的第二道显式同意，拒绝启动安装向导"
        record["consent_received"] = bool(install_consent)
        return record
    record["consent"] = "verified"

    state_file = app_paths.first_existing("engines/KasperskyFull/artifact.json")
    if not state_file.is_file():
        record["reason"] = "尚未下载并验签官方安装器，请先执行 install()"
        return record
    try:
        st = json.loads(state_file.read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        record["reason"] = "安装器状态文件不可读: %s" % e
        return record
    installer = Path(str(st.get("installer") or ""))
    if not installer.is_file():
        record["reason"] = "安装器文件不存在，需重新下载"
        return record
    v = verify_vendor_installer(installer, c.acquire, str(st.get("version") or ""))
    record["verify"] = v
    if not v.get("ok"):
        record["reason"] = "启动前复验失败，拒绝运行安装器"
        return record
    record["system_impact"] = dict(c.system_impact)
    record["official_page"] = c.official_page

    try:
        # 交互式向导：只传可执行路径，不带任何静默/代接受协议参数。
        proc = subprocess.Popen([str(installer)], shell=False)
        record["launched"] = True
        record["ok"] = True
        record["pid"] = proc.pid
        record["arguments"] = []
        record["note"] = ("应用已启动官方向导；安装与协议接受完全由用户本人完成，"
                          "应用不监控、不代填、不自动重启")
    except Exception as e:
        record["reason"] = "启动官方向导失败: %s: %s" % (type(e).__name__, e)
    return record


def install(component_id: str, consent: str = "", force: bool = False,
            offline: bool = False) -> Dict[str, Any]:
    """
    用户同意后由应用进程自己补齐组件。

    consent 必须是服务端签发的一次性令牌（scope=download）；空值、布尔 True 一律拒绝。
    zip_artifact 走通用 acquire_zip()，kvrt_exe 继续复用 kvrt_bundle 的验签链路，
    vendor_installer 只下载并验签官方安装器（**绝不运行**），
    guided / detect_only 一律不下载不安装。

    注意：install() 的「完成」对 vendor_installer 而言只是「安装器备好」，
    installed 恒为 False；真正装进系统必须另调 launch_vendor_wizard()
    并传第二道令牌，且由用户在官方向导里本人操作。
    """
    c = next((x for x in COMPONENTS if x.id == component_id), None)
    record: Dict[str, Any] = {
        "at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "component_id": component_id, "executed": False, "ok": False,
        "force": force, "offline": offline,
    }
    if c is None:
        record["reason"] = "清单中不存在该组件"
        _audit(record)
        return record
    if not check_consent(consent, "download"):
        record["reason"] = "缺少用户显式同意，拒绝下载/安装"
        record["consent_received"] = bool(consent)
        _audit(record)
        return record
    record["consent"] = "verified"

    if c.acquire and c.acquire.kind == "vendor_installer":
        before_full = c.checker()
        if before_full.get("ready") and not force:
            record["reason"] = "客户机已安装卡巴斯基完整版，无需再下载安装器"
            record["path"] = before_full.get("path")
            record["ok"] = True
            record["audit_file"] = _audit(record)
            return record
        result = acquire_vendor_installer(c.acquire, Path(c.target_dir), offline)
        record["acquire"] = result
        record["executed"] = bool(result.get("executed"))
        record["ok"] = bool(result.get("ok"))
        record["installed"] = False
        record["reason"] = (result.get("reason") or
                            ("官方安装器已下载并验签，未运行、未安装" if result.get("executed")
                             else "未完成"))
        record["system_impact"] = dict(c.system_impact)
        record["next_step"] = result.get("next_step", "")
        record["retryable"] = bool(result.get("retryable"))
        record["audit_file"] = _audit(record)
        return record

    if c.acquire and c.acquire.kind == "zip_artifact":
        result = acquire_zip(c.acquire, Path(c.target_dir), offline)
        record["acquire"] = result
        record["executed"] = bool(result.get("executed"))
        record["reason"] = (result.get("reason") or
                            ("安装完成，已落到应用目录" if result.get("executed")
                             else "未完成"))
        # 「已安装，幂等跳过」是成功，不是失败；不能让 CLI 返回非 0。
        record["ok"] = bool(result.get("executed") or
                            str(result.get("reason") or "").startswith("已安装"))
        record["retryable"] = bool(result.get("retryable"))
        record["audit_file"] = _audit(record)
        return record

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
        record["ok"] = True
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
    record["ok"] = True
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
        description="启动依赖自检 / 用户同意后补齐（默认只读）")
    ap.add_argument("--check", action="store_true", help="完整自检（默认动作，只读）")
    ap.add_argument("--plan", action="store_true", help="只列待办建议，不执行")
    ap.add_argument("--list", action="store_true", help="列出组件清单")
    ap.add_argument("--install", metavar="ID", default="", help="补齐指定组件")
    ap.add_argument("--consent", default="",
                    help="用户显式同意；CLI 现场签发一次性令牌，不接受固定常量")
    ap.add_argument("--force", action="store_true", help="配合 --install 强制重下")
    ap.add_argument("--offline", action="store_true",
                    help="不联网，改用 engines/_offline/ 下用户手动放置的官方包")
    ap.add_argument("--launch-wizard", metavar="ID", default="",
                    help="启动厂商交互式安装向导（会写系统，必须配合 --install-consent）")
    ap.add_argument("--install-consent", default="",
                    help="用户对本机系统级安装的第二道显式同意")
    args = ap.parse_args(argv)

    if args.list:
        rows = []
        for c in COMPONENTS:
            row = {k: getattr(c, k) for k in
                   ("id", "name", "category", "required", "install_mode",
                    "source_url", "official_page", "target_dir", "note")}
            row["acquire_kind"] = c.acquire.kind if c.acquire else ""
            row["pinned_version"] = c.acquire.version if c.acquire else ""
            row["system_impact"] = dict(c.system_impact)
            rows.append(row)
        print(json.dumps(rows, ensure_ascii=False, indent=2))
        return 0

    # 系统级动作单独一条命令，绝不被 --install 顺带触发。
    if args.launch_wizard:
        # CLI 上带 --install-consent 本身就是显式操作，现场签发一次性令牌。
        cli_consent = mint_consent("install") if args.install_consent else ""
        out = launch_vendor_wizard(args.launch_wizard, cli_consent)
        print(json.dumps(out, ensure_ascii=False, indent=2))
        return 0 if out.get("ok") else 2

    if args.install:
        cli_consent = mint_consent("download") if args.consent else ""
        out = install(args.install, cli_consent, args.force, args.offline)
        print(json.dumps(out, ensure_ascii=False, indent=2))
        return 0 if out.get("ok") else 2

    if args.plan:
        print(json.dumps(plan(), ensure_ascii=False, indent=2))
        return 0

    print(json.dumps(startup_check(), ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
