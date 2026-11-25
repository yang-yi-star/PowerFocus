# 第三方许可证包（LICENSES）

生成时间：`2026-11-24T23:16:09+08:00`
包数量：**38**（不含 pip；pip 不随 exe 分发）

本目录由 `tools/generate_license_bundle.py` 从本机 `.venv` 生成。
每份 `<包名>-<版本>.txt` 含：SPDX 标识、元数据声明、许可证来源与 SHA256、许可证全文。
`index.json` 为机器可读索引，根目录 `SBOM.cdx.json` 为 CycloneDX 1.5 SBOM。

## 重要口径

- **源码仓库**只含项目原创代码与 Apache-2.0 许可证。
- **Release 单文件 exe** 内含 CPython 与本目录所列 Python 包；分发 exe 时须同时附带 `LICENSE`、`THIRD_PARTY_NOTICES.md`、`LICENSES/` 与 `SBOM.cdx.json`。
- KVRT、Node.js、卡巴斯基完整版安装器**不随包分发**，不进入本目录。

## 本机环境与 lock 的漂移

| 包 | lock 目标 | 本机实际 |
|---|---|---|
| annotated-doc | 0.0.6 | 0.0.5 |
| click | 8.5.1 | 8.5.0 |
| fastapi | 0.162.4 | 0.162.0 |
| pyinstaller-hooks-contrib | 2026.10 | 2026.9 |
| ruff | 0.17.4 | 0.17.3 |

这些差异说明当前 `.venv` 不是按 `requirements.lock.txt` 精确重建的；生成包按实际 exe 环境为准，重新打包前应先对齐。

## 已核实的上游元数据冲突

- `proxy_tools 0.1.0`：PyPI 元数据写 MIT，上游仓库 `LICENSE.txt` 正文为 BSD-2-Clause；本包按正文收录并保留冲突说明。
