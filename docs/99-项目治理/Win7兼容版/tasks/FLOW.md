# 跨模块完整业务闭环

由唯一进度登记表生成。

## W7-FLOW-001

- [ ] **基础资料新增→编辑→状态→引用** — 进行中

影响：`shared`；负责人：Codex；依赖：W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014。

源入口：`lib/core/router/route_names.dart`；`server/src/main/java/com/uten/imp/features`。

完成条件：

1. 真实UUID/字段保留、作用范围/权限、历史、批量/导出打印，至少一完整可写模块先闭合。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`docs/99-项目治理/Win7兼容版/02-业务流程迁移与验收矩阵.md`；`clients/windows_legacy/progress/evidence/biz037-flow001-upd009-20261030.json`；`clients/windows_legacy/progress/evidence/local-main-integration-20261103.json`。

接续/限制：单位→货品真实引用已接：货品保留unitId/unitLegacyId权威UUID关系键+历史快照回落事实区分，详情按UUID导航到单位主档窗口(自带编辑/状态/删除引用保护)；删除保护仍走服务端逐项原因(既有检查钉住)，未自造端点或客户端推导。goods 24→27双架构绿；完整可写模块闭环与目标机验收仍待。；2026-11-03 本地整合：销售备货进度已保存稳定快照，服务端权威区分库存/自产/委外并共用 contracts/sales-preparation-progress/v1.json 样例；Dart详情面板、选单和发货预填消费同一 plan-progress 契约。WPF这些销售入口仍未迁移，不开放候选写入口、不改变本项完成状态，后续须同步数量、生命周期和未知提交语义。。

## W7-FLOW-002

- [ ] **采购需求→订货→审批→到货→库存** — 未开始

影响：`shared`；负责人：待认领；依赖：W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014。

源入口：`lib/core/router/route_names.dart`；`server/src/main/java/com/uten/imp/features`。

完成条件：

1. 来源/单位/币种/差异量、允许动作、版本和财务/仓储核对一致。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-FLOW-003

- [ ] **委外申请→下单→领料→回厂→结算** — 未开始

影响：`shared`；负责人：待认领；依赖：W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014。

源入口：`lib/core/router/route_names.dart`；`server/src/main/java/com/uten/imp/features`。

完成条件：

1. 分批/直接材料/按工序/归属/退回/差异和撤回路径按真实合同。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：2026-11-09 Flutter/Web 物料列修订(ADR-156)：待处理申请行下单前也显示直属物料备齐/缺的种数(工作台行级逐种计数分页后批量下发，点开「齐套情况」弹窗)，与领料行/车间任务共用公共物料组件；本 WPF 入口未迁移，保持 todo，不开放占位写入，不以 Flutter/服务端测试替代原生验收。见 docs/99-决策记录-ADR/ADR-156。。

## W7-FLOW-004

- [ ] **生产分析→BOM→任务→领料→报工** — 未开始

影响：`shared`；负责人：待认领；依赖：W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014。

源入口：`lib/core/router/route_names.dart`；`server/src/main/java/com/uten/imp/features`。

完成条件：

1. 精度/替代/齐套/库存归属/分配/超领/回执，不在客户端重算权威。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`clients/windows_legacy/progress/evidence/order-bom-delivery-20261104.json`。

接续/限制：；2026-11-04：订单BOM交付配置、必要加工、组件实物库存及发货合同新增；本WPF入口尚未迁移，保留原状态/DoD/依赖，不开放占位写入。见E-ORDER-BOM-DELIVERY-20261104。。

## W7-FLOW-005

- [ ] **仓库预计→到货→质检→入库→领用** — 未开始

影响：`shared`；负责人：待认领；依赖：W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014。

源入口：`lib/core/router/route_names.dart`；`server/src/main/java/com/uten/imp/features`。

完成条件：

1. 超量隔离、先入库后质检、库位/叶仓、批量和恢复身份正确。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-FLOW-006

- [ ] **库存盘点→复核→调整→台账** — 未开始

影响：`shared`；负责人：待认领；依赖：W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014。

源入口：`lib/core/router/route_names.dart`；`server/src/main/java/com/uten/imp/features`。

完成条件：

1. 快照/历史/单位、审核版本、未知提交与账实对应。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-FLOW-007

- [ ] **财务采购审批→支付/对账** — 未开始

影响：`shared`；负责人：待认领；依赖：W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014。

源入口：`lib/core/router/route_names.dart`；`server/src/main/java/com/uten/imp/features`。

完成条件：

1. 共享任务、expectedVersion/claim等真实字段、币种税率/汇率和权限边界。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-FLOW-008

- [ ] **销售报价→核价→订单→财务确认** — 未开始

