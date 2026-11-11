# 生产包整改与本地验证

本包从当前 `main=fdeda88b3d73b24b8691ad132caa765196b19a3d` 建立独立分支 `uimp/feedback-remediate-a-20261110`，工作树为 `D:/Projects/uten_imp_worktrees/feedback-remediate-a-20261110`。产品修复提交为 `81cc0eac0dc8e08f59c6abcde266f8845a9a6860`；独立复核后的前向补充为 `59364ea00a6aeafc2adf31850cecd4e0b4f7414c`。其后同分支追加三材料旧草稿、同密钥造数及两条 Dart 分析整改。没有合并 main、推送、操作公司库、部署或正式打包。

原始审查目录 `D:/Projects/uten_imp_worktrees/feedback-audit-20261110/audit/production` 保持不变。本包原件复制、首次失败、修后输出均在 `D:/Projects/uten_imp_worktrees/feedback-remediate-a-20261110/tmp/feedback-a-20261110`，下文简写为“证据目录”。该目录未进 Git，不能因代码已整合删除工作树。原件的实际字节 SHA-256 及来源、复制路径保存在 `original-byte-manifest.json`；Git 源文件使用 Git blob 口径，日志、工作簿、dump 等使用实际文件字节。没有改写旧证据配平指纹。

## 缺陷、公共入口及适用调用方

| 项目 | 原反例与根因 | 修复和保留的差异 | 本包证据 |
|---|---|---|---|
| A1 历史缩量追认 | 旧计划20，实发10、实退9，提前完结到10且已有已审报工10；V1129 单事件把今天计划/需求门槛当成当时证明，额度变为 NULL | 只新增 V1130/V1131。未变目标须有不可变原材料基数、无 CAP/恢复历史、原需求及发料货品/颜色/单位一致、冻结曲线或 EXACT 指纹。缺证按当前可验证配套减有效占用；冻结曲线大于当前需求不能用 LEAST 降门槛。没有回填 ledger_order 或检查点、没有冲销旧账 | `baseline-legacy-repeat*.log`、`upgrade-v1128-public-baseline.log`、`upgrade-candidate-{create,edit,approve,already1129}.log`、`focused-v1131-1.log` |
| A2 本草稿重选重复占用 | 500 配套中草稿300，重选时固定排除 NULL，只给200 | 候选入口接收原日报 ID/版本，服务端前后核对原身份、读写权、草稿状态及版本，只排该服务端草稿的持久化占用。新建、其它普通账号、旧版本不能借量；保存/审核仍由原锁内守卫复算，不信客户端旧数量 | `ui-draft-1.log`、`ui-draft-typed-1.log`、生产业务 JUnit、`three-case-final/` |
| A2 状态及通用指引 | 三料各领一半应限量；上方通用步骤条只说“可报工” | 权威限量标志及紫色/读屏文字继续共用；步骤条改“生产中 · 按工单额度报工”，不暗示额度无上限。默认使用 frontend-design，保留原 UI 主题、Uten 等待组件与输入/未知提交合同 | `ui-combined-2.log` 5/5；真实三材料对象由浏览器造数工具提供，最终同版 Web/桌面另列 |
| A3 历史证明平方扫描 | 每个 proof 重扫后续红冲，513/1025/2049 份原热读约258/1110/3616ms | 把红冲写为按需求的信用区间，按位置一次 sweep；较新 ISSUE 的红冲不撤较旧证明。新增 `(segment,source_stock_order,...)` 索引及无候选早退，避免 capture 为新前缀遍历整段历史。RANGE 明确同位置 delta 一起结算。proof.ledger_order 由同序列下一值产生，严格晚于 source_stock_order，二者不可混用 | `proof-v1131.log`、`proof-v1131/candidate-proof-plan-*.json`、`focused-capacity-1.log`、`focused-v1131-1.log` |
| A3 正反向/锁图 | 普通 ISSUE 与 DIRECT_LOT 的退料目标都必须在已锁计划图；不能在 WDRAW 中间态补证 | 既有锁序和最终保存/flush 后按工单去重捕获入口保留；没有开放通用撤审。补真实 PG 的两条 DIRECT_LOT 退库/终态 reverse 与精确指令用例 | `direct-return-final/direct-return.log`，wrapper 1/1，内含两条具名 owning 业务用例；原普通 WDRAW 业务与图守卫单测另列 |
| A4 投影防线 | 当前交付列序正确，但旧测试按自己的常量造数组，交换两个布尔列仍绿 | 新增真实 SQL、非超管 read-all 岗位：部分料/异车间不得办理；本车间/齐套保持可报工；同时核对限制标志、动作、阻断原因及真实总数。另编译独立变异类，仅交换表达式，必须业务断言失败，恢复查询才通过 | `projection-run-1/projection-{baseline,mutant,restored}.log`、`projection-mutation.diff`、`projection-driver-1.log` |

