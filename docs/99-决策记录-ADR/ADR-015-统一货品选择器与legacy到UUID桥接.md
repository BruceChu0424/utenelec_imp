# ADR-015 · 统一货品选择器与 legacy→UUID 桥接

| | |
|---|---|
| 状态 | 已采纳；其中“在线 legacy→UUID 桥接”已被 V182 及当前 UUID-only 源码候选取代 |
| 日期 | 2026-07-28 |
| 关联 | [ADR-010 组织岗位模型与统一部门选择器](ADR-010-组织岗位模型与统一部门选择器.md)、[UtenGoodsPicker 组件文档](../02-组件库/UtenGoodsPicker.md) |

---

## 背景

销售 / 采购 / 委外 / 仓库 / 生产 各单据编辑页的明细「货品」单元格，原先各自弹**居中搜索款选择器**（`showSalesGoodsPickerDialog` / `showGoodsPickerDialog`，520×480 纯关键词列表），三个问题：

1. **无分类树**——只能搜索、不能按货品分类浏览；且会把「原材料 / 辅料 / 未分类」也列出来（销售场景只该选可售成品类）。
2. **选中不回填颜色/单位**——旧选择器只返回 `GoodsOption{id,code,name}`，明细的颜色/单位列还得用户手动下拉选。
3. **重复实现**——销售、采购各一份几乎同款的搜索 picker。

当时同时发现一个**数据模型 id 鸿沟**：2026-07-28 的货品主档颜色/单位**只存 `colorLegacyId/unitLegacyId`**（老库 B_Color/B_Unit 的 int 主键，无指向新库 `colors/units` 表的 UUID FK）；而所有单据明细行的 `colorId/unitId` 存的是**新库 UUID**。这段是历史背景，当前 `goods.color_id/unit_id` 与 `GoodsListItem.colorId/unitId` 已取代该在线桥接。

## 决策

### 1. 统一选择器 `showUtenGoodsPicker`

新建 `lib/features/basic_data/widgets/uten_goods_picker.dart`，**全模块共用**（销售/采购/委外/仓库/生产日报/生产计划/物料反查 7 处接入）。形态仿 `UtenDepartmentPicker`（[ADR-010]）：compact 底部抽屉 / medium+ 右侧滑入 **720** 宽面板；内部**左分类树 + 右货品表**（搜索+分页），复用 `UtenCategoryTreeView` + `GoodsRepository` + `ProductCategoryRepository.tree`。旧居中搜索款 picker（`sales_goods_picker.dart`、`goods_picker_dialog.dart`）删除。

历史实现返回含 `colorLegacyId/unitLegacyId/colorName/unitName` 的 `GoodsListItem`，而非旧的精简 `GoodsOption`。当前实现直接增加并使用 `colorId/unitId` UUID；legacy 字段只保留迁移溯源或历史只读展示。

### 2. 前端排除「原材料 / 辅料 / 未分类」

分类树经 `_filterExcludedTree` 过滤 `legacyId ∈ {2113 原材料, 2480 辅料, -1 未分类(历史孤儿)}` 或 `name` 含关键字的节点（整子树丢弃），返回**过滤副本**（不影响货品资料页原树）。后端 `/master/goods` 只支持 `categoryId` 子树 IN、**不支持排除分类**，故排除只能前端做。

### 3. legacy→UUID 桥接（2026-07-28 历史过渡方案，已取代）

历史方案由 `MasterNameService` 解析 `/master/colors/dict`、`/master/units/dict` 的 `legacyId`，建立 `legacyId→UUID` 映射并通过 `colorIdByLegacy(int?)` / `unitIdByLegacy(int?)` 回填明细。**该方案不再允许用于在线新建/编辑**：当前 `GoodsListItem` 直接携带 `colorId/unitId`，调用方直接透传；UUID 缺失时保持未选择并失败关闭，不按旧整数或名称补造关系。

### 4. 销售明细颜色/单位只读化

销售明细的颜色/单位列从可手选下拉改为**只读 Text**（选货品后自动回填显示）；`SalesGridRow.colorId/unitId` 改 `ValueNotifier` 即时刷新。其余模块（采购/委外/生产）保持各自现状（透传或可手选下拉），仅接入统一选择器 + 自动回填。

## 后果

**正面**
- 交互统一（一处改、全模块生效），与部门选择器范式一致。
- 选货品即自动带出颜色/单位，减少录入。
- 销售场景不再误选原材料/辅料/未分类。
- 2026-07-28 过渡阶段曾做到零后端改动；该历史收益不再代表当前 UUID-only 调用链。

**权衡 / 限制**
- 销售明细颜色/单位**不可手改**——若货品主档未维护颜色/单位，该格显示「—」且无法手填（符合本次「不要自己选」诉求；若后续要「自动优先、空时允许手选」，可把列改回下拉）。
- 历史 `legacy→UUID` 桥接依赖字典完整性；现行规则改为直接 UUID，缺失、悬空或停用均失败关闭。

## 备选方案（未采纳）

- **后端 `/master/goods` 列表项加 `colorId/unitId` UUID**：需 `goods` 表加 `color_id/unit_id` FK 列或 JOIN，改动面大；且货品主档本身就没存 UUID。否决。
- **单据明细颜色/单位改存 legacyId**：与现有 UUID 体系冲突，后端 DDL/FK/迁移/其它模块全要动。否决。
- **前端按 `colorName` 反查 UUID**：重名风险（同名颜色取错 UUID）。否决，选精确的 legacyId 映射。

