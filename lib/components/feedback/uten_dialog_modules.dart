import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';

/// A label above a dialog field, with room for validation or helper content.
/// The caller owns the input/controller and its business validation.
class UtenDialogField extends StatelessWidget {
  const UtenDialogField({
    super.key,
    required this.label,
    required this.child,
    this.description,
  });

  final Widget label;
  final Widget child;
  final Widget? description;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DefaultTextStyle.merge(
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          child: label,
        ),
        const SizedBox(height: UtenSpacing.s8),
        child,
        if (description != null) ...[
          const SizedBox(height: UtenSpacing.s8),
          DefaultTextStyle.merge(
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            child: description!,
          ),
        ],
      ],
    );
  }
}

/// A full-width setting/action row. Material provides keyboard focus and
/// pointer feedback; the natural height grows with translated or large text.
class UtenDialogSettingTile extends StatelessWidget {
  const UtenDialogSettingTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    required this.onTap,
    this.trailing,
    this.selected = true,
    this.showBorder = true,
    this.canRequestFocus = true,
  });

  final IconData icon;
  final Widget title;
  final Widget? subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;

  /// Settings use the accented outline by default. Choice cards pass their
  /// controlled selection so unselected options keep a neutral outline.
  final bool selected;
  final bool showBorder;

  /// Native radio/switch controls may own keyboard focus for the whole row.
  final bool canRequestFocus;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final tinted = selected || !showBorder;
    final background = tinted
        ? Color.alphaBlend(
            scheme.primary.withValues(alpha: dark ? 0.13 : 0.055),
            scheme.surface,
          )
        : scheme.surface;
    final shape = RoundedRectangleBorder(
      borderRadius: UtenRadius.controlAll,
      side: showBorder
          ? BorderSide(color: selected ? scheme.primary : scheme.outlineVariant)
          : BorderSide.none,
    );
    return MergeSemantics(
      child: Material(
        color: background,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          canRequestFocus: canRequestFocus,
          customBorder: shape,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 84),
            child: Padding(
              padding: const EdgeInsets.all(UtenSpacing.s16),
              child: LayoutBuilder(
                builder: (context, bounds) => _SettingTileContent(
                  availableWidth: bounds.hasBoundedWidth
                      ? bounds.maxWidth
                      : MediaQuery.sizeOf(context).width,
                  minimumTextWidth: UtenControlMetrics.minimumHitExtent(
                    context,
                  ),
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color: scheme.primary.withValues(
                          alpha: dark ? 0.13 : 0.07,
                        ),
                        borderRadius: UtenRadius.controlAll,
                      ),
                      child: Icon(
                        icon,
                        size: 28,
                        color: selected || !showBorder
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        DefaultTextStyle.merge(
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: scheme.onSurface,
                            fontWeight: FontWeight.w700,
                            height: 1.35,
                          ),
                          child: title,
                        ),
                        if (subtitle != null) ...[
                          const SizedBox(height: UtenSpacing.s4),
                          DefaultTextStyle.merge(
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                              height: 1.45,
                            ),
                            child: subtitle!,
                          ),
                        ],
                      ],
                    ),
                    trailing ??
                        Icon(
                          Icons.chevron_right_rounded,
                          color: scheme.onSurfaceVariant,
                          size: 24,
                        ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A single radio choice whose complete card is the interaction target.
/// Selection is owned by the caller so the same module works in any form.
class UtenDialogOptionCard extends StatelessWidget {
  const UtenDialogOptionCard({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final Widget title;
  final Widget? subtitle;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    checked: selected,
    inMutuallyExclusiveGroup: true,
    child: UtenDialogSettingTile(
      icon: icon,
      title: title,
      subtitle: subtitle,
      selected: selected,
      onTap: onTap,
      trailing: Icon(
        selected
            ? Icons.radio_button_checked_rounded
            : Icons.radio_button_unchecked_rounded,
        size: 24,
        color: selected
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.outline,
      ),
    ),
  );
}

/// Measures the real trailing control before assigning the remaining text width.
/// The three child Elements stay mounted when their layout changes at a resize.
class _SettingTileContent extends MultiChildRenderObjectWidget {
  const _SettingTileContent({
    required this.availableWidth,
    required this.minimumTextWidth,
    required super.children,
  });
  final double availableWidth;
  final double minimumTextWidth;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSettingTileContent(this, Directionality.of(context));

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderSettingTileContent renderObject,
  ) => renderObject.configure(this, Directionality.of(context));
}

class _RenderSettingTileContent extends RenderBox
    with
        ContainerRenderObjectMixin<
          RenderBox,
          ContainerBoxParentData<RenderBox>
        >,
        RenderBoxContainerDefaultsMixin<
          RenderBox,
          ContainerBoxParentData<RenderBox>
        > {
  _RenderSettingTileContent(this._config, this._direction);
  _SettingTileContent _config;
  TextDirection _direction;

  void configure(_SettingTileContent config, TextDirection direction) {
    _config = config;
    _direction = direction;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! ContainerBoxParentData<RenderBox>) {
      child.parentData = _SettingTileParentData();
    }
  }

  Size _layout(BoxConstraints limits, {required bool dry}) {
    Size measure(RenderBox child, BoxConstraints box) {
      if (dry) return child.getDryLayout(box);
      child.layout(box, parentUsesSize: true);
      return child.size;
    }

    final leading = firstChild!;
    final body = childAfter(leading)!;
    final trailing = lastChild!;
    final width = limits.constrainWidth(_config.availableWidth);
    final trailingSize = measure(trailing, BoxConstraints(maxWidth: width));
    const leadingExtent = 52.0;
    const leadingGap = UtenSpacing.s16;
    const trailingGap = UtenSpacing.s12;
    final showLeading =
        width >=
        leadingExtent +
            leadingGap +
            trailingGap +
            trailingSize.width +
            _config.minimumTextWidth;
    final leadingWidth = showLeading ? leadingExtent + leadingGap : 0.0;
    final inlineWidth = width - leadingWidth - trailingGap - trailingSize.width;
    final stacked = inlineWidth < _config.minimumTextWidth;
    measure(
      leading,
      BoxConstraints.tight(
        showLeading ? const Size(leadingExtent, leadingExtent) : Size.zero,
      ),
    );
    final bodySize = measure(
      body,
      BoxConstraints.tightFor(
        width: stacked ? width : math.max(0.0, inlineWidth),
      ),
    );
    final contentHeight = stacked
        ? bodySize.height + UtenSpacing.s8 + trailingSize.height
        : math.max(
            showLeading ? leadingExtent : 0.0,
            math.max(bodySize.height, trailingSize.height),
          );
    final result = limits.constrain(Size(width, contentHeight));
    if (!dry) {
      void place(RenderBox child, double x, double y) {
        (child.parentData! as ContainerBoxParentData<RenderBox>).offset =
            Offset(
              _direction == TextDirection.rtl
                  ? result.width - x - child.size.width
                  : x,
              y,
            );
      }

      place(leading, 0, (result.height - leading.size.height) / 2);
      place(
        body,
        stacked ? 0 : leadingWidth,
        stacked ? 0 : (result.height - bodySize.height) / 2,
      );
      place(
        trailing,
        stacked ? 0 : width - trailingSize.width,
        stacked
            ? bodySize.height + UtenSpacing.s8
            : (result.height - trailingSize.height) / 2,
      );
    }
    return result;
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      _layout(constraints, dry: true);
  @override
  void performLayout() => size = _layout(constraints, dry: false);
  @override
  void paint(PaintingContext context, Offset offset) {
    var child = firstChild;
    while (child != null) {
      if (!child.size.isEmpty) {
        final data = child.parentData! as ContainerBoxParentData<RenderBox>;
        context.paintChild(child, offset + data.offset);
      }
      child = childAfter(child);
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

class _SettingTileParentData extends ContainerBoxParentData<RenderBox> {}
