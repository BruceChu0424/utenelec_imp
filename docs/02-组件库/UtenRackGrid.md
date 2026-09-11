# UtenRackGrid 货架图

- 文件：`lib/components/data_display/uten_rack_grid.dart`
- 测试：`test/components/uten_rack_grid_test.dart`（7 例）
- 接入日期：2026-09-10（货架目视化清单页信息架构重做）
- 已接入页面：[货架目视化清单页](../03-页面/货架目视化清单页.md)（`/warehouse/shelf-labels`）

## 一、功能

把「库位号」这串文本变成看得见的货架：**一库行一张卡，行 = 层（高层在上，贴近实物）、
列 = 位、格 = 一个库位号**。现场按 库行→层→位 找东西，屏幕就按 库行→层→位 摆格子。

- **格内聚合**：同一库位号有多个货品时，格里出首件（物料编码 + 名称 + 库存量小字），
  右上角 `+n` 计数徽章表示「本格还有 n 个货品」——不铺开成多格，货架上本来就是一格。
- **定位**：点格 → `onCellTap(place)` 回传库位号，宿主页据此过滤/高亮表格。
- **反查**：`selectedPlace` 受控高亮（`primaryContainer` 底 + `primary` 描边），
  值变化时自动 `Scrollable.ensureVisible` 把该格滚进视口（宿主页点表格行写回即可）。
- **空位**：`surfaceContainerLowest` + 弱化边框 + 「—」，不建 `InkWell`、不进无障碍焦点。
- **未分层**：`rack` 为空串的桶（库位号不符合「库行-层-位」三段格式的老库残值）不画网格，
  单独一段平铺 + 指路文案「请在货品资料改正」。
- **无障碍**：每个有货格是 `Semantics(button: true, selected: …)`，
  label = 「库位 A31-3-1，2 个货品，首件 静音风扇电机」。
- **性能**：入参换引用时才做一次 O(n) 索引（build 不重复聚合）；
  `performanceProvider` 为 lite 档时格子动画与滚动时长归零；
  网格维度按 `levelRenderCap`(20)/`slotRenderCap`(30) 封顶，**但真实占用的层/位一律渲染**
  （超上限只是不再补空格，不会丢数据）。
- **响应式**：宽度超出走 [`UtenHScrollArea`](../../lib/components/layout/uten_h_scroll_area.dart)
  横滚；格宽/层标签宽/格高随字号档（`MediaQuery.textScalerOf`，封顶 1.8 倍）整体放大，
  超大字号下文字省略不溢出。

## 二、数据契约

组件自持契约，**不依赖任何 feature 模型**（宿主页做映射）。

`UtenRackGridRack`（一个库行的网格维度）：

| 字段 | 类型 | 说明 |
|---|---|---|
| `rack` | `String` | 库行号（如 `A31`）；空串 = 未分层桶 |
| `maxLevel` / `maxSlot` | `int?` | 网格维度；null 时按 `items` 实际占用推导 |
| `count` | `int` | 该库行货品行数（服务端计数，>0 时优先于 items 计数显示） |

`UtenRackGridItem`（格内一条货品）：

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | `String` | 行唯一键（货品 id），仅用于稳定 key |
| `place` | `String` | 库位号原值；**同格聚合就按它分组** |
| `level` / `slot` | `int?` | 层 / 位；任一为 null = 归未分层桶 |
| `code` / `name` / `qtyLabel` | `String?` | 物料编码 / 名称 / 库存量展示文本（数字格式化由宿主页做） |
| `disabled` | `bool` | 已禁用货品：文字弱化，仍占格（现场货还在货架上） |

## 三、参数

| 参数 | 类型 | 说明 |
|---|---|---|
| `racks` | `List<UtenRackGridRack>` | 布局；缺项时按 `items` 兜底（后端 layout 挂了也画得出） |
| `items` | `List<UtenRackGridItem>` | 当前应画的行（宿主页已按筛选口径裁剪） |
| `selectedPlace` | `String?` | 受控高亮 + 自动滚入视口 |
| `onCellTap` | `void Function(String place)?` | 点格回调；null = 整图只读 |
| `emptyMessage` / `unparsedHint` | `String` | 空态文案 / 未分层指路文案 |

## 四、用法

```dart
UtenRackGrid(
  racks: [for (final r in layout) UtenRackGridRack(
    rack: r.rack, maxLevel: r.maxLevel, maxSlot: r.maxSlot, count: r.count)],
  items: [for (final r in rows) UtenRackGridItem(
    id: r.goodsId, place: r.place ?? '', level: r.level, slot: r.slot,
    code: r.goodsCode, name: r.goodsName, qtyLabel: '12只', disabled: r.disabled)],
  selectedPlace: _selectedPlace,           // 点表格行时写回 = 反查
  onCellTap: (place) => setState(() => _selectedPlace = place), // 点格 = 定位
)
```

## 五、约定

- 组件**限高由宿主页给**：放进 `ConstrainedBox(maxHeight: …) + SingleChildScrollView`
  才能让 `ensureVisible` 有可滚的视口；直接塞进无界高度的 `Column` 会一路铺下去。
- 颜色只取 `ColorScheme`（选中 `primaryContainer` / 格底 `surfaceContainerHigh` /
  空位 `surfaceContainerLowest` / 描边 `outlineVariant`），**无裸色、无硬编码 fontSize**。
- 「格内还有几个货品」只由 `+n` 徽章表达，不在格里堆第二三行货品名。
- 未分层桶是**数据治理提示**不是功能位：文案必须指向「去货品资料把库位号改成三段格式」，
  批量治理走 `server/legacy_migration/clean_shelf_place_residue.sql`（人工确认脚本）。
