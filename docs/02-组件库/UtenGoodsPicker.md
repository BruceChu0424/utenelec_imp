# UtenGoodsPicker · 货品选择器

> 位置：`lib/features/basic_data/widgets/uten_goods_picker.dart`（跨模块共享，同 `MasterDataTableView` 一样放在 basic_data 域）
> 入口：`Future<GoodsListItem?> showUtenGoodsPicker(BuildContext context, WidgetRef ref)`
> 决策背景：[ADR-015 统一货品选择器与 legacy→UUID 桥接](../99-决策记录-ADR/ADR-015-统一货品选择器与legacy到UUID桥接.md)

---

## 一、用途

单据明细 / 报表里**选一个货品**的统一选择器。点明细「货品」单元格（或报表的材料选择）触发，选中返回完整 `GoodsListItem`，调用方按需回填货品 / 颜色 / 单位等字段。

**解决什么**：旧款居中搜索框（`sales_goods_picker` / `goods_picker_dialog`，**已删除**）只有关键词搜索、没有分类树、会把「原材料/辅料/未分类」也列出来、且选中后只返回 `{id,code,name}` 无法自动回填颜色/单位。

**何时用**：任何「选一个货品」的场景——销售 / 采购 / 委外 / 仓库 / 生产（日报、计划）单据明细，以及物料反查报表。

**何时不用**：
- 货品资料**管理**（查看/新增/编辑/删除货品主档）→ 用 [基础资料页](../03-页面/基础资料页.md) 的货品资料页（分类树 + `MasterDataTableView` + 详情弹窗）。
- 多选货品 → 本组件是单选，不支持。

---

## 二、API

| 项 | 签名 | 说明 |
|---|---|---|
| 入口 | `Future<GoodsListItem?> showUtenGoodsPicker(BuildContext context, WidgetRef ref, {UtenGoodsPickerScope scope = UtenGoodsPickerScope.sellable})` | 弹出选择器；确认返回所选货品，取消/关闭返回 `null` |
| 多选入口 | `Future<List<GoodsListItem>> showUtenGoodsPickerMulti(BuildContext context, WidgetRef ref, {UtenGoodsPickerScope scope = UtenGoodsPickerScope.component})` | 多选款：点货品行勾选/取消（显 ✓），底部「确定(N)」返回所选列表；取消返回空列表。BOM 组装「一个层级添加多个组件」批量录入用 |
| 返回 | `GoodsListItem` | 完整模型：`id/code/name/spec/model/price/series/material/colorLegacyId(int?)/unitLegacyId(int?)/colorName/unitName`（见 `lib/features/basic_data/models/goods_node.dart`） |

> 内部 `_GoodsPickerSheet` 为实现细节，调用方不直接使用。

### scope 参数（按单据场景分流）

默认 `sellable`（成品/可售卖类，排除原材料/辅料/未分类）——历史行为，未显式传参的调用点零回归。

| scope | 显示 | 适用调用点 |
|---|---|---|
| `sellable`（默认） | 成品/可售卖：排除原材料 2113 / 辅料 2480 / 未分类 -1 | 销售（5 类）、生产计划、生产日报、委外进仓/退货/订货/申请/询价、仓库产成品进/出仓 |
| `material` | 原材料/辅料：只保留原材料/辅料子树 | 采购（4 类）、**物料反查**、委外发料/材料退/损耗、仓库领料/退料 |
| `all` | 全部：不过滤（未分类默认收起） | 仓库调拨/其它入库/其它出库/盘点 |
| `component` | 组件类：只保留原材料/半成品/辅料/OEM成品/OEM物料/OEM功能件子树（白名单 6 分类，仿 `material`） | **货品 BOM 组装信息「添加组件」**（`goods_bom_tab.dart`） |

- docType→scope 映射封装在各编辑页 `_pickerScope` getter，不泄漏到 picker。
- 仅 `all` 允许「未选分类 + 关键词」全库搜；`sellable`/`material` 必须先选分类，否则会把不该显示的类目混搜出来（回归 ADR-015 老 bug）。
- **滑窗默认隐藏已禁用货品 + 迁移兜底 stub**（内部 `list`/`search` 传 `excludeDisabled: true` + `excludeStub: true`，后者排除 `goods.auto_created=true` 的历史外键锚，V177）；货品资料管理页把这两类收拢到顶部集合行（见 [基础资料页](../03-页面/基础资料页.md)），不进滑窗。V181 进一步把活动 BOM 的 stub 端点清零并加数据库/API 守卫，因此该排除是持续业务规则，不是等待“补全货品”后的临时筛选。
- **「按权限显示不一样」** 由后端 `GoodsService.list` 货品归属授权过滤（V85/V89）保障，滑窗同源，无需前端处理。
- **懒载**（2026-07-31）：打开预选第一个根分类（树高亮，用户有定位感）但**不立即加载货品列表**，输关键词或点分类才加载（省资源，与各资料页统一）。
- **搜索扩字段**（2026-07-31）：`keyword` 除名称/编号/型号/规格/系列外，新增**客户型号/材质/备注**模糊匹配（后端 `GoodsService.list` keyword OR 谓词）。

