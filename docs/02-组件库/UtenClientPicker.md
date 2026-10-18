# UtenClientPicker · 客户选择器

> 源码：[`uten_client_picker.dart`](../../lib/features/basic_data/widgets/uten_client_picker.dart)(配置) + [`uten_master_picker.dart`](../../lib/features/basic_data/widgets/uten_master_picker.dart)(面板与字段本体) · 统一层级搜索契约：[UtenHierarchySearch](UtenHierarchySearch.md) · 最后核对：2026-10-17。
>
> 2026-09-23(ADR-111)：客户与供应商选择器原是两份 84% 相同的面板，现合为泛型 `showUtenMasterPicker<TItem>` / `UtenMasterPickerField<TItem>`；`showUtenClientPicker` 与 `ClientPickerField`(以及 `showUtenSupplierPicker` / `SupplierPickerField`)保留原函数名与构造参数，只提供仓储闭包、文案与供应商的「添加供应商」。客户和供应商通过 `tableColumns` 配置重点字段表格；供应商仅显示名称、联系人、联系电话和地区，不生成不存在的编号；其余搜索、分页与确认契约共用。

## 一、用途与入口

`showUtenClientPicker(context, ref)` 用于销售、钱流等单据表头选择客户，返回 `ClientListItem?`；取消返回 `null`。`UtenClientPickerField` 是表单字段包装，只提交客户 ID。

选择器取代旧的平铺客户字典：用户可以按分类浏览，也可以直接输入分类名称/编号或客户名称/编号等字段定位。客户列表与主档服务同源，继续受 `client:view` 及服务端客户 owner 可见范围约束；前端不复制权限过滤。

**二次操作契约(2026-08-16，全站滑窗统一)**：点客户行仅高亮暂选(整行使用共享表格选中色 + 底部确认栏显示「已选择：客户名(编号)」)，必须再点底部「确定」才把选中客户返回给调用方并关闭面板；「取消」(或右上角关闭/点遮罩)= 放弃选择。底部确认栏是共享的 [UtenPickerConfirmBar](UtenPickerConfirmBar.md)。

## 二、响应式布局

- compact：`showUtenAdaptivePanel` 底部抽屉，搜索与分类入口移到表格上方，分类树通过入口展开，表格使用可用宽度。
- medium/expanded：右侧滑入面板，**宽 = min(屏宽, max(720, 屏宽 × 75%))**（2026-10-17 全站滑窗档位 `UtenPanelWidth.browse`，720 只作小屏下限）。
- medium+ 面板内部为“左客户分类树 + 右客户分页表格”；中间是 [UtenSplitView](UtenSplitView.md) 可拖分割线（持久化 key `masterPicker.categoryTree`），**默认左栏宽 = 全树最长一行「名称(编码)」实测宽**（夹在 200–560），双击复位。
- 左树为无缩进层级色模式（`UtenCategoryTreeView(flatLevelColors: true)`，与货品选择滑窗同款）：一级深绿白字、二级浅灰、三级更浅，方角紧凑行；单根包装分类自动提升不占一层（`hoistSingleRootTree`）；**默认全部收起**（`initiallyExpandDepth: 0`，2026-09-24），搜索命中路径仍自动展开。
- 右侧复用货品选择器同款 `MasterDataTableView`，仅显示 **客户名称、编号、联系人、联系电话** 四列。名称优先简称，空白时使用全称；联系电话依次取手机、联系电话、备用电话的首个非空值。地址、银行、税号、信用额度等详细资料不在选择器内展示。
- 表格保持单击暂选、底部确认后返回；列头固定，窄屏可横向滚动。只使用左侧统一搜索，不增加列搜索框、列选择入口或主档自定义列；不绑定客户主档表格布局，避免主档配置把额外字段带入选择器。
- 左侧分类区手动最小宽从 200 调整为 160dp；分类展开按钮、选中标记和按实际字号测算的标题片段仍保留安全空间，文字放大时可自动提高下限。初始自然宽、宽度记忆和双击复位沿用共享分栏规则。
- 搜索框按左栏实际可用宽度调整两侧留白：不足 240dp 时为 8dp，其余为 16dp，compact 保持 8dp。缩窄后仍可输入、清除搜索和展开/选择分类，长分类名称保留完整路径提示。
- 搜索框始终在左树顶部，不因抽屉/侧滑形态退化成右侧独立搜索。
- 底部固定 `UtenPickerConfirmBar` 确认栏（取消 / 确定；未选中时「确定」禁用）。

