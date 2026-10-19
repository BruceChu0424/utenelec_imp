# UtenFloatingWindow

源码：`lib/components/feedback/uten_floating_window.dart`。

可拖动、可缩放、可收起成悬浮球的**页面内浮层**。2026-10-19 因「组装信息-添加组件」需要边看底层资料边核对而引入，同日二轮按用户反馈从路由弹窗改为页面内常驻：没有灰色蒙版，底层内容保持可见且**照常可点可滚**；跳去其它页面时随宿主页面一起被盖住（回来现场还在），宿主卸载它才真正消失。

## 用法

放进宿主页面的 `Stack`（用 `Positioned.fill` 包裹以拿到满屏约束），窗口位置/尺寸/收起全部在组件内管理：

```dart
Stack(children: [
  页面内容,
  if (会话进行中)
    Positioned.fill(child: MyFloatingPane(onClose: 关闭会话, onSaved: ...)),
]);
```

- **显隐由宿主状态决定**：`onClose`（关闭按钮/Esc）只是回调，宿主 setState 卸载；保存成功后由宿主关闭并清理草稿。组件不操作 Navigator。
- **标题栏**（拖动手柄 + 双击复位居中）右侧依次是「缩小成悬浮球」与关闭按钮；拖动/双击手势只包标题区，按钮单击即时响应。
- **缩小成悬浮球（带 morph 动画）**：缩起/展开是 300ms 的矩形过渡——窗口矩形在原位与「缩小」按钮位置之间 lerp，圆角同步 morph、窗口内容淡出（内容按原窗口尺寸布局、由外层圆角盒裁切，过渡帧不逐帧重排，避免收缩途中布局溢出）、球图标缩放淡入；球落在缩小按钮的位置且可拖动，点球 morph 展开复原。再次点击页面入口按钮时宿主可经 `GlobalKey<UtenFloatingWindowState>.currentState.expand()` 把球展开。
- **四边/四角缩放**：锚定边语义——拉底边时顶端固定、高度上限=到屏幕底；拉顶边时底端固定；左右同理。拉到极限只停不动，不会把窗口顶跑。
- 阴影是一圈较深的 BoxShadow（无蒙版下靠它与底层分层）；Esc 关闭仅在焦点位于窗口内时生效（`CallbackShortcuts`）。
- 底层无 barrier 拦截——适合"核对"场景；需要强制决策的确认流程仍用 `UtenAlertDialog`。

## 验证

- `goods_bom_add_components_test.dart`：添加组件整批原子保存、服务端逐行拒绝原因留在浮窗、成功才关闭；缩成悬浮球再展开现场不丢、关闭即卸载（按 `UtenFloatingWindow` 类型断言开合）。
- `goods_bom_tab_periodic_grams_test.dart`：整批领料按克填单个重量、双料确认重发。
