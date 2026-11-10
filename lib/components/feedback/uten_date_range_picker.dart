// 全站统一的日期范围选择弹窗。
//
// Material 自带区间选择器把关闭按钮钉死在头部左上、铅笔与「应用」钉在右上，
// 布局不可通过主题调整；这里自绘紧凑弹窗（内容自适应高度，最大 520 宽）：
// 共享渐变标题、右上角关闭及底部居中的「取消 / 确定」按钮组；当前选中的
// 日期直接作为标题区的重点值显示（2026-11-10 用户口径），不重复选择提示标题；
// 月份模式的年月已在导航行展示，不再另起一行。
// 口径出自 admin 审计日志（2026-09-28 用户口径），2026-10-24 推广为全站
// 唯一形态：所有日期范围选择都走本函数，不再各自内联 builder。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/uten_tokens.dart';
import '../../core/utils/date_range_defaults.dart';
import '../../core/utils/china_datetime.dart';
import '../buttons/uten_button.dart';
import 'uten_dialog.dart';

/// [wrap] 供调用方叠加自己的包装（如 trackNativeReadDialog 的只读门禁），
/// 作用在弹窗内容之外、居中约束之内。返回值与 showDateRangePicker 一致：
/// 取消返回 null；起止值归一化为本地 date-only，壁钟转换由调用方按各自
/// 口径处理。
typedef UtenDateRangeSelection = ({DateTime? start, DateTime? end});

Future<T?> _showUtenCalendar<T>({
  required BuildContext context,
  required UtenDateRangePickerDialog dialog,
  Widget Function(BuildContext context, Widget child)? wrap,
  Locale? locale,
}) => showDialog<T>(
  context: context,
  barrierDismissible: false,
  builder: (dialogContext) {
    Widget child = dialog;
    if (locale != null) {
      child = Localizations.override(
        context: dialogContext,
        locale: locale,
        child: child,
      );
    }
    if (wrap != null) child = wrap(dialogContext, child);
    return child;
  },
);

Future<DateTimeRange?> showUtenDateRangePicker({
  required BuildContext context,
  required DateTime firstDate,
  required DateTime lastDate,
  DateTimeRange? initialDateRange,
  String? helpText,
  Widget Function(BuildContext context, Widget child)? wrap,
}) => _showUtenCalendar<DateTimeRange>(
  context: context,
  wrap: wrap,
  dialog: UtenDateRangePickerDialog(
    firstDate: firstDate,
    lastDate: lastDate,
    initialDateRange: initialDateRange,
    helpText: helpText,
  ),
);

/// Open ends are explicit choices; cancelling never applies a draft.
Future<UtenDateRangeSelection?> showUtenDateRangeSelectionPicker({
  required BuildContext context,
  required DateTime firstDate,
  required DateTime lastDate,
  DateTime? initialStart,
  DateTime? initialEnd,
  bool allowOpenRange = false,
  bool defaultToRecentMonth = true,
  String? openStartLabel,
  String? openEndLabel,
  String? helpText,
  Widget Function(BuildContext context, Widget child)? wrap,
}) => _showUtenCalendar<UtenDateRangeSelection>(
  context: context,
  wrap: wrap,
  dialog: UtenDateRangePickerDialog(
    firstDate: firstDate,
    lastDate: lastDate,
    initialStart: initialStart,
    initialEnd: initialEnd,
    allowOpenRange: allowOpenRange,
    defaultToRecentMonth: defaultToRecentMonth,
    openStartLabel: openStartLabel,
    openEndLabel: openEndLabel,
    returnSelection: true,
    helpText: helpText,
  ),
);

/// Single dates use the same year / month / day navigation as ranges.
Future<DateTime?> showUtenDatePicker({
  required BuildContext context,
  required DateTime firstDate,
  required DateTime lastDate,
  DateTime? initialDate,
  DateTime? currentDate,
  String? helpText,
  Locale? locale,
}) => _showUtenCalendar<DateTime>(
  context: context,
  locale: locale,
  dialog: UtenDateRangePickerDialog(
    firstDate: firstDate,
    lastDate: lastDate,
    initialStart: initialDate,
    currentDate: currentDate,
    singleDate: true,
    helpText: helpText,
  ),
);

