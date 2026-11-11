# B 最终真实网页准备（prep）

本目录基于 `6e1bfd38a5b6f8db1ce565abcd9216ec8b2919e2`，仅新增验收夹具、脚本和证据，未改产品。最终整合 SHA 尚未冻结。Root 的 `28630` 仍是旧 `7b` 运行程序；本文的准备、独立服务 PG 与控件测试均不能计为最终真实 Web 通过。

Root 数据库 `127.0.0.1:26630/feedback` 只做只读 RR 查询，未登录、造数、改 ACL、改科目或重启服务。A 的 Windows 操作窗口结束且 Root 明确放行后才能执行下文写入步骤。

## 已完成的独立旧程序升级证据

原 B 报告确实未完成“真实旧程序公开保存历史草稿”。本次补齐：

1. 原审计树 HEAD 为 `fdeda88b3d73b24b8691ad132caa765196b19a3d`，`server/src/main` / `pom.xml` 无未提交修改。复制其 `audit/orders-returns/target/classes` 与测试支持；主程序字节不改。`legacy-runtime-provenance.json` 逐文件保存复制主产物 SHA-256。只将当前 opt-in seed 夹具编译到复制品的 test-classes，旧主程序中不存在 `ProcurementReturnOrderAuthority`。
2. 独立容器 `uten-feedback-b-legacy-prep-20261111`，端口 `26633`，原库 `bremediation`。旧程序公开 `create` 保存采购、委外 receipt-only 草稿；未直接 UPDATE/伪造 orderItemId 或 null 历史。旧程序 `old-program-run1/seed-web.log` 与 XML 为 1/1 通过。
3. `old-program-before-upgrade.json`、`old-program-seed.json` 保留原草稿/明细/owner/收货/订单祖先/数量，原 `order_item_id`、`price` 均确为 null。旧库私有 dump 保留于 `private/old-program-before-upgrade.dump`，SHA-256 `8bd30213423f079219a36ad7edf3814828090d0ee6e6731ad393793dbf6b1df1`。不提交私有 dump 或密钥。
4. 当前候选源码完整重新编译（`current-compile-2.log`），普通 Flyway 从旧 v1129 升到 v1131。不同 ordinary `approver` 公开 approve 两类旧草稿。只在审批业务内由真实 receipt 祖先补齐 order，旧 owner / item / receipt / qty 保留。
5. 原 `upgrade-run1` 已完成两类审批和 stock/AP 核查，随后追加财务夹具调用旧 `seedWorld` 时，跨 JVM 静态序号从 9000 重启，撞旧单位 9001。原失败日志/XML与已审批库保留。只修夹具为复用原部门；从旧程序 dump 正常恢复到同容器独立 `bremediation_retry`，不回滚/篡改原已审批单。
6. `upgrade-run3` 1/1 通过；另一个 ordinary `finance_post:execute` 公开生成两次 GL。采购 qty=9、stock=90、AP=-10、GL inventory=-10；委外 qty=9、stock=540、AP=-50、GL inventory=-60、variance=+10，价差凭证唯一 1 份，每张退货 GL 借贷净额 0。见 `upgrade-run3/result.json`、`after-source-counters.json` 和原 XML。

采购旧草稿 `1edc1ea0-24ec-490c-8822-0d45f5faa056`，明细 `75e166fb-f5dd-4f73-ba36-cb33c7219b70`；委外旧草稿 `387014d7-bb34-42b8-9be7-7f008b7b317f`，明细 `b7604f5a-480a-42fd-9244-12a2aaac6cf9`。这是真旧程序→当前服务升级证据，仍不是浏览器操作证据。容器及原/重试数据库均保留。

其他原失败同样保留：`current-compile-1` 为 PowerShell 未引用 Maven 属性导致命令解析失败；`upgrade-run2` 在旧库恢复尚未结束时读取配置失败，尚未启动 JVM；`transport-test-1` 错把流 high-water threshold 当硬上限，测试断言失败。修订后 `transport-test-2` 比较 256 KiB 全部原请求字节及合成头一致，upstream 只收到 1 次，暂停缓冲实际 65289 字节，小于测试的 128 KiB 界限；不改任何 API 值。

## Root 只读源核对与真实页面

