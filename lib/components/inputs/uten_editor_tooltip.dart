import 'package:flutter/material.dart';

/// Preserves a live editor when TooltipVisibility or an empty message removes
/// Flutter's tooltip wrappers. A local ValueKey cannot retain that subtree
/// across reparenting; the stable content boundary keeps its input client.
class UtenEditorTooltip extends StatefulWidget {
  const UtenEditorTooltip({
    super.key,
    required this.message,
    required this.child,
  });

  final String? message;
  final Widget child;

  @override
  State<UtenEditorTooltip> createState() => _UtenEditorTooltipState();
}

class _UtenEditorTooltipState extends State<UtenEditorTooltip> {
  final _contentKey = GlobalKey();

  @override
  Widget build(BuildContext context) => Tooltip(
    message: widget.message,
    child: KeyedSubtree(key: _contentKey, child: widget.child),
  );
}
