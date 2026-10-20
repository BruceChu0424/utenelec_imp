import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/responsive/breakpoint.dart';
import '../../core/theme/uten_anim.dart';
import '../../core/theme/uten_tokens.dart';
import '../feedback/uten_motion.dart';
import 'uten_panel_opening_scope.dart';

/// 右侧滑窗屏宽占比档位（2026-10-17：保留表格可读性，滑窗适当收窄）。
///
/// 面板宽度 = `min(屏宽, max(drawerWidth, 屏宽 × 档位))`：比例优先、调用点的
/// [showUtenAdaptivePanel.drawerWidth] 只作小屏下限。旧口径是各调用点写死像素
/// （720 / 840 / max(720, 50%)），在 expanded 大屏上占比缩水到 35% 左右，表格
/// 挤成一团——这是「滑窗太小」的根因，故全站改为比例驱动并集中在此调参；
/// 与居中弹窗的 [utenDialogWidth] 三档口径分工：右滑面板不走那边。
class UtenPanelWidth {
  UtenPanelWidth._();

  /// 表单 / 简单选择面板：max(下限, 35% 屏宽)。
  static const double form = 0.35;

  /// 内容面板：max(下限, 60% 屏宽)。
  static const double content = 0.60;

  /// 表格 / 列表浏览面板（默认档）：max(下限, 75% 屏宽)。
  static const double browse = 0.75;

  /// 不放大：保持 drawerWidth 原值（菜单类面板）。
  static const double none = 0;
}

/// 右滑面板宽度计算：`min(屏宽, max(preferred, 屏宽 × fraction))`。
/// [showUtenAdaptivePanel] 与各自绘右滑面板（page_permission_drawer 等 5 处）
/// 共用这一个函数，保证全站滑窗一个口径。
double utenPanelWidth(Size screenSize, double preferred, double fraction) =>
    math.min(
      screenSize.width,
      math.max(preferred, screenSize.width * fraction),
    );

