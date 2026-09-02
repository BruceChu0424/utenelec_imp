import 'package:flutter/material.dart';

/// 顶部通知叠放项构建器。
///
/// [active] 为 true 时，该项当前完整可见，可以启动自动关闭计时；收拢状态下仅最上层
/// 通知 active，背后的层只渲染不可交互的卡片轮廓（未挂载项的到期由宿主按
/// 「到达时刻 + 停留时长」统一处理，最早的先消失）。
/// [announce] 仅对本次需要播报的新顶层通知为 true，展开旧通知不会重复打断读屏。
typedef UtenNotificationStackItemBuilder =
    Widget Function(
      BuildContext context,
      int index,
      bool active,
      bool announce,
    );

/// iPhone 式顶部通知叠放展示层（受控组件：展开状态由宿主持有）。
///
/// - 默认收拢：最新通知完整显示，较早通知以 2 层轮廓向后叠放；
/// - 展开：最近最多 [maxVisibleItems] 条通知完整显示，均可点击、滑动或关闭；
/// - 队列更长时只限制“同时完整展示”的数量，不删除任何通知（到期移除由宿主
///   独立计时，最早到达的先消失）；
/// - 展开控制是一枚紧凑计数胶囊（居中悬挂在叠放层下方，箭头 + 队列总数），
///   不再使用整行文字按钮；命中区域与触控目标仍保证 48dp，完整文案走
///   tooltip 与 Semantics 标签；
/// - 动画只做 220ms 淡入淡出，系统关闭动画时立即切换，不抢焦点。
class UtenNotificationStack extends StatefulWidget {
  const UtenNotificationStack({
    super.key,
    required this.totalCount,
    required this.visibleCount,
    required this.expanded,
    required this.onToggleExpanded,
    required this.itemBuilder,
  }) : assert(totalCount >= visibleCount),
       assert(visibleCount > 0),
       assert(visibleCount <= maxVisibleItems);

  /// 顶部区域同时完整展示的安全上限；更多通知继续保留在服务队列中。
  static const int maxVisibleItems = 3;

  final int totalCount;
  final int visibleCount;

  /// 当前是否展开（受控）：宿主持有状态，便于它判断哪些通知处于挂载中。
  final bool expanded;

  /// 展开 / 收拢切换回调（计数胶囊触发）。
  final VoidCallback onToggleExpanded;

  final UtenNotificationStackItemBuilder itemBuilder;

  @override
  State<UtenNotificationStack> createState() => _UtenNotificationStackState();
}

class _UtenNotificationStackState extends State<UtenNotificationStack> {
  static const Duration _expandDuration = Duration(milliseconds: 220);
  static const Duration _collapseDuration = Duration(milliseconds: 160);

  String get _expandLabel {
    if (widget.totalCount <= widget.visibleCount) {
      return '展开 ${widget.totalCount} 条通知';
    }
    return '展开最近 ${widget.visibleCount} 条通知，共 ${widget.totalCount} 条';
  }

  String get _collapseLabel => '收起通知，共 ${widget.totalCount} 条';

  /// 紧凑计数胶囊：替代历史上的整行「展开 X 条通知」文字按钮。
  ///
  /// 视觉只有「方向箭头 + 队列总数」一枚 stadium 小胶囊，居中挂在叠放层下方；
  /// 完整说明（展开/收起、共几条）保留在 tooltip 与 Semantics 标签里，读屏与
  /// 悬停仍能拿到完整语义。IconButton + padded 触控目标保证 ≥48dp 命中。
  Widget _toggleButton(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final label = widget.expanded ? _collapseLabel : _expandLabel;
    // 宿主可能挂在 Navigator 兄弟层（无 Overlay 祖先，同 _AppNotificationBanner
    // 关闭按钮的守卫）：此时不建 Tooltip，语义标签仍由外层 Semantics 提供。
    final hasOverlay = Overlay.maybeOf(context) != null;
    Widget button = IconButton(
      onPressed: widget.onToggleExpanded,
      visualDensity: VisualDensity.compact,
      style: IconButton.styleFrom(
        backgroundColor: scheme.surfaceContainerHigh,
        foregroundColor: scheme.onSurfaceVariant,
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 14),
      ),
      icon: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            widget.expanded
                ? Icons.expand_less_rounded
                : Icons.expand_more_rounded,
            size: 18,
          ),
          const SizedBox(width: 2),
          Text(
            '${widget.totalCount}',
            style: theme.textTheme.labelMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
    if (hasOverlay) {
      button = Tooltip(message: label, child: button);
    }
    return Semantics(
      key: const ValueKey('app-notification-stack-toggle'),
      button: true,
      label: label,
      excludeSemantics: true,
      child: button,
    );
  }

  Widget _collapsedStack(BuildContext context) {
    final theme = Theme.of(context);
    final peekCount = widget.visibleCount > 2 ? 2 : widget.visibleCount - 1;
    final bottomInset = peekCount * 6.0;

    // 「后面还有通知」的深度提示是卡片下缘露出的 6px 细边条，画在卡片足迹
    // **之外**（Stack 向下溢出 6px + 底部预留），绝不垫在卡片背后——历史上
    // 曾用整块灰色圆角矩形垫背，只露下缘；左/右滑动或淡出移开卡片时整块
    // 灰板暴露出来，就成了「突然全屏宽的灰色横条」。
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.topCenter,
        children: [
          for (var depth = 1; depth <= peekCount; depth++)
            Positioned(
              left: depth * 8.0,
              right: depth * 8.0,
              bottom: -depth * 6.0,
              height: 6.0,
              child: ExcludeSemantics(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: ShapeDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4),
                        side: BorderSide(
                          color: theme.colorScheme.outlineVariant.withValues(
                            alpha: 0.72,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          widget.itemBuilder(context, 0, true, true),
        ],
      ),
    );
  }

  Widget _expandedList(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (var index = 0; index < widget.visibleCount; index++)
        widget.itemBuilder(context, index, true, index == 0),
    ],
  );

  @override
  Widget build(BuildContext context) {
    if (widget.visibleCount == 1) {
      return widget.itemBuilder(context, 0, true, true);
    }

    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final content = Column(
      key: ValueKey(widget.expanded),
      mainAxisSize: MainAxisSize.min,
      children: [
        widget.expanded ? _expandedList(context) : _collapsedStack(context),
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: _toggleButton(context),
        ),
      ],
    );
    return AnimatedSwitcher(
      duration: reduceMotion ? Duration.zero : _expandDuration,
      reverseDuration: reduceMotion ? Duration.zero : _collapseDuration,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) =>
          FadeTransition(opacity: animation, child: child),
      child: content,
    );
  }
}
