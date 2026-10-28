import 'package:flutter/material.dart';

import '../../core/theme/uten_anim.dart';
import '../../core/theme/uten_tokens.dart';
import '../feedback/uten_motion.dart';
import '../inputs/uten_field_hint_icon.dart';
import '../layout/uten_collapsible_content.dart';

/// A read-only document summary. Each page chooses its own essential facts;
/// warnings and controls in [notices] never disappear when details are folded.
class UtenDetailSummaryCard extends StatefulWidget {
  const UtenDetailSummaryCard({
    super.key,
    this.heading,
    this.status,
    this.primary = const [],
    this.facts = const [],
    this.details = const [],
    this.notices = const [],
    this.expanded,
    this.onExpandedChanged,
  });

  final Widget? heading;
  final Widget? status;
  final List<Widget> primary;
  final List<Widget> facts;
  final List<Widget> details;
  final List<Widget> notices;
  final bool? expanded;
  final ValueChanged<bool>? onExpandedChanged;

  @override
  State<UtenDetailSummaryCard> createState() => _UtenDetailSummaryCardState();
}

class _UtenDetailSummaryCardState extends State<UtenDetailSummaryCard> {
  bool _expanded = false;
  bool get _isExpanded => widget.expanded ?? _expanded;

  void _toggle() {
    final next = !_isExpanded;
    if (widget.expanded == null) setState(() => _expanded = next);
    widget.onExpandedChanged?.call(next);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final expandable = widget.details.isNotEmpty;
    return UtenMotion(
      duration: UtenAnim.normal,
      builder: (context, duration) => Card(
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.heading != null || widget.status != null || expandable)
                LayoutBuilder(
                  builder: (context, constraints) {
                    final controls = Wrap(
                      spacing: UtenSpacing.s8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      alignment: WrapAlignment.end,
                      children: [
                        if (widget.status != null) widget.status!,
                        if (expandable)
                          Semantics(
                            expanded: _isExpanded,
                            child: TextButton(
                              key: const ValueKey('detail-summary-toggle'),
                              onPressed: _toggle,
                              style: TextButton.styleFrom(
                                textStyle: theme.textTheme.labelLarge,
                                minimumSize: Size.square(
                                  UtenControlMetrics.minimumHitExtent(
                                    context,
                                    desktop: UtenControlMetrics.compactHeight,
                                  ),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: UtenSpacing.s8,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Flexible(
                                    child: Text(
                                      _isExpanded ? '收起信息' : '查看更多',
                                      softWrap: true,
                                    ),
                                  ),
                                  const SizedBox(width: UtenSpacing.s4),
                                  AnimatedRotation(
                                    turns: _isExpanded ? .5 : 0,
                                    duration: duration,
                                    curve: UtenAnim.standard,
                                    child: const Icon(
                                      Icons.keyboard_arrow_down_rounded,
                                      size: 20,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    );
                    final heading = DefaultTextStyle.merge(
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                      child: _SummaryPresentation(
                        inline: true,
                        child: widget.heading ?? const SizedBox.shrink(),
                      ),
                    );
                    if (constraints.maxWidth < 600 ||
                        MediaQuery.textScalerOf(context).scale(14) > 21) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (widget.heading != null) heading,
                          Align(
                            alignment: Alignment.centerRight,
                            child: controls,
                          ),
                        ],
                      );
                    }
                    return Row(
                      children: [
                        Expanded(child: heading),
                        const SizedBox(width: UtenSpacing.s12),
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: constraints.maxWidth * .45,
                          ),
                          child: controls,
                        ),
                      ],
                    );
                  },
                ),
              if (widget.primary.isNotEmpty) ...[
                const SizedBox(height: UtenSpacing.s8),
                UtenSummaryFacts(
                  minFieldWidth: 180,
                  separated: true,
                  inline: false,
                  children: widget.primary,
                ),
              ],
              if (widget.facts.isNotEmpty) ...[
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: UtenSpacing.s8),
                  child: Divider(height: 1),
                ),
                UtenSummaryFacts(inline: true, children: widget.facts),
              ],
              for (final notice in widget.notices) ...[
                const SizedBox(height: UtenSpacing.s8),
                notice,
              ],
              if (expandable)
                UtenCollapsibleContent(
                  expanded: _isExpanded,
                  maintainState: false,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: UtenSpacing.s8),
                        child: Divider(height: 1),
                      ),
                      for (var i = 0; i < widget.details.length; i++) ...[
                        if (i > 0) const SizedBox(height: UtenSpacing.s8),
                        _SummaryPresentation(
                          inline: true,
                          child: widget.details[i],
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Denser facts than the editing form grid, without changing form/table layout.
/// Column count follows the available width and the user's text scale.
class UtenSummaryFacts extends StatelessWidget {
  const UtenSummaryFacts({
    super.key,
    required this.children,
    this.minFieldWidth = defaultMinFieldWidth,
    this.maxColumns = 6,
    this.inline,
    this.separated = false,
  }) : assert(minFieldWidth > 0),
       assert(maxColumns > 0);

  final List<Widget> children;
  final double minFieldWidth;
  final int maxColumns;
  final bool? inline;
  final bool separated;

  static const double defaultMinFieldWidth = 220;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final scaledWidth =
            minFieldWidth *
            (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(1, 3);
        final columns =
            ((width + UtenSpacing.s12) / (scaledWidth + UtenSpacing.s12))
                .floor()
                .clamp(1, maxColumns.clamp(1, children.length));
        final itemWidth = (width - UtenSpacing.s12 * (columns - 1)) / columns;
        return Wrap(
          spacing: UtenSpacing.s12,
          runSpacing: UtenSpacing.s8,
          children: [
            for (var i = 0; i < children.length; i++)
              SizedBox(
                width: itemWidth,
                child: Container(
                  padding: separated && i % columns != 0
                      ? const EdgeInsets.only(left: UtenSpacing.s12)
                      : EdgeInsets.zero,
                  decoration: separated && i % columns != 0
                      ? BoxDecoration(
                          border: Border(
                            left: BorderSide(
                              color: Theme.of(
                                context,
                              ).colorScheme.outlineVariant,
                            ),
                          ),
                        )
                      : null,
                  child: _SummaryPresentation(
                    inline: inline ?? _SummaryPresentation.of(context),
                    child: children[i],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class UtenSummaryField extends StatelessWidget {
  const UtenSummaryField({
    super.key,
    required this.label,
    this.value,
    this.emphasis = false,
    this.danger = false,
    this.selectable = false,
    this.inline,
    this.info,
  });

  final String label;
  final String? value;
  final bool emphasis;
  final bool danger;
  final bool selectable;
  final bool? inline;
  final String? info;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = value?.trim();
    final inline = this.inline ?? _SummaryPresentation.of(context);
    final labelText = Text(
      label,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        fontWeight: FontWeight.w400,
      ),
    );
    final labelWidget = info?.trim().isNotEmpty == true
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(child: labelText),
              UtenFieldHintIcon(info: info, dense: true),
            ],
          )
        : labelText;
    final valueWidget = Text(
      text == null || text.isEmpty ? '—' : text,
      style:
          (emphasis
                  ? (inline
                        ? theme.textTheme.titleMedium
                        : theme.textTheme.titleLarge)
                  : theme.textTheme.bodyMedium)
              ?.copyWith(
                fontWeight: emphasis ? FontWeight.w700 : FontWeight.w500,
                color: danger ? theme.colorScheme.error : null,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
    );
    Widget stacked() => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        labelWidget,
        const SizedBox(height: UtenSpacing.s2),
        valueWidget,
      ],
    );
    final content = inline
        ? LayoutBuilder(
            builder: (context, constraints) {
              // Reuse the fact grid's readable-width role. Splitting a tiny
              // canvas into two columns turns a long exact value vertical.
              final readableWidth =
                  UtenSummaryFacts.defaultMinFieldWidth *
                  (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(1, 3);
              if (constraints.maxWidth < readableWidth) return stacked();
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: constraints.maxWidth * .45,
                    ),
                    child: labelWidget,
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  Expanded(child: valueWidget),
                ],
              );
            },
          )
        : stacked();
    return selectable ? SelectionArea(child: content) : content;
  }
}

class _SummaryPresentation extends InheritedWidget {
  const _SummaryPresentation({required this.inline, required super.child});
  final bool inline;
  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_SummaryPresentation>()
          ?.inline ??
      false;
  @override
  bool updateShouldNotify(_SummaryPresentation oldWidget) =>
      inline != oldWidget.inline;
}