## 验证

`flutter analyze` 0 error（111 条均为既有 info/warning lint）。运行时手测：销售订货单新建→点货品→验证左树排除三类 + 右滑入 + 选中回填颜色/单位只读 + 保存；各模块冒烟选货品。详见 [UtenGoodsPicker.md §六/§七](../02-组件库/UtenGoodsPicker.md)。

## 2026-08-01 演进说明

- 本 ADR 的“前端排除/零后端改动”只描述 2026-07-28 的分类筛选与 legacy→UUID 回填决策；现行选择器
  已按 `sellable/material/all/component/rawMaterial/allExceptUncategorized` 六种 scope 分流，并由货品 API 统一排除 `goods.auto_created=true`。
- V177 把 31 个迁移 stub 明确标成历史外键锚；V181 已隔离 81 条误接活动 BOM 边，并由数据库与
  `GoodsBomService` 禁止占位/已删除货品重新进入活动 BOM。该规则必须服务端强制，不能只靠 picker 隐藏。
- V182 的 nullable UUID 关系迁移目前仍是待应用源码；在目标库确认应用并完成双读/对账前，legacy 列继续
  作为兼容与溯源字段保留，不能把本 ADR 的桥接层提前删除。

## 2026-08-14 身份语义收口

本 ADR 第 3 节记录的是 2026-07-28 的过渡实现，不再是在线新写契约。当前 V182、V257–V276
及后续应用层候选已经把货品及相关主档/单据关系收敛为系统 UUID：`GoodsListItem` 直接返回 `colorId`、
`unitId`，销售、采购、仓库、委外和生产编辑页直接透传这些 UUID，不再调用
`colorIdByLegacy()` / `unitIdByLegacy()` 二次换算；选择器同时直接提交
`mouldId`、`clientId`、供应商 ID、分类 ID 和货品 ID；可编辑编号、名称、旧整数只作展示、快照或
受控旧库导入影子。普通 API 新建/编辑不得靠名称、编号或 `legacy_id` 反查后生成关系，也不得在 UUID
缺失时静默回退。旧值解析只允许出现在显式 legacy 迁移/适配器或历史只读展示中，并必须对未命中、
多命中和 UUID/旧值冲突失败关闭。

货品编号也不再承担外键身份：分类前缀、手工编号、复制/粘贴及批量导入统一走分类驱动取号；改前缀
只批量改变业务编号，所有单据、BOM 和主档关系仍指向原 UUID。编号规则详见
[ADR-034](ADR-034-分类驱动业务编号与UUID关联.md)。这些迁移和调用链仍是共享工作树源码候选；目标库
迁移、历史关系对账和岗位 UAT 完成前，不得写成已部署。

货品 Excel 导入也遵守同一边界。`detect` 在无歧义时把每行分类路径、颜色和单位固化为“既有 UUID”
或本次计划内的新建 token，并返回 `planId`；`commit` 必须在五分钟内由同一操作者提交同一 SHA-256
文件，且分类/颜色/单位主档指纹未变化。计划单次消费、最多保留 128 个，服务重启、过期、重复提交、
文件变化、操作者变化或主档漂移均要求重新检测。提交阶段只物化已固化的 UUID/token，不再按名称
“取第一条”；最终货品保存请求只写 UUID。数据库编号/唯一约束仍作为检测后并发变化的最终
fail-closed 防线。

## 2026-08-14 补充决策：分类与货品统一关联搜索

本节是现行搜索演进，不改写 2026-07-28 的历史背景：

1. 搜索入口收敛到左树顶部，一个关键词同时搜索当前 scope 内的分类名称/编号与货品名称/编号等业务字段。货品命中展开全部祖先路径，右侧直接显示受限分页结果；只命中分类时显示该分类全部货品，不能把分类词误作货品关键词。
2. 浏览仍使用单个 `categoryId` 子树；跨分类统一搜索使用当前可见根 `categoryRootIds` 的子树并集。服务端单次上限 32 个根，repository 分批拉完、按货品 ID 去重并重新分页；分类定位 `GET /api/master/goods/search-category-ids` 同样分批取并集。任一批失败则整体失败，无效根零命中，禁止回退全库。
3. 客户端对返回货品及定位 ID 再做授权树内 fail-closed 校验。分类黑/白名单仍由 scope 可见树定义；服务端 `excludeDisabled/excludeStub` 强制选择器排除禁用品与历史 stub。
4. 每次输入立即让旧请求失效，300ms 后才启动新搜索；手动点分类取消待执行和在途定位。加载、错误、无结果和 compact 布局均保持可见且语义一致。
5. 物料反查后来改用专用 `showWhereUsedMaterialPicker`：它必须在 `production_where_used:view` 下保留禁用/stub/软删历史物料，权限和数据口径不同于通用选择器。2026-07-28 背景中的“物料反查接入”仅记录当时状态，不再代表当前调用链。

因此，原“后端不支持排除分类”仍指不接受任意黑名单；它不再意味着统一搜索只能在前端对全库结果事后过滤。现行后端支持的是 fail-closed 的可见根白名单。