/// Month-only fields retain their year/month precision without inventing a day.
Future<DateTime?> showUtenMonthPicker({
  required BuildContext context,
  required int firstYear,
  required int lastYear,
  DateTime? initialMonth,
  String? helpText,
}) => _showUtenCalendar<DateTime>(
  context: context,
  dialog: UtenDateRangePickerDialog(
    firstDate: DateTime(firstYear),
    lastDate: DateTime(lastYear, 12, 31),
    initialStart: initialMonth,
    singleDate: true,
    monthOnly: true,
    helpText: helpText,
  ),
);

enum _CalendarView { days, years, months }

/// 区间选择的交互语义与 Material 一致：首击定起点；再击不早于起点则定
/// 终点（同日即单日区间），早于起点则重设起点；按住拖拽实时扩展区间。
class UtenDateRangePickerDialog extends StatefulWidget {
  const UtenDateRangePickerDialog({
    super.key,
    required this.firstDate,
    required this.lastDate,
    this.initialDateRange,
    this.helpText,
    this.initialStart,
    this.initialEnd,
    this.currentDate,
    this.allowOpenRange = false,
    this.defaultToRecentMonth = true,
    this.openStartLabel,
    this.openEndLabel,
    this.singleDate = false,
    this.monthOnly = false,
    this.returnSelection = false,
  });

  final DateTime firstDate;
  final DateTime lastDate;

  /// 打开时预选的区间；入参允许带时刻，内部归一化为本地 date-only。
  final DateTimeRange? initialDateRange;
  final String? helpText;
  final DateTime? initialStart;
  final DateTime? initialEnd;
  final DateTime? currentDate;
  final bool allowOpenRange;
  final bool defaultToRecentMonth;
  final String? openStartLabel;
  final String? openEndLabel;
  final bool singleDate;
  final bool monthOnly;
  final bool returnSelection;

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
  bool _unboundedStart = false;
  bool _unboundedEnd = false;
  _CalendarView _view = _CalendarView.days;

  /// 当前展示月（该月 1 日，本地 date-only）。
  late DateTime _displayedMonth;

  /// 拖拽锚点：按下那天的日期，拖拽期间固定不动。
  DateTime? _dragAnchor;

  @override
  void initState() {
    super.initState();
    if (widget.monthOnly) _view = _CalendarView.months;
    final now = widget.currentDate ?? ChinaDateTime.today();
    _today = _dateOnly(now);
    _firstDate = _dateOnly(widget.firstDate);
    _lastDate = _dateOnly(widget.lastDate);
    assert(!_lastDate.isBefore(_firstDate));
    var start = widget.initialDateRange?.start ?? widget.initialStart;
    var end = widget.initialDateRange?.end ?? widget.initialEnd;
    if (start == null &&
        end == null &&
        !widget.allowOpenRange &&
        widget.defaultToRecentMonth &&
        !widget.singleDate) {
      end = _clampDate(_today);
      start = _clampDate(_dateOnly(recentMonthStart(today: end)));
    }
    if (start != null) _startDate = _dateOnly(start);
    if (end != null) _endDate = _dateOnly(end);
    if (_startDate != null &&
        _endDate != null &&
        _endDate!.isBefore(_startDate!)) {
      final swap = _startDate;
      _startDate = _endDate;
      _endDate = swap;
    }
    _unboundedStart = widget.allowOpenRange && start == null;
    _unboundedEnd = widget.allowOpenRange && end == null;
    final anchor =
        _startDate ??
        _endDate ??
        (_today.isBefore(_firstDate)
            ? _firstDate
            : (_today.isAfter(_lastDate) ? _lastDate : _today));
    final visible = _clampDate(anchor);
    _displayedMonth = DateTime(visible.year, visible.month);
  }

