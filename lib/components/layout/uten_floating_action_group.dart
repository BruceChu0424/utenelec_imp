import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';
import '../../core/ui/capsule_nav_metrics.dart';

/// 右下角悬浮操作组。
///
/// 组内业务动作（按钮/胶囊）高度统一为 [controlHeight]；宽度各自随内容
/// 收紧，不互相等宽拉伸（2026-10-04 用户口径：已选胶囊、取消等短按钮被
/// 长按钮撑宽显得空，每个控件内容多宽就多宽；计数文案变化时宽度自然跟随）。
class UtenFloatingActionGroup extends StatefulWidget {
  const UtenFloatingActionGroup({
    super.key,
    required this.children,
    this.maxWidth = 1080,
    this.maxHeight,
    this.onMinimumContentHeightChanged,
  });

  final List<Widget> children;
  final double maxWidth;

  /// Optional local total-height budget, including capsule-navigation padding.
  /// Null keeps the window-based default for existing non-table consumers.
  /// A table must reserve a complete row before supplying this budget.
  final double? maxHeight;

  /// Natural height of the tallest individual control at this local width.
  /// Excludes capsule padding and wrap spacing. A bounded host can use it to
  /// keep one complete, naturally wrapping action visible while scrolling.
  final ValueChanged<double>? onMinimumContentHeightChanged;

  /// 悬浮组内控件的统一高度。
  ///
  /// 取值 = [UtenButtonSize.large] 的最小高度：组里的业务动作一律用 large，
  /// 与表格选择摘要沿同一套48dp主操作规格。这里对每个孩子统一下 minHeight，谁也不用
  /// 记得在调用点传高度；用 min 而非 tight，超大字号下按钮文案换行仍能长高。
  static const double controlHeight = 48;

  /// 正文末尾的可滚动留白，可把末行完整滚到悬浮操作组上方。
  /// 也是默认的总高度上限；有本地预算的宿主可传 [maxHeight]，超长组内滚动。
  static const double scrollClearance = 200;

  @override
  State<UtenFloatingActionGroup> createState() =>
      _UtenFloatingActionGroupState();
}

class _UtenFloatingActionGroupState extends State<UtenFloatingActionGroup> {
  final _scrollController = ScrollController();
  final _controlKeys = <GlobalKey>[];
  bool _minimumMeasureScheduled = false;
  double? _reportedMinimumContentHeight;

  @override
  void didUpdateWidget(covariant UtenFloatingActionGroup oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The keyed group survives embedded/fullscreen handoff. An embedded host
    // stops consuming measurements and clears its budget, so a new consumer
    // must receive the current natural height even if that height is unchanged.
    if (oldWidget.onMinimumContentHeightChanged == null &&
        widget.onMinimumContentHeightChanged != null) {
      _reportedMinimumContentHeight = null;
    }
  }

  void _scheduleMinimumMeasure() {
    if (widget.onMinimumContentHeightChanged == null ||
        _minimumMeasureScheduled) {
      return;
    }
    _minimumMeasureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _minimumMeasureScheduled = false;
      if (!mounted || widget.onMinimumContentHeightChanged == null) return;
      var minimum = 0.0;
      for (final key in _controlKeys) {
        final box = key.currentContext?.findRenderObject() as RenderBox?;
        if (box != null && box.attached && box.hasSize) {
          if (box.size.height > minimum) minimum = box.size.height;
        }
      }
      if (_reportedMinimumContentHeight == null ||
          (_reportedMinimumContentHeight! - minimum).abs() > 0.5) {
        _reportedMinimumContentHeight = minimum;
        widget.onMinimumContentHeightChanged!(minimum);
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.children.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    final availableWidth = (media.size.width - UtenSpacing.s32)
        .clamp(0.0, widget.maxWidth)
        .toDouble();

    // compact 悬浮胶囊避让：本组常挂在 Scaffold FAB 位或表格 Stage 的贴底
    // Positioned 上，靠自带底 padding 抬到胶囊上方（弹窗/抽屉里查不到 scope
    // 取 0，位置不变）。滚动末尾让位由各页滚动件另行查询，不在组内重复加。
    final capsuleOcclusion = UtenCapsuleNavScope.occlusionOf(context);
    final totalHeight =
        widget.maxHeight ??
        ((media.size.height - media.viewInsets.bottom) * 0.4)
            .clamp(
              UtenFloatingActionGroup.controlHeight,
              UtenFloatingActionGroup.scrollClearance,
            )
            .toDouble();
    assert(totalHeight.isFinite && totalHeight >= 0);
    assert(widget.maxHeight == null || totalHeight >= capsuleOcclusion);
    final contentHeight = (totalHeight - capsuleOcclusion)
        .clamp(0.0, totalHeight)
        .toDouble();

    if (widget.onMinimumContentHeightChanged != null) {
      while (_controlKeys.length < widget.children.length) {
        _controlKeys.add(GlobalKey());
      }
      if (_controlKeys.length > widget.children.length) {
        _controlKeys.removeRange(widget.children.length, _controlKeys.length);
      }
    }

    final group = Padding(
      padding: EdgeInsets.only(bottom: capsuleOcclusion),
      child: Material(
        type: MaterialType.transparency,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: availableWidth,
            maxHeight: contentHeight,
          ),
          child: NotificationListener<ScrollMetricsNotification>(
            onNotification: (_) => true,
            child: NotificationListener<ScrollNotification>(
              onNotification: (_) => true,
              child: Scrollbar(
                controller: _scrollController,
                thumbVisibility: true,
                child: SingleChildScrollView(
                  controller: _scrollController,
                  primary: false,
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    runAlignment: WrapAlignment.end,
                    spacing: UtenSpacing.s8,
                    runSpacing: UtenSpacing.s8,
                    children: [
                      for (var i = 0; i < widget.children.length; i++)
                        KeyedSubtree(
                          key: widget.onMinimumContentHeightChanged != null
                              ? _controlKeys[i]
                              : null,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(
                                UtenRadius.control,
                              ),
                              boxShadow: UtenElevation.mid(
                                isDark: theme.brightness == Brightness.dark,
                              ),
                            ),
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(
                                minHeight:
                                    UtenFloatingActionGroup.controlHeight,
                              ),
                              child: widget.children[i],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (widget.onMinimumContentHeightChanged == null) return group;
    return LayoutBuilder(
      builder: (context, constraints) {
        _scheduleMinimumMeasure();
        return group;
      },
    );
  }
}
