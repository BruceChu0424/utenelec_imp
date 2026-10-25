// 全站统一的日期范围选择弹窗。
//
// Material 自带区间选择器把关闭按钮钉死在头部左上、铅笔与「应用」钉在右上，
// 布局不可通过主题调整；这里自绘紧凑弹窗（内容自适应高度，最大 520 宽）：
// UtenRadius.dialog 圆角、右上角关闭、右下角「确定」主按钮。
// 口径出自 admin 审计日志（2026-09-28 用户口径），2026-10-24 推广为全站
// 唯一形态：所有日期范围选择都走本函数，不再各自内联 builder。
import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';
import '../buttons/uten_button.dart';

/// [wrap] 供调用方叠加自己的包装（如 trackNativeReadDialog 的只读门禁），
/// 作用在弹窗内容之外、居中约束之内。返回值与 showDateRangePicker 一致：
/// 取消返回 null；起止值归一化为本地 date-only，壁钟转换由调用方按各自
/// 口径处理。
Future<DateTimeRange?> showUtenDateRangePicker({
  required BuildContext context,
  required DateTime firstDate,
  required DateTime lastDate,
  DateTimeRange? initialDateRange,
  String? helpText,
  Widget Function(BuildContext context, Widget child)? wrap,
}) {
  return showDialog<DateTimeRange>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      Widget dialog = UtenDateRangePickerDialog(
        firstDate: firstDate,
        lastDate: lastDate,
        initialDateRange: initialDateRange,
        helpText: helpText,
      );
      if (wrap != null) dialog = wrap(dialogContext, dialog);
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: dialog,
          ),
        ),
      );
    },
  );
}

/// 区间选择的交互语义与 Material 一致：首击定起点；再击不早于起点则定
/// 终点（同日即单日区间），早于起点则重设起点；按住拖拽实时扩展区间。
class UtenDateRangePickerDialog extends StatefulWidget {
  const UtenDateRangePickerDialog({
    super.key,
    required this.firstDate,
    required this.lastDate,
    this.initialDateRange,
    this.helpText,
  });

  final DateTime firstDate;
  final DateTime lastDate;

  /// 打开时预选的区间；入参允许带时刻，内部归一化为本地 date-only。
  final DateTimeRange? initialDateRange;
  final String? helpText;

  @override
  State<UtenDateRangePickerDialog> createState() =>
      _UtenDateRangePickerDialogState();
}

class _UtenDateRangePickerDialogState extends State<UtenDateRangePickerDialog> {
  static const double _cellHeight = 40;

  /// 网格固定 6 行，月与月之间行数不同也不跳动。
  static const int _rowCount = 6;

  final GlobalKey _gridKey = GlobalKey();

  late final DateTime _firstDate;
  late final DateTime _lastDate;
  late final DateTime _today;

  DateTime? _startDate;
  DateTime? _endDate;

  /// 当前展示月（该月 1 日，本地 date-only）。
  late DateTime _displayedMonth;

