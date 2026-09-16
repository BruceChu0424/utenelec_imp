# UtenGridPageScrollbar

> 文件：`lib/components/layout/uten_grid_page_scrollbar.dart`
> 分类：Layout · 滚动条口径

## 一、用途

单据编辑页（表头表单 + `UtenEditableGrid` 明细表、整页一条 ListView 滚动）的
**竖向滚动条门控包装**（2026-09-14 全站滚动条口径）。

明细表未置顶（表头表单还没滚完）时**不显示上下滚动条**；`UtenEditableGrid`
的 sticky 表头吸附视口顶后（继续滚动在观感上就是表内滚动）才显示——与
`UtenCollapsingHeaderScrollView` + `MasterDataTableView` 经
`UtenInnerScrollActiveScope` 的门控口径一致（见
[UtenCollapsingHeaderScrollView.md](UtenCollapsingHeaderScrollView.md) §五）。

## 二、用法

`pinned` 与 `UtenEditableGrid.stickyHeaderPinned` 传同一个 notifier：

```dart
final _gridPinned = ValueNotifier<bool>(false);   // 页面持有，dispose 记得释放

UtenGridPageScrollbar(
  pinned: _gridPinned,
  controller: _scrollCtl,
  child: ListView(controller: _scrollCtl, ...),
)

UtenEditableGrid<Row>(
  controller: _grid,
  stickyHeaderPinned: _gridPinned,   // 网格写入「表头已置顶」信号
  ...
)
```

接入页面：销售 / 采购（申请+订货）/ 财务 / 库存 / 委外（申请+订货）/ 生产计划 /
生产日报 共 9 个编辑页，以及到货登记、分批收货、产成品登记（含分批）3 个仓库任务页。