---

## 三、响应式行为

形态**完全仿 `UtenDepartmentPicker`**（`lib/features/department/widgets/uten_department_picker.dart` 的 `_open`）：

| 断点 | 形态 |
|---|---|
| **compact**（手机） | 底部抽屉（`showModalBottomSheet`，`isScrollControlled` + `useSafeArea`，85% 屏高） |
| **medium / expanded**（平板/桌面） | 右侧滑入面板（`showGeneralDialog` + `SlideTransition` 右滑 250ms），**宽 720**（部门选择器是 420；货品要容纳「左树 + 右表」故加宽） |

内部布局：`标题行 + Row[ 左分类树（compact 150 / medium+ 240 宽）| VerticalDivider | 右（搜索框 + 货品列表 + 分页）]`。

---

## 四、性能档行为

无 BackdropFilter / 粒子 / 复杂着色器，三档（lite/standard/rich）一致。

懒加载：
- 分类树打开时一次性拉（`productCategoryRepositoryProvider.tree()`）。
- 货品列表**选了分类才拉**（`goodsRepositoryProvider.list(categoryId, page, keyword)`，子树 IN）；搜索框防抖 300ms。

---

## 五、主题与国际化

- 颜色全走 `Theme.of(context).colorScheme`，不硬编码。
- 文案目前硬编码中文（「选择货品」「搜索分类」「无匹配货品」等），与同模块其它页一致，待统一补 arb（`TODO(l10n)`）。

---

## 六、示例代码

```dart
// ① 单据明细选货品 + 自动回填颜色/单位（销售订货单等）
Future<void> _pickGoods(SalesGridRow row) async {
  final g = await showUtenGoodsPicker(context, ref);
  if (g == null) return;
  final names = ref.read(salesMasterNameServiceProvider); // 采购/委外/生产用 masterNameServiceProvider
  row
    ..goods = GoodsOption(id: g.id, code: g.code, name: g.name)
    ..colorId = names.colorIdByLegacy(g.colorLegacyId) // legacy id → 新库 UUID
    ..unitId = names.unitIdByLegacy(g.unitLegacyId);
}

// ② 仅选货品、不回填（仓库单据明细无颜色/单位字段；物料反查报表选材料）
final g = await showUtenGoodsPicker(context, ref);
if (g != null) {
  setState(() { _material = g; _page = 1; });
  _load();
}
```

---

## 七、实现要点（避坑）

1. **排除「原材料/辅料/未分类」**：分类树来自 `productCategoryRepositoryProvider.tree()`，经 `_filterExcludedTree` 过滤后喂给树——命中 `legacyId ∈ {2113 原材料, 2480 辅料, -1 未分类(历史孤儿)}` 或 `name` 含「原材料/辅料/未分类」的节点**整子树丢弃**。返回**过滤副本**，不影响货品资料页的原始树。后端 `/master/goods` 只支持 `categoryId` 子树 IN、**不支持排除分类**，故排除只能前端做。
2. **颜色/单位回填的 id 鸿沟**（核心）：货品主档只有 `colorLegacyId/unitLegacyId`（老库 int），而单据明细 `colorId/unitId` 存的是**新库 UUID**。桥接靠 `MasterNameService.colorIdByLegacy/unitIdByLegacy`——解析 `/master/colors/dict`、`/master/units/dict`（这两个接口实际返回 `legacyId`）建 `legacyId→UUID` 映射。**零后端改动**。详见 [ADR-015](../99-决策记录-ADR/ADR-015-统一货品选择器与legacy到UUID桥接.md)。
3. **导航**：sheet 内用 `Navigator.of(context).pop(g)` 返回；选择器从编辑页（已在 go_router 嵌套 navigator 内）打开，照搬部门 picker 的写法已验证无「pop 误关页面」崩溃（对照 [go_router 嵌套 navigator 坑](../../) 已规避）。
4. **复用**：左树 = `UtenCategoryTreeView<ProductCategoryNode>`（`basic_data/widgets/uten_category_tree_view.dart`，`mode: single, expandOnRowTap: true`）；货品数据 = `GoodsRepository.list/search`；分类 = `ProductCategoryRepository.tree`。

---

## 八、相关

- [ADR-015 统一货品选择器与 legacy→UUID 桥接](../99-决策记录-ADR/ADR-015-统一货品选择器与legacy到UUID桥接.md)
- [MasterDataTableView.md](MasterDataTableView.md)（同样位于 basic_data 域的跨模块共享组件）
- [基础资料页.md](../03-页面/基础资料页.md)（货品资料页——本选择器复用其「左分类树 + 右货品表」范式）
- [采购仓库单据页-UI优化路线图.md](../03-页面/采购仓库单据页-UI优化路线图.md)（明细 Excel 表 + 货品选择统一的落地记录）
