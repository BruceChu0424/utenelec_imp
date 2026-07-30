# ADR-015 · 统一货品选择器与 legacy→UUID 桥接

| | |
|---|---|
| 状态 | 已采纳 |
| 日期 | 2026-07-28 |
| 关联 | [ADR-010 组织岗位模型与统一部门选择器](ADR-010-组织岗位模型与统一部门选择器.md)、[UtenGoodsPicker 组件文档](../02-组件库/UtenGoodsPicker.md) |

---

## 背景

销售 / 采购 / 委外 / 仓库 / 生产 各单据编辑页的明细「货品」单元格，原先各自弹**居中搜索款选择器**（`showSalesGoodsPickerDialog` / `showGoodsPickerDialog`，520×480 纯关键词列表），三个问题：

1. **无分类树**——只能搜索、不能按货品分类浏览；且会把「原材料 / 辅料 / 未分类」也列出来（销售场景只该选可售成品类）。
2. **选中不回填颜色/单位**——旧选择器只返回 `GoodsOption{id,code,name}`，明细的颜色/单位列还得用户手动下拉选。
3. **重复实现**——销售、采购各一份几乎同款的搜索 picker。

同时发现一个**数据模型 id 鸿沟**：货品主档 `goods` 表的颜色/单位**只存 `colorLegacyId/unitLegacyId`**（老库 B_Color/B_Unit 的 int 主键，无指向新库 `colors/units` 表的 UUID FK）；而所有单据明细行的 `colorId/unitId` 存的是**新库 UUID**。两套 id 体系不一致，直接阻碍「选货品自动回填颜色/单位」。

## 决策

### 1. 统一选择器 `showUtenGoodsPicker`

新建 `lib/features/basic_data/widgets/uten_goods_picker.dart`，**全模块共用**（销售/采购/委外/仓库/生产日报/生产计划/物料反查 7 处接入）。形态仿 `UtenDepartmentPicker`（[ADR-010]）：compact 底部抽屉 / medium+ 右侧滑入 **720** 宽面板；内部**左分类树 + 右货品表**（搜索+分页），复用 `UtenCategoryTreeView` + `GoodsRepository` + `ProductCategoryRepository.tree`。旧居中搜索款 picker（`sales_goods_picker.dart`、`goods_picker_dialog.dart`）删除。

返回**完整 `GoodsListItem`**（含 `colorLegacyId/unitLegacyId/colorName/unitName`），而非旧的精简 `GoodsOption`。

### 2. 前端排除「原材料 / 辅料 / 未分类」

分类树经 `_filterExcludedTree` 过滤 `legacyId ∈ {2113 原材料, 2480 辅料, -1 未分类(历史孤儿)}` 或 `name` 含关键字的节点（整子树丢弃），返回**过滤副本**（不影响货品资料页原树）。后端 `/master/goods` 只支持 `categoryId` 子树 IN、**不支持排除分类**，故排除只能前端做。

### 3. legacy→UUID 桥接（零后端）

`MasterNameService`（销售 `salesMasterNameServiceProvider` / 其余 `masterNameServiceProvider`）解析 `/master/colors/dict`、`/master/units/dict` 时——这两个接口**实际已返回 `legacyId`**——建立 `legacyId→UUID` 映射，暴露 `colorIdByLegacy(int?)` / `unitIdByLegacy(int?)`。选货品拿到 `GoodsListItem.colorLegacyId` → 查映射 → 填明细 `colorId`（UUID）。

### 4. 销售明细颜色/单位只读化

销售明细的颜色/单位列从可手选下拉改为**只读 Text**（选货品后自动回填显示）；`SalesGridRow.colorId/unitId` 改 `ValueNotifier` 即时刷新。其余模块（采购/委外/生产）保持各自现状（透传或可手选下拉），仅接入统一选择器 + 自动回填。

## 后果

**正面**
- 交互统一（一处改、全模块生效），与部门选择器范式一致。
- 选货品即自动带出颜色/单位，减少录入。
- 销售场景不再误选原材料/辅料/未分类。
- **零后端改动**（dict 早返回 `legacyId`，只是前端解析时之前丢了）。

**权衡 / 限制**
- 销售明细颜色/单位**不可手改**——若货品主档未维护颜色/单位，该格显示「—」且无法手填（符合本次「不要自己选」诉求；若后续要「自动优先、空时允许手选」，可把列改回下拉）。
- `legacy→UUID` 映射依赖 `colors/units` dict 完整性（dict 缺某 legacy 则该项回填为空，不报错）。

## 备选方案（未采纳）

- **后端 `/master/goods` 列表项加 `colorId/unitId` UUID**：需 `goods` 表加 `color_id/unit_id` FK 列或 JOIN，改动面大；且货品主档本身就没存 UUID。否决。
- **单据明细颜色/单位改存 legacyId**：与现有 UUID 体系冲突，后端 DDL/FK/迁移/其它模块全要动。否决。
- **前端按 `colorName` 反查 UUID**：重名风险（同名颜色取错 UUID）。否决，选精确的 legacyId 映射。

## 验证

`flutter analyze` 0 error（111 条均为既有 info/warning lint）。运行时手测：销售订货单新建→点货品→验证左树排除三类 + 右滑入 + 选中回填颜色/单位只读 + 保存；各模块冒烟选货品。详见 [UtenGoodsPicker.md §六/§七](../02-组件库/UtenGoodsPicker.md)。
