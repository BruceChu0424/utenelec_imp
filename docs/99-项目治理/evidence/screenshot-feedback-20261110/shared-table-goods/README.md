# 图 7 与图 14：公共空表、货品删除证据

源码工作树：`uimp/screenshot-feedback-20261110`，基线 `cb6e9ad26`。本记录不代替主台账的本地主链集成及多端验收结论。

## 原始要求及根因

- 图 7：“即使没有数据 表格的表头也要有”“表头太长的 就要有左右拖动条”。读表原已保留表头，但公共实现有 2026-10-10 的旧规则，专门对零行隐藏横滚条；编辑表零行直接绕过 `UtenHScrollArea`。恢复编辑表横滚时还发现 0→有行会换掉滚动拥有者、把横偏移退回 0，已统一为常驻布局。
- 图 14：“新建货品建议改为可删除，货品应用后再改为不可删除”。单条、批量及详情的删除权限都是 `goods:delete`；原菜单变灰只说明该客户端没有删除权限，不能据截图替用户授予权限。当前有权限、对象范围可写且未使用的新货品可经既有软删路径删除；无权限菜单现直接标明“无权限”。
- 服务端原引用目录主要拦在办业务，已完成或已清理业务可能不再阻止删除。现在复用 `goods_code_usage_facts` 终身首次使用证据，关闭、冲回或删除原业务不消除货品的已使用身份；拒绝原因明确改用停用，不泄露原业务单号、账户或正文。

## 唯一维护入口

- `MasterDataTableView`：普通与覆盖层横滚都保留；空/错/加载提示固定在当前视口内，覆盖层贴提示行下方，不沉到悬浮操作预留空白底。
- `UtenEditableGrid`：零行、表头筛空和有行共用常驻 `LayoutBuilder → UtenHScrollArea`；提示固定可视宽，表头、表体同步且不丢横偏移。两个公共入口都显式设置横滚条 `interactive: true`，不依赖 Flutter 在 Android 上默认关闭滑块拖动的行为。
- `UtenRevisionTable`、`UtenCellRevisionTable` 全部委托 `MasterDataTableView`，没有第二套横滚实现。没有新增表格样式或等待组件。
- `MasterReferenceCatalog` / `MasterReferenceGuard`：永久使用事实作为 `GOODS_USAGE` 拒绝项，继续保留原权限、对象范围、版本、BOM、库存及在办引用检查。
- `V1128__goods_used_identity_delete_guard.sql`：按已有唯一使用来源目录，为实际仍存在的历史引用补首次使用事实；不凭缺失审计虚构“未使用”证明。再加数据库软删兜底，复用相同事实，不改货品 UUID、原单据或权限。旁路只更新 `is_deleted` 原本仅拿 `NO KEY UPDATE`，与首次使用的 `KEY SHARE` 不冲突；触发器现显式升级 `FOR UPDATE`，与应用写路径采用相同互斥强度，等首次使用提交后拒删、回滚后允许未用货品删除。权限说明同步“未用可删、用后停用”，没有增加权限。

## 调用方扫描与迁移

`table-consumers.json` 为本次静态扫描发现的 273 个公共表格相关文件，包含读表、编辑表及两类修订包装的完整源码路径。该清单证明调用路由，不把每页都算作实际交互验收。

普通空结果原先绕开表格、现已迁入公共入口的调用方：

