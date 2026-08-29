import 'package:flutter/material.dart';

/// A compact message that discloses its full text only when it really overflows.
///
/// The visible text stays on [maxLines]. When it no longer fits, an anchored
/// help button is appended. Mouse hover, touch/click and keyboard focus all
/// reveal the same full-text tooltip; the button keeps a 44dp hit target even
/// though the visual icon remains small enough for dense ERP forms.
class UtenOverflowMessage extends StatefulWidget {
  const UtenOverflowMessage({
    super.key,
    required this.message,
    this.maxLines = 1,
    this.style,
    this.iconColor,
    this.liveRegion = false,
    this.disclosureLabel = '查看完整提示',
    this.tooltipMaxWidth = 480,
  }) : assert(maxLines > 0),
       assert(tooltipMaxWidth > 0);

  final String message;
  final int maxLines;
  final TextStyle? style;
  final Color? iconColor;

  /// Announces changed error text without moving accessibility focus.
  final bool liveRegion;

  /// Accessible name for the overflow affordance.
  final String disclosureLabel;

  final double tooltipMaxWidth;

  @override
  State<UtenOverflowMessage> createState() => _UtenOverflowMessageState();
}

class _UtenOverflowMessageState extends State<UtenOverflowMessage> {
  final _tooltipKey = GlobalKey<TooltipState>();
  late final FocusNode _disclosureFocus;

  @override
  void initState() {
    super.initState();
    _disclosureFocus = FocusNode(debugLabel: 'uten-overflow-message');
    _disclosureFocus.addListener(_handleFocusChanged);
  }

  @override
  void dispose() {
    _disclosureFocus
      ..removeListener(_handleFocusChanged)
      ..dispose();
    super.dispose();
  }

  void _handleFocusChanged() {
    if (!_disclosureFocus.hasFocus) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _showFullMessage());
  }

  void _showFullMessage() {
    if (!mounted) return;
    _tooltipKey.currentState?.ensureTooltipVisible();
  }

  bool _doesOverflow(
    BuildContext context, {
    required double maxWidth,
    required TextStyle style,
  }) {
    if (!maxWidth.isFinite) return false;
    if (maxWidth <= 0) return widget.message.isNotEmpty;
    final painter = TextPainter(
      text: TextSpan(text: widget.message, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      locale: Localizations.maybeLocaleOf(context),
      maxLines: widget.maxLines,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth);
    final overflow = painter.didExceedMaxLines;
    painter.dispose();
    return overflow;
  }

  Widget _messageText(TextStyle style, {required bool ellipsize}) {
    return Semantics(
      liveRegion: widget.liveRegion,
      label: widget.message,
      child: ExcludeSemantics(
        child: Text(
          widget.message,
          maxLines: widget.maxLines,
          overflow: ellipsize ? TextOverflow.ellipsis : TextOverflow.clip,
          style: style,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final inherited = DefaultTextStyle.of(context).style;
    final style = inherited.merge(widget.style);
    return LayoutBuilder(
      builder: (context, constraints) {
        final overflow = _doesOverflow(
          context,
          maxWidth: constraints.maxWidth,
          style: style,
        );
        if (!overflow) return _messageText(style, ellipsize: false);

        final iconColor =
            widget.iconColor ??
            style.color ??
            Theme.of(context).colorScheme.primary;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Expanded(child: _messageText(style, ellipsize: true)),
            const SizedBox(width: 4),
            Tooltip(
              key: _tooltipKey,
              message: widget.message,
              triggerMode: TooltipTriggerMode.tap,
              waitDuration: const Duration(milliseconds: 250),
              showDuration: const Duration(seconds: 10),
              constraints: BoxConstraints(maxWidth: widget.tooltipMaxWidth),
              excludeFromSemantics: true,
              child: Semantics(
                button: true,
                label: widget.disclosureLabel,
                hint: widget.message,
                child: IconButton(
                  focusNode: _disclosureFocus,
                  onPressed: _showFullMessage,
                  constraints: const BoxConstraints.tightFor(
                    width: 44,
                    height: 44,
                  ),
                  padding: const EdgeInsets.all(12),
                  splashRadius: 22,
                  icon: Icon(
                    Icons.help_outline_rounded,
                    size: 18,
                    color: iconColor,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

enum UtenFieldMessageKind { helper, error }

/// Nullable adapters keep call sites compact while ensuring that every
/// InputDecoration uses the same overflow and accessibility behavior.
Widget? utenFieldHelper(String? message, {int maxLines = 1}) {
  return message == null
      ? null
      : UtenFieldMessage.helper(message, maxLines: maxLines);
}

Widget? utenFieldError(String? message, {int maxLines = 1}) {
  return message == null
      ? null
      : UtenFieldMessage.error(message, maxLines: maxLines);
}

/// Shared [TextFormField.errorBuilder] for validator-generated messages.
Widget utenTextFieldErrorBuilder(BuildContext context, String errorText) {
  return UtenFieldMessage.error(errorText);
}

/// Semantic helper/error text for use with [InputDecoration.helper] and
/// [InputDecoration.error].
class UtenFieldMessage extends StatelessWidget {
  const UtenFieldMessage.helper(this.message, {super.key, this.maxLines = 1})
    : kind = UtenFieldMessageKind.helper;

  const UtenFieldMessage.error(this.message, {super.key, this.maxLines = 1})
    : kind = UtenFieldMessageKind.error;

  final String message;
  final int maxLines;
  final UtenFieldMessageKind kind;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isError = kind == UtenFieldMessageKind.error;
    final themedStyle = isError
        ? theme.inputDecorationTheme.errorStyle
        : theme.inputDecorationTheme.helperStyle;
    final fallback = theme.textTheme.bodySmall ?? const TextStyle(fontSize: 12);
    final semanticColor = isError
        ? theme.colorScheme.error
        : theme.colorScheme.onSurfaceVariant;
    final style = (themedStyle ?? fallback).copyWith(
      color: themedStyle?.color ?? semanticColor,
    );

    return UtenOverflowMessage(
      message: message,
      maxLines: maxLines,
      style: style,
      iconColor: style.color,
      liveRegion: isError,
      disclosureLabel: isError ? '查看完整错误提示' : '查看完整帮助提示',
    );
  }
}
