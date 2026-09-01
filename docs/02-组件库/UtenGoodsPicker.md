# UtenGoodsPicker · 货品选择器

> 位置：`lib/features/basic_data/widgets/uten_goods_picker.dart`（跨模块共享，同 `MasterDataTableView` 一样放在 basic_data 域）
> 入口：`showUtenGoodsPicker(...)`（单选）/ `showUtenGoodsPickerMulti(...)`（多选）
> 最后核对：2026-08-27
> 决策背景：[ADR-015 统一货品选择器与 legacy→UUID 桥接](../99-决策记录-ADR/ADR-015-统一货品选择器与legacy到UUID桥接.md)
> 统一搜索契约：[UtenHierarchySearch](UtenHierarchySearch.md)

---

## 一、用途

单据明细 / 报表里**选一个货品**的统一选择器。点明细「货品」单元格（或报表的材料选择）触发，选中返回完整 `GoodsListItem`，调用方按需回填货品 / 颜色 / 单位等字段。

**解决什么**：旧款居中搜索框（`sales_goods_picker` / `goods_picker_dialog`，**已删除**）只有关键词搜索、没有分类树、会把「原材料/辅料/未分类」也列出来、且选中后只返回 `{id,code,name}` 无法自动回填颜色/单位。

**何时用**：通用的「选一个或多个货品」场景——销售 / 采购 / 委外 / 仓库 / 生产（日报、计划、物料分析）单据或分析入口。物料反查因需保留禁用/stub 历史引用并采用独立权限，使用专用 `showWhereUsedMaterialPicker`，不复用本选择器。

**何时不用**：
- 货品资料**管理**（查看/新增/编辑/删除货品主档）→ 用 [基础资料页](../03-页面/基础资料页.md) 的货品资料页（分类树 + `MasterDataTableView` + 详情弹窗）。
- 需要一次选择多个货品时使用同文件的 `showUtenGoodsPickerMulti`；不要在业务页另造选择器。

---

## 二、API

| 项 | 签名 | 说明 |
|---|---|---|
| 入口 | `Future<GoodsListItem?> showUtenGoodsPicker(BuildContext context, WidgetRef ref, {UtenGoodsPickerScope scope = UtenGoodsPickerScope.sellable, bool requireConfirm = true})` | 弹出选择器；默认二次操作（点行高亮 → 底部「取消/确定」确认），`requireConfirm=false` 恢复点行即返回的历史行为；取消/关闭返回 `null` |
| 多选入口 | `Future<List<GoodsListItem>> showUtenGoodsPickerMulti(BuildContext context, WidgetRef ref, {UtenGoodsPickerScope scope = UtenGoodsPickerScope.component})` | 多选款：点货品行勾选/取消（显 ✓），底部「确定(N)」返回所选列表；取消返回空列表。BOM 组装「一个层级添加多个组件」批量录入用 |
| 返回 | `GoodsListItem` | 完整模型：除 `id/code/name/spec/model/price/series/material` 外，还含 `discount/status/legacyId/cNumber/requireRemark/sourceType/categoryId/autoCreated/stockQty/stockPlace` 及颜色、单位 UUID/名称；legacy ID 只作历史溯源，权威字段见 `goods_node.dart` |

> 内部 `_GoodsPickerSheet` 为实现细节，调用方不直接使用。

### scope 参数（按单据场景分流）

默认 `sellable`（成品/可售卖类，排除原材料/辅料/未分类）——历史行为，未显式传参的调用点零回归。

> **2026-08-16 二次操作契约统一**：`requireConfirm` 默认值从 `false` 改为 `true`，单选与多选一致——点货品行仅高亮勾选(✓)，底部为共享 [UtenPickerConfirmBar](UtenPickerConfirmBar.md)(多选带「清空」与「确定(n)」)，点「确定」才返回；点「取消」/右上角关闭/遮罩 = 放弃。所有未显式传 `requireConfirm` 的调用点(销售/采购/委外/仓库/生产等单据编辑页)随之统一。

