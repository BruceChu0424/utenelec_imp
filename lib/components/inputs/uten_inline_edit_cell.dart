import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';

/// A compact editable value that mounts its editor only after activation.
///
/// The editor remains mounted when its preview, row selection or busy state
/// changes. The host owns values, permissions, validation and saving; changing
/// this widget's key deliberately starts a different editing identity.
class UtenInlineEditCell extends StatefulWidget {
  const UtenInlineEditCell({
    super.key,
    required this.semanticLabel,
    required this.preview,
    required this.editorBuilder,
    this.activationKey,
    this.enabled = true,
    this.changed = false,
    this.retainFocusWhenDisabled = false,
    this.requiredEmpty = false,
    this.onActivate,
  });

  final String semanticLabel;
  final Widget preview;
  final WidgetBuilder editorBuilder;
  final Key? activationKey;
  final bool enabled;
  final bool changed;

  /// Text editors may retain focus while their own readOnly flag blocks input.
  /// Other controls keep the default keyboard fence while temporarily frozen.
  final bool retainFocusWhenDisabled;
  final bool requiredEmpty;
  final VoidCallback? onActivate;

  @override
  State<UtenInlineEditCell> createState() => _UtenInlineEditCellState();
}

class _UtenInlineEditCellState extends State<UtenInlineEditCell> {
  bool _activated = false;

  void _activate() {
    if (!widget.enabled || _activated) return;
    setState(() => _activated = true);
    widget.onActivate?.call();
  }

  @override
  Widget build(BuildContext context) {
    if (_activated) {
      return ExcludeFocus(
        excluding: !widget.enabled && !widget.retainFocusWhenDisabled,
        child: IgnorePointer(
          ignoring: !widget.enabled,
          child: widget.editorBuilder(context),
        ),
      );
    }
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: widget.activationKey,
        onTap: widget.enabled ? _activate : null,
        borderRadius: UtenRadius.controlAll,
        child: Semantics(
          button: true,
          enabled: widget.enabled,
          label: widget.semanticLabel,
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(
                color: widget.requiredEmpty
                    ? theme.colorScheme.error
                    : theme.colorScheme.outlineVariant,
                width: widget.requiredEmpty ? 1.5 : 1,
              ),
              borderRadius: UtenRadius.controlAll,
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: UtenSpacing.s8,
              vertical: UtenSpacing.s8,
            ),
            child: widget.preview,
          ),
        ),
      ),
    );
  }
}
