import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import '../layout/uten_app_bar_action_scope.dart';
import '../layout/uten_app_bar_action_feedback.dart';
import '../feedback/uten_dialog_action_scope.dart';

import '../../core/theme/uten_colors.dart';
import '../../core/theme/uten_tokens.dart';
import '../../core/responsive/scale.dart';
import '../../core/responsive/compact_presentation.dart';

/// The shared Uten action button.
///
/// Uses Material interaction primitives so pointer, keyboard, focus, ripple,
/// and accessibility behavior stay consistent across supported platforms.
class UtenButton extends StatelessWidget {
  const UtenButton({
    super.key,
    this.onPressed,
    required this.child,
    this.type = UtenButtonType.primary,
    this.size = UtenButtonSize.medium,
    this.isLoading = false,
    this.isExpanded = false,
    this.icon,
    this.onLongPress,
    this.onDisabledTap,
    this.height,
    this.compactIcon,
    this.compactLabel,
    this.semanticLabel,
    this.closeBeforeAction = false,
  });

  final FutureOr<void> Function()? onPressed;
  final Widget child;
  final UtenButtonType type;
  final UtenButtonSize size;
  final bool isLoading;
  final bool isExpanded;
  final IconData? icon;
  final VoidCallback? onLongPress;

  /// Aligns a compact control with its toolbar. Touch targets retain their
  /// minimum extent even when the visual desktop height is overridden.
  final double? height;

  /// Opt-in presentation for familiar auxiliary actions on narrow windows.
  /// Menus and medium/large windows retain the full original child and icon.
  final IconData? compactIcon;
  final String? compactLabel;
  final String? semanticLabel;

  /// Navigation actions release a transient menu before moving its controls.
  final bool closeBeforeAction;

  /// Called when the visually disabled button is tapped.
  ///
  /// This is useful for explaining why an action is unavailable. When omitted,
  /// a disabled or loading button remains non-interactive.
  final VoidCallback? onDisabledTap;

  UtenButtonSize get _visualSize =>
      size == UtenButtonSize.large &&
          height != null &&
          height! <= UtenControlMetrics.standardHeight
      ? UtenButtonSize.medium
      : size;

  double get _minimumExtent => switch (_visualSize) {
    UtenButtonSize.small => UtenControlMetrics.compactHeight,
    UtenButtonSize.medium => UtenControlMetrics.standardHeight,
    UtenButtonSize.large => UtenControlMetrics.primaryHeight,
  };

  EdgeInsetsGeometry get _padding => switch (_visualSize) {
    UtenButtonSize.small => const EdgeInsets.symmetric(
      horizontal: 12,
      vertical: 8,
    ),
    UtenButtonSize.medium => const EdgeInsets.symmetric(
      horizontal: 16,
      vertical: 8,
    ),
    UtenButtonSize.large => const EdgeInsets.symmetric(
      horizontal: 20,
      vertical: 8,
    ),
  };

  double get _iconSize => switch (_visualSize) {
    UtenButtonSize.small => 16,
    UtenButtonSize.medium => 18,
    UtenButtonSize.large => 20,
  };

  TextStyle get _textStyle => TextStyle(
    fontSize: switch (_visualSize) {
      UtenButtonSize.small => 14,
      UtenButtonSize.medium => 14,
      UtenButtonSize.large => 16,
    },
    fontWeight: FontWeight.w600,
    height: 1.2,
  );

  @override
  Widget build(BuildContext context) {
    if (UtenAppBarActionPresentation.contains(context)) {
      return UtenAppBarActionFeedback(
        onPressed: onPressed,
        onLongPress: onLongPress,
        isLoading: isLoading,
        builder: (context, busy, press, longPress) => _buildButton(
          context,
          loading: busy,
          press: press,
          longPress: longPress,
        ),
      );
    }
    return _buildButton(
      context,
      loading: isLoading,
      press: onPressed,
      longPress: onLongPress,
    );
  }

