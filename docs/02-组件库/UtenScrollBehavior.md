# UtenScrollBehavior

入口：`lib/core/theme/uten_scroll_behavior.dart`。界面遵循 `frontend-design`，复用现有 Uten 主题和滚动条配色。

## 默认行为

`MaterialApp.scrollBehavior` 使用 `const UtenScrollBehavior()`。普通列表、详情、表单、网格及长弹窗的竖向内容溢出时，自动提供常显、可拖动滚动条；内容装得下时不绘制滑块。无需先滚轮滚动，也不以表头是否置顶为前提。

滚动条只读取该视口的竖向通知，独立列表按其 ScrollPosition 控制。多个列表共用 PrimaryScrollController 时也不会把滚动条同时绑定到多个位置。控制器或物理配置变更时更新位置绑定，卸载时释放代理监听，不持有旧位置。

## 显式滚动条所有权

直接包住同控制器的 `Scrollbar` / `RawScrollbar` 会被识别并保留。自绘覆盖层不在滚动视口的祖先链上时，使用 `UtenScrollbarOwnerScope`：

```dart
UtenScrollbarOwnerScope(
  controller: scrollController,
  child: Stack(
    children: [
      ListView(controller: scrollController, children: rows),
      Positioned.fill(
        child: UtenContentScrollbar(controller: scrollController),
      ),
    ],
  ),
)
```

所有权只跳过匹配控制器；嵌套的独立滚动区域继续获得自己的滚动条。共用单据包装见 [UtenGridPageScrollbar](UtenGridPageScrollbar.md)。表格通过自己的直接控制器识别跳过自动条，单元格内独立视口仍委托默认行为。

## 输入与回归

滚轮窗口位移由 `UtenDisplayZoomPointerEvents` 统一换算一次。输入消费须回执一次；绑定层补齐框架滚动条漏发的消费回执，并保留边界及不可滚动视图的原生默认处理。

按住 Shift 或当前滚动行为定义的轴修饰键时，自动条暂时把输入交回原视口，沿用原生鼠标翻轴和触控板方向规则；释放后恢复拖动。iOS 使用同主题的稳定 RawScrollbar，避免框架自适应分支忽略交互开关或替换正文子树。

回归入口：`test/core/theme/uten_scroll_behavior_test.dart`、`test/core/theme/uten_scroll_behavior_lifecycle_test.dart`、`test/core/responsive/display_zoom_wheel_test.dart`，以及内容滚动条、折叠布局、表格和弹窗测试。