| scope | 显示 | 适用调用点 |
|---|---|---|
| `sellable`（默认） | 成品/可售卖：排除原材料 2113 / 辅料 2480 / 未分类 -1 | 销售缺料、生产计划/日报、委外进仓/退货/订货/申请/询价、仓库产成品进/出仓 |
| `material` | 原材料/辅料：只保留原材料/辅料子树 | 采购（4 类）、委外发料/材料退/损耗、仓库领料/退料 |
| `all` | 全部：不过滤（未分类默认收起） | 仓库调拨/其它入库/其它出库/盘点 |
| `component` | 组件类：只保留原材料/半成品/辅料/OEM成品/OEM物料/OEM功能件子树（白名单 6 分类，仿 `material`） | **货品 BOM 组装信息「添加组件」**（`goods_bom_tab.dart`） |
| `rawMaterial` | 原材料：只保留原材料子树 | 货品详情“包装材料”字段（`requireConfirm=true`） |
| `allExceptUncategorized` | 除未分类外的全部货品分类 | 销售 5 类单据多选；生产物料分析手工货品（`requireConfirm=true`） |

- docType→scope 映射封装在各编辑页 `_pickerScope` getter，不泄漏到 picker。
- 左侧使用一个统一搜索框，同时匹配分类名称/编号和货品名称/编号等字段；货品命中后展开完整分类路径并定位首个分类，右侧直接显示结果。
- 六种 scope 都可跨当前可见分类搜索。前端把可见根作为 `categoryRootIds` 交给后端展开、合并并分页；服务端单次最大 32 个根，repository 会按 32 个一组完整拉取、按货品 ID 去重后重新分页，定位 ID 同样分批取并集。任一批失败则整体失败，不返回部分结果；无效根零命中，不能退化成全库。前端还会校验每条结果及定位 `categoryId` 都属于当前树。
- **滑窗默认隐藏已禁用货品 + 迁移兜底 stub**（内部 `list`/`search` 传 `excludeDisabled: true` + `excludeStub: true`，后者排除 `goods.auto_created=true` 的历史外键锚，V177）；货品资料管理页把这两类收拢到顶部集合行（见 [基础资料页](../03-页面/基础资料页.md)），不进滑窗。V181 进一步把活动 BOM 的 stub 端点清零并加数据库/API 守卫，因此该排除是持续业务规则，不是等待“补全货品”后的临时筛选。
- **权限与归属范围**：接口要求 `goods:view`；货品归属隔离只在 `UTEN_GOODS_OWNER_SCOPE_ENABLED=true` 时生效，默认关闭时 `GoodsService` 全员可见全部货品。滑窗与列表/定位同源，前端不自行扩大范围；分类树仍要求 `material_category:view`。
- **懒载**（2026-07-31）：打开预选第一个根分类（树高亮，用户有定位感）但**不立即加载货品列表**，输关键词或点分类才加载（省资源，与各资料页统一）。
- **搜索扩字段**（2026-07-31）：`keyword` 除名称/编号/型号/规格/系列外，新增**客户型号/材质/备注**模糊匹配（后端 `GoodsService.list` keyword OR 谓词）。
- **列表项库位号**（2026-08-17）：货品行副标题在有库位号（`goods.stock_place`，挂牌「库行-层-位」）时
  前置显示「库位 A31-3-1」（无库位不显示，不占位）——仓库在所有单据选品时第一眼可见摆放位置，
  与货架目视化清单同口径；各单据编辑页选品后直接把该值带入明细「库位号」只读列。

---

## 三、响应式行为

形态**完全仿 `UtenDepartmentPicker`**（`lib/features/department/widgets/uten_department_picker.dart` 的 `_open`）：

| 断点 | 形态 |
|---|---|
| **compact**（手机） | 底部抽屉（`showModalBottomSheet`，`isScrollControlled` + `useSafeArea`，85% 屏高） |
| **medium / expanded**（平板/桌面） | 右侧滑入面板（`showGeneralDialog` + `SlideTransition` 右滑 250ms），**宽 720**（部门选择器是 420；货品要容纳「左树 + 右表」故加宽） |