`root-readonly-source-3.json` 是一个明确 read-only / REPEATABLE READ 快照，来源同 Root `web-seeds/b.json`。以下名称来自真实库，进入页面可用单号/代码准确定位：

| 项目 | 采购 | 委外 |
| --- | --- | --- |
| 页面 | `/purchase/returns/new` | `/subcontract/returns/new` |
| 收货来源 | `CJ20261111000001` | `EJ20261111000001` |
| 订货祖先 | `CD20261111000001` | `EO20261111000001` |
| 供应商代码 | `SUP-gift-f0f11c73-b246-4ed3-a1e4-2b0bf72ac563` | `SUP-sc-return-gl-32ae9c33-157e-4ba2-a11a-d6f3f31e12cc` |
| 供应商名称 | `测试供应商-gift-f0f11c73-b246-4ed3-a1e4-2b0bf72ac563` | `测试供应商-sc-return-gl-32ae9c33-157e-4ba2-a11a-d6f3f31e12cc` |
| 仓库名称 | `测试仓库-gift-f0f11c73-b246-4ed3-a1e4-2b0bf72ac563` | `测试仓库-sc-return-gl-32ae9c33-157e-4ba2-a11a-d6f3f31e12cc` |
| 货品代码 | `D-gift-f0f11c73-b246-4ed3-a1e4-2b0bf72ac563` | `E-sc-return-gl-32ae9c33-157e-4ba2-a11a-d6f3f31e12cc` |
| 货品名称 | `原料D-gift-f0f11c73-b246-4ed3-a1e4-2b0bf72ac563` | `委外E-sc-return-gl-32ae9c33-157e-4ba2-a11a-d6f3f31e12cc` |
| 收货状态/量/单价 | 已审 / 10 / 10 | 已审 / 10 / 加工费 50 |
| 初始 stock qty / amount | 10 / 100 | 10 / 600（材料+加工） |

已核实路由来源为 `route_names.dart` / `app_router.dart`；上游选择器配置和共用 sheet：采购 `doc_link_picker.dart`、委外 `subcontract_link_picker.dart`、`uten_doc_link_picker_sheet.dart`。产品保存组装 `_linkItemKey` 优先仅提交 `receiptItemId`；不能用请求补填 orderItemId 掩盖原反例。

## Root 真 Web 操作及 SQL 前后核查

1. Root 先冻结最终 SHA，重新运行同 SHA backend/frontend，记录 actual classes、静态 Web hash 与数据库迁移版本；本目录 prep SHA 不替代。由 CUA 操作浏览器，不使用 CDP、Fetch 或外部脚本控制浏览器。业务日按 `BusinessTime`（Asia/Shanghai）真实当天和开放期间核对，不绕锁期。
2. 使用 `snapshot.py --config ROOT/evidence/root/private/runtime.json --seed ROOT/evidence/root/web-seeds/b.json --out NEW/before.json`。每次新文件名，不覆盖原证据。脚本会拒绝覆盖；单个只读 RR 快照同时查 receipt/order 祖先与已退量、全部关联退货、库存余额/事件、AP、GL、ordinary actor、物料 command/batch/event/action/allocation/真实采购申请。
3. CUA 以 `b.json.maker.login` 登录，密码仅从 private 配置在输入框使用，不入日志。打开上述采购页面，先不选供应商，点击 **从上游引入**，选单号 CJ…，进入明细，勾选准确 D… 行。核对 **剩余** 为 10，**本次数量** 输入 `0.123456789012345678901234`；确认引入，核对供应商、仓库及来源自动回填、数量原文不变。快速重复点击只存在一套引入过程；取消选择器不追加行。
4. **保存，下一步审核**，记录实际返回的退货 UUID/单号，保存后详情数量仍为精确原文。CUA 进入 `/purchase/returns/{实际id}/edit`，数量改为 `1`，再保存。保存/编辑两个阶段均补 SQL 快照：status=0、来源相同、order已由权威receipt解析，stock/AP/GL 不发生退货副作用。
5. CUA 退出 maker，登录 `b.json.approver.login`（不同 ordinary 用户），打开 `/purchase/returns/{实际id}`，点 **审核** 并确认。记录等待件正常收尾、成功详情状态。快照：原 maker 不变，approver=该 ordinary 员工，qty=1，price=10，stock qty9/amount90，receipt/order returned_qty 增 1，AP 该单 -10，退货库存事件和价值事件无重复。不得拿“单据状态变已审”替代各账口径。
6. 用同样步骤实际完成委外 `/subcontract/returns/new`，来源 EJ…，上游选择器标题 **从委外进仓单引入**，真实 E… 行；先保存精确数量再编辑为 `1`，由另 ordinary approver 审核。快照 qty9/stock540、AP -50，来源返回数量增 1。加工费50与实物实际成本60各自保持权威。
7. GL 前置尚未通过：`root-readonly-posting-roles.json` 证明 Root 当前 `INVENTORY_ASSET`、`PROCUREMENT_RETURN_VARIANCE` 均未配置。Root 写窗口后须经合法合成科目配置流程补必要科目，再用独立 ordinary 财务岗位实际执行 `POST /api/finance/gl/generate?period=2026-11`（页面按钮以当前界面为准）。不能用超级管理员直接业务审批或把空GL当通过。生成两次后快照：采购退货 asset=-10；委外退货 asset=-60、return variance=+10；每张退货 GL 借贷净额0、重复生成无重复凭证。若最终候选的科目/期间流程未完成，明确单列待验。
8. 每个阶段保 CUA 截图、实际 HTTP path/status 的原代理日志及新 SQL 快照。同一个实际单据串起引入→保存→编辑→不同岗位审批→账；服务PG/VM不拼接成真Web。需要请求形状时，CUA 打开浏览器 Network，只保合成 Request Payload 的精确内容/截图；不保存 Headers、token、密码或完整 HAR。与 SQL 的 receipt/order、command key/hash 对照。

