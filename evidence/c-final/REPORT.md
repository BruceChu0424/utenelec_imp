# 冻结候选 7b912287：C 全组本地验收

本报告只认 `7b912287e53315228b469790ff066a9fab643e3c`。独立工作树 `D:/Projects/uten_imp_worktrees/feedback-final-c-20261110`，分支 `uimp/feedback-final-c-20261110`，没有生产代码改动。其他 SHA 的准备运行和红轮在 `feedback-cost-structure-v3-20261110/evidence/cost-structure-v3/PREP-REPORT.md`，不混为本轮通过。整体网页/Windows 仍有 Root 正在处理的布局故障，本报告不代表整体系统、现场或发布通过。

## 同一源码证明

每组开始/结束都是上述 HEAD、server/main/test/contract 共 7228 个 Git 对象一致，树清单 SHA-256 均为 `eeecf965cd5cf3125446178c3c1c83722c437f71d0e90d1e87a87ca47abdfa26`。`source-proof.py` 检查源目录无改动；公开入口各组同时核对 20 个关键已编译产品 class 的原始 SHA-256 未变。Maven 为本树独立目录正常 fresh 编译 3275 个生产源码、2755 个测试源码，未 overlay 产品 class。

| 组 | 本轮实际结果 | 原始证据 |
| --- | --- | --- |
| 23 类完整 C 文件/持久化/历史/原命令 | **146 项：145 通过，0 失败/错误，1 私有 Excel 环境 skip**；正常 Maven BUILD SUCCESS，exit0 | `maven/maven.log`、`maven/reports/`、`maven-23-classes-start/end.json` |
| 四份独立原 XLSX 只读复验 | **4/4**：正常材料、与表头同名材料、“小计数器件”各保留两行且数量 1/单价 4；混合尾行明确拒绝并定位第 3 行第 4 未命名列 | `final-7b912287-originals.log`、对应 start/end/exit |
| 真实旧 v2 → 当前公开提交 | **五类全部拒绝**，含成本两错误 pending、科目父子、备注、辅助、凭证+余额；原 JSON/owner/来源/谱系不变，七业务表 0 错误写入；辅助 accounting adapter invalid。合法当前成本两行公开 apply 成功；仅新增一份匹配回执，另一 owner 先被拒绝 | `final-7b912287-v2.log`、`old-v2-program.json`、`old-v2-finance.json`、对应 start/end/exit/result |
| 真实旧 v1 → 当前公开提交/回执 | **五类 pending 拒绝**；父子原 JSON 精确不变；旧已成功备注在锁期后原回执精确重放、不增第二行；另一 owner 拒绝 | `final-7b912287-v1.log`、对应 start/end/exit |
| 七入口真实原文件攻击及合法对照 | **七类攻击全部拒绝**，真实新建普通数据库 actor、真实 repositories/transactions，七业务表计数不变；chart/note/auxiliary/cost 合法公开 apply 成功，gl 保持 0 | `final-7b912287-files.log`、对应 start/end/exit |

这些组有意重叠同一原反例，不将四件重读、服务探针的内部断言累加为额外 JUnit 数量。全部组在 `finish-orchestrator.log` 串行连接，最终 `.exit=0`。没有修改门槛、取消旧轮或跳过适用检查。

## 实际业务边界

完整 Maven 包括七类的物理列/额外表/隐藏输入/空缓存公式/结构行/签名、商品导入历史及 BOM、成本重映射/手工更改/回滚、备注/科目/辅助/凭证接续、科目原请求/停止/并发顺序与真实 V1090 历史升级。原单格合计、多区块、普通缓存公式、空尾列与合法名称对照保持；“合计”混业务数量/价格/公式的行明确拒绝，不静默丢弃。唯一服务端 `ImportColumnGuard.VERSION=3`，客户端不提供安全事实。

实际旧预览来自先前保留的真实 v1 程序和本轮准备阶段保留的真实 v2 程序，未用 SQL 改版本伪造。v2 两份错误成本原 ID 分别为 `944f2fc0-d664-4570-ae35-e12ef6a100b6`、`1bfd1e34-c3bd-46d1-a0ba-c9877864787c`；科目父子等其余 ID 及原 JSON 在复制的签发档案中。专用库仍为 `uten-remediate-c-upgrade-1110` / `127.0.0.1:26632/imports`，原合成 crypto/key 和原不可变文件目录沿用；未访问 Root 统一 Web 库/配置。恢复探针使用原普通 owner，七入口文件组另建真实普通 actor `f15072a3-517d-43bc-be2d-12b9f826db83`（superAdmin=false）。

成本 apply 是新的匹配动作；合法对照产生新匹配回执，不将其冒称旧匹配终态的幂等重放。文件组的“应用 1 行/条”表示该次合法来源应用量，不保证既有目录表的行数都新增 1；所有旧 pending 拒绝前后均逐表证明无业务写入。没有 UPDATE 旧 preview JSON，没有关闭 V755/V1090 或修改旧账。

Java 公开服务/真 PG 证据不冒称浏览器 HTTP 交互；Root 负责同候选真实网页 chart/note 合法 Apply 和攻击工作簿。共享后端安全门适用于现有 Flutter Web/桌面/移动调用方；Win7 WPF 已迁移与未迁移状态沿用进度清单，未迁移的导入/财务写入口不因后端通过而变为已支持。

## 恢复、复跑和现场

旧 v1/v2 pending 保留为历史。保留原件、原 ID、owner、谱系和未知回执；不能把版本填 3、改文件名或 UPDATE JSON 来恢复。按拒绝位置在副本核对真实材料/表头/额外列，正常重新生成当前支持的系统列文件后重新检测，逐行完整核对/明确映射或跳过后再提交。当前没有可直接安全升级旧 JSON 的入口。已成功、停止或未知的原请求仍按原编号核查；业务更正走原流程，不改旧账。

`run-finish.ps1` 在同一编译目录上只读重验四原件、真实 v2/v1 和七入口，拒绝覆写同名日志。`source-proof.py` 固定上述冻结 SHA；从其他 SHA 运行会明确失败，不能静默把别的源码当成本报告版本。完整 Maven 原命令在 `maven-command.json`，所有执行参数复制到 `run-arguments/`。完整原始日志、退出、源码对象和 class 哈希见 `manifest.json`。

私有 Excel 环境未提供的那一项仍 **skip/现场待验**，不是通过。公司真实模板/原单、目标 Windows/Win7 设备及完整原生 ERP 未在本轮提供；现场以同一最终候选原件复跑材料数量/价格/来源与权限、成功/停止/未知回执恢复，并保留输出文件和应用日志。没有合并 main、推送、部署或正式打包。