| 调用方 | 本次收口 |
| --- | --- |
| `UtenEmployeeSelectionPanel` | 空候选保留同一表头与人员范围；不补回旧组织名或旧候选 |
| `DepartmentEmployeePicker` | 空候选、加载及错误走公共表行区，重试仍用原部门/关键词 |
| `PagePermissionDrawer._staffList` | 空员工、加载及错误保留原表，授权范围不扩大 |
| `UtenPositionPicker` | 已加载零岗位保留岗位表头 |
| `FinanceAccountPickerPanel` | 搜索无账户保留账户/币种列头 |
| `FinanceDocDetailPage._itemsCard` | 直接收付、预付没有核销行时仍保留本种明细表头 |
| `FinanceAssetPostingPanel._previewLines` | 零项计提预览保留原列 |
| `FinanceAssetDetail` | 零行资产计提计划保留原列 |
| `FinanceActualReceiptContext` | 已授权且可用的到账明细，即使零行仍保留列头；不可用/无权不展开数据表 |
| `FinancePayableStatementAdjustmentDialog` | 未选处理行保留编辑表，仍只能从上方实际应付选择 |
| `ExpenseInvoiceSection` | 无发票记录仍保留发票列头 |
| `WorkshopTaskMaterialTable` | 非 compact 的零物料表保留列头 |
| `ProductionMaterialReturnRequestSheet` | 零可退余料保留来源/数量等表头，原提交资格继续禁用 |
| `ProductionMaterialSettlementSheet` | 零待登记材料保留原编辑表，来源不可手工新增 |
| `WorkshopMaterialRequestDialog` | 无退料候选保留表头，不开放新增候选来源 |
| `WorkshopMaterialIssuePage` | 已选择车间但无整批料时保留编辑表；数量/首次用途/未知提交合同不变 |
| `StartConfirmationSheet` | 不需确认的工单保留确认产品列头，直接开工语义沿用 |

品质批量审批/成品批量入库的零行路径由仓库子任务同步核对，最终结论见主台账及该子证据。

## 保留的语义差异

- `standalone-table-inventory.txt` 覆盖全部裸 `Table` / `DataTable` 构造：12 处、6 个文件，均为公共打印、BOM 打印、采购打印、费用打印、执行卡打印预览或货架标签打印排版；这些纸面布局继续保留原版式，不套业务查询横滚行为。
- `UtenRackGrid` 是实物库行/层/位图；耗用趋势是图表；移动端产品/物料卡片、资产审批轨迹、导入报价选项等原本就是卡片/列表，不伪造表头。
- `WorkshopMaterialPrepTab` / `WorkshopMaterialEnablePanel` 上方完整产品摘要表常驻；下方是明确打开后才产生的编辑 workset。没有打开、读取已退休或权限被撤回时，不凭展示表头创建工作集或发布旧输入。
- 未选择必要客户/仓库/内料仓、来源任务不存在、首次动态原表还未导入列定义、修订快照未保留，均保留其来源/权限/未知提交提示，不伪造服务端列或业务来源。已有授权表格的普通零行结果不走这些路径。
- WPF 的 `UtenDataGrid` 仍保留原生 `HeadersVisibility.Column` 和按列宽横滚；货品读取工作区仍是只读候选。本次服务端新规则对任何合法写调用生效，但不开放尚未迁移的 WPF 货品删除/业务写入口，也不把本机检查算作 Win7 真机完成。

## 验证与失败保留