两类真实 HTTP：`GET /api/{purchase|subcontract}/receipts`、`GET /api/{purchase|subcontract}/receipts/{id}`；`POST /api/{purchase|subcontract}/returns`；`PUT /api/{purchase|subcontract}/returns/{id}`；`POST /api/{purchase|subcontract}/returns/{id}/approve`。分页/资格参数以实际 UI 请求记录，不手工伪造来源资格。

## 真确定未写：500 → 原处 499

现有 Root B planner 只有 view/notify/over_supply，缺 `production_material_analysis:route`。不得内部直调绕权限。准备的 `seedIndependentMaterialOrderCases` 在**明确写窗口后**可另建两个独立 analysis/goods 与有 view/route/notify/over_supply 的 ordinary owner；不改原 ACL 或原 analysis。该方法已在 26633 自有库 `order-fixtures-own-1` 1/1 通过，两个 seed 各保独立输入、owner和物料路径。

`run_public_service.py` 的 `--build` 必须是新的私有编译输出/副本，禁止传正在运行的 Root build 或原 audit target；`--fixtures` 仅提供测试支持复制源。运行示例（变量均由最终候选实际路径指定）：

```powershell
python evidence/b-final-prep/run_public_service.py --config $runtime --seed $bSeed --build $privateBuild --fixtures $fixtureBuild --out $newFixtureRun --method seedIndependentMaterialOrderCases
python evidence/b-final-prep/run_public_service.py --config $runtime --seed $definiteSeed --build $privateBuild --fixtures $fixtureBuild --out $newHelperRun --method stalePreviewViaSameOwnerRoutes --gate $rootPrivate/transport-holds/$newTag
```

`helper-own-contract-1` 只验证预热/ordinary owner权限/同路线合法保存/版本从2变3；其 hold 信号是明确写着“fixture contract probe; no real Web”的夹具信号，**未发真实UI请求、不能计为原提交409**。

真实执行步骤：

