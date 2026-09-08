# UtenSelectionSummaryPill 选择摘要胶囊

- 文件：`lib/components/data_display/uten_selection_summary_pill.dart`
- 接入日期：2026-09-05（自 `MasterDataTableView._buildBatchBar` 私有实现升位为公共组件）。
- 契约已接入表：MasterDataTableView（悬浮批量组首位）、物料分析「下达车间」可安排桶（钉底动作组）。

## 功能

「已选 N 项 + ✕ 清除」选择摘要——全站表格批量动作区的统一口径：

- 选中态：`primaryContainer` 45% 底 + `primary` 边框/加粗字；未选态整体降级中性灰（`outline`/`outlineVariant`）。
- 固定高 `UtenTableToolbar.controlHeight`(48)，与表头工具条控件等高。
- ✕ 清除：`onClear` 为 null（未选/冻结）时不可点；清空选中集由调用方决定语义（回交空集或控制器 `clearSelection()`）。

## 参数

| 参数 | 类型 | 说明 |
|---|---|---|
| `count` | `int` | 当前选中行数（可传服务端口径汇总数，如跨页全选总数） |
| `onClear` | `VoidCallback?` | 清除回调；null=不可点 |
| `clearKey` | `Key?` | 清除按钮 Key（`master-table-clear-selection` 契约由调用方保留传入） |

## 用法

```dart
UtenFloatingActionGroup(children: [
  UtenSelectionSummaryPill(
    count: controller.selectedRows.length,
    clearKey: const Key('master-table-clear-selection'),
    onClear: count > 0 ? controller.clearSelection : null,
  ),
  ...batchActions,
])
```

## 约定

- 不给内部 Container 设 alignment（无 width 会撑满父级）；高度固定、宽度随内容收紧。
- 与业务按钮同框时放进 `UtenFloatingActionGroup`（右对齐 + 逐子件投影）。