候选、创建、编辑、审核、工作台、执行段及车间导出共用 `fn_execution_partial_material_report_room`；不可变证明验证共用 `fn_execution_full_kit_checkpoint_valid`。`DailyReportExecutionSegmentGuard` 仍在原保存/审核锁内执行。候选的所有重载保持新建默认不排占用；Flutter 的恢复补全、单个/多个初始来源、重选面板及共享 repository 全部携带同一原日报 ID/版本，读取 owner 键同时绑定这两个值。实际用料沿实填，不用今日 BOM 反算。

## 真实业务反例及合法对照

旧程序由 `git archive 86dffb9db` 干净编译，正常迁移至 V1128。所有发料、WDRAW、报工、CAP 和旧草稿来自公开业务服务，触发器正常启用。旧基线实际形成：计划20→发10→退9→审核提前完结10，当前净能力1；并保存两个数量3的旧草稿。

分别复制数据库后，创建新增3、编辑修前旧草稿、审核修前旧草稿均明确因配套拒绝：capacity=1、有效 proof=false、room=0。完整生产事实 JSON 前后相同，已审产量仍10，两个原草稿仍在，没有额外3入账。另一副本先正常迁移停在 V1129，再升到 V1130，同样拒绝。此四路原证据对应 V1130 实施检查点；V1131 的冻结需求/位置边界另有4项真 PG 与全规模复跑，最终统一 SHA 应使用本目录工具重新跑完整升级链，不能将实施期检查点冒充最终整包版本。

三材料补验另保留 V1128 库和三个独立候选副本：各计划10000、冻结需求10000/10000/10000、实际发料5000/5000/5000。修前公开保存编辑/审核用6000草稿，实耗为5000/5000/5000；新建对照工单不预存草稿。V1131 候选中，普通岗位在候选读取得到5000；新建及编辑提交6000、保留原因及实耗5000/6000/6000被拒，独立普通审批岗审核修前6000草稿也被拒。三路原事实和实际用料不变，已审产量0。证据为 `three-case-final/old-v1128-three.log`、`candidate-three-{create,edit,approve}.log`、`v1128-three.dump`；不能把旧草稿的实耗说成6000/6000。

合法对照包括真实先齐套再退料/损耗、零材料、品质恢复、实际超产、同工单多行及销售/公共份额、删除释放、原本草稿300改400、两个真正不同普通账号各报300而配套500只成功一个。普通岗位候选/写入与全量管理员准备数据分开记录。原已审核老账只读核查入口见 `tool/company_feedback_production/legacy_approved_read_only.sql`：缺证不等于旧产量虚假；须核对原计划/物料身份、发退料、实耗、品质/入库及成本财务下游，再由有权岗位按原业务逆向流程决定处置，不能自动 UPDATE、清账或泛化撤审。

## 规模、原失败及计数口径