内部布局：`标题行 + Row[ 左分类树（含统一搜索，compact 176 / medium+ 240 宽）| VerticalDivider | 右（货品列表 + 分页）]`。

---

## 四、性能档行为

无 BackdropFilter / 粒子 / 复杂着色器，三档（lite/standard/rich）一致。

懒加载：
- 分类树打开时一次性拉（`productCategoryRepositoryProvider.tree()`）。
- 浏览时选中分类后拉 `goodsRepositoryProvider.list(categoryId, page, keyword)`；搜索时走带 `categoryRootIds` 的受限全局分页。搜索框防抖 300ms，旧请求结果会被 request version 丢弃。
- 只命中分类名称/编号时，右侧展示该分类全部货品；只有点击的分支确实包含货品字段命中才保留同一关键词。手动点树会取消待执行/在途搜索，清空框退出搜索态。

---

## 五、主题与国际化

- 颜色全走 `Theme.of(context).colorScheme`，不硬编码。
- 文案目前硬编码中文（「选择货品」「搜索分类/货品名称或编号」「无匹配货品」等），与同模块其它页一致，待统一补 arb（`TODO(l10n)`）。

---

## 六、示例代码

```dart
// ① 单据明细选货品 + 自动回填颜色/单位（销售订货单等）
Future<void> _pickGoods(SalesGridRow row) async {
  final g = await showUtenGoodsPicker(context, ref);
  if (g == null) return;
  row
    ..goods = GoodsOption(id: g.id, code: g.code, name: g.name)
    ..colorId = g.colorId // 后端列表项直接返回关系 UUID
    ..unitId = g.unitId;
}

// ② 仅选货品、不回填颜色/单位（仓库单据明细等）
final g = await showUtenGoodsPicker(
  context,
  ref,
  scope: UtenGoodsPickerScope.all,
);
if (g != null) setState(() => _selectedGoods = g);
```

---

## 七、实现要点（避坑）

1. **scope 分类边界**：分类树来自 `productCategoryRepositoryProvider.tree()`，按 scope 产生过滤副本，不影响货品资料页原始树。后端不接受“排除某分类”黑名单，但统一搜索接受当前可见根 `categoryRootIds` 并按其子树并集失败关闭；因此分类黑/白名单仍由选择器定义，服务端负责把搜索严格限制在这些根内。
2. **颜色/单位 UUID 直传**（现行）：后端 `GoodsListItem` 直接返回 `colorId/unitId`，销售、采购、仓库、委外和生产调用方直接赋给单据明细；不再经 `MasterNameService.colorIdByLegacy/unitIdByLegacy` 桥接。若历史货品只有 legacy 影子而无 UUID，选择结果保持空关联，不按旧整数、名称或“第一条”静默补关系。旧桥接只作为 ADR-015 的历史演进记录。
3. **导航**：sheet 内用 `Navigator.of(context).pop(g)` 返回；选择器从 go_router 嵌套 navigator 内的编辑页打开，沿用部门 picker 的 navigator 层级，避免 pop 误关业务页面。
4. **复用**：左树 = `UtenCategoryTreeView<ProductCategoryNode>`（`basic_data/widgets/uten_category_tree_view.dart`，`mode: single, expandOnRowTap: true`）；货品数据 = `GoodsRepository.list/search`；分类 = `ProductCategoryRepository.tree`。

---

## 八、相关

- [ADR-015 统一货品选择器与 legacy→UUID 桥接](../99-决策记录-ADR/ADR-015-统一货品选择器与legacy到UUID桥接.md)
- [MasterDataTableView.md](MasterDataTableView.md)（同样位于 basic_data 域的跨模块共享组件）
- [UtenHierarchySearch.md](UtenHierarchySearch.md)（分类树与具体内容统一关联搜索契约）
- [基础资料页.md](../03-页面/基础资料页.md)（货品资料页——本选择器复用其「左分类树 + 右货品表」范式）
