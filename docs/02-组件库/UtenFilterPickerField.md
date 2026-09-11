# UtenFilterPickerField（筛选入口字段 + 侧滑选择面板）

> 源码：[`lib/components/inputs/uten_filter_picker_field.dart`](../../lib/components/inputs/uten_filter_picker_field.dart)
> 配套面板：[`lib/features/basic_data/widgets/product_category_picker_panel.dart`](../../lib/features/basic_data/widgets/product_category_picker_panel.dart)、
> [`lib/shared/widgets/warehouse_picker_panel.dart`](../../lib/shared/widgets/warehouse_picker_panel.dart)
> 落地：2026-09-11（即时库存页、货架目视化清单页）

---

## 一、它解决什么

页面工具栏里的**层级型筛选**（货品分类树、仓库主/子层级）此前用 `DropdownButtonFormField`
把树摊平成缩进长条。分类一多（真实库里上百个）下拉就成了滚动噩梦，而且和全站
「点开侧滑窗选」的范式割裂——用户原话：

> 即时库存 点击货品分类 应该是显示侧边滑窗 显示对应的分类 跟货品资料里面的一样，不是下拉框；仓库也是；UI 统一。

统一后的口径：**同一个元素扮演「页面筛选」角色时，全站只有一种形态**——
`UtenFilterPickerField` 字段 + `showUtenAdaptivePanel` 侧滑面板。

---

## 二、字段（UtenFilterPickerField）

单行紧凑字段：`前置图标（可选） + 标签 + 当前值 + 尾部 chevron`。

| 参数 | 说明 |
|---|---|
| `label` | 字段标签（「货品分类」「仓库」）。 |
| `value` | 当前选中值的显示文案；`null`/空 = 未筛选，显示 `placeholder`。 |
| `placeholder` | 未筛选占位，默认「全部」。 |
| `onTap` | 打开侧滑面板。 |
| `icon` | 可选前置图标。 |
| `width` | 固定宽度，默认 200；传 `null` 时父级必须给有界约束（`Wrap` 的直接子级是无界的）。 |
| `enabled` | `false` = 置灰不可点。 |

视觉约束：

- 圆角固定 `UtenRadius.control`（全平台唯一控件圆角），不开放参数；
- 高度与 `UtenSearchBar`（内容驱动 ≈44）对齐：纵向内边距 11 + 20 图标 + 1px 边框，
  字号放大时随内容自然增高，不写死高度；
- **已生效**（`value` 非空）时边框与值文字走 `primary`、底色浅 `primaryContainer`，
  一眼看出「这个筛选正开着」；未生效走中性描边 + 占位文案；
- 颜色全部取自 `theme.colorScheme`，无裸 `Color(0x...)`。

字段只管呈现与点击，**不持有数据**；面板内容、加载与选中语义都在调用方。

---

## 三、配套面板

### 3.1 货品分类：`showUtenProductCategoryPickerPanel`

面板内直接复用货品资料那棵树（`UtenCategoryTreeView<ProductCategoryNode>`：
可展开折叠、搜索、命中路径自动展开、选中高亮），外壳是 `showUtenAdaptivePanel`
（宽屏右侧 420 滑入 / 窄屏 85% 底部弹层）。

- 顶部固定「全部」行 = 清空筛选（当前无选中时打勾）；
- 点分类行 = **选中并立即关闭**（一次点击到位，不加确认按钮）；有子类的行左侧
  chevron 单独负责展开/收起，因此 `expandOnRowTap` 必须保持默认 `false`，
  开了会「点一下既展开又关窗」；
- 每节点尾部显子树货品数（后端 `treeWithGoodsCounts` 给 `goodsCount` 时）；
- 零货品分类整支隐藏（`pruneCategoriesWithoutGoods`：`goodsCount == 0` 剪掉，
  `null` = 后端未给计数，一律保留）；
- 返回值 `ProductCategoryPickResult`：`null` = 用户取消（**不动**现有筛选），
  `isAll` = 选了「全部」（清空），否则 `id`/`name` 为选中分类。
- 辅助函数 `findCategoryName(tree, id)`：页面只存 id 时用它回显字段文案。

### 3.2 仓库：`showUtenWarehousePickerPanel`

同一个面板两种口径：

| 口径 | 参数 | 行为 |
|---|---|---|
| 运营（单据登记，默认） | `allowParent: false` | 先显主仓 → 点主仓钻到子仓 → 选叶子仓返回「主仓名-子仓名」；父仓只导航不选定。 |
| 查询（页面筛选） | `allowParent: true`，通常配 `includeAll: true` | **不钻层**，整棵层级按缩进一次铺开，任意层级一点即选；主仓 = 自身 + 全部子仓聚合（服务端 `WarehouseScopeService` 展开）；顶部「全部」行返回 `WarehousePickerResult.all`（`isAll`，id 为空串）供调用方置 `null`。带本地搜索框（名称/编号，命中保留祖先链）。 |

查询口径**不做可选性裁剪**（禁用仓、不记账仓也能单独看），与旧
`WarehouseHierarchyDropdown` 的 `allowParent` 分支同口径，避免筛选能力回退。

---

## 四、什么时候**不**用它

`WarehouseHierarchyDropdown` / `UtenDropdownField` 继续服务**单据表单里的一格**
（如委外出仓编辑页的「发出仓(必选)」）：它在 `UtenFormGrid` 里与日期/文本各格
同节奏，录单时就地点选比拉面板少一步，且运营口径只允许叶子仓，选项集本来就小。
判定标准是**角色**而非控件：页面级筛选 → 字段 + 面板；表单内一格 → 下拉。

---

## 五、调用方

| 页面 | 用法 |
|---|---|
| [即时库存页](../03-页面/即时库存页.md) | 货品分类字段（分类树面板）+ 仓库字段（查询口径面板，`includeAll` + `allowParent`） |
| [货架目视化清单页](../03-页面/货架目视化清单页.md) | 仓库字段（同上查询口径） |

---

## 六、测试

- `test/components/inputs/uten_filter_picker_field_test.dart`：占位/当前值、点击回调、
  禁用不可点、圆角走 `UtenRadius.control`。
- `test/features/basic_data/product_category_picker_panel_test.dart`：树渲染 +「全部」行 +
  货品数、搜索收窄（保留祖先）、点分类返回 id 并关窗、「全部」返回 `isAll`、
  `pruneCategoriesWithoutGoods` 剪枝口径。
- `test/shared/widgets/warehouse_hierarchy_dropdown_test.dart`：查询口径面板整棵铺开 +
  主仓可选、「全部」清空、搜索收窄；运营口径钻层用例不变。
- `test/features/stock/instant_inventory_page_test.dart` /
  `test/features/warehouse/pages/shelf_label_page_test.dart`：点字段拉面板 → 选节点 → 带
  `categoryId` / `warehouseId` 重查。
