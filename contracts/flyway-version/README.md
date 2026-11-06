# Flyway 多段版本与历史证据契约

2026-11-05：此契约修复源码工具对 `V999_1` 至 `V999_11` 等已存在迁移的识别。它不执行迁移、修改数据库历史、重写回执、签署正式发布或更新服务器。

唯一 Python 实现在 `deploy/contracts/flyway_version_contract.py`，跨工具样例在本目录 `fixtures.json`。通过 `tool/sync_flyway_version_contract.py` 将同一实现嵌入既有独立工具；运行时不增加未经固定的模块加载。生成块记录源文件 SHA-256，并保留每个调用方原有异常类型。

## 版本与文件绑定

- 比较按任意精度整数分段：`999 < 999.1 < 999.2 < 999.10 < 999.11 < 1000`。不能用浮点数、十进制数、文本 `MAX` 或 `installed_rank` 代替版本比较。安装顺序仍独立校验。
- manifest、校验清单和版本字符串字段使用规范正数点分版本；拒绝前导零、末尾零段、下划线别名、空白、科学计数、布尔值、浮点数及重复版本。脚本名可使用统一的 `_` 或 `.` 分隔版本，不能混用；必须与版本、原始描述和实际文件精确对应。
- Flyway Java 比较使用实际 `MigrationVersion`；SQL 在严格语法检查后使用 `numeric[]` 分段排序，保留脚本与 CRC 的真实行比对。
- 仅允许已发布的九个完整文件名 `V01__enable_pgcrypto.sql` 至 `V09__audit_redact_password.sql` 保留原历史版本 `01` 至 `09`。完整名单维护于唯一实现，伪造同编号文件名或 `001` 不在例外中。新清单的版本字段仍是 `1` 至 `9`，文件名与 CRC 不变。

原始历史 JSON 的版本、描述及字节语义参与原 `canonicalHistorySha256`，不改写为规范版本。经过原版本与脚本绑定校验后，`signedProjectionSha256` 的投影使用清单的规范版本、原脚本名和原 CRC。Flyway 在历史表中将文件描述的下划线转换为空格；清单保留文件原始描述，两者分别按其实际来源校验。

既有健康/恢复证据的整数 `headVersion` 继续输出 JSON 整数；只有多段头版本输出规范字符串，如 `"999.11"`。原 manifest 和回执的字符串字段保持字符串，不更新现存记录或改变其 schema。备份恢复的原计数、摘要、权限、真实恢复证明、签名 namespace、签署者及固定源加载检查继续生效。

## 生成与检查

```sh
python3 tool/sync_flyway_version_contract.py
python3 tool/sync_flyway_version_contract.py --check
python3 -m unittest discover -s deploy/release -p 'test_flyway*.py' -v
python3 -m unittest discover -s server/legacy_migration -p 'test_flyway_caller_versions.py' -v
```

生成范围共 13 个调用方：release tools、release guard、runtime boot verifier、release updater、retention manager、recovery commit verifier、migration authorization、pgBackRest health、backup acceptance、paired internal backup、legacy candidate verifier、legacy importer 和 existing PostgreSQL role hardener。shell 仅从经过审查的独立 Python 引用块调用；单测抽取执行该块，不执行导入器或角色加固流程。

生成器同时按依赖顺序更新既有固定摘要：guard → boot verifier / migration authorization / updater；boot verifier 与 migration authorization → updater；migration authorization → phase 3 / phase 4；updater 与 retention manager → retention launcher。检查模式只核对，不写文件；缺失、重复、未解析的 pin 或生成边界，以及不属于源码根的文件或符号链接均拒绝。

完整 updater 与 backup 单测仍按现有 CI 执行。新增端到端样例用临时目录、临时签署密钥和合成双 JAR 验证签名、清单、实时历史、备份投影与 append-only 前缀；真实 SQL 全清单由 `FlywayChecksumManifestExporterTest` 使用 Flyway 自身导出并校验。root 元数据用例与依赖真实 PostgreSQL/systemd 的用例保持原运行条件，不能将跳过项写成通过。

既有Task安装链的 Guard → pgbackrest_repo2 / existing_host_installer → 独立launcher 固定源码摘要也由同一生成器按依赖顺序归集；不另建版本解析器，不安装或重建信任，仍要求Guard预先独立审核和引导。