影响：`shared`；负责人：待认领；依赖：W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014。

源入口：`lib/core/router/route_names.dart`；`server/src/main/java/com/uten/imp/features`。

完成条件：

1. 退回/改价/确认/撤销，来源与版本/claim、输出单据一致。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`clients/windows_legacy/progress/evidence/order-bom-delivery-20261104.json`。

接续/限制：；2026-11-04：订单BOM交付配置、必要加工、组件实物库存及发货合同新增；本WPF入口尚未迁移，保留原状态/DoD/依赖，不开放占位写入。见E-ORDER-BOM-DELIVERY-20261104。。

## W7-FLOW-009

- [ ] **品质检查→判定→处置→回流** — 未开始

影响：`shared`；负责人：待认领；依赖：W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014。

源入口：`lib/core/router/route_names.dart`；`server/src/main/java/com/uten/imp/features`。

完成条件：

1. 检验单/批次/记录、补料/返工/退回、allowedActions及原件。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-FLOW-010

- [ ] **HR档案→修改申请→审核→账号生命周期** — 未开始

影响：`shared`；负责人：待认领；依赖：W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014。

源入口：`lib/core/router/route_names.dart`；`server/src/main/java/com/uten/imp/features`。

完成条件：

1. 组织/员工/岗位/移交/禁用、别名历史、不可重做既有数据修复。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-FLOW-011

- [ ] **权限/模板/数据范围→读写/导出** — 未开始

影响：`shared`；负责人：待认领；依赖：W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014。

源入口：`lib/core/router/route_names.dart`；`server/src/main/java/com/uten/imp/features`。

完成条件：

1. 委派/模拟只读、撤权退役、角色/部门/多人归属与审计，不能只看按钮。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-FLOW-012

- [ ] **报销→附件→审批→支付** — 未开始

影响：`shared`；负责人：待认领；依赖：W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014。

源入口：`lib/core/router/route_names.dart`；`server/src/main/java/com/uten/imp/features`。

完成条件：

1. 原附件/金额/发票/组织范围、草稿及未知提交，拒绝/撤回一致。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`clients/windows_legacy/progress/evidence/employee-applications-20261103.json`。

接续/限制：2026-11-03 报销/行政财务申请：新四级报销及四类申请、负责人本人回避、独立权限/徽章/付款与打印合同已变更；原生业务仍未迁移，保持原状态及 DoD。仅公共 read-scope 识别完成本机 x86/x64 fixture，不等于业务或目标机验收。合同见 clients/windows_legacy/progress/contracts/employee-applications-workflow.json。。

## W7-FLOW-013

- [ ] **工资条/成本/费用敏感读取** — 未开始

影响：`shared`；负责人：待认领；依赖：W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014。

源入口：`lib/core/router/route_names.dart`；`server/src/main/java/com/uten/imp/features`。

完成条件：

1. 财务遮罩/授权/审计/导出和密码，数据不能跨身份缓存。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-FLOW-014

- [ ] **通知/建议/询盘→办理→回执** — 未开始

影响：`shared`；负责人：待认领；依赖：W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014。

源入口：`lib/core/router/route_names.dart`；`server/src/main/java/com/uten/imp/features`。

完成条件：

1. 来源深链、发布/阅读/处理权限、附件/历史，不落空占位页。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`clients/windows_legacy/progress/evidence/notice-ack-read-badge-20261103.json`。

接续/限制：2026-11-03 通知收到/未读合同增量：当前 WPF 通知列表、详情、外壳未读徽标及收到动作均未迁移；MainWindow 仅工作台/货品/单位入口，DashboardView 仅 GET /dashboard/overview，未接通知回执。后续迁移须由服务端同事务保存本人收到与已读，列表/详情/筛选/未读计数/弹窗同一权威状态；重复收到幂等，未知结果不盲重放。卡片红点与未读文字移至顶行右侧、与类型 icon 同排并放大；异步动作复用原生等待层及防连点，保留身份/权限/读取代次隔离。仅登记待迁移合同，不新增原生写入口，不提高任务状态或 Win7/完整 ERP 验收；见 E-NOTICE-ACK-READ-BADGE-20261103。。

## W7-FLOW-015

- [ ] **访客员工审批→被访→保安办理** — 未开始

影响：`shared`；负责人：待认领；依赖：W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014。

源入口：`lib/core/router/route_names.dart`；`server/src/main/java/com/uten/imp/features`。

完成条件：

1. 保留员工功能，门户退役另分类；扫码/手工/黑名单权限与流程。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-FLOW-016

- [ ] **公司文件→授权→版本/原件** — 未开始

影响：`shared`；负责人：待认领；依赖：W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014。

源入口：`lib/core/router/route_names.dart`；`server/src/main/java/com/uten/imp/features`。