1. Root 审查 `proxy-with-hold-prep.mjs` 与 `submit_hold.mjs`，在允许重启本地代理的窗口，将二者放到 Root 原代理相同目录（使用原 `web/`、`private/runtime.json`），新 runTag 启动准备副本。保留原代理字节和关闭后的原日志；本次未安装或运行 Root 副本。
2. 启动上述 helper，等 gate 内 `helper-ready.json` 出现：Spring 已预热、ordinary owner及route/view权限明确，尚未修改路线。helper仅SecurityContext，不发 HTTP login，不更替浏览器session。等待真实 gate 最多10分钟。
3. CUA 用对应普通计划员打开 `/production/material-analyses/{analysisId}/summary`，核对按物料汇总的真实货品，填总量 `500`，选择合法“足额下单，不扣可用数量”口径/公共备货许可；先等合法预览稳定。保持真实UI实际选择，不替换请求值。
4. `python arm_transport.py --private $rootPrivate --analysis $analysis --mode hold --tag $newTag`。它要求匹配 helper-ready，精确一次性路径只能是 `POST /api/production/material-analyses/{analysisId}/aggregate-orders/submit`。然后 CUA 点下单并确认。Node 在构造 upstream 前暂停原 IncomingMessage及socket、形成有界背压；只写 metadata-only ready，不动任何原header/body。
5. helper看见真实 `hold-ready.json` 后，以同ordinary owner公开 `saveRoutes`，路线仍BUY，仅合法原因更新，保业务检查，版本实际增加；完成后写 release。代理原样转发真实UI请求。服务真实 submit 应返回409；不是伪造422，也不直接 UPDATE version/关trigger。保原代理日志中的 submit409及helper两版本。40秒未释放只断开传输、不转发，按未知/未送达事实另列，不能算确定409通过。
6. SQL核对该旧 key **无 `AGGREGATE_ORDER` command/新batch/event/action/申请写入**，仅合法 `ROUTE` command增加；界面保留 `500`、选择和草稿、等待消退，原数量格可编辑。就在同处改 `499` 再点下单，合法预览后成功；本次 fresh key 与原拒绝key区分，实际申请/供给总量499。截图与快照必须属于同一 analysis、同一个最终运行版本。
7. 如果只在确认前saveRoutes使 preview409，单列“真实预览确定未写/保输入”，不冒成原submit拒绝。因为UI会重新核对，也可能重用合法缓存预览，本次精确提交hold保证命中真实submit场景。

## 真已提交回包丢失：独立 analysis / 原 key 一笔

1. 使用另一个 `unknown-seed.json`，其 analysis/goods 与确定拒绝场景完全独立。CUA实际普通计划员打开真实汇总页，填 `500`，等合法预览。先存SQL基线。
2. `python arm_transport.py --private $rootPrivate --analysis $unknownAnalysis --mode committed-response-loss`，仅复用原 Root 代理的精确 path 一次性响应丢失机制。CUA确认真实提交。代理等真实server 2xx完整结束后才毁掉客户端响应，API值、请求和服务提交均不改。
3. 原代理日志须记录 `committed-response-loss`、真实2xx；SQL已出现该 `AGGREGATE_ORDER` command和真实申请。界面仍显示未知结果，500/原意图保留、数量和撤销冻结；重开页面/窗口后原票据能恢复。此时不能允许改499或产生第二个新写意图。
4. CUA点击产品已有原意图恢复/重试核对，只重送原body、previewFingerprint和idempotencyKey。比较客户端原合成payload（不含凭据）和command hash；`production_material_analysis_commands` 中 `(analysis_id,'AGGREGATE_ORDER',idempotency_key)` 仍1条、`request_hash`不变，result引用同batch/单据。`preplan_aggregate_batches`、`preplan_aggregate_batch_events`、`preplan_supply_actions`、`preplan_supply_action_allocations`及真实 `purchase_requests`/items 全部无重复，最终总量500。
5. 只有真实回执确认后解除冻结；真实UI恢复与窗口恢复都未执行前状态仍待验，不用VM或PG测试代签。

## 仍需 Root/现场完成

- Root 最终统一SHA冻结后，真实Web两类退货链、确定拒绝500→499、未知提交原key恢复与重开页；本目录只提供可执行准备和独立PG证据。
- Root合法GL科目配置/普通财务岗位/真实期间；当前未配置科目明确阻断GL Web验收。
- 公司真实原单、私有文件、目标Windows/Win7设备仍按原任务现场清单，不能拿本地合成库或WPF未迁移入口标通过。
- 未合 main、未push、未触公司DB、未部署或正式打包。所有私有凭据/密钥/dump留本机忽略目录；原红及旧程序保存库均保留。