  DateTime _clampDate(DateTime date) => date.isBefore(_firstDate)
      ? _firstDate
      : date.isAfter(_lastDate)
      ? _lastDate
      : date;

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
      if (widget.singleDate) {
        _startDate = day;
        _endDate = null;
      } else if (_unboundedStart && !_unboundedEnd) {
        _endDate = day;
      } else if (_unboundedEnd && !_unboundedStart) {
        _startDate = day;
      } else if (_startDate == null ||
          _endDate != null ||
          (_unboundedStart && _unboundedEnd)) {
        _unboundedStart = false;
        _unboundedEnd = false;
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
    if (widget.singleDate ||
        _unboundedStart ||
        _unboundedEnd ||
        anchor == null ||
        _sameDay(day, anchor)) {
      return;
    }
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
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      _dragAnchor = null;
      return;
    }
    if (!mounted) return;
    final box = _gridKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final local = box.globalToLocal(event.position);
    if (!(Offset.zero & box.size).contains(local)) return;
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
    }
  }

  bool get _canConfirm {
    final start = _unboundedStart ? null : _startDate;
    final end = _unboundedEnd ? null : _endDate ?? start;
    if (!widget.allowOpenRange && start == null) return false;
    if (widget.allowOpenRange && !_unboundedStart && start == null) {
      return false;
    }
    if (widget.allowOpenRange && !_unboundedEnd && end == null) return false;
    if (start != null && !_isSelectable(start)) return false;
    if (end != null && !_isSelectable(end)) return false;
    return start == null || end == null || !end.isBefore(start);
  }

  void _toggleOpenEnd({required bool start, required bool unbounded}) {
    setState(() {
      if (start) {
        _unboundedStart = unbounded;
        if (!unbounded &&
            _startDate != null &&
            _endDate != null &&
            _startDate!.isAfter(_endDate!)) {
          _startDate = _endDate;
        }
      } else {
        _unboundedEnd = unbounded;
        if (!unbounded &&
            _endDate != null &&
            _startDate != null &&
            _endDate!.isBefore(_startDate!)) {
          _endDate = _startDate;
        }
      }
      _dragAnchor = null;
    });
  }

  void _confirm() {
    if (!_canConfirm) return;
    if (widget.singleDate) {
      Navigator.of(context).pop(_startDate);
    } else if (widget.returnSelection) {
      Navigator.of(context).pop<UtenDateRangeSelection>((
        start: _unboundedStart ? null : _startDate,
        end: _unboundedEnd ? null : _endDate ?? _startDate,
      ));
    } else {
      Navigator.of(
        context,
      ).pop(DateTimeRange(start: _startDate!, end: _endDate ?? _startDate!));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final localizations = MaterialLocalizations.of(context);
    final helpText =
        widget.helpText ??
        (widget.singleDate
            ? _t(context, '选择日期', 'Select date', '날짜 선택')
            : _t(context, '选择日期范围', 'Select date range', '날짜 범위 선택'));
    return UtenAlertDialog(
      maxWidth: 520,
      showCloseButton: true,
      semanticLabel: helpText,
      title: _buildHeader(),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.allowOpenRange) _buildOpenEnds(),
          _buildMonthNav(scheme, localizations),
          if (_view == _CalendarView.days) ...[
            _buildWeekdayRow(scheme, localizations),
            _buildGrid(scheme),
          ] else if (_view == _CalendarView.years)
            SizedBox(
              width: 440,
              height: 268,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
                  final columns = (constraints.maxWidth / (92 * scale))
                      .floor()
                      .clamp(2, 4);
                  final rowHeight = (44 * scale).clamp(44.0, 88.0);
                  return _CalendarYearGrid(
                    key: ValueKey(
                      'years-$columns-$rowHeight-${_displayedMonth.year}',
                    ),
                    columns: columns,
                    rowHeight: rowHeight,
                    firstYear: _firstDate.year,
                    lastYear: _lastDate.year,
                    selectedYear: _displayedMonth.year,
                    currentYear: _today.year,
                    onSelected: (year) => setState(() {
                      final next = _clampDate(
                        DateTime(year, _displayedMonth.month),
                      );
                      _displayedMonth = DateTime(next.year, next.month);
                      _view = _CalendarView.months;
                    }),
                  );
                },
              ),
            )
          else
            _buildMonths(scheme, localizations),
        ],
      ),
      actions: [
        UtenButton(
          type: UtenButtonType.secondary,
          onPressed: () => Navigator.of(context).pop(),
          child: Text(localizations.cancelButtonLabel),
        ),
        if (!widget.monthOnly)
          UtenButton(
            onPressed: _canConfirm ? _confirm : null,
            child: Text(_t(context, '确定', 'OK', '확인')),
          ),
      ],
    );
  }

  Widget _buildHeader() {
    final parts = _headerSelectionParts();
    final theme = Theme.of(context);
    final style = theme.textTheme.headlineSmall?.copyWith(
      color: theme.colorScheme.primary,
      fontWeight: FontWeight.w700,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return UtenDialogHeading(
      icon: Icons.date_range_outlined,
      title: parts == null
          ? const SizedBox.shrink()
          : Semantics(
              key: const Key('uten-date-selection'),
              container: true,
              label: parts.join(' - '),
              liveRegion: true,
              child: ExcludeSemantics(
                child: LayoutBuilder(
                  builder: (context, bounds) {
                    Widget text(String value) =>
                        Text(value, maxLines: 1, softWrap: false, style: style);
                    final full = parts.join(' - ');
                    final painter = TextPainter(
                      text: TextSpan(text: full, style: style),
                      textDirection: Directionality.of(context),
                      textScaler: MediaQuery.textScalerOf(context),
                      maxLines: 1,
                    )..layout();
                    final fits = painter.width <= bounds.maxWidth;
                    painter.dispose();
                    if (fits || !bounds.hasBoundedWidth) return text(full);
                    // A complete date is one visual group. Only a group which
                    // exceeds its lane scales down; it never wraps at a slash
                    // or loses digits. The semantic value retains the full
                    // range while the original text scaler remains in use.
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (var index = 0; index < parts.length; index++) ...[
                          if (index > 0) const SizedBox(height: UtenSpacing.s4),
                          SizedBox(
                            width: bounds.maxWidth,
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: AlignmentDirectional.centerStart,
                              child: text(
                                index < parts.length - 1
                                    ? '${parts[index]} -'
                                    : parts[index],
                              ),
                            ),
                          ),
                        ],
                      ],
                    );
                  },
                ),
              ),
            ),
    );
  }

  /// 当前选择是标题区的重点值；月份模式和单日未选时不显示占位文字。
  /// 日期采用跨语言一致的 yyyy/MM/dd，开放端仍保留明确的无界语义。
  List<String>? _headerSelectionParts() {
    final l10n = MaterialLocalizations.of(context);
    String date(DateTime value) =>
        '${value.year.toString().padLeft(4, '0')}/'
        '${value.month.toString().padLeft(2, '0')}/'
        '${value.day.toString().padLeft(2, '0')}';
    if (widget.monthOnly) return null;
    if (widget.singleDate) {
      return _startDate == null ? null : [date(_startDate!)];
    }
    final start = _unboundedStart
        ? (widget.openStartLabel ?? _t(context, '不限开始', 'No start', '시작 제한 없음'))
        : _startDate == null
        ? l10n.dateRangeStartLabel
        : date(_startDate!);
    final end = _unboundedEnd
        ? (widget.openEndLabel ?? _t(context, '不限结束', 'No end', '종료 제한 없음'))
        : _endDate == null
        ? l10n.dateRangeEndLabel
        : date(_endDate!);
    return [start, end];
  }

  Widget _buildOpenEnds() => Wrap(
    spacing: UtenSpacing.s8,
    children: [
      FilterChip(
        label: Text(
          (widget.openStartLabel ??
              _t(context, '不限开始', 'No start', '시작 제한 없음')),
        ),
        selected: _unboundedStart,
        onSelected: (value) => _toggleOpenEnd(start: true, unbounded: value),
      ),
      FilterChip(
        label: Text(
          (widget.openEndLabel ?? _t(context, '不限结束', 'No end', '종료 제한 없음')),
        ),
        selected: _unboundedEnd,
        onSelected: (value) => _toggleOpenEnd(start: false, unbounded: value),
      ),
    ],
  );

  Widget _buildMonths(ColorScheme scheme, MaterialLocalizations l10n) =>
      SizedBox(
        height:
            224 *
            (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(1.2, 2.5),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            for (var row = 0; row < 4; row++)
              Row(
                children: [
                  for (var col = 0; col < 3; col++)
                    Expanded(
                      child: Builder(
                        builder: (context) {
                          final month = row * 3 + col + 1;
                          final date = DateTime(_displayedMonth.year, month);
                          final enabled =
                              !DateTime(
                                date.year,
                                date.month + 1,
                                0,
                              ).isBefore(_firstDate) &&
                              !date.isAfter(_lastDate);
                          return Padding(
                            padding: const EdgeInsets.all(4),
                            child: TextButton(
                              key: ValueKey('uten-calendar-month-$month'),
                              style: TextButton.styleFrom(
                                foregroundColor: month == _displayedMonth.month
                                    ? scheme.onPrimary
                                    : scheme.onSurface,
                                backgroundColor: month == _displayedMonth.month
                                    ? scheme.primary
                                    : null,
                                minimumSize: const Size(44, 44),
                              ),
                              onPressed: enabled
                                  ? () {
                                      if (widget.monthOnly) {
                                        Navigator.of(context).pop(date);
                                      } else {
                                        setState(() {
                                          _displayedMonth = date;
                                          _view = _CalendarView.days;
                                        });
                                      }
                                    }
                                  : null,
                              child: Text(
                                _t(
                                  context,
                                  '$month月',
                                  const [
                                    'Jan',
                                    'Feb',
                                    'Mar',
                                    'Apr',
                                    'May',
                                    'Jun',
                                    'Jul',
                                    'Aug',
                                    'Sep',
                                    'Oct',
                                    'Nov',
                                    'Dec',
                                  ][month - 1],
                                  '$month월',
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
          ],
        ),
      );

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
            onPressed: _view == _CalendarView.days && _canGoPrev
                ? () => _shiftMonth(-1)
                : null,
          ),
          Expanded(
            child: TextButton(
              key: const Key('uten-calendar-month-year'),
              onPressed: () => setState(() {
                _dragAnchor = null;
                _view = _view == _CalendarView.years
                    ? _CalendarView.days
                    : _CalendarView.years;
              }),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: Text(
                      localizations.formatMonthYear(_displayedMonth),
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                  const Icon(Icons.expand_more, size: 18),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: localizations.nextMonthTooltip,
            icon: const Icon(Icons.chevron_right, size: 22),
            visualDensity: VisualDensity.compact,
            onPressed: _view == _CalendarView.days && _canGoNext
                ? () => _shiftMonth(1)
                : null,
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
              onSelected: () => _selectOnDown(day),
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
}

/// Virtualized years use the same measured columns and row height for layout
/// and initial offset, including narrow windows with large accessibility text.
class _CalendarYearGrid extends StatefulWidget {
  const _CalendarYearGrid({
    super.key,
    required this.columns,
    required this.rowHeight,
    required this.firstYear,
    required this.lastYear,
    required this.selectedYear,
    required this.currentYear,
    required this.onSelected,
  });
  final int columns;
  final double rowHeight;
  final int firstYear;
  final int lastYear;
  final int selectedYear;
  final int currentYear;
  final ValueChanged<int> onSelected;

  @override
  State<_CalendarYearGrid> createState() => _CalendarYearGridState();
}

class _CalendarYearGridState extends State<_CalendarYearGrid> {
  late final ScrollController _controller;

  @override
  void initState() {
    super.initState();
    final row = (widget.selectedYear - widget.firstYear) ~/ widget.columns;
    _controller = ScrollController(
      initialScrollOffset: (row - 2).clamp(0, row) * widget.rowHeight,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = MaterialLocalizations.of(context);
    return GridView.builder(
      key: const Key('uten-calendar-years'),
      controller: _controller,
      padding: EdgeInsets.zero,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: widget.columns,
        mainAxisExtent: widget.rowHeight,
      ),
      itemCount: widget.lastYear - widget.firstYear + 1,
      itemBuilder: (context, index) {
        final year = widget.firstYear + index;
        final selected = year == widget.selectedYear;
        return Padding(
          padding: const EdgeInsets.all(4),
          child: TextButton(
            key: ValueKey<int>(year),
            style: TextButton.styleFrom(
              foregroundColor: selected ? scheme.onPrimary : scheme.onSurface,
              backgroundColor: selected ? scheme.primary : null,
              side: !selected && year == widget.currentYear
                  ? BorderSide(color: scheme.primary)
                  : null,
              padding: const EdgeInsets.symmetric(horizontal: 4),
            ),
            onPressed: () => widget.onSelected(year),
            child: Text(l10n.formatYear(DateTime(year))),
          ),
        );
      },
    );
  }
}

/// 单个日期格子：区间带、悬停圆、选中圆叠画在固定格内；命中与拖拽由外层
/// Listener 统一换算，格子自身不参与手势竞技。
class _DayCell extends StatefulWidget {
  const _DayCell({
    required this.day,
    required this.onSelected,
    required this.enabled,
    required this.isToday,
    required this.isStart,
    required this.isEnd,
    required this.hasRange,
    required this.inBand,
  });

  final DateTime day;
  final VoidCallback onSelected;
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

    return FocusableActionDetector(
      enabled: widget.enabled,
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onSelected();
            return null;
          },
        ),
      },
      onShowFocusHighlight: (value) => setState(() => _hovered = value),
      child: MouseRegion(
        cursor: widget.enabled ? SystemMouseCursors.click : MouseCursor.defer,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Semantics(
          button: true,
          onTap: widget.enabled ? widget.onSelected : null,
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
      ),
    );
  }
}