完成条件：

1. 上传下载/目录/权限/历史/并发/取消/原件字节及更新不删附件。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-FLOW-017

- [ ] **业务导出/打印完整性闭环** — 未开始

影响：`shared`；负责人：待认领；依赖：W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014。

源入口：`lib/core/router/route_names.dart`；`server/src/main/java/com/uten/imp/features`。

完成条件：

1. 筛选与列投影、密码、完整快照、大文件/真实打印、取消/重复/权限撤销。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-FLOW-018

- [ ] **编辑中切服/注销/断网/重启/升级** — 未开始

影响：`shared`；负责人：待认领；依赖：W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014。

源入口：`lib/core/router/route_names.dart`；`server/src/main/java/com/uten/imp/features`。

完成条件：

1. 跨模块草稿/owner/版本/回执保全，不能丢输入或让旧响应复活。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-FLOW-019

- [ ] **统一进度弹窗：UtenBusyDialog 确定进度模式与 Flutter 端同步** — 源码已实现/待整合验证

影响：`shared`；负责人：bruce；依赖：W7-CORE-011, W7-CORE-012, W7-CORE-013, W7-CORE-014。

源入口：`clients/windows_legacy/Uten.Legacy.Desktop/Controls/UtenBusyDialog.cs`；`clients/windows_legacy/Uten.Legacy.Desktop/Features/Units/UnitExportWindow.cs`；`clients/windows_legacy/Uten.Legacy.Desktop/MainWindow.xaml.cs`；`clients/windows_legacy/Uten.Legacy.Desktop/Features/Downloads/SoftwareDownloadsView.cs`；`lib/components/feedback/uten_progress_dialog.dart`。

完成条件：

1. UtenBusyDialog 新增 ShowProgress 确定进度模式与 Report/Stage 汇报；总量未知走扫动条+详情，不伪造百分比；样式走 Uten.PrimaryBrush/Uten.Space 资源。
2. 单位导出下载、更新下载两流程接入；安装包下载页既有内联进度（Uten 资源样式+取消）确认合规不改。
3. 已提交业务请求不提供误导性取消；单请求型与 Flutter 端 cancellable:false 同口径。
4. C# 级编译验证（本机 dotnet msbuild 无法生成 XAML codegen，过滤 XAML 名错误后本次改动零错误）；Win7 真机验收未做。
5. 未迁移项明确记录：WPF 端无同步导出生成进度协议（服务端进度端点）与 UtenProgressRing 圆环组件——按需后续补。

证据：`clients/windows_legacy/Uten.Legacy.Desktop/Controls/UtenBusyDialog.cs`；`clients/windows_legacy/Uten.Legacy.Desktop/Features/Units/UnitExportWindow.cs`；`clients/windows_legacy/Uten.Legacy.Desktop/MainWindow.xaml.cs`；`docs/99-项目治理/evidence/screenshot-feedback-20261110/shared-table-goods/wpf-busy/README.md`；`clients/windows_legacy/progress/evidence/screenshot-feedback-20261110.json`。

接续/限制：2026-11-09 随 Flutter「导出/下载/批量操作统一进度弹窗」批次实施；Flutter 侧组件 docs/02-组件库/通用进度弹窗.md。状态 implemented：代码就位，Win7 真机 UAT 未完成，不据此开放任何已支持组合。；原evidence非路径描述原文留存（不把旧构建失败改写为通过）：clients/windows_legacy/Uten.Legacy.Desktop/Controls/UtenBusyDialog.cs（ShowProgress/Report/Stage）；clients/windows_legacy/Uten.Legacy.Desktop/Features/Units/UnitExportWindow.cs DownloadAsync（下载全程持弹窗+取消传输令牌）；clients/windows_legacy/Uten.Legacy.Desktop/MainWindow.xaml.cs OnCheckUpdate（确定进度 received/SizeBytes+幂等 Dispose 收尾）；本机 dotnet msbuild：85 个错误全为 XAML 生成名缺失（既有环境限制），本次新增符号零错误；2026-11-10 E-SCREENSHOT-FEEDBACK-20261110：WPF公共确定/未知进度模式切换。完整入口、公共实现、真实运行时与保留差异见docs/99-项目治理/2026-11-10-十四张截图反馈修复.md。任务原status/owner/DoD/依赖/nativeTargets保留；Flutter或服务端通过不等于本项原生业务、Win7目标机或正式交付完成。 Stage/未知总量切回扫动，Report已知计数恢复确定；本机x86/x64完整含XAML编译TreatWarningsAsErrors，各65项控件断言及PE/CLR校验通过，状态仍implemented；旧DoD括注为当时环境事实，当前结果以上述新证据为准。。
