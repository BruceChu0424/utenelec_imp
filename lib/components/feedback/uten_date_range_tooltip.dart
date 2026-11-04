import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';

/// The date control itself discloses its dates, without an extra hint icon.
/// Hover is immediate; keyboard focus and touch long press expose the same text.
class UtenDateRangeTooltip extends StatefulWidget {
  const UtenDateRangeTooltip({
    super.key,
    required this.message,
    required this.child,
  });

  final String message;
  final Widget child;

  @override
  State<UtenDateRangeTooltip> createState() => _UtenDateRangeTooltipState();
}

class _UtenDateRangeTooltipState extends State<UtenDateRangeTooltip> {
  final _tooltipKey = GlobalKey<TooltipState>();
  bool _focused = false;

  void _focusChanged(bool focused) {
    _focused = focused;
    if (!focused) {
      Tooltip.dismissAllToolTips();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _focused) {
        _tooltipKey.currentState?.ensureTooltipVisible();
      }
    });
  }

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    onFocusChange: _focusChanged,
    child: Tooltip(
      key: _tooltipKey,
      message: widget.message,
      waitDuration: Duration.zero,
      showDuration: const Duration(seconds: 10),
      constraints: const BoxConstraints(maxWidth: 480),
      margin: const EdgeInsets.all(UtenSpacing.s12),
      child: widget.child,
    ),
  );
}
