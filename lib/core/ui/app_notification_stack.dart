import 'package:flutter/material.dart';

/// 顶部通知叠放项构建器。
///
/// [active] 为 true 时，该项当前完整可见，可以启动自动关闭计时；收拢状态下仅最上层
/// 通知 active，背后的层只渲染不可交互的卡片轮廓，避免用户尚未读到就自动消失。
/// [announce] 仅对本次需要播报的新顶层通知为 true，展开旧通知不会重复打断读屏。
typedef UtenNotificationStackItemBuilder = Widget Function(
  BuildContext context,
  int index,
  bool active,
  bool announce,
);

/// iPhone 式顶部通知叠放展示层。
///
/// - 默认收拢：最新通知完整显示，较早通知以 2 层轮廓向后叠放；
/// - 展开：最近最多 [maxVisibleItems] 条通知完整显示，均可点击、滑动或关闭；
/// - 队列更长时只限制“同时完整展示”的数量，不删除任何通知；
/// - 展开按钮使用 48dp 触控目标；小屏/大字号自动切为图标按钮；
/// - 动画只做 220ms 淡入淡出，系统关闭动画时立即切换，不抢焦点。
class UtenNotificationStack extends StatefulWidget {
  const UtenNotificationStack({
    super.key,
    required this.totalCount,
    required this.visibleCount,
    required this.itemBuilder,
  }) : assert(totalCount >= visibleCount),
       assert(visibleCount > 0),
       assert(visibleCount <= maxVisibleItems);

  /// 顶部区域同时完整展示的安全上限；更多通知继续保留在服务队列中。
  static const int maxVisibleItems = 3;

  final int totalCount;
  final int visibleCount;
  final UtenNotificationStackItemBuilder itemBuilder;

  @override
  State<UtenNotificationStack> createState() => _UtenNotificationStackState();
}

class _UtenNotificationStackState extends State<UtenNotificationStack> {
  static const Duration _expandDuration = Duration(milliseconds: 220);
  static const Duration _collapseDuration = Duration(milliseconds: 160);

  bool _expanded = false;

  @override
  void didUpdateWidget(covariant UtenNotificationStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visibleCount <= 1) _expanded = false;
  }

  String get _expandLabel {
    if (widget.totalCount <= widget.visibleCount) {
      return '展开 ${widget.totalCount} 条通知';
    }
    return '展开最近 ${widget.visibleCount} 条通知，共 ${widget.totalCount} 条';
  }

  String get _collapseLabel => '收起通知，共 ${widget.totalCount} 条';

  void _toggleExpanded() {
    setState(() => _expanded = !_expanded);
  }

  Widget _toggleButton(BuildContext context, BoxConstraints constraints) {
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final compact = constraints.maxWidth < 420 || textScale > 1.5;
    final label = _expanded ? _collapseLabel : _expandLabel;
    final icon = _expanded
        ? Icons.unfold_less_rounded
        : Icons.unfold_more_rounded;

    if (compact) {
      return Semantics(
        key: const ValueKey('app-notification-stack-toggle'),
        button: true,
        label: label,
        excludeSemantics: true,
        child: Tooltip(
          message: label,
          child: IconButton(
            onPressed: _toggleExpanded,
            icon: Icon(icon, semanticLabel: label),
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          ),
        ),
      );
    }

    return Semantics(
      key: const ValueKey('app-notification-stack-toggle'),
      button: true,
      label: label,
      excludeSemantics: true,
      child: TextButton.icon(
        onPressed: _toggleExpanded,
        icon: Icon(icon, size: 20),
        label: Text(label),
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 12),
        ),
      ),
    );
  }

  Widget _collapsedStack(BuildContext context) {
    final theme = Theme.of(context);
    final peekCount = widget.visibleCount > 2 ? 2 : widget.visibleCount - 1;
    final bottomInset = peekCount * 6.0;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.topCenter,
        children: [
          for (var depth = peekCount; depth >= 1; depth--)
            Positioned.fill(
              top: depth * 6.0,
              left: depth * 8.0,
              right: depth * 8.0,
              bottom: depth * -6.0,
              child: ExcludeSemantics(
                child: IgnorePointer(
                  child: Material(
                    color: theme.colorScheme.surfaceContainerHighest,
                    elevation: (3 - depth).toDouble(),
                    shadowColor: theme.colorScheme.shadow.withValues(
                      alpha: 0.16,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final content = Column(
          key: ValueKey(_expanded),
          mainAxisSize: MainAxisSize.min,
          children: [
            _expanded ? _expandedList(context) : _collapsedStack(context),
            _toggleButton(context, constraints),
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
      },
    );
  }
}
