// UtenDragReorderList - 纵向「拖手柄换位」列表(Draggable 实现)。
// 文档：docs/00-项目准则/03-自适应布局组件.md §3.3
//
// 替代 ReorderableListView 的原因：根部整体缩放(UtenDisplayZoomBox，zoom ≠ 1)之下，
// SDK 的拖影用「窗口坐标的指针位置 − 画布坐标的浮层原点」定位、换位判定也混用两套坐标，
// 拖影会偏 zoom 倍。这里所有坐标都相对列表/视口 RenderBox 换算(globalToLocal /
// localToGlobal(ancestor:))，任何 Transform 祖先之下都正确。
//
// 交互：
// - 手柄 [UtenDragReorderHandle] 放在项内任意位置；桌面/网页按住即拖，触屏长按起拖
//   ([UtenDragReorderHandle.immediate] 可强制)；
// - 拖影 = 项本身同宽 + 浮起投影，起拖时与原项完全重合、随指针移动(可用
//   [feedbackBuilder] 换轻量版，如工作台分区只显示标题行)；被拖项原位 30% 透明；
// - 换位判定与 ReorderableListView 同口径：指针(列表坐标)在其余各项**中点**之下的个数
//   = 被拖项应在的下标，不等于当前下标即回调 [onReorder](悬停即换位、立即写回，松手
//   不再二次处理；指针越出列表上/下沿自然钳到首/末位)；
// - 拖到所在滚动视口上下沿 [autoScrollEdge] 内自动滚动(嵌入页面滚动视图时滚页面，
//   自带 ListView 时滚自己)，滚动中按最近指针位置继续判定换位。
//
// 两种承载：
// - [UtenDragReorderList.embedded]：渲染成 Column，嵌在外层 ListView /
//   SingleChildScrollView 里(等价 shrinkWrap + NeverScrollable)；
// - 默认：自带 ListView(controller / padding / shrinkWrap / physics 透传)。
//
// onReorder(oldIndex, newIndex) 语义与 ReorderableListView.onReorderItem 一致：
// newIndex 为被拖项应落到的最终下标，宿主 removeAt(oldIndex) 后 insert(newIndex)。
// 固定行(如列设置的「全选」「恢复默认」)由宿主在回调里钳位，本组件不裁剪 newIndex。

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../core/theme/uten_tokens.dart';

/// 拖影构造器：[width] 为被拖项实测宽(画布单位)。
typedef UtenDragReorderFeedbackBuilder =
    Widget Function(BuildContext context, int index, double width);

class UtenDragReorderList extends StatefulWidget {
  /// 自带 ListView 的列表(列设置弹层等有限高、可滚的场景)。
  const UtenDragReorderList({
    super.key,
    required this.ids,
    required this.itemBuilder,
    required this.onReorder,
    this.feedbackBuilder,
    this.controller,
    this.padding,
    this.shrinkWrap = false,
    this.physics,
    this.autoScrollEdge = 56,
  }) : embedded = false;

  /// 嵌在外层滚动视图里的列表：渲染成 Column，自动滚动作用于外层视口。
  const UtenDragReorderList.embedded({
    super.key,
    required this.ids,
    required this.itemBuilder,
    required this.onReorder,
    this.feedbackBuilder,
    this.autoScrollEdge = 56,
  }) : embedded = true,
       controller = null,
       padding = null,
       shrinkWrap = true,
       physics = null;

  /// 各项稳定标识(与 [itemBuilder] 下标一一对应；换位后宿主按新顺序重建)。
  final List<Object> ids;

  final IndexedWidgetBuilder itemBuilder;

  /// 悬停换位回调：被拖项从 [oldIndex] 落到最终下标 [newIndex]。
  final void Function(int oldIndex, int newIndex) onReorder;

  /// 拖影；默认「项本身 + 浮起投影」，宽度取项实测宽。
  final UtenDragReorderFeedbackBuilder? feedbackBuilder;