  /// 拖拽锚点：按下那天的日期，拖拽期间固定不动。
  DateTime? _dragAnchor;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _today = DateTime(now.year, now.month, now.day);
    _firstDate = _dateOnly(widget.firstDate);
    _lastDate = _dateOnly(widget.lastDate);
    final initial = widget.initialDateRange;
    if (initial != null) {
      final start = _dateOnly(initial.start);
      final end = _dateOnly(initial.end);
      if (!end.isBefore(start)) {
        _startDate = start;
        _endDate = end;
      } else {
        _startDate = end;
        _endDate = start;
      }
    }
    final anchor =
        _startDate ??
        (_today.isBefore(_firstDate)
            ? _firstDate
            : (_today.isAfter(_lastDate) ? _lastDate : _today));
    _displayedMonth = DateTime(anchor.year, anchor.month);
  }

  static DateTime _dateOnly(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  static bool _sameDay(DateTime? a, DateTime? b) {
    if (a == null || b == null) return false;
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  String _t(BuildContext context, String zh, String en, String ko) =>
      switch (Localizations.localeOf(context).languageCode) {
        'en' => en,
        'ko' => ko,
        _ => zh,
      };

  bool _isSelectable(DateTime day) =>
      !day.isBefore(_firstDate) && !day.isAfter(_lastDate);

  int get _daysInMonth =>
      DateTime(_displayedMonth.year, _displayedMonth.month + 1, 0).day;

  /// 展示月 1 日之前需要补的空格数（按周首列对齐）。
  int get _leadingBlanks {
    final firstDow = MaterialLocalizations.of(context).firstDayOfWeekIndex;
    final sundayBased = _displayedMonth.weekday % 7;
    return (sundayBased - firstDow) % 7;
  }

  bool get _canGoPrev =>
      _displayedMonth.isAfter(DateTime(_firstDate.year, _firstDate.month));

  bool get _canGoNext =>
      _displayedMonth.isBefore(DateTime(_lastDate.year, _lastDate.month));

  void _shiftMonth(int months) {
    setState(() {
      _displayedMonth = DateTime(
        _displayedMonth.year,
        _displayedMonth.month + months,
      );
    });
  }

  void _selectOnDown(DateTime day) {
    setState(() {
      if (_startDate == null || _endDate != null) {
        _startDate = day;
        _endDate = null;
      } else if (day.isBefore(_startDate!)) {
        _startDate = day;
      } else {
        _endDate = day;
      }
      _dragAnchor = day;
    });
  }

  void _extendOnDrag(DateTime day) {
    final anchor = _dragAnchor;
    if (anchor == null || _sameDay(day, anchor)) return;
    setState(() {
      if (!day.isBefore(anchor)) {
        _startDate = anchor;
        _endDate = day;
      } else {
        _startDate = day;
        _endDate = anchor;
      }
    });
  }

  /// 换算指针落在哪个日期上；按住拖动时事件都路由到网格这一个 Listener，
  /// 由坐标直接换算行列，格子自身不参与手势竞技。
  void _handlePointer(PointerEvent event) {
    if (!mounted) return;
    final box = _gridKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final local = box.globalToLocal(event.position);
    final cellWidth = box.size.width / 7;
    final col = (local.dx ~/ cellWidth).clamp(0, 6);
    final row = (local.dy ~/ _cellHeight).clamp(0, _rowCount - 1);
    final dayNumber = row * 7 + col + 1 - _leadingBlanks;
    if (dayNumber < 1 || dayNumber > _daysInMonth) return;
    final day = DateTime(
      _displayedMonth.year,
      _displayedMonth.month,
      dayNumber,
    );
    if (!_isSelectable(day)) return;
    if (event is PointerDownEvent) {
      _selectOnDown(day);
    } else if (event is PointerMoveEvent) {
      _extendOnDrag(day);
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      _dragAnchor = null;
    }
  }

  void _confirm() {
    final start = _startDate;
    if (start == null) return;
    Navigator.of(
      context,
    ).pop(DateTimeRange(start: start, end: _endDate ?? start));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final localizations = MaterialLocalizations.of(context);
    final helpText =
        widget.helpText ??
        _t(context, '选择日期范围', 'Select date range', '날짜 범위 선택');
    return Material(
      color: scheme.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: UtenRadius.dialogAll,
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(scheme, helpText),
          Divider(height: 1, thickness: 1, color: scheme.outlineVariant),
          _buildMonthNav(scheme, localizations),
          _buildWeekdayRow(scheme, localizations),
          _buildGrid(scheme),
          _buildFooter(scheme),
        ],
      ),
    );
  }

  Widget _buildHeader(ColorScheme scheme, String helpText) {
    final localizations = MaterialLocalizations.of(context);
    final placeholderStyle = TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w500,
      color: scheme.onSurfaceVariant,
    );
    final valueStyle = TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w500,
      color: scheme.onSurface,
    );
    final startText = _startDate == null
        ? localizations.dateRangeStartLabel
        : localizations.formatCompactDate(_startDate!);
    final endText = _endDate == null
        ? localizations.dateRangeEndLabel
        : localizations.formatCompactDate(_endDate!);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 8, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  helpText,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: UtenSpacing.s8),
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: startText,
                        style: _startDate == null
                            ? placeholderStyle
                            : valueStyle,
                      ),
                      TextSpan(text: ' – ', style: placeholderStyle),
                      TextSpan(
                        text: endText,
                        style: _endDate == null ? placeholderStyle : valueStyle,
                      ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: localizations.closeButtonTooltip,
            icon: const Icon(Icons.close, size: 20),
            visualDensity: VisualDensity.compact,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _buildMonthNav(
    ColorScheme scheme,
    MaterialLocalizations localizations,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: Row(
        children: [
          IconButton(
            tooltip: localizations.previousMonthTooltip,
            icon: const Icon(Icons.chevron_left, size: 22),
            visualDensity: VisualDensity.compact,
            onPressed: _canGoPrev ? () => _shiftMonth(-1) : null,
          ),
          Expanded(
            child: Text(
              localizations.formatMonthYear(_displayedMonth),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
          ),
          IconButton(
            tooltip: localizations.nextMonthTooltip,
            icon: const Icon(Icons.chevron_right, size: 22),
            visualDensity: VisualDensity.compact,
            onPressed: _canGoNext ? () => _shiftMonth(1) : null,
          ),
        ],
      ),
    );
  }

  Widget _buildWeekdayRow(
    ColorScheme scheme,
    MaterialLocalizations localizations,
  ) {
    final narrow = localizations.narrowWeekdays;
    final firstDow = localizations.firstDayOfWeekIndex;
    final style = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w500,
      color: scheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s16),
      child: SizedBox(
        height: 28,
        child: Row(
          children: [
            for (var i = 0; i < 7; i++)
              Expanded(
                child: Center(
                  child: Text(narrow[(firstDow + i) % 7], style: style),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildGrid(ColorScheme scheme) {
    final blanks = _leadingBlanks;
    final year = _displayedMonth.year;
    final month = _displayedMonth.month;
    final daysInMonth = _daysInMonth;
    final hasRange = _startDate != null && _endDate != null;
    final rows = <Widget>[];
    for (var r = 0; r < _rowCount; r++) {
      final rowChildren = <Widget>[];
      for (var c = 0; c < 7; c++) {
        final dayNumber = r * 7 + c + 1 - blanks;
        if (dayNumber < 1 || dayNumber > daysInMonth) {
          rowChildren.add(const Expanded(child: SizedBox.shrink()));
          continue;
        }
        final day = DateTime(year, month, dayNumber);
        rowChildren.add(
          Expanded(
            child: _DayCell(
              day: day,
              enabled: _isSelectable(day),
              isToday: _sameDay(day, _today),
              isStart: _sameDay(day, _startDate),
              isEnd: _sameDay(day, _endDate),
              hasRange: hasRange,
              inBand:
                  hasRange &&
                  day.isAfter(_startDate!) &&
                  day.isBefore(_endDate!),
            ),
          ),
        );
      }
      rows.add(
        SizedBox(
          height: _cellHeight,
          child: Row(children: rowChildren),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s16),
      child: Listener(
        key: _gridKey,
        behavior: HitTestBehavior.opaque,
        onPointerDown: _handlePointer,
        onPointerMove: _handlePointer,
        onPointerUp: _handlePointer,
        onPointerCancel: _handlePointer,
        child: Column(children: rows),
      ),
    );
  }

  Widget _buildFooter(ColorScheme scheme) {
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 12, 16, 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          UtenButton(
            onPressed: _startDate == null ? null : _confirm,
            child: Text(_t(context, '确定', 'OK', '확인')),
          ),
        ],
      ),
    );
  }
}

/// 单个日期格子：区间带、悬停圆、选中圆叠画在固定格内；命中与拖拽由外层
/// Listener 统一换算，格子自身不参与手势竞技。
class _DayCell extends StatefulWidget {
  const _DayCell({
    required this.day,
    required this.enabled,
    required this.isToday,
    required this.isStart,
    required this.isEnd,
    required this.hasRange,
    required this.inBand,
  });

  final DateTime day;
  final bool enabled;
  final bool isToday;
  final bool isStart;
  final bool isEnd;

  /// 当前是否已有完整区间（起点+终点）；区分「待定起点」不画半带。
  final bool hasRange;
  final bool inBand;

  @override
  State<_DayCell> createState() => _DayCellState();
}

class _DayCellState extends State<_DayCell> {
  static const double _dayDiameter = 36;

  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final localizations = MaterialLocalizations.of(context);
    final selected = widget.isStart || widget.isEnd;
    final bandColor = scheme.primary.withValues(alpha: 0.12);
    // 区间带只画在完整区间上：起点无终点时（待定选择）只亮圆，不拖半条带。
    final bandRight = widget.isStart && widget.hasRange && !widget.isEnd;
    final bandLeft = widget.isEnd && !widget.isStart;
    final hovered = _hovered && widget.enabled && !selected;

    final textStyle = TextStyle(
      fontSize: 14,
      fontWeight: selected || widget.isToday
          ? FontWeight.w600
          : FontWeight.w500,
      color: !widget.enabled
          ? scheme.onSurface.withValues(alpha: 0.32)
          : selected
          ? scheme.onPrimary
          : widget.isToday
          ? scheme.primary
          : scheme.onSurface,
    );

    return MouseRegion(
      cursor: widget.enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Semantics(
        button: true,
        enabled: widget.enabled,
        selected: selected,
        label: localizations.formatFullDate(widget.day),
        child: SizedBox(
          height: 40,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (widget.inBand)
                Positioned.fill(
                  top: 2,
                  bottom: 2,
                  child: ColoredBox(color: bandColor),
                ),
              if (bandRight)
                Positioned.fill(
                  top: 2,
                  bottom: 2,
                  child: FractionallySizedBox(
                    alignment: Alignment.centerRight,
                    widthFactor: 0.5,
                    child: ColoredBox(color: bandColor),
                  ),
                ),
              if (bandLeft)
                Positioned.fill(
                  top: 2,
                  bottom: 2,
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: 0.5,
                    child: ColoredBox(color: bandColor),
                  ),
                ),
              if (hovered)
                Container(
                  width: _dayDiameter,
                  height: _dayDiameter,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: scheme.onSurface.withValues(alpha: 0.06),
                  ),
                ),
              Container(
                width: _dayDiameter,
                height: _dayDiameter,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: selected ? scheme.primary : Colors.transparent,
                  border: widget.isToday && !selected
                      ? Border.all(color: scheme.primary, width: 1.5)
                      : null,
                ),
                alignment: Alignment.center,
                child: Text('${widget.day.day}', style: textStyle),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