- `table-widget-pass.log`：25 项通过，覆盖空表普通/覆盖层横滚、表头同步、空态提示可见、0→有行→0、编辑表横偏移、长表末行及悬浮操作避让。
- `table-offset-initial-failure.log` 保留最初回归：测试短表头没有真实横溢出，以及编辑表零行/有行切换时滚动拥有者退回 0。修复拥有者后改用真实长表头验证，没有放宽到允许跳回 0。
- 调用方首轮 93 项中 92 项通过；唯一失败是旧测试要求“无候选时整个表不存在”。`caller-scope-initial-failure.log` 保留原失败；新断言要求表头存在、真实候选 ID 集合为空，并继续验证旧组织名称不能把新范围候选补回。
- `caller-followup-pass.log`：36 项通过，包含该权限/范围用例、财务账户、材料登记与余料退仓。未知回执后冻结输入、同键重试、取消后恢复及连续批次意图均保留。
- `table-pointer-pass.log`：17 项通过，包括真实鼠标按下、连续拖动滑块及抬起后横偏移增加，再检查表头同步。`table-pointer-platform-initial-failure.log` 保留原始失败；查 Flutter 实际 owning SDK 确认 Android 平台缺省禁用滚动条手势，现由公共横滚入口显式打开。
- `caller-final-migrations-pass.log`：发票、应付费用处理、开工确认和可展开编辑行 33 项通过；另在首次最终批次中，2000 行完整编辑源、旧禁用回调拒写和 primary 表格横滚 7 项通过，其他文件当时被 totals 并行编译错误挡住，失败保留于 `caller-totals-initial-compile-failure.log`，修复后才记录 33 项结果。
- `caller-final-analyze-pass.log`：最终新增调用方分析器零问题；首次可空值问题已修，不忽略分析错误。
- Windows 原生实际运行在主任务中进行；首次编辑表测试误把宿主自动竖滚也计入横滚，后按真实控制器轴向精确断言业务横滚数量，仍要求恰好一条横轴，未放宽数量。主任务保留 `build-feedback-native.log` 并负责复跑。
- `backend-initial-compile-failure.log` 保留首次后端测试编译失败（并行新增仓库测试的 wildcard 泛型断言），责任子任务修复后重跑。
- `goods-delete-concurrency-initial-failure.txt` 保留真实数据库首次使用/旁路删除竞态，两次都实证删除提前成功；没有放宽锁等待断言。修复后 `backend-final-pass.log` 及四份 Surefire 摘要证明 **40 项通过、0 失败/错误/跳过**，包括全部 1067 个迁移成功到 V1128、历史引用回填、已清理业务仍拒删、首次使用先提交拒删和首次使用回滚允许删除，以及原编号复用/撤销/权限保留用例。
- `backend-permission-final-pass.log`：权限展示说明及生命周期 HTTP 合同追加 7 项通过，0 跳过；没有授予任何新的操作权限。
- `native-pointer-final-pass.log`：独立 `integration_test/shared_table_pointer_runtime_test.dart --name 空` 在真实 Windows 引擎 **4 项全过**。保留精确横轴数量、真实鼠标拖动产生位移、表头同步和零行/有行往返。Windows 的 SDK 滑块有 2px crossAxisMargin，硬编码 bottom-2 原命中外边界；现由共享测试辅助读取公开 painter 的 `hitTestOnlyThumbInteractive` 找实际绘制滑块中心，再产生鼠标手势。生产滚动行为没有为测试改坐标，也没有放宽位移断言。

## 浏览器测试阻断的独立根因

原始异常保存于 `browser-host-collision-original.log`。DDC 在 `uten_scroll_behavior.dart.js:17` 取依赖时报 `uten_page_scrollbar_host` 未定义。源码导入图没有从其三个直接依赖回到该行为类的路径。实际 HTTP 响应更直接证明问题：请求 `packages/uten_imp/components/layout/uten_page_scrollbar_host.dart.js` 却得到 638194 字节、dart2js 3.6.1 的非 AMD 测试宿主脚本，其余模块为当前 DDC 3.12.2。

Owning Flutter SDK 的 `flutter_web_platform.dart:391` 使用 `path.contains('host.dart.js')`，误把应用的 `_host.dart.js` 也送入 `_testHostDartJs` 分支（摘录见 `sdk-test-host-route-collision.txt`）。定位期间曾将该生产文件暂时重命名为 `uten_page_scrollbar_owner.dart`，24 个 import 对应迁移，类和内容未变（历史操作列表保留在 `scrollbar-owner-import-migration.txt`）。主任务最终选择从正确的测试工具层修复保留名匹配，已将该文件及 24 个 import **按精确字符串全部迁回原 `uten_page_scrollbar_host.dart`**，保留每个文件的其它并行改动；恢复后的 Git blob 仍为原 `05a4eacdfad37bd6f4c86238458f0ada45eb14b1`，生产源码没有因 SDK 测试路由做最终改名。

最终方案是主任务拥有的隔离 `flutter_tools` 源码副本：修复测试宿主的精确 basename 匹配及 CanvasKit URI 路径，不修改共享 Flutter SDK，也不拆错层级的组件依赖。其余 12 个 `_host.dart` 生产文件同样保留原名。隔离工具的冷启动浏览器结果由主任务记录，不能用 Windows 通过替代浏览器通过。

## WPF 台账接续

直接相关：`W7-UI-004`、`W7-BIZ-025`、`W7-BIZ-034`、`W7-BIZ-063`、`W7-BIZ-176`。保持原 owner、status、DoD、依赖及 nativeTargets；本记录只能作为共享契约/Flutter 增量证据。
