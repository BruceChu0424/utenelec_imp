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
| 入口 | `Future<GoodsListItem?> showUtenGoodsPicker(BuildContext context, WidgetRef ref)` | 弹出选择器；确认返回所选货品，取消/关闭返回 `null` |
| 返回 | `GoodsListItem` | 完整模型：`id/code/name/spec/model/price/series/material/colorLegacyId(int?)/unitLegacyId(int?)/colorName/unitName`（见 `lib/features/basic_data/models/goods_node.dart`） |

> 内部 `_GoodsPickerSheet` 为实现细节，调用方不直接使用。

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
