import 'package:flutter/material.dart';

import '../../core/l10n/gen/app_localizations.dart';
import '../../core/l10n/gen/app_localizations_zh.dart';
import '../../core/theme/uten_colors.dart';
import '../../core/theme/uten_tokens.dart';

/// In-field disclosure shared by text inputs, dropdowns and pickers.
class UtenFieldHintIcon extends StatefulWidget {
  const UtenFieldHintIcon({
    super.key,
    this.info,
    this.errorMessage,
    this.autofillMessage,
    this.autofilled = false,
  });

  final String? info;
  final String? errorMessage;
  final String? autofillMessage;
  final bool autofilled;

  @override
  State<UtenFieldHintIcon> createState() => _UtenFieldHintIconState();
}

class _UtenFieldHintIconState extends State<UtenFieldHintIcon> {
  final _tooltipKey = GlobalKey<TooltipState>();
  final _focusNode = FocusNode(debugLabel: 'uten-field-hint');

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChanged);
  }

  void _onFocusChanged() {
    if (_focusNode.hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _show());
    } else {
      Tooltip.dismissAllToolTips();
    }
  }

  void _show() {
    if (mounted) _tooltipKey.currentState?.ensureTooltipVisible();
  }

  @override
  void dispose() {
    _focusNode
      ..removeListener(_onFocusChanged)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final autofillMessage =
        widget.autofillMessage ??
        (widget.autofilled
            ? (Localizations.of<AppLocalizations>(context, AppLocalizations) ??
                      AppLocalizationsZh())
                  .fieldAutofilledReview
            : null);
    final messages = <String>{
      if (widget.errorMessage?.isNotEmpty ?? false) widget.errorMessage!,
      if (autofillMessage?.isNotEmpty ?? false) autofillMessage!,
      if (widget.info?.isNotEmpty ?? false) widget.info!,
    };
    if (messages.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final isError = widget.errorMessage?.isNotEmpty ?? false;
    final isWarning = autofillMessage?.isNotEmpty ?? false;
    final message = messages.join('\n\n');
    final color = isError
        ? theme.colorScheme.error
        : isWarning
        ? (theme.brightness == Brightness.dark
              ? UtenColors.warningOnDark
              : UtenColors.warningText)
        : theme.colorScheme.onSurfaceVariant;

    return TextFieldTapRegion(
      child: Tooltip(
        key: _tooltipKey,
        message: message,
        triggerMode: TooltipTriggerMode.tap,
        waitDuration: const Duration(milliseconds: 250),
        showDuration: const Duration(seconds: 10),
        constraints: const BoxConstraints(maxWidth: 480),
        margin: const EdgeInsets.all(UtenSpacing.s12),
        excludeFromSemantics: true,
        child: Semantics(
          button: true,
          liveRegion: isError || isWarning,
          label: message,
          child: ExcludeSemantics(
            child: IconButton(
              focusNode: _focusNode,
              onPressed: _show,
              padding: const EdgeInsets.all(UtenSpacing.s12),
              constraints: const BoxConstraints.tightFor(width: 44, height: 44),
              style: const ButtonStyle(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.standard,
              ),
              icon: Icon(
                isError
                    ? Icons.error_outline
                    : isWarning
                    ? Icons.warning_amber_rounded
                    : Icons.info_outline,
                size: 18,
                color: color,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
