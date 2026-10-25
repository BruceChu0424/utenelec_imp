import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';
import '../../core/ui/action_feedback.dart';
import '../buttons/click_guard.dart';

/// Compact, labelled access to a full record picker. The pending picker owns
/// the button until it closes, including when its host only supplies a Future.
class UtenPickerIconButton extends StatefulWidget {
  const UtenPickerIconButton({
    super.key,
    required this.tooltip,
    this.onPressed,
    this.isLoading = false,
    this.icon = Icons.more_horiz_rounded,
  });

  final String tooltip;
  final Future<void> Function()? onPressed;
  final bool isLoading;
  final IconData icon;

  @override
  State<UtenPickerIconButton> createState() => _UtenPickerIconButtonState();
}

class _UtenPickerIconButtonState extends State<UtenPickerIconButton> {
  final _guard = ClickGuard();

  Future<void> _open() async {
    if (widget.isLoading || widget.onPressed == null) return;
    final action = _guard.run(widget.onPressed!);
    if (action == null) return;
    setState(() {});
    try {
      await action;
    } catch (error) {
      if (mounted) context.appApiError(error);
    } finally {
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = widget.isLoading || _guard.isBusy;
    final extent = UtenControlMetrics.minimumHitExtent(
      context,
      desktop: UtenControlMetrics.cellHeight,
    );
    return IconButton(
      tooltip: widget.tooltip,
      onPressed: busy || widget.onPressed == null ? null : _open,
      constraints: BoxConstraints.tightFor(width: extent, height: extent),
      padding: const EdgeInsets.all(UtenSpacing.s4),
      visualDensity: VisualDensity.standard,
      iconSize: 20,
      icon: busy
          ? TickerMode(
              enabled: ModalRoute.of(context)?.isCurrent ?? true,
              child: const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : Icon(widget.icon),
    );
  }
}
