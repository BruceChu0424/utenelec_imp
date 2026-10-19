import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/uten_tokens.dart';

/// 可拖动、可缩放、可收起成悬浮球的无蒙版浮窗（2026-10-19「添加组件弹窗改浮窗核对」，
/// 同日按用户反馈改为页面内常驻浮层，并带缩起/展开动画）。
///
/// 用法：把它放进宿主页面的 `Stack` 里（`Positioned.fill` 包裹拿满屏约束），窗口自身
/// 管理位置与尺寸。因为不是路由弹窗：底层页面照常可点可滚；跳去别的页面时随页面
/// 一起被盖住（回来现场还在，由宿主决定何时卸载）；标题栏按住拖动移动，四边/四角
/// 手柄缩放（拉到屏幕边即停，不会把窗口顶跑），双击标题栏复位居中，Esc 关闭
/// （焦点在窗口内时）。标题栏关闭按钮左侧有「缩小」按钮：窗口收成可拖动的圆形
/// 悬浮球——动画从窗口 morph 到缩小按钮所在位置；点球再 morph 展开回原位。
/// 关闭/保存的时机全部经 [onClose] 回调交给宿主。
class UtenFloatingWindow extends StatefulWidget {
  const UtenFloatingWindow({
    super.key,
    required this.title,
    required this.body,
    required this.onClose,
    this.actions,
    this.initialSize = const Size(560, 640),
    this.minSize = const Size(420, 320),
    this.maxSize,
    this.headerTrailing,
    this.collapseIcon = Icons.post_add_rounded,
  });

  final String title;
  final Widget body;

  /// 点关闭按钮 / Esc 时回调；窗口的显隐完全由宿主状态决定。
  final VoidCallback onClose;

  /// 底部操作区（取消/保存等）；为空时不渲染分隔线与区域。
  final Widget? actions;

  /// 初始窗口尺寸（屏幕或 [maxSize] 不足时自动收缩）；双击标题栏也复位到它。
  final Size initialSize;
  final Size minSize;
  final Size? maxSize;

  /// 标题行右侧、缩小按钮之前的自定义内容。
  final Widget? headerTrailing;

  /// 缩小后的悬浮球图标（默认添加组件语义）。
  final IconData collapseIcon;

  @override
  State<UtenFloatingWindow> createState() => UtenFloatingWindowState();
}

