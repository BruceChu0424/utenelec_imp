# UtenGridPageScrollbar

> 文件：`lib/components/layout/uten_grid_page_scrollbar.dart`
> 分类：Layout · 滚动条口径

## 一、用途

单据编辑页的右缘竖向滚动条包装。2026-10-25 起，只要页面内容超出视口即显示，不再等待明细表头置顶。

通过 [UtenScrollbarOwnerScope](UtenScrollBehavior.md) 声明当前控制器的覆盖层所有权，避免自动滚动条重复绘制；独立内层列表继续使用全局自动滚动条。pinned/extraPinned 参数保留调用兼容，不再参与显隐。

共享竖条 `UtenContentScrollbar` 支持按住滑块上下拖动、点击滑块上下的轨道翻页，悬停与拖动时加深提示。命中范围限于右缘活动带，底部悬浮按钮让位区不接管点击；鼠标停在滚动条上仍可使用滚轮。滑块与轨道继续排除底部让位空白。

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
