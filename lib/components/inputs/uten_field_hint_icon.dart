import 'package:flutter/material.dart';
import 'dart:math' as math;

import '../../core/l10n/gen/app_localizations.dart';
import '../../core/l10n/gen/app_localizations_zh.dart';
import '../../core/theme/uten_colors.dart';
import '../../core/theme/uten_tokens.dart';
import 'uten_filter_field_theme.dart';
import 'uten_table_cell_hints.dart';
import 'uten_table_cell_spec.dart';

/// In-field disclosure shared by text inputs, dropdowns and pickers.
class UtenFieldHintIcon extends StatefulWidget {
  const UtenFieldHintIcon({
    super.key,
    this.info,
    this.errorMessage,
    this.autofillMessage,
    this.autofilled = false,
    this.dense = false,
    this.compact = false,
  });

  final String? info;
  final String? errorMessage;
  final String? autofillMessage;
  final bool autofilled;

  /// 紧凑态（表格列头用）：命中区 28×28、图标 16。表单里的 44×44 命中区在
  /// 稠密表头里会把列头 Row 顶出 1~2px 溢出（2026-09-11 实测 material_analysis
  /// 等 26 个用例），而列头本身已是 44 高的可点区域，图标只需落在其中。
  final bool dense;

  /// Paired suffix actions share the field height with a narrower inline slot.
  /// This does not change dense table hint registration or the icon itself.
  final bool compact;

  @override
  State<UtenFieldHintIcon> createState() => _UtenFieldHintIconState();
}

class _UtenFieldHintIconState extends State<UtenFieldHintIcon> {
  final _tooltipKey = GlobalKey<TooltipState>();
  final _focusNode = FocusNode(debugLabel: 'uten-field-hint');
  UtenTableCellHintRegistration? _cellHints;

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
    _cellHints?.removeMessage(this);
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
    // Nested tables can live inside a cell; their compact column headers still
    // own visible guidance, even under an outer table's cell scope.
    final cellHints = widget.dense
        ? null
        : UtenTableCellHints.registrationOf(context);
    if (_cellHints != cellHints) {
      _cellHints?.removeMessage(this);
      _cellHints = cellHints;
    }
    final message = messages.join('\n\n');
    if (cellHints != null) {
      cellHints.setMessage(
        this,
        message,
        liveRegion:
            (widget.errorMessage?.isNotEmpty ?? false) ||
            (autofillMessage?.isNotEmpty ?? false),
        error: widget.errorMessage,
        autofill: autofillMessage,
      );
      return const SizedBox.shrink();
    }
    if (messages.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final compact = widget.dense || UtenTableCellInputTheme.contains(context);
    final extent = compact
        ? UtenEditableGridCellSpec.heightOf(context)
        : UtenFilterFieldTheme.contains(context)
        ? UtenFilterRow.heightOf(context)
        : UtenPageField.heightOf(context);
    final isError = widget.errorMessage?.isNotEmpty ?? false;
    final isWarning = autofillMessage?.isNotEmpty ?? false;
    final color = isError
        ? theme.colorScheme.error
        : isWarning
        ? (theme.brightness == Brightness.dark
              ? UtenColors.warningOnDark
              : UtenColors.warningText)
        : theme.colorScheme.onSurfaceVariant;

    // Help can contain several paragraphs. Keep long disclosures inside the
    // visible viewport at large text sizes, and let touch users scroll them.
    final media = MediaQuery.of(context);
    final helpWidth = math.min(440.0, math.max(40.0, media.size.width - 64));
    final helpHeight = math.max(
      48.0,
      math.min(
        420.0,
        (media.size.height - media.viewInsets.vertical - 64) * .65,
      ),
    );
    final helpStyle =
        theme.tooltipTheme.textStyle ??
        theme.textTheme.bodyMedium!.copyWith(
          color: theme.brightness == Brightness.dark
              ? Colors.black
              : Colors.white,
        );
    var scrollHelp = false;
    if (message.length > 100 || '\n'.allMatches(message).length > 4) {
      final painter = TextPainter(
        text: TextSpan(text: message, style: helpStyle),
        textDirection: Directionality.of(context),
        textScaler: media.textScaler,
      )..layout(maxWidth: helpWidth);
      scrollHelp = painter.height > helpHeight;
      painter.dispose();
    }

    return TextFieldTapRegion(
      // WidgetSpan scales its whole child. Apply accessibility scaling to the
      // actual text once, keeping the scroll viewport in logical pixels.
      child: MediaQuery(
        data: scrollHelp
            ? media.copyWith(textScaler: TextScaler.noScaling)
            : media,
        child: Tooltip(
          key: _tooltipKey,
          message: scrollHelp ? null : message,
          richMessage: scrollHelp
              ? WidgetSpan(
                  child: SizedBox(
                    width: helpWidth,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: helpHeight),
                      child: SingleChildScrollView(
                        primary: false,
                        child: Text(
                          message,
                          style: helpStyle,
                          textScaler: media.textScaler,
                        ),
                      ),
                    ),
                  ),
                )
              : null,
          enableTapToDismiss: !scrollHelp,
          triggerMode: TooltipTriggerMode.tap,
          waitDuration: const Duration(milliseconds: 250),
          showDuration: const Duration(seconds: 10),
          constraints: const BoxConstraints(maxWidth: 480),
          margin: const EdgeInsets.all(UtenSpacing.s12),
          excludeFromSemantics: true,
          child: Semantics(
            // InputDecorator already gives suffixIcon its own semantics group.
            // An extra boundary can retain a clipped child outside a viewport.
            button: true,
            onTap: _show,
            liveRegion: isError || isWarning,
            label: message,
            child: ExcludeSemantics(
              child: IconButton(
                focusNode: _focusNode,
                onPressed: _show,
                padding: EdgeInsets.all(
                  widget.dense || widget.compact
                      ? UtenSpacing.s4
                      : UtenSpacing.s8,
                ),
                constraints: BoxConstraints.tightFor(
                  width: widget.compact ? 28 : extent,
                  height: extent,
                ),
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
                  size: widget.dense ? 16 : 18,
                  color: color,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