## 三、统一搜索

- 一个关键词同时匹配分类名称/编号，以及客户名称、编号、全称、联系人、手机等服务端 keyword 字段。
- 浏览与搜索都向主档接口传 `excludeLegacyFinanceStub=true`，由数据库在分页前排除 legacy 财务占位；搜索再按服务端分页完整汇总授权范围内的有效客户并按客户 ID 去重，因此不会出现占位吃掉整页、漏掉后续真实客户或显示错误页数。
- 内容命中默认定位首个有效分类，右侧展示跨分类结果；翻页复用已完成的客户与分类定位缓存，不用当前页覆盖整棵命中树。
- 点击包含命中客户的分类分支时，右侧改为“该分类子树 + 同一关键词”；只命中分类时，右侧展示该分类全部客户。
- 请求使用 300ms 防抖与 request version；加载、搜索失败、完整定位失败、无结果均有可见状态。清空框才完全退出搜索态。
- V272 候选之后，数据层的正常客户、官网询盘转客户与 legacy 财务占位都绑定真实、受保护的“未分类”系统根（本选择器仍按上文排除财务占位）；可见的未分类客户命中时应展开并选中该根，不再把“未分类”当成无节点结果。`categoryId` 为空或不在当前树只作为滚动升级/脏数据防御：不形成无效选中，右侧仍可展示服务端授权范围内的全局客户结果。

## 四、数据与权限

- 分类树：客户分类 repository。
- 浏览：`GET /api/master/clients?categoryId=&excludeLegacyFinanceStub=true&page=&size=`，`categoryId` 为子树范围。
- 搜索：`GET /api/master/clients?keyword=&excludeLegacyFinanceStub=true&page=&size=100`，逐页收集有效客户和定位信息，再在选择器内按 100 条分页。
- 权限：分类树与客户列表各自接受后端权限校验；客户列表仍执行 owner 可见范围，选择器不能放宽为全库。
- 旧财务占位客户（编号前缀 `LEGACY-FIN-CL-`）在列表和定位中都排除。
- **禁用客户（`status=禁用`）不进选择器**（2026-08-16）：单据不能再选禁用客户开新单。过滤在前端分类浏览与全局搜索两条路径同时生效（`_clientSelectable`）；已删除（软删）客户后端已过滤不下发。客户管理页不受影响，仍显示禁用客户供维护。

## 五、回归测试

[`uten_client_picker_test.dart`](../../test/features/basic_data/widgets/uten_client_picker_test.dart) 覆盖：宽屏单一搜索、分类名称搜索、跨分页分类完整展开、legacy 占位跨页过滤与页数重算、compact 形态无布局异常；2026-08-16 起两处选中用例按二次操作契约改为「点行高亮 → 点确定返回」。共享的分页取消、树外 ID 和分支保留规则由 `category_tree_search_test.dart` 覆盖。

2026-10-17：客户重点字段表格与名称/电话回退、取消不回填、暗色及紧凑布局检查沿用上述测试入口；客户和供应商共用分页状态，供应商表格继续由 `uten_supplier_picker_pagination_test.dart` 验证。分类区拖窄至 160dp 后的搜索、清除、展开、选择、确认与宽度记忆，以及放大和触控模式的安全下限，继续由 `uten_client_picker_test.dart` 覆盖。