  final ScrollController? controller;
  final EdgeInsetsGeometry? padding;
  final bool shrinkWrap;
  final ScrollPhysics? physics;

  /// 距滚动视口上下沿多少像素内开始自动滚动；0 = 关闭。
  final double autoScrollEdge;

  /// true = Column 承载(嵌入外层滚动视图)；false = 自带 ListView。
  final bool embedded;

  @override
  State<UtenDragReorderList> createState() => _UtenDragReorderListState();
}

class _UtenDragReorderListState extends State<UtenDragReorderList>
    with SingleTickerProviderStateMixin {
  /// 贴边自动滚动满速(画布像素/秒)。
  static const double _autoScrollSpeed = 900;

  /// 每项一个稳定 GlobalKey：换位后项在 Column/ListView 里换位置，GlobalKey 让
  /// Element/State 跟着搬家(手势与折叠状态不断)，也用于实测项的位置与尺寸。
  final Map<Object, GlobalKey> _itemKeys = {};

  /// 正在拖动的项；null = 无拖动。
  Object? _dragging;

  /// 上次回调 onReorder 时的 ids 快照与请求下标：宿主重建前的连续 update 不重复换位。
  List<Object>? _requestedIds;
  int? _requestedIndex;

  /// 最近一次指针窗口坐标(自动滚动中重判换位用)。
  Offset? _lastGlobalPosition;

  Ticker? _ticker;
  ScrollPosition? _scrollPosition;
  double _scrollVelocity = 0;
  Duration? _lastTick;

  GlobalKey _keyFor(Object id) => _itemKeys.putIfAbsent(id, GlobalKey.new);

  /// 已布局且仍在树上的项 RenderBox；视口外未布局的项返回 null。
  RenderBox? _boxOf(Object id) {
    final box = _itemKeys[id]?.currentContext?.findRenderObject();
    if (box is RenderBox && box.attached && box.hasSize) return box;
    return null;
  }

  @override
  void didUpdateWidget(covariant UtenDragReorderList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.ids, widget.ids)) {
      _itemKeys.removeWhere((id, _) => !widget.ids.contains(id));
    }
  }

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }

  void _onDragStarted(Object id) {
    setState(() {
      _dragging = id;
      _requestedIds = null;
      _requestedIndex = null;
    });
  }

  void _onDragEnded() {
    _stopAutoScroll();
    _lastGlobalPosition = null;
    if (_dragging == null) return;
    setState(() {
      _dragging = null;
      _requestedIds = null;
      _requestedIndex = null;
    });
  }

  void _onDragUpdate(BuildContext handleContext, Offset globalPosition) {
    _lastGlobalPosition = globalPosition;
    _updateReorder(globalPosition);
    _updateAutoScroll(handleContext, globalPosition);
  }

  /// 拖影锚点：指针在项内的位置(画布单位)，拖影与原项重合。
  Offset _dragAnchor(Object id, Offset globalPosition) {
    final box = _boxOf(id);
    if (box == null) return Offset.zero;
    return box.globalToLocal(globalPosition);
  }

  /// 换位判定：指针(换算到列表坐标)在其余各项中点之下的个数 = 被拖项应在的下标。
  void _updateReorder(Offset globalPosition) {
    final dragging = _dragging;
    final listBox = context.findRenderObject();
    if (dragging == null || listBox is! RenderBox || !listBox.attached) return;
    final ids = widget.ids;
    final oldIndex = ids.indexOf(dragging);
    if (oldIndex < 0) return;
    final pointerY = listBox.globalToLocal(globalPosition).dy;
    // 只量已布局的项(ListView 视口外的项没有 RenderBox)：ListView 的布局范围连续，
    // 视口上方未布局的项一律算在指针之上、下方的一律算在指针之下。
    int? firstLaidOut;
    var passed = 0;
    for (var i = 0; i < ids.length; i++) {
      if (i == oldIndex) continue;
      final box = _boxOf(ids[i]);
      if (box == null) continue;
      firstLaidOut ??= i;
      final top = box.localToGlobal(Offset.zero, ancestor: listBox).dy;
      if (top + box.size.height / 2 < pointerY) passed++;
    }
    if (firstLaidOut == null) return;
    var aboveUnlaid = 0;
    for (var i = 0; i < firstLaidOut; i++) {
      if (i != oldIndex) aboveUnlaid++;
    }
    final newIndex = aboveUnlaid + passed;
    if (newIndex == oldIndex) return;
    if (_requestedIndex == newIndex &&
        _requestedIds != null &&
        listEquals(_requestedIds, ids)) {
      return;
    }
    _requestedIds = List<Object>.of(ids);
    _requestedIndex = newIndex;
    widget.onReorder(oldIndex, newIndex);
  }

  void _updateAutoScroll(BuildContext handleContext, Offset globalPosition) {
    final edge = widget.autoScrollEdge;
    final scrollable = Scrollable.maybeOf(handleContext);
    final viewport = scrollable?.context.findRenderObject();
    if (edge <= 0 ||
        scrollable == null ||
        viewport is! RenderBox ||
        !viewport.attached ||
        !viewport.hasSize) {
      _stopAutoScroll();
      return;
    }
    // 指针换算到视口坐标(globalToLocal 反算整条变换链，整体缩放下也对)。
    final local = viewport.globalToLocal(globalPosition);
    final height = viewport.size.height;
    var velocity = 0.0;
    if (local.dy < edge) {
      velocity = -((edge - local.dy) / edge).clamp(0.0, 1.0);
    } else if (local.dy > height - edge) {
      velocity = ((local.dy - (height - edge)) / edge).clamp(0.0, 1.0);
    }
    if (velocity == 0) {
      _stopAutoScroll();
      return;
    }
    _scrollPosition = scrollable.position;
    _scrollVelocity = velocity;
    final ticker = _ticker ??= createTicker(_tick);
    if (!ticker.isActive) {
      _lastTick = null;
      ticker.start();
    }
  }

  void _tick(Duration elapsed) {
    final position = _scrollPosition;
    final last = _lastTick;
    _lastTick = elapsed;
    if (position == null ||
        !position.hasPixels ||
        !position.hasContentDimensions ||
        last == null) {
      return;
    }
    final dt = (elapsed - last).inMicroseconds / Duration.microsecondsPerSecond;
    if (dt <= 0) return;
    final next = (position.pixels + _scrollVelocity * _autoScrollSpeed * dt)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if (next == position.pixels) return;
    position.jumpTo(next);
    // 视口滚了、指针没动：项从指针下方滑过，也要判定换位。
    final pointer = _lastGlobalPosition;
    if (pointer != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _dragging != null) _updateReorder(pointer);
      });
    }
  }

  void _stopAutoScroll() {
    _ticker?.stop();
    _lastTick = null;
    _scrollVelocity = 0;
    _scrollPosition = null;
  }

  Widget _buildFeedback(BuildContext context, Object id) {
    final index = widget.ids.indexOf(id);
    if (index < 0) return const SizedBox.shrink();
    final width = _boxOf(id)?.size.width ?? 320.0;
    final custom = widget.feedbackBuilder;
    if (custom != null) return custom(context, index, width);
    return SizedBox(
      width: width,
      child: Material(
        elevation: 6,
        color: Theme.of(context).colorScheme.surface,
        borderRadius: UtenRadius.lgAll,
        clipBehavior: Clip.antiAlias,
        child: widget.itemBuilder(context, index),
      ),
    );
  }

  Widget _buildItem(BuildContext context, int index) {
    final id = widget.ids[index];
    return KeyedSubtree(
      key: _keyFor(id),
      // 树形恒定（始终隔一层 Opacity）：起拖后若把项换成另一种包裹，项下的 Draggable
      // 会被重建，后续 onDragUpdate/onDragEnd 全部丢失（拖动卡死在半透明态）。
      child: Opacity(
        opacity: _dragging == id ? 0.3 : 1,
        child: widget.itemBuilder(context, index),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Widget list;
    if (widget.embedded) {
      list = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < widget.ids.length; i++) _buildItem(context, i),
        ],
      );
    } else {
      list = ListView.builder(
        controller: widget.controller,
        padding: widget.padding,
        shrinkWrap: widget.shrinkWrap,
        physics: widget.physics,
        itemCount: widget.ids.length,
        itemBuilder: _buildItem,
      );
    }
    return _UtenDragReorderScope(state: this, dragging: _dragging, child: list);
  }
}