  Widget _buildButton(
    BuildContext context, {
    required bool loading,
    required FutureOr<void> Function()? press,
    required FutureOr<void> Function()? longPress,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final inMenu = UtenMenuActionPresentation.contains(context);
    final compact = UtenCompactPresentation.of(context);
    final inAppBar = UtenAppBarActionPresentation.contains(context);
    final inDialog = UtenDialogActionScope.contains(context);
    final enabled = press != null && !loading;
    final effectiveOnTap = enabled
        ? closeBeforeAction
              ? UtenAppBarActionScope.wrapBefore(context, press)
              : UtenAppBarActionScope.wrap(context, press)
        : loading && inAppBar
        ? null
        : onDisabledTap;
    final effectiveLongPress = enabled
        ? UtenAppBarActionScope.wrap(context, longPress)
        : null;
    final (enabledBackground, enabledForeground, enabledBorder) = inMenu
        ? (
            colorScheme.surface,
            type == UtenButtonType.danger
                ? colorScheme.error
                : colorScheme.onSurface,
            null,
          )
        : _resolveColors(colorScheme, inAppBar: inAppBar, inDialog: inDialog);

    // 禁用态刻意比 M3 默认（12% 底 + 38% 字）浓：默认那套在浅色底上几乎透明，
    // 用户在物料分析/下达采购等页反馈「不选的时候根本不知道这里可以点」。
    // 现在是「实底 + 描边 + 可读灰字」——看得见是个按钮，也看得出现在不可用。
    // 描边对所有类型都给（含本来无边的实心型），禁用态才有清晰边界。
    final background = enabled
        ? enabledBackground
        : colorScheme.surfaceContainerHigh;
    final foreground = enabled
        ? enabledForeground
        : colorScheme.onSurfaceVariant.withValues(alpha: 0.75);
    final border = enabled ? enabledBorder : colorScheme.outline;
    final radius = BorderRadius.circular(UtenRadius.control);
    final minimumWidth = UtenControlMetrics.minimumHitExtent(
      context,
      desktop: context.scaled(
        inAppBar ? UtenFilterRow.minHeight : _minimumExtent,
      ),
    );
    final minimumHeight = UtenControlMetrics.minimumHitExtent(
      context,
      desktop: context.scaled(
        inAppBar
            ? UtenFilterRow.minHeight
            : (height ??
                  (inDialog
                      ? UtenControlMetrics.primaryHeight
                      : _minimumExtent)),
      ),
    );
    final iconSize = context.scaled(compact ? 18 : _iconSize);
    final shape = RoundedRectangleBorder(
      borderRadius: radius,
      side: border == null ? BorderSide.none : BorderSide(color: border),
    );
    final content = inAppBar
        ? UtenAppBarActionProgress(
            isLoading: loading,
            child: child is Flexible ? (child as Flexible).child : child,
          )
        : child;

    if (compact && !inDialog) {
      final iconOnly =
          compactIcon != null &&
          !inMenu &&
          UtenCompactPresentation.auxiliaryIconsOf(context);
      final abbreviated = compactLabel != null && !inMenu;
      final description =
          semanticLabel ?? (child is Text ? (child as Text).data : null);
      final visualHeight =
          (inDialog || size == UtenButtonSize.large && height == null) &&
              !inMenu &&
              !inAppBar
          ? 40.0
          : 36.0;
      final label = DefaultTextStyle.merge(
        style: _textStyle.copyWith(fontSize: 13, color: foreground),
        child: iconOnly
            ? loading
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: foreground,
                      ),
                    )
                  : Icon(compactIcon, size: 18, color: foreground)
            : inAppBar && !abbreviated
            ? content
            : _content(
                context: context,
                foreground: foreground,
                iconSize: 16,
                inAppBar: false,
                labelOverride: abbreviated
                    ? ExcludeSemantics(child: Text(compactLabel!))
                    : null,
              ),
      );
      Widget compactButton = MergeSemantics(
        child: Semantics(
          button: true,
          enabled: enabled,
          label: iconOnly || abbreviated ? description : null,
          onTap: effectiveOnTap,
          onLongPress: effectiveLongPress,
          child: Focus(
            canRequestFocus: effectiveOnTap != null,
            onKeyEvent: (_, event) {
              if (effectiveOnTap != null &&
                  event is KeyDownEvent &&
                  (event.logicalKey == LogicalKeyboardKey.enter ||
                      event.logicalKey == LogicalKeyboardKey.space)) {
                effectiveOnTap();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: Builder(
              builder: (context) => Listener(
                onPointerDown: effectiveOnTap == null
                    ? null
                    : (_) => Focus.of(context).requestFocus(),
                child: GestureDetector(
                  excludeFromSemantics: true,
                  behavior: HitTestBehavior.opaque,
                  onTap: enabled ? null : effectiveOnTap,
                  onLongPress: !enabled && effectiveOnTap != null
                      ? _ignoreLongPress
                      : null,
                  child: _CompactHitTarget(
                    minimumExtent: UtenControlMetrics.minimumHitExtent(context),
                    expandWidth: isExpanded || inMenu,
                    child: ExcludeFocus(
                      child: RawMaterialButton(
                        onPressed: enabled ? effectiveOnTap : null,
                        onLongPress: enabled ? effectiveLongPress : null,
                        fillColor: background,
                        shape:
                            Focus.of(context).hasFocus &&
                                FocusManager.instance.highlightMode ==
                                    FocusHighlightMode.traditional
                            ? RoundedRectangleBorder(
                                borderRadius: radius,
                                side: BorderSide(
                                  color: colorScheme.onSurface,
                                  width: 2,
                                ),
                              )
                            : shape,
                        elevation: 0,
                        focusElevation: 0,
                        hoverElevation: 0,
                        highlightElevation: 0,
                        materialTapTargetSize: MaterialTapTargetSize.padded,
                        constraints: BoxConstraints(
                          minWidth: 36,
                          minHeight: visualHeight,
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: inMenu
                            ? Align(
                                alignment: AlignmentDirectional.centerStart,
                                heightFactor: 1,
                                child: label,
                              )
                            : label,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      if (isExpanded && !inMenu) {
        compactButton = SizedBox(width: double.infinity, child: compactButton);
      }
      if ((iconOnly || abbreviated) && description != null) {
        compactButton = Tooltip(
          message: description,
          excludeFromSemantics: true,
          child: compactButton,
        );
      }
      return compactButton;
    }

    Widget button = MergeSemantics(
      child: Semantics(
        button: true,
        enabled: enabled,
        onTap: effectiveOnTap,
        onLongPress: effectiveLongPress,
        child: Material(
          color: background,
          elevation: inDialog && enabled && type == UtenButtonType.primary
              ? 1
              : 0,
          shadowColor: colorScheme.primary.withValues(alpha: 0.18),
          shape: shape,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: effectiveOnTap,
            onLongPress: enabled
                ? effectiveLongPress
                : effectiveOnTap == null
                ? null
                : _ignoreLongPress,
            canRequestFocus: effectiveOnTap != null,
            excludeFromSemantics: true,
            customBorder: shape,
            overlayColor: WidgetStateProperty.resolveWith(
              (states) => _resolveStateLayer(
                states: states,
                foreground: foreground,
                enabled: enabled,
                interactive: effectiveOnTap != null,
              ),
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: minimumWidth,
                minHeight: minimumHeight,
              ),
              child: Padding(
                padding: inAppBar
                    ? const EdgeInsets.symmetric(horizontal: 12, vertical: 8)
                    : inDialog
                    ? const EdgeInsets.symmetric(horizontal: 20, vertical: 12)
                    : compact
                    ? const EdgeInsets.symmetric(horizontal: 12, vertical: 6)
                    : _padding,
                child: DefaultTextStyle.merge(
                  style:
                      (inAppBar
                              ? const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  height: 1.2,
                                )
                              : inDialog
                              ? _textStyle.copyWith(fontSize: compact ? 13 : 14)
                              : compact
                              ? _textStyle.copyWith(fontSize: 14)
                              : _textStyle)
                          .copyWith(color: foreground),
                  child: inAppBar
                      ? content
                      : inMenu
                      ? Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: _content(
                            context: context,
                            foreground: foreground,
                            iconSize: iconSize,
                            inAppBar: false,
                          ),
                        )
                      : _content(
                          context: context,
                          foreground: foreground,
                          iconSize: iconSize,
                          inAppBar: inAppBar,
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    if (isExpanded && !inMenu) {
      button = SizedBox(width: double.infinity, child: button);
    }
    return button;
  }

  Widget _content({
    required BuildContext context,
    required Color foreground,
    required double iconSize,
    required bool inAppBar,
    Widget? labelOverride,
  }) {
    final leading = isLoading
        ? ExcludeSemantics(
            child: SizedBox(
              width: iconSize,
              height: iconSize,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: foreground,
              ),
            ),
          )
        : icon != null && !inAppBar
        ? Icon(icon, size: iconSize, color: foreground)
        : null;
    final gap = isLoading ? UtenSpacing.s8 : UtenSpacing.s6;
    final label =
        labelOverride ??
        (child is Flexible ? (child as Flexible).child : child);
    if (leading == null) {
      return Align(widthFactor: 1, heightFactor: 1, child: label);
    }
    return _UtenButtonContent(
      gap: gap,
      textDirection: Directionality.of(context),
      leading: FittedBox(fit: BoxFit.scaleDown, child: leading),
      label: label,
    );
  }

  (Color, Color, Color?) _resolveColors(
    ColorScheme colorScheme, {
    bool inAppBar = false,
    bool inDialog = false,
  }) {
    return switch (inAppBar
        ? UtenButtonType.primary
        : inDialog && type == UtenButtonType.ghost
        ? UtenButtonType.secondary
        : type) {
      UtenButtonType.primary => (
        colorScheme.primary,
        colorScheme.onPrimary,
        null,
      ),
      UtenButtonType.secondary => (
        inDialog
            ? colorScheme.surfaceContainerLow
            : colorScheme.surfaceContainerHigh,
        colorScheme.onSurface,
        // 2026-09-15 用户口径：普通动作按钮（取消/返回/进度追踪这类 secondary）
        // 全站统一带边框——与悬浮组按钮同语言，实底按钮不再「裸」在页面上。
        inDialog ? colorScheme.outlineVariant : colorScheme.outline,
      ),
      UtenButtonType.tonal => (
        colorScheme.primaryContainer,
        colorScheme.onPrimaryContainer,
        null,
      ),
      UtenButtonType.ghost => (
        Colors.transparent,
        colorScheme.onSurface,
        colorScheme.outline,
      ),
      UtenButtonType.success => (UtenColors.deepGreen, Colors.white, null),
      UtenButtonType.danger => (colorScheme.error, colorScheme.onError, null),
    };
  }

  void _ignoreLongPress() {}

  Color? _resolveStateLayer({
    required Set<WidgetState> states,
    required Color foreground,
    required bool enabled,
    required bool interactive,
  }) {
    if (!interactive) return null;

    final disabledFactor = enabled ? 1.0 : 0.67;
    if (states.contains(WidgetState.pressed)) {
      return foreground.withValues(alpha: 0.12 * disabledFactor);
    }
    if (states.contains(WidgetState.focused)) {
      return foreground.withValues(alpha: 0.12 * disabledFactor);
    }
    if (states.contains(WidgetState.hovered)) {
      return foreground.withValues(alpha: 0.08 * disabledFactor);
    }
    return null;
  }
}

/// Keep normal-width labels beside the leading, with the same wrapping width
/// as a flexible Row. Only move below it when even the label's minimum natural
/// width cannot fit. A render layout preserves intrinsic sizing in dialogs.
class _UtenButtonContent extends MultiChildRenderObjectWidget {
  _UtenButtonContent({
    required Widget leading,
    required Widget label,
    required this.gap,
    required this.textDirection,
  }) : super(children: [leading, label]);

  final double gap;
  final TextDirection textDirection;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderUtenButtonContent(gap, textDirection);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderUtenButtonContent renderObject,
  ) {
    renderObject
      ..gap = gap
      ..textDirection = textDirection;
  }
}

typedef _ButtonContentGeometry = ({
  Size size,
  Offset leadingOffset,
  Offset labelOffset,
  BoxConstraints labelConstraints,
});

class _UtenButtonContentParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderUtenButtonContent extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _UtenButtonContentParentData>,
        RenderBoxContainerDefaultsMixin<
          RenderBox,
          _UtenButtonContentParentData
        > {
  _RenderUtenButtonContent(this._gap, this._textDirection);

  double _gap;
  set gap(double value) {
    if (value == _gap) return;
    _gap = value;
    markNeedsLayout();
  }

  TextDirection _textDirection;
  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _UtenButtonContentParentData) {
      child.parentData = _UtenButtonContentParentData();
    }
  }

  _ButtonContentGeometry _layoutContent(
    BoxConstraints constraints,
    Size Function(RenderBox, BoxConstraints) layout,
  ) {
    final leading = firstChild!;
    final label = lastChild!;
    final leadingSize = layout(
      leading,
      BoxConstraints(maxWidth: constraints.maxWidth),
    );
    final horizontal =
        leadingSize.width +
            _gap +
            label.getMinIntrinsicWidth(double.infinity) <=
        constraints.maxWidth;
    final labelConstraints = BoxConstraints(
      maxWidth: horizontal
          ? math.max(0.0, constraints.maxWidth - leadingSize.width - _gap)
          : constraints.maxWidth,
    );
    final labelSize = layout(label, labelConstraints);
    final contentSize = horizontal
        ? Size(
            leadingSize.width + _gap + labelSize.width,
            math.max(leadingSize.height, labelSize.height),
          )
        : Size(
            math.max(leadingSize.width, labelSize.width),
            leadingSize.height + _gap + labelSize.height,
          );
    final size = constraints.constrain(contentSize);
    final start = (size.width - contentSize.width) / 2;
    final top = (size.height - contentSize.height) / 2;
    return (
      size: size,
      leadingOffset: horizontal
          ? Offset(
              start +
                  (_textDirection == TextDirection.rtl
                      ? labelSize.width + _gap
                      : 0),
              (size.height - leadingSize.height) / 2,
            )
          : Offset((size.width - leadingSize.width) / 2, top),
      labelOffset: horizontal
          ? Offset(
              start +
                  (_textDirection == TextDirection.ltr
                      ? leadingSize.width + _gap
                      : 0),
              (size.height - labelSize.height) / 2,
            )
          : Offset(
              (size.width - labelSize.width) / 2,
              top + leadingSize.height + _gap,
            ),
      labelConstraints: labelConstraints,
    );
  }

  @override
  void performLayout() {
    final geometry = _layoutContent(constraints, (child, limits) {
      child.layout(limits, parentUsesSize: true);
      return child.size;
    });
    size = geometry.size;
    (firstChild!.parentData! as _UtenButtonContentParentData).offset =
        geometry.leadingOffset;
    (lastChild!.parentData! as _UtenButtonContentParentData).offset =
        geometry.labelOffset;
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) => _layoutContent(
    constraints,
    (child, limits) => child.getDryLayout(limits),
  ).size;

  @override
  double computeMinIntrinsicWidth(double height) => math.max(
    firstChild!.getMinIntrinsicWidth(height),
    lastChild!.getMinIntrinsicWidth(height),
  );

  @override
  double computeMaxIntrinsicWidth(double height) =>
      firstChild!.getMaxIntrinsicWidth(height) +
      _gap +
      lastChild!.getMaxIntrinsicWidth(height);

  @override
  double computeMinIntrinsicHeight(double width) =>
      computeDryLayout(BoxConstraints(maxWidth: width)).height;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      computeDryLayout(BoxConstraints(maxWidth: width)).height;

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) {
    final label = lastChild!;
    final distance = label.getDistanceToBaseline(baseline, onlyReal: true);
    final data = label.parentData! as _UtenButtonContentParentData;
    return distance == null ? null : data.offset.dy + distance;
  }

  @override
  double? computeDryBaseline(
    BoxConstraints constraints,
    TextBaseline baseline,
  ) {
    final geometry = _layoutContent(
      constraints,
      (child, limits) => child.getDryLayout(limits),
    );
    final distance = lastChild!.getDryBaseline(
      geometry.labelConstraints,
      baseline,
    );
    return distance == null ? null : geometry.labelOffset.dy + distance;
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);
}

/// Paint compact controls naturally while retaining the window-sized target
/// when application zoom is below 100%. The hit padding adds no visible fill.
class _CompactHitTarget extends SingleChildRenderObjectWidget {
  const _CompactHitTarget({
    required this.minimumExtent,
    required this.expandWidth,
    required super.child,
  });
  final double minimumExtent;
  final bool expandWidth;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _CompactHitBox(minimumExtent, expandWidth);
  @override
  void updateRenderObject(BuildContext context, _CompactHitBox renderObject) {
    renderObject.minimumExtent = minimumExtent;
    renderObject.expandWidth = expandWidth;
  }
}

class _CompactHitBox extends RenderShiftedBox {
  _CompactHitBox(this._minimumExtent, this._expandWidth) : super(null);
  double _minimumExtent;
  bool _expandWidth;
  set minimumExtent(double value) {
    if (_minimumExtent == value) return;
    _minimumExtent = value;
    markNeedsLayout();
  }

  set expandWidth(bool value) {
    if (_expandWidth == value) return;
    _expandWidth = value;
    markNeedsLayout();
  }

  BoxConstraints _childConstraints(BoxConstraints limits) =>
      _expandWidth && limits.hasBoundedWidth
      ? BoxConstraints(
          minWidth: limits.maxWidth,
          maxWidth: limits.maxWidth,
          maxHeight: limits.maxHeight,
        )
      : limits.loosen();
  Size _sizeFor(BoxConstraints limits, Size childSize) => limits.constrain(
    Size(
      math.max(_minimumExtent, childSize.width),
      math.max(_minimumExtent, childSize.height),
    ),
  );
  @override
  Size computeDryLayout(BoxConstraints constraints) => _sizeFor(
    constraints,
    child?.getDryLayout(_childConstraints(constraints)) ?? Size.zero,
  );
  @override
  double computeMinIntrinsicWidth(double height) =>
      math.max(_minimumExtent, child?.getMinIntrinsicWidth(height) ?? 0);
  @override
  double computeMaxIntrinsicWidth(double height) =>
      math.max(_minimumExtent, child?.getMaxIntrinsicWidth(height) ?? 0);
  @override
  double computeMinIntrinsicHeight(double width) =>
      math.max(_minimumExtent, child?.getMinIntrinsicHeight(width) ?? 0);
  @override
  double computeMaxIntrinsicHeight(double width) =>
      math.max(_minimumExtent, child?.getMaxIntrinsicHeight(width) ?? 0);
  @override
  void performLayout() {
    child?.layout(_childConstraints(constraints), parentUsesSize: true);
    size = _sizeFor(constraints, child?.size ?? Size.zero);
    if (child case final child?) {
      (child.parentData! as BoxParentData).offset = Offset(
        (size.width - child.size.width) / 2,
        (size.height - child.size.height) / 2,
      );
    }
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    final child = this.child;
    if (child == null || !size.contains(position) || child.size.isEmpty) {
      return false;
    }
    final offset = (child.parentData! as BoxParentData).offset;
    final local = position - offset;
    final target = Offset(
      local.dx.clamp(0.0, child.size.width - .001),
      local.dy.clamp(0.0, child.size.height - .001),
    );
    return result.addWithPaintOffset(
      offset: position - target,
      position: position,
      hitTest: (result, transformed) =>
          child.hitTest(result, position: transformed),
    );
  }
}

enum UtenButtonType { primary, secondary, tonal, ghost, success, danger }

enum UtenButtonSize { small, medium, large }
