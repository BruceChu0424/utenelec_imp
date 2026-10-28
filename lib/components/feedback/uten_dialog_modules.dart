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
                builder: (context, bounds) {
                  const leadingExtent = 52.0;
                  const leadingGap = UtenSpacing.s16;
                  const trailingGap = UtenSpacing.s12;
                  final available = bounds.hasBoundedWidth
                      ? bounds.maxWidth
                      : MediaQuery.sizeOf(context).width;
                  final controlExtent = UtenControlMetrics.minimumHitExtent(
                    context,
                  );
                  final trailingExtent = trailing == null
                      ? 24.0
                      : controlExtent;
                  // Decoration never takes the last readable control-width of
                  // text. A single Wrap keeps native controls mounted when the
                  // row flows vertically; it does not duplicate their state.
                  final showLeading =
                      available >=
                      leadingExtent +
                          leadingGap +
                          trailingGap +
                          trailingExtent +
                          controlExtent;
                  final inlineTextWidth =
                      available -
                      (showLeading ? leadingExtent + leadingGap : 0) -
                      trailingExtent -
                      trailingGap;
                  final stacked = inlineTextWidth < controlExtent;
                  return Wrap(
                    runSpacing: UtenSpacing.s8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (showLeading)
                        Padding(
                          padding: const EdgeInsets.only(right: leadingGap),
                          child: Container(
                            width: leadingExtent,
                            height: leadingExtent,
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
                        ),
                      SizedBox(
                        width: stacked ? available : inlineTextWidth,
                        child: Column(
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
                      ),
                      Padding(
                        padding: EdgeInsets.only(
                          left: stacked ? 0 : trailingGap,
                        ),
                        child:
                            trailing ??
                            Icon(
                              Icons.chevron_right_rounded,
                              color: scheme.onSurfaceVariant,
                              size: 24,
                            ),
                      ),
                    ],
                  );
                },
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
