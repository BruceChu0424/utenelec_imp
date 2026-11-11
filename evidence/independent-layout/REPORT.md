# 独立 Tooltip 保留子树宽窄搬移复核

执行源码为 `4d45dc9b6c291e9d8e9121b48017b69030fd1f4c`，独立工作树 `D:/Projects/uten_imp_worktrees/feedback-independent-review-20261111`。没有修改任何生产源码、Root浏览器或旧audit。下列是 Flutter VM / 合成 API 控件实验；不冒称公司设备或真实 Web→PG 已通过。

## 已证实的最小反例

`probes/minimal_split_tooltip_reparent_test.dart` 只用普通MaterialApp、UtenSplitView、Material Tooltip和未保存文本框；没有API/provider。它显式配置与真实分类页相同的 `minTwoPaneWidth=840`，并验证1280宽时canSplit=true、714宽时false。外层Overlay保持尺寸，局部面板真实跨split/compact边界。

同轮4例：**2通过/2失败/0跳过，退出1**。leading/trailing两组关闭Tooltip合法对照均通过；同一控件已经可见的Tooltip随保留GlobalKey子树搬移时都报 `_RenderLayoutBuilder was mutated in _RenderLayoutBuilder.performLayout`。两份选择并没有被假造；文本 `unsaved exact 7.125` 是本实验合成输入。原每项断言未放松，无超时提升。

## 与实际模具路径的对照

从C代理当前完整夹具复制到新探针，保留真实MouldPage/PlatformTablesHost/GoRouter/UtenApp主题与控件，合成1626行。先真实mouse hover分类“全部模具”并显示Tooltip，再1280→714，尚未打开菜单就出现同型首错，组件位置 `uten_adaptive_hierarchy_pane.dart:226`。

- 独立JVM/进程 hover-category 单例：**0通过/1失败，退出1**，日志 `private-flutter-independent-full-mould-category-7.log`。
- 同条件不hover的合法对照独立进程：**1通过/0失败，退出0**，日志 `private-flutter-independent-full-mould-legal-8.log`。
- 去掉UtenApp/GoRouter，只保留项目Mould页/主题/Zoom的local host同样红（`independent-local-mould-category-9`）。因此不能把该首因归于提醒协调器，也不需要依赖打开动作菜单。
- 最初6变体同进程出现1绿5红，后续可能含异常级联，**不把5个失败全当独立反例**。独立单例和最小4例才是稳定的判定证据。

## SDK机制与修复边界

SDK标准LayoutBuilder和OverlayPortal各有私有同名 `_RenderLayoutBuilder`。Root实际编译Web的 `_RenderLayoutBuilder0` 构造包含 `_layoutInfo/_callbackId`，对应overlay私有类。RawTooltip的build使用 `OverlayPortal.overlayChildLayoutBuilder`；当UtenSplitView的LayoutBuilder回调令AdaptiveHierarchyPane把同一keyed leading/trailing从Row搬到compact Stack时，旧portal先在activate中重新挂回原RenderTheater，attach的dirty deferred child会调用markNeedsLayout，此时不属于当前布局回调的活跃祖先链，遂触发断言。

这是保留状态的结构搬移与已布局portal相遇的问题。不能删除GlobalKey、丢掉草稿/输入、关闭assert、单纯延迟固定120ms或直接把所有Popup判坏。生产修由A代理负责；本独立树保持生产源码只读。候选修后应重跑本文件所有四项、真实Mould hover-first-narrow和实际Web/Windows相同动作。

## 初轮夹具错误已保留并排除

早期bare探针使用UtenSplitView默认minTwoPaneWidth=600，1280→714根本没跨界，绿色不能证明迁移安全。旧探针源码及原日志没有删除；修正为840后得到最小2绿2红。`probe-v5-before-threshold-correction.dart` 等保留这一执行错误证据，不用于关闭缺陷。

所有SDK操作经仓库私有Flutter工具，receipt记录保护输入字节未变。源码指纹用Git blob；日志/JSON原件按实际文件字节，不做换行配平。未合并main、推送、部署或正式打包。