class UtenFloatingWindowState extends State<UtenFloatingWindow>
    with TickerProviderStateMixin {
  static const double _handleThickness = 6;
  static const double _cornerExtent = 14;
  static const double _areaMargin = 8;
  static const double _dragKeepWidth = 120;
  static const double _dragKeepHeight = 48;
  static const double _ballSize = 56;
  static const Duration _morphDuration = Duration(milliseconds: 300);

  BoxConstraints _area = const BoxConstraints();
  double _left = 0;
  double _top = 0;
  double _width = 0;
  double _height = 0;
  bool _positioned = false;

  /// 缩小成悬浮球（true=收起态）。缩起/展开经 [_morph] 在窗口矩形与球矩形间
  /// morph 过渡；球初始落在「缩小」按钮的位置（2026-10-19 用户口径）。
  bool _collapsed = false;
  Rect _ballRect = Rect.zero;
  bool _ballPositioned = false;
  final GlobalKey _collapseButtonKey = GlobalKey();
  late final AnimationController _morph = AnimationController(
    vsync: this,
    duration: _morphDuration,
  );
  late final CurvedAnimation _morphCurve = CurvedAnimation(
    parent: _morph,
    curve: Curves.easeInOutCubic,
    reverseCurve: Curves.easeInOutCubic.flipped,
  );

  @override
  void initState() {
    super.initState();
    // morph 结束（收起完成/展开完成）时主动重建一次，让 build 从过渡帧切回
    // 球/窗口的稳态路径；过渡帧里内容以 Opacity 淡出，不重建就还会挂在树上。
    _morph.addStatusListener((status) {
      if ((status == AnimationStatus.completed ||
              status == AnimationStatus.dismissed) &&
          mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _morphCurve.dispose();
    _morph.dispose();
    super.dispose();
  }

  double get _maxWidth {
    final byArea = _area.maxWidth - _areaMargin;
    final cap = widget.maxSize?.width ?? double.infinity;
    final max = byArea < cap ? byArea : cap;
    return max < widget.minSize.width ? widget.minSize.width : max;
  }

  double get _maxHeight {
    final byArea = _area.maxHeight - _areaMargin;
    final cap = widget.maxSize?.height ?? double.infinity;
    final max = byArea < cap ? byArea : cap;
    return max < widget.minSize.height ? widget.minSize.height : max;
  }

  Rect get _windowRect => Rect.fromLTWH(_left, _top, _width, _height);

  void _centerAtInitial() {
    final width = widget.initialSize.width.clamp(
      widget.minSize.width,
      _maxWidth,
    );
    final height = widget.initialSize.height.clamp(
      widget.minSize.height,
      _maxHeight,
    );
    _width = width;
    _height = height;
    _left = (_area.maxWidth - _width) / 2;
    _top = (_area.maxHeight - _height) / 2;
    _positioned = true;
  }

  void _clampPosition() {
    // 至少留 120px 宽、一个标题栏高度在屏幕内，窗口永远拽得回来。
    final minLeft = _dragKeepWidth - _width;
    final maxLeft = _area.maxWidth - _dragKeepWidth;
    _left = _left.clamp(
      minLeft < maxLeft ? minLeft : maxLeft,
      minLeft < maxLeft ? maxLeft : minLeft,
    );
    const double minTop = 0.0;
    final maxTop = _area.maxHeight - _dragKeepHeight;
    _top = _top.clamp(
      minTop < maxTop ? minTop : maxTop,
      minTop < maxTop ? maxTop : minTop,
    );
  }

  void _clampBallPosition() {
    final left = _ballRect.left.clamp(
      _areaMargin,
      _area.maxWidth - _ballSize - _areaMargin,
    );
    final top = _ballRect.top.clamp(
      _areaMargin,
      _area.maxHeight - _ballSize - _areaMargin,
    );
    _ballRect = Rect.fromLTWH(left, top, _ballSize, _ballSize);
  }

  void _beginGesture() {
    // 拖动/缩放前收起焦点，让引用选择框等 Overlay 下拉先关掉。
    FocusManager.instance.primaryFocus?.unfocus();
  }

  /// 宿主要求展开（例如再次点击入口按钮时窗口还缩成球）。
  void expand() {
    if (_collapsed) _startMorph(expand: true);
  }

  void _collapseFromButton() {
    _beginGesture();
    // 球的目标位置 = 「缩小」按钮当前位置（球心对齐按钮中心）。
    final buttonBox =
        _collapseButtonKey.currentContext?.findRenderObject() as RenderBox?;
    final stackBox = context.findRenderObject() as RenderBox?;
    if (buttonBox != null &&
        stackBox != null &&
        buttonBox.attached &&
        stackBox.attached) {
      final center = buttonBox.localToGlobal(
        buttonBox.size.center(Offset.zero),
        ancestor: stackBox,
      );
      _ballRect = Rect.fromCenter(
        center: center,
        width: _ballSize,
        height: _ballSize,
      );
      _clampBallPosition();
      _ballPositioned = true;
    } else if (!_ballPositioned) {
      _ballRect = Rect.fromLTWH(
        _area.maxWidth - _ballSize - 24,
        _area.maxHeight - _ballSize - 24,
        _ballSize,
        _ballSize,
      );
      _ballPositioned = true;
    }
    _startMorph(expand: false);
  }

  void _startMorph({required bool expand}) {
    setState(() {
      _collapsed = !expand;
      if (expand) {
        _morph.reverse();
      } else {
        _morph.forward();
      }
    });
  }

  // 锚定边缩放：拉底边时顶端固定、高度上限=到屏幕底；拉顶边时底端固定、
  // 上限=当前底边；左右同理。保证拉到极限只停不动，不会把窗口顶跑。
  void _resizeBottom(double dy) => setState(() {
    final maxH = (_area.maxHeight - _areaMargin - _top)
        .clamp(widget.minSize.height, _maxHeight);
    _height = (_height + dy).clamp(widget.minSize.height, maxH);
  });

  void _resizeTop(double dy) => setState(() {
    final maxH = (_top + _height - _areaMargin)
        .clamp(widget.minSize.height, _maxHeight);
    final next = (_height - dy).clamp(widget.minSize.height, maxH);
    _top += _height - next;
    _height = next;
  });

  void _resizeRight(double dx) => setState(() {
    final maxW = (_area.maxWidth - _areaMargin - _left)
        .clamp(widget.minSize.width, _maxWidth);
    _width = (_width + dx).clamp(widget.minSize.width, maxW);
  });

  void _resizeLeft(double dx) => setState(() {
    final maxW = (_left + _width - _areaMargin)
        .clamp(widget.minSize.width, _maxWidth);
    final next = (_width - dx).clamp(widget.minSize.width, maxW);
    _left += _width - next;
    _width = next;
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, area) {
        final areaChanged = _area.maxWidth != area.maxWidth ||
            _area.maxHeight != area.maxHeight;
        _area = area;
        if (!_positioned) {
          _centerAtInitial();
        } else if (areaChanged) {
          _width = _width.clamp(widget.minSize.width, _maxWidth);
          _height = _height.clamp(widget.minSize.height, _maxHeight);
          _clampPosition();
        }
        if (_ballPositioned && areaChanged) {
          _clampBallPosition();
        }
        if (_morph.isAnimating) {
          return AnimatedBuilder(
            animation: _morphCurve,
            builder: (context, _) => _buildMorph(theme, _morphCurve.value),
          );
        }
        if (_collapsed) {
          return _buildBall(theme);
        }
        return Focus(
          autofocus: true,
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
            },
            child: Stack(
              children: [
                Positioned.fromRect(
                  rect: _windowRect,
                  child: Stack(
                    children: [
                      _buildWindowScaffold(theme),
                      _edgeHandle(
                        cursor: SystemMouseCursors.resizeRight,
                        top: _cornerExtent,
                        bottom: _cornerExtent,
                        right: 0,
                        width: _handleThickness,
                        onPanUpdate: (dx, dy) => _resizeRight(dx),
                      ),
                      _edgeHandle(
                        cursor: SystemMouseCursors.resizeLeft,
                        top: _cornerExtent,
                        bottom: _cornerExtent,
                        left: 0,
                        width: _handleThickness,
                        onPanUpdate: (dx, dy) => _resizeLeft(dx),
                      ),
                      _edgeHandle(
                        cursor: SystemMouseCursors.resizeDown,
                        left: _cornerExtent,
                        right: _cornerExtent,
                        bottom: 0,
                        height: _handleThickness,
                        onPanUpdate: (dx, dy) => _resizeBottom(dy),
                      ),
                      _edgeHandle(
                        cursor: SystemMouseCursors.resizeUp,
                        left: _cornerExtent,
                        right: _cornerExtent,
                        top: 0,
                        height: _handleThickness,
                        onPanUpdate: (dx, dy) => _resizeTop(dy),
                      ),
                      _cornerHandle(
                        cursor: SystemMouseCursors.resizeDownRight,
                        right: 0,
                        bottom: 0,
                        onPanUpdate: (dx, dy) {
                          _resizeRight(dx);
                          _resizeBottom(dy);
                        },
                      ),
                      _cornerHandle(
                        cursor: SystemMouseCursors.resizeDownLeft,
                        left: 0,
                        bottom: 0,
                        onPanUpdate: (dx, dy) {
                          _resizeLeft(dx);
                          _resizeBottom(dy);
                        },
                      ),
                      _cornerHandle(
                        cursor: SystemMouseCursors.resizeUpRight,
                        right: 0,
                        top: 0,
                        onPanUpdate: (dx, dy) {
                          _resizeTop(dy);
                          _resizeRight(dx);
                        },
                      ),
                      _cornerHandle(
                        cursor: SystemMouseCursors.resizeUpLeft,
                        left: 0,
                        top: 0,
                        onPanUpdate: (dx, dy) {
                          _resizeLeft(dx);
                          _resizeTop(dy);
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 缩起/展开过渡帧：一个矩形在窗口矩形与球矩形之间 lerp，圆角同步 morph，
  /// 窗口内容淡出、球图标淡入。过渡期间不响应指针。
  Widget _buildMorph(ThemeData theme, double t) {
    final rect = Rect.lerp(_windowRect, _ballRect, t)!;
    final radiusValue = lerpDouble(
      UtenRadius.xxlAll.topLeft.x,
      _ballSize / 2,
      t,
    )!;
    final windowOpacity = (1.0 - t * 1.35).clamp(0.0, 1.0);
    final ballOpacity = ((t - 0.45) / 0.55).clamp(0.0, 1.0);
    return Stack(
      children: [
        Positioned.fromRect(
          rect: rect,
          child: IgnorePointer(
            child: Material(
              color: Color.lerp(
                theme.colorScheme.surfaceContainerHigh,
                theme.colorScheme.primary,
                t,
              ),
              elevation: lerpDouble(8, 6, t)!,
              borderRadius: BorderRadius.circular(radiusValue),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // 窗口内容按原窗口尺寸布局（OverflowBox 固定 min=max），由外层
                  // 圆角盒裁切：过渡帧不逐帧重排内容，避免收缩途中布局溢出。
                  Opacity(
                    opacity: windowOpacity,
                    child: OverflowBox(
                      minWidth: _windowRect.width,
                      maxWidth: _windowRect.width,
                      minHeight: _windowRect.height,
                      maxHeight: _windowRect.height,
                      child: _buildWindowScaffold(theme),
                    ),
                  ),
                  Center(
                    child: Opacity(
                      opacity: ballOpacity,
                      child: ScaleTransition(
                        scale: Tween<double>(begin: 0.6, end: 1.0)
                            .animate(_morphCurve),
                        child: Icon(
                          widget.collapseIcon,
                          color: theme.colorScheme.onPrimary,
                          size: 26,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBall(ThemeData theme) {
    return Stack(
      children: [
        Positioned.fromRect(
          rect: _ballRect,
          child: Material(
            color: theme.colorScheme.primary,
            borderRadius: BorderRadius.circular(_ballSize / 2),
            elevation: 6,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => _startMorph(expand: true),
              child: Icon(
                widget.collapseIcon,
                color: theme.colorScheme.onPrimary,
                size: 26,
              ),
            ),
          ),
        ),
        // 悬浮球的拖动手柄：整球可拖（InkWell 的点击与拖动并存——拖动距离超过
        // slop 才算拖，不误触点击）。
        Positioned.fromRect(
          rect: _ballRect,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onPanStart: (_) => _beginGesture(),
            onPanUpdate: (details) => setState(() {
              _ballRect = _ballRect.translate(details.delta.dx, details.delta.dy);
              _clampBallPosition();
            }),
          ),
        ),
      ],
    );
  }

  /// 窗口主体（Material 外壳 + 标题栏 + body + actions）；morph 过渡时复用并整体淡出。
  Widget _buildWindowScaffold(ThemeData theme) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: UtenRadius.xxlAll,
        boxShadow: [
          // 无蒙版下浮窗靠这一圈阴影与底层分层（2026-10-19
          // 用户口径：再深一点、层级更明显）。
          BoxShadow(
            color: theme.shadowColor.withValues(alpha: 0.38),
            blurRadius: 32,
            spreadRadius: 2,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Material(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: UtenRadius.xxlAll,
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(theme),
            const Divider(height: 1),
            Flexible(child: widget.body),
            if (widget.actions != null) ...[
              const Divider(height: 1),
              widget.actions!,
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    // 拖动/双击复位手势只包标题区——不把右侧按钮圈进来，否则按钮单击要等
    // 双击判定超时才生效（手感迟滞）。
    final dragArea = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) => _beginGesture(),
      onPanUpdate: (details) => setState(() {
        _left += details.delta.dx;
        _top += details.delta.dy;
        _clampPosition();
      }),
      onDoubleTap: () => setState(_centerAtInitial),
      child: MouseRegion(
        cursor: SystemMouseCursors.move,
        child: Padding(
          padding: const EdgeInsets.only(left: UtenSpacing.s16),
          child: Text(
            widget.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s12),
      child: Row(
        children: [
          Expanded(child: dragArea),
          if (widget.headerTrailing != null) widget.headerTrailing!,
          IconButton(
            key: _collapseButtonKey,
            tooltip: '缩小成悬浮球',
            icon: const Icon(Icons.compress_rounded),
            onPressed: _collapseFromButton,
          ),
          Padding(
            padding: const EdgeInsets.only(right: UtenSpacing.s8),
            child: IconButton(
              tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
              icon: const Icon(Icons.close_rounded),
              onPressed: widget.onClose,
            ),
          ),
        ],
      ),
    );
  }

  Widget _edgeHandle({
    required MouseCursor cursor,
    double? left,
    double? top,
    double? right,
    double? bottom,
    double? width,
    double? height,
    required void Function(double dx, double dy) onPanUpdate,
  }) {
    return Positioned(
      left: left,
      top: top,
      bottom: bottom,
      right: right,
      width: width,
      height: height,
      child: MouseRegion(
        cursor: cursor,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) => _beginGesture(),
          onPanUpdate: (details) =>
              onPanUpdate(details.delta.dx, details.delta.dy),
        ),
      ),
    );
  }

  Widget _cornerHandle({
    required MouseCursor cursor,
    double? left,
    double? top,
    double? right,
    double? bottom,
    required void Function(double dx, double dy) onPanUpdate,
  }) {
    return _edgeHandle(
      cursor: cursor,
      left: left,
      top: top,
      right: right,
      bottom: bottom,
      width: _cornerExtent,
      height: _cornerExtent,
      onPanUpdate: onPanUpdate,
    );
  }
}
