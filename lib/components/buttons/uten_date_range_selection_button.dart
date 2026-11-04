import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';
import '../feedback/uten_busy_overlay.dart';
import '../feedback/uten_date_range_picker.dart';
import '../inputs/required_field_decoration.dart';
import '../inputs/uten_field_hint_icon.dart';
import '../layout/uten_app_bar_action_scope.dart';
import 'uten_button.dart';
import 'uten_close_button.dart';

/// One entry for a calendar interval, including optional unbounded endpoints.
/// Values stay local to the picker until confirmation; cancellation does not
/// notify the caller. The callback owns its date/time conversion semantics.
class UtenDateRangeSelectionButton extends StatefulWidget {
  const UtenDateRangeSelectionButton({
    super.key,
    required this.onChanged,
    this.from,
    this.to,
    this.firstDate,
    this.lastDate,
    this.allowOpenRange = false,
    this.label,
    this.helpText,
    this.required = false,
    this.errorMessage,
    this.enabled = true,
    this.onClear,
    this.defaultToRecentMonth = true,
    this.buttonKey,
    this.clearButtonKey,
    this.info,
    this.openStartLabel,
    this.openEndLabel,
  });

  final DateTime? from;
  final DateTime? to;
  final DateTime? firstDate;
  final DateTime? lastDate;
  final FutureOr<void> Function(DateTime? from, DateTime? to) onChanged;
  final bool allowOpenRange;
  final String? label;
  final String? helpText;
  final bool required;
  final String? errorMessage;
  final bool enabled;
  final FutureOr<void> Function()? onClear;
  final bool defaultToRecentMonth;
  final Key? buttonKey;
  final Key? clearButtonKey;
  final String? info;
  final String? openStartLabel;
  final String? openEndLabel;

  @override
  State<UtenDateRangeSelectionButton> createState() =>
      _UtenDateRangeSelectionButtonState();
}

class _UtenDateRangeSelectionButtonState
    extends State<UtenDateRangeSelectionButton> {
  bool _picking = false;
  bool _applying = false;

  String _t(String zh, String en, String ko) =>
      switch (Localizations.localeOf(context).languageCode) {
        'en' => en,
        'ko' => ko,
        _ => zh,
      };

  String _date(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  String get _summary => switch ((widget.from, widget.to)) {
    (final DateTime start, final DateTime end) =>
      '${_date(start)} ~ ${_date(end)}',
    (final DateTime start, null) =>
      widget.openEndLabel == null
          ? '${_date(start)} ${_t('起', 'onwards', '이후')}'
          : '${_date(start)} ~ ${widget.openEndLabel}',
    (null, final DateTime end) =>
      widget.openStartLabel == null
          ? '${_t('截至', 'Until', '까지')} ${_date(end)}'
          : '${widget.openStartLabel} ~ ${_date(end)}',
    _ =>
      widget.openStartLabel == null && widget.openEndLabel == null
          ? widget.required
                ? _t('未选择日期', 'No dates selected', '선택한 날짜 없음')
                : _t('全部日期', 'All dates', '전체 날짜')
          : '${widget.openStartLabel ?? _t('不限开始', 'No start', '시작 제한 없음')} ~ '
                '${widget.openEndLabel ?? _t('不限结束', 'No end', '종료 제한 없음')}',
  };

  Future<void> _pick() async {
    if (!widget.enabled || _picking || _applying) return;
    final owner = UtenActionOwnerScope.identityOf(context);
    final onChanged = widget.onChanged;
    setState(() => _picking = true);
    try {
      final result = await showUtenDateRangeSelectionPicker(
        context: context,
        firstDate: widget.firstDate ?? DateTime(2010),
        lastDate: widget.lastDate ?? DateTime(2100),
        initialStart: widget.from,
        initialEnd: widget.to,
        allowOpenRange: widget.allowOpenRange,
        defaultToRecentMonth: widget.defaultToRecentMonth && !widget.required,
        openStartLabel: widget.openStartLabel,
        openEndLabel: widget.openEndLabel,
        helpText: widget.helpText ?? widget.label,
      );
      if (result == null ||
          !mounted ||
          !widget.enabled ||
          owner != UtenActionOwnerScope.identityOf(context)) {
        return;
      }
      await _apply(() => onChanged(result.start, result.end));
    } finally {
      if (mounted) {
        setState(() {
          _picking = false;
          _applying = false;
        });
      }
    }
  }

  Future<void> _apply(FutureOr<void> Function() action) async {
    final pending = action();
    if (pending is Future) {
      if (mounted) setState(() => _applying = true);
      await pending;
    }
  }

  Future<void> _clear() async {
    final action = widget.onClear;
    if (action == null || !widget.enabled || _picking || _applying) return;
    setState(() => _picking = true);
    try {
      await _apply(action);
    } finally {
      if (mounted) {
        setState(() {
          _picking = false;
          _applying = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final choose = _t('选择日期', 'Select dates', '날짜 선택');
    final label = widget.label;
    final text = label == null || label.isEmpty ? choose : '$label：$choose';
    final invalid =
        (widget.errorMessage?.isNotEmpty ?? false) ||
        (widget.required && (widget.from == null || widget.to == null));
    final canClear =
        !widget.required &&
        widget.onClear != null &&
        (widget.from != null || widget.to != null);
    final button = UtenButton(
      key: widget.buttonKey,
      type: canClear || invalid
          ? UtenButtonType.ghost
          : UtenButtonType.secondary,
      icon: Icons.date_range_outlined,
      semanticLabel: '$text，$_summary',
      onPressed: widget.enabled && !_picking && !_applying ? _pick : null,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: requiredLabel(text, theme, required: widget.required),
          ),
          SizedBox(
            height: UtenControlMetrics.standardHeight - UtenSpacing.s16,
            child: UtenFieldHintIcon(
              info: [
                _summary,
                if (widget.info?.isNotEmpty ?? false) widget.info!,
              ].join('\n\n'),
              errorMessage: widget.errorMessage,
              dense: true,
            ),
          ),
        ],
      ),
    );
    return Stack(
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(UtenRadius.control),
            border: invalid || canClear
                ? Border.all(
                    color: invalid
                        ? theme.colorScheme.error
                        : theme.colorScheme.outlineVariant,
                    width: invalid ? 1.5 : 1,
                  )
                : null,
          ),
          child: canClear
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(child: button),
                    UtenCloseButton(
                      key:
                          widget.clearButtonKey ??
                          const Key('uten-date-range-clear'),
                      tooltip: _t('清除日期范围', 'Clear date range', '날짜 범위 지우기'),
                      onPressed: widget.enabled && !_picking && !_applying
                          ? _clear
                          : null,
                    ),
                  ],
                )
              : button,
        ),
        if (_applying)
          UtenBusyOverlay(
            title: _t('正在应用日期', 'Applying dates', '날짜 적용 중'),
            showDoNotLeaveHint: false,
          ),
      ],
    );
  }
}