| 独立运行 | 结果及界限 |
|---|---|
| 最新聚焦 V1130 真 PG | `focused-capacity-1.log`，22/22，0失败/错误/跳过；热读513/1025/2049为155/257/259ms；20k历史容量基线37ms、限额52ms；1000 posting一次捕获124ms |
| V1131追加边界 | `focused-v1131-1.log`，4/4，0失败/错误/跳过；首 ISSUE 的证明位置、反冲前缀捕获、缩小需求门槛、原损耗预算合法对照 |
| V1131全规模 SQL | 513/1025/2049均返回0；原 ISSUE/REVERSE分别扫描257/513/1025行、各1循环。完整 EXPLAIN 时间63.041/73.932/64.111ms，原热读文本和造数5.56/13.18/17.01s分别保留；不同负载、psql/容器往返不能混为 UI 延迟合同 |
| UI 交互/语义 | `ui-combined-2.log` 5/5；Dart类型补充后 `ui-draft-typed-1.log` 1/1；`analyze-2.log` 2文件0问题。VM/合成 API 不算真实后端或桌面窗口验收 |
| A4变异 | 正确查询1/1通过，变异1项明确 AssertionFailedError，恢复1/1通过。预期变异失败不记为产品失败或新增三个独立业务完成数 |
| 实施期长轮 | `maven-1.log` 15类184项：168通过、0断言失败、16错误、0跳过，未取消。1项为 V936 授权操作者夹具，已用真实管理员事务修正并在真实 SQL 变异三轮复验；15项为实施中旧 test-classes 遇更新后 SQL 的 `demand.goods_id` 缺列。原 XML/日志保留，最新聚焦夹具重新编译后已通过；该长轮不是最终源码整包绿 |

原件之外，`candidate-probe.log` 保留0.0000与字符串0比较的夹具失败，后改精确 Decimal 数值断言；`candidate-probe-3.log` 保留重复添加 fixture unit_id 的错误；`tracked-probe.log` 保留容器临时 Unix socket就绪/最终TCP未就绪的启动竞态，后按TCP就绪检查重跑。`ui-combined-1.log` 保留语义句柄清理时点错误，修后在测试体 finally 释放。中间实现没有 capture 早退时1024轮造数448.48s也自然完成并保留，不以较快复测覆盖它。上述分组有交集，不能相加为新的总用例数。

## 最终统一候选的复跑入口与多端边界

`tool/company_feedback_production/README.md` 给出参数和新目录要求。最终候选清编译产物应同时提供 `classes`、`test-classes` 和仅 jar 的 test scope classpath。使用 `proof_probe.py`、`upgrade_probe.py`、`projection_mutation.py` 重跑；旧 V1128 编译可由 `compile_legacy.py` 再现。全部输出/TMP/数据库独立，旧证据只读保留。最新 owning 聚焦类现为26项；原长轮错误不能通过沿用旧字节码、改松断言或覆盖日志“转绿”。

`seed_browser.py` 已在自有库公开造业务1/1通过，最新同密钥版本另编译通过；最终真实 Web 库必须先用统一源码迁移，再从私有 runtime 配置提供相同 JWT/HMAC/PGP，不能让 fixture 常量加密真实 runtime 的合成员工数据。脚本在连接前拒绝缺密钥，动态属性在 Spring 初始化前覆盖，断言不回显秘密。它提供普通编辑岗、独立审批岗、三料部分领料、300/500草稿及合法齐套工单的页面 ID，最终真实网页/下载和桌面交互由统一候选验收记录承接，不将本包服务层、VM和造数拼成闭环。

已核对 Win7 总计划、逐项清单及当前接手记录。`W7-BIZ-102`（日报编辑）、`W7-BIZ-110`（计划详情）、`W7-BIZ-115`（车间任务）仍为 todo、nativeTargets为空，没有相应原生业务入口；不造 WPF 写壳、不提升373项状态/owner/DoD/依赖，也不宣称 Win7 真机已验。Flutter Web/现有桌面共享本包 Dart 实现；实际窗口、设备及公司原单仍按最终验收分栏。

公司现场应使用原单/原权限核对变更前目标、物料身份与历史；历史材料不足时按当前净配套拒绝新超报，并保留输入，不凭纸面说明补造自动信用。Win7 SP1目标机、公司私有单据/文件和正式 CI 无本包环境，需分别验证原生入口是否已迁移、真实 Web/桌面办理及当前最终 SHA 的 CI；没有这些证据不得签为通过。多人分次领料自动关联仍是评估，自动功能未实施；完整自定义 TEXT/NUMBER 回写不在本包范围。