/// Opens a Uten panel as a bottom sheet on compact screens and an end drawer
/// on wider screens.
///
/// The function owns only the responsive presentation shell. Loading,
/// selection drafts, validation, cancel and confirm behavior remain inside
/// [builder].
Future<T?> showUtenAdaptivePanel<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  double compactHeightFactor = 0.85,
  double drawerWidth = 420,
  double widthFraction = UtenPanelWidth.browse,
  bool barrierDismissible = true,
  bool enableDrag = true,
  bool useSafeArea = true,
  bool showDragHandle = false,
  String? barrierLabel,
  Color barrierColor = Colors.black54,
  Duration transitionDuration = UtenAnim.normal,

  /// Optional inset/shape for a floating panel. Compact sheets retain their
  /// normal bottom-sheet shape and use the full available width.
  EdgeInsetsGeometry panelMargin = EdgeInsets.zero,
  BorderRadiusGeometry? panelBorderRadius,

  /// 宽屏右侧面板 Material 的投影高度（默认 0 与历史行为一致）。
  double panelElevation = 0,
}) {
  assert(compactHeightFactor > 0 && compactHeightFactor <= 1);
  assert(drawerWidth > 0);

  final resolvedBarrierLabel =
      barrierLabel ??
      MaterialLocalizations.of(context).modalBarrierDismissLabel;
  final duration = utenMotionDurationOf(context, transitionDuration);

  if (context.breakpoint.isCompact) {
    const shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(UtenRadius.lg)),
    );
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      isDismissible: barrierDismissible,
      enableDrag: enableDrag,
      useSafeArea: useSafeArea,
      showDragHandle: showDragHandle,
      barrierLabel: resolvedBarrierLabel,
      barrierColor: barrierColor,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      sheetAnimationStyle: AnimationStyle(
        duration: duration,
        reverseDuration: duration,
      ),
      builder: (sheetContext) {
        final mediaQuery = MediaQuery.of(sheetContext);
        final visibleHeight = math.max(
          0.0,
          mediaQuery.size.height -
              mediaQuery.viewInsets.bottom -
              mediaQuery.padding.top,
        );
        return Padding(
          padding: EdgeInsets.only(bottom: mediaQuery.viewInsets.bottom),
          child: SizedBox(
            height: visibleHeight * compactHeightFactor,
            child: _PanelContent(builder: builder),
          ),
        );
      },
    );
  }

  final isRtl = Directionality.of(context) == TextDirection.rtl;
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: resolvedBarrierLabel,
    barrierColor: barrierColor,
    transitionDuration: duration,
    pageBuilder: (dialogContext, animation, _) {
      final mediaQuery = MediaQuery.of(dialogContext);
      Widget content = _PanelContent(builder: builder);
      if (useSafeArea) {
        content = SafeArea(left: false, child: content);
      }
      return Padding(
        padding: EdgeInsets.only(bottom: mediaQuery.viewInsets.bottom),
        child: Align(
          alignment: AlignmentDirectional.centerEnd,
          // Translate the panel and its inset, rather than the full-screen
          // route. Including a floating margin keeps the whole panel outside
          // the screen at the start of the transition.
          child: UtenMotion(
            duration: transitionDuration,
            builder: (_, motionDuration) => SlideTransition(
              position: motionDuration == Duration.zero
                  ? const AlwaysStoppedAnimation(Offset.zero)
                  : Tween<Offset>(
                      begin: Offset(isRtl ? -1 : 1, 0),
                      end: Offset.zero,
                    ).animate(
                      animation.drive(CurveTween(curve: UtenAnim.standard)),
                    ),
              child: Padding(
                padding: panelMargin,
                child: Material(
                  key: const Key('uten-adaptive-panel'),
                  color: Theme.of(dialogContext).colorScheme.surface,
                  elevation: panelElevation,
                  borderRadius: panelBorderRadius,
                  clipBehavior: panelBorderRadius == null
                      ? Clip.none
                      : Clip.antiAlias,
                  child: SizedBox(
                    width: utenPanelWidth(
                      mediaQuery.size,
                      drawerWidth,
                      widthFraction,
                    ),
                    height: double.infinity,
                    child: content,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
    transitionBuilder: (_, _, _, child) => child,
  );
}

/// Mount lifecycle and authorization state immediately so requests run in
/// parallel with motion. Only heavy views use the opening-ready scope.
class _PanelContent extends StatefulWidget {
  const _PanelContent({required this.builder});

  final WidgetBuilder builder;

  @override
  State<_PanelContent> createState() => _PanelContentState();
}

class _PanelContentState extends State<_PanelContent> {
  Animation<double>? _animation;
  bool _ready = false;
  late Widget _content = Builder(builder: widget.builder);

  @override
  void didUpdateWidget(_PanelContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.builder != widget.builder) {
      _content = Builder(builder: widget.builder);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animation = ModalRoute.of(context)?.animation;
    if (_animation != animation) {
      _animation?.removeStatusListener(_onStatus);
      _animation?.removeListener(_onTick);
      _animation = animation;
      animation?.addStatusListener(_onStatus);
      animation?.addListener(_onTick);
    }
    if (animation == null ||
        animation.value >= 1 ||
        utenMotionDurationOf(context, UtenAnim.normal) == Duration.zero) {
      _ready = true;
    }
  }

  void _onStatus(AnimationStatus status) {
    if (!_ready && status == AnimationStatus.completed && mounted) {
      setState(() => _ready = true);
    }
  }

  void _onTick() {
    // A route can already be at its final transform while Flutter reports
    // forward until the next simulation tick. Release the view at the actual
    // end position, without imposing an extra empty frame on ready data.
    if (!_ready && (_animation?.value ?? 0) >= 1 && mounted) {
      setState(() => _ready = true);
    }
  }

  @override
  void dispose() {
    _animation?.removeStatusListener(_onStatus);
    _animation?.removeListener(_onTick);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => UtenMotion(
    duration: UtenAnim.normal,
    builder: (context, duration) {
      // A performance/accessibility change may finish the reveal early. Once
      // mounted the content stays mounted, even if motion is later re-enabled.
      _ready = _ready || duration == Duration.zero;
      return UtenPanelOpeningScope(
        ready: _ready,
        child: RepaintBoundary(child: _content),
      );
    },
  );
}