/// 手柄找列表用的作用域；[dragging] 变化时通知手柄重建(拖动中其余手柄不再起拖)。
class _UtenDragReorderScope extends InheritedWidget {
  const _UtenDragReorderScope({
    required this.state,
    required this.dragging,
    required super.child,
  });

  final _UtenDragReorderListState state;
  final Object? dragging;

  static _UtenDragReorderScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_UtenDragReorderScope>();

  @override
  bool updateShouldNotify(_UtenDragReorderScope oldWidget) =>
      oldWidget.state != state || oldWidget.dragging != dragging;
}

/// 拖动手柄：包住手柄外观放进第 [index] 项里即可(对应 ReorderableDragStartListener)。
///
/// 不在 [UtenDragReorderList] 之内(如拖影副本里的手柄)或下标越界时只显示外观。
class UtenDragReorderHandle extends StatelessWidget {
  const UtenDragReorderHandle({
    super.key,
    required this.index,
    required this.child,
    this.immediate,
  });

  final int index;
  final Widget child;

  /// true 按住即拖、false 长按起拖；null 按平台(桌面/网页即拖，触屏长按)。
  final bool? immediate;

  @override
  Widget build(BuildContext context) {
    final scope = _UtenDragReorderScope.maybeOf(context);
    final state = scope?.state;
    if (scope == null ||
        state == null ||
        index < 0 ||
        index >= state.widget.ids.length) {
      return child;
    }
    final id = state.widget.ids[index];
    final platform = Theme.of(context).platform;
    final touch =
        platform == TargetPlatform.android ||
        platform == TargetPlatform.iOS ||
        platform == TargetPlatform.fuchsia;
    final delayed = !(immediate ?? !touch);
    final feedback = Builder(
      builder: (feedbackContext) => state._buildFeedback(feedbackContext, id),
    );
    final handle = MouseRegion(cursor: SystemMouseCursors.grab, child: child);
    // 已有一项在拖时其余手柄不再起拖(多指误触)。
    final maxDrags = scope.dragging == null ? 1 : 0;
    Offset anchor(Draggable<Object> _, BuildContext _, Offset position) =>
        state._dragAnchor(id, position);
    void started() => state._onDragStarted(id);
    void update(DragUpdateDetails details) =>
        state._onDragUpdate(context, details.globalPosition);
    void ended(DraggableDetails _) => state._onDragEnded();
    // onDraggableCanceled 不看 Draggable 是否仍挂载（onDragEnd 看）：没有 DragTarget
    // 的拖动松手一律走 canceled，作为收尾兜底；_onDragEnded 幂等。
    void canceled(Velocity _, Offset _) => state._onDragEnded();
    if (delayed) {
      return LongPressDraggable<Object>(
        data: id,
        feedback: feedback,
        maxSimultaneousDrags: maxDrags,
        dragAnchorStrategy: anchor,
        onDragStarted: started,
        onDragUpdate: update,
        onDragEnd: ended,
        onDraggableCanceled: canceled,
        child: handle,
      );
    }
    return Draggable<Object>(
      data: id,
      feedback: feedback,
      maxSimultaneousDrags: maxDrags,
      dragAnchorStrategy: anchor,
      onDragStarted: started,
      onDragUpdate: update,
      onDragEnd: ended,
      onDraggableCanceled: canceled,
      child: handle,
    );
  }
}
