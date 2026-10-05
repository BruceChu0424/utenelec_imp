// AI 页面快照的有界数据模型与清理(ADR-150)。
//
// 契约见 docs/05-架构/AI平台接入指南.md 第八章 8.2。这里只做「把屏幕上看得见的东西
// 变成有界 JSON」: 截断、去控制字符、标签里的编号/网址整条丢弃、值里的编号/网址替换、
// 敏感列/字段留空并写进 withheld。所有上限都比服务端略紧, 服务端仍会再校验一遍。
library;

import 'dart:convert';

/// Bounds mirror the server contract (AiChatPageSnapshot) with a byte margin.
abstract final class AiSnapshotLimits {
  static const tables = 4;
  static const columns = 12;
  static const rows = 30;
  static const value = 80;
  static const label = 40;
  static const info = 200;
  static const fields = 60;
  static const legend = 40;
  static const flagged = 80;
  static const badges = 30;
  static const notices = 10;
  static const noticeText = 600;
  static const actions = 16;
  static const withheld = 30;
  static const title = 80;
  static const meaning = 120;

  /// Server rejects more than 24 KB; the client keeps a 2 KB margin because
  /// both sides serialize the same data with slightly different whitespace.
  static const maxBytes = 22 * 1024;
}

/// Cell states of `flaggedCells[].state`.
enum AiCellState {
  review('REVIEW'),
  requiredEmpty('REQUIRED_EMPTY'),
  warning('WARNING'),
  error('ERROR'),
  flagged('FLAGGED');

  const AiCellState(this.wire);
  final String wire;
}

/// Field states of `fields[].state`.
enum AiFieldState {
  normal('NORMAL'),
  requiredEmpty('REQUIRED_EMPTY'),
  autofilled('AUTOFILLED'),
  warning('WARNING'),
  error('ERROR');

  const AiFieldState(this.wire);
  final String wire;
}

/// Notice kinds of `notices[].kind`.
enum AiNoticeKind {
  banner('BANNER'),
  inline('INLINE'),
  dialog('DIALOG');

  const AiNoticeKind(this.wire);
  final String wire;
}

/// Shared tone names; anything else is dropped before sending.
const aiSnapshotTones = {
  'neutral',
  'info',
  'success',
  'warning',
  'danger',
  'fuchsia',
  'violet',
  'accent',
};

class AiTableColumn {
  const AiTableColumn({required this.label, this.info, this.sensitive = false});
  final String label;
  final String? info;
  final bool sensitive;
}

class AiTableRow {
  const AiTableRow({
    required this.no,
    required this.cells,
    this.selected = false,
    this.flagged = false,
  });

  /// 1-based screen row number; "the 3rd row" means 3.
  final int no;
  final List<String> cells;
  final bool selected;
  final bool flagged;
}

class AiLegendEntry {
  const AiLegendEntry({
    required this.column,
    required this.value,
    this.color,
    this.tone,
    this.meaning,
    this.count = 1,
  });
  final String column;
  final String value;
  final String? color;
  final String? tone;
  final String? meaning;
  final int count;
}

class AiFlaggedCell {
  const AiFlaggedCell({
    required this.rowNo,
    required this.state,
    this.rowLabel,
    this.column,
    this.value,
    this.reason,
  });
  final int rowNo;
  final String? rowLabel;
  final String? column;
  final String? value;
  final AiCellState state;
  final String? reason;
}

class AiTableSnapshot {
  const AiTableSnapshot({
    this.title,
    this.totalRows,
    this.visibleRows,
    this.selectedRows,
    this.columns = const [],
    this.rows = const [],
    this.legend = const [],
    this.flaggedCells = const [],
    this.truncated = false,
  });
  final String? title;
  final int? totalRows;
  final int? visibleRows;
  final int? selectedRows;
  final List<AiTableColumn> columns;
  final List<AiTableRow> rows;
  final List<AiLegendEntry> legend;
  final List<AiFlaggedCell> flaggedCells;
  final bool truncated;
}

class AiFieldSnapshot {
  const AiFieldSnapshot({
    required this.label,
    this.value,
    this.state = AiFieldState.normal,
    this.required = false,
    this.message,
    this.info,
    this.sensitive = false,
  });
  final String label;
  final String? value;
  final AiFieldState state;
  final bool required;
  final String? message;
  final String? info;
  final bool sensitive;
}

class AiBadgeSnapshot {
  const AiBadgeSnapshot({
    required this.label,
    this.tone,
    this.color,
    this.count,
  });
  final String label;
  final String? tone;
  final String? color;
  final int? count;
}

class AiNoticeSnapshot {
  const AiNoticeSnapshot({required this.kind, required this.text, this.title});
  final AiNoticeKind kind;
  final String? title;
  final String text;
}

/// Same list as the server backstop (AiChatPageSnapshot.SENSITIVE_LABEL):
/// costs and margins, payroll vocabulary, credit limits, personal identifiers
/// and contact details. A matching column or field is sent with its label and
/// state only; value, message and explanation stay in the app.
final aiSensitiveLabel = RegExp(
  r'成本|毛利|利润|进价|进货价|工资|薪|奖金|年终奖|提成|佣金|社保|公积金|应发|实发|扣减|扣款|扣除合计|扣除金额|个税|所得税'
  r'|加班费|津贴|补贴|绩效|信用额度|信用余额|授信|身份证|证件号|护照|银行卡|银行账号|银行帐号|开户账号|账户号码|卡号'
  r'|手机|电话|联系方式|邮箱|住址|家庭地址|户籍'
  r'|cost|margin|profit|purchase\s*price|salary|payroll|wage|bonus|commission|deduction|gross\s*pay|net\s*pay|income\s*tax'
  r'|credit\s*limit|id\s*(?:card|number)|passport|bank\s*account|account\s*number|phone|mobile|e-?mail'
  r'|home\s*address',
  caseSensitive: false,
);

/// Credentials (AiChatPageSnapshot.CREDENTIAL_LABEL): never registered or sent
/// in any form, not even the label.
final aiCredentialLabel = RegExp(
  r'密码|口令|验证码|校验码|动态码|密钥|私钥|令牌|password|passcode|passwd|secret'
  r'|api[\s_-]*key|access[\s_-]*key|(?:access|refresh|auth|bearer|session|api)[\s_-]*token|^\s*token\s*$',
  caseSensitive: false,
);

/// Pages whose content is never read (AiChatPageSnapshot.CONTENT_WITHHELD_ROUTES):
/// payroll, HR and personal records and credentials. There only the question
/// itself is sent.
const aiContentWithheldRoutes = [
  '/payroll',
  '/hr',
  '/employee',
  '/profile',
  '/change-password',
];

/// ADR-153 protected pages (AiChatPageSnapshot.PROTECTED_ROUTES): system
/// administration (system settings, AI service settings, permissions, audit
/// logs, server status), page permissions, security and device receipts.
/// Nothing on them is captured or sent and no confirmation card runs there.
const aiProtectedRoutes = [
  '/admin',
  '/page-permissions',
  '/security',
  '/settings/device-receipts',
];

bool _aiRouteUnder(String? route, List<String> prefixes) {
  if (route == null) return false;
  final path = aiCanonicalRoute(route);
  return prefixes.any(
    (prefix) => path == prefix || path.startsWith('$prefix/'),
  );
}

/// The route a protection decision is made on (AiChatPageSnapshot.canonicalRoute):
/// letter case, repeated and trailing slashes never get a page past the lists.
String aiCanonicalRoute(String route) {
  var path = route.toLowerCase().replaceAll(RegExp(r'/{2,}'), '/');
  if (path.length > 1 && path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return path;
}

/// True on a system administration or security page (ADR-153).
bool aiPageProtected(String? route) => _aiRouteUnder(route, aiProtectedRoutes);

/// True when nothing of the page is read: payroll, HR and personal pages and
/// the protected system pages.
bool aiPageContentWithheld(String? route) =>
    _aiRouteUnder(route, aiContentWithheldRoutes) || aiPageProtected(route);

final _uuid = RegExp(
  r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}',
  caseSensitive: false,
);
final _url = RegExp(
  r'(?:[a-z][a-z0-9+.-]{1,15}://|www\.)\S*',
  caseSensitive: false,
);
final _format = RegExp(r'\p{Cf}+', unicode: true);
final _control = RegExp(r'\p{Cc}', unicode: true);
final _spaces = RegExp(r'[ \u00A0\u3000]{2,}');

String _cut(String text, int max) {
  if (text.length <= max) return text;
  var end = max;
  final last = text.codeUnitAt(end - 1);
  if (last >= 0xD800 && last <= 0xDBFF) end--;
  return text.substring(0, end);
}

/// Single-line display value: control characters become spaces, format
/// characters are removed, identifiers and links are replaced, then the text
/// is cut to [max] UTF-16 units (Java String.length on the server).
String? aiSnapshotValue(String? raw, [int max = AiSnapshotLimits.value]) {
  if (raw == null) return null;
  var text = raw.replaceAll(_format, '').replaceAll(_control, ' ');
  text = text
      .replaceAll(_uuid, '[编号]')
      .replaceAll(_url, '[链接]')
      .replaceAll(_spaces, ' ')
      .trim();
  return _cut(text, max);
}

/// Multi-line text (notices): newlines kept, other control characters removed.
String? aiSnapshotMultiline(
  String? raw, [
  int max = AiSnapshotLimits.noticeText,
]) {
  if (raw == null) return null;
  var text = raw
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll('\t', ' ')
      .replaceAll(_format, '');
  text = text.replaceAll(
    RegExp(r'[\u0000-\u0009\u000B-\u001F\u007F-\u009F]'),
    '',
  );
  text = text
      .replaceAll(_uuid, '[编号]')
      .replaceAll(_url, '[链接]')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
  return _cut(text, max);
}

/// Labels name what the user sees. A label containing an identifier or link is
/// not a label and is dropped (the server would reject the whole snapshot).
String? aiSnapshotLabel(String? raw, [int max = AiSnapshotLimits.label]) {
  final text = aiSnapshotValue(raw, 400);
  if (text == null || text.isEmpty) return null;
  if (_uuid.hasMatch(raw!) || _url.hasMatch(raw) || text.contains('[编号]')) {
    return null;
  }
  return _cut(text, max);
}

/// Value withheld (sensitive word or credential). Matched on the label as a
/// person reads it: full-width letters folded, spaces and invisible characters
/// removed ("成 本", "Ｃｏｓｔ" are 成本 and cost), as on the server.
bool aiIsSensitiveLabel(String label) {
  final key = _labelKey(label);
  return aiSensitiveLabel.hasMatch(label) ||
      aiCredentialLabel.hasMatch(label) ||
      aiSensitiveLabel.hasMatch(key) ||
      aiCredentialLabel.hasMatch(key);
}

/// Dropped entirely.
bool aiIsCredentialLabel(String label) =>
    aiCredentialLabel.hasMatch(label) ||
    aiCredentialLabel.hasMatch(_labelKey(label));

String _labelKey(String label) {
  final folded = String.fromCharCodes(
    label.runes.map(
      (rune) => rune >= 0xFF01 && rune <= 0xFF5E
          ? rune - 0xFEE0
          : (rune == 0x3000 ? 0x20 : rune),
    ),
  );
  return folded.replaceAll(_format, '').replaceAll(RegExp(r'\s+'), '');
}

/// Builder state shared by the controller: everything is bounded while it is
/// added, and [toJson] shrinks the result until it fits [AiSnapshotLimits.maxBytes].
class AiSnapshotDraft {
  String? title;
  String? focusField;
  final tables = <AiTableSnapshot>[];
  final fields = <AiFieldSnapshot>[];
  final badges = <AiBadgeSnapshot>[];
  final notices = <AiNoticeSnapshot>[];
  final actions = <Map<String, Object?>>[];
  final withheld = <String>{};

  bool get isEmpty =>
      tables.isEmpty &&
      fields.isEmpty &&
      badges.isEmpty &&
      notices.isEmpty &&
      actions.isEmpty &&
      (title == null || title!.isEmpty);

  /// Rows that will actually be attached (after bounding).
  int get attachedRows => _attached.$1;
  int get attachedFields => _attached.$2;
  int get attachedFlagged => _attached.$3;
  (int, int, int) _attached = (0, 0, 0);

  Map<String, Object?> toJson() {
    // Progressive shrink: fewer rows first, then fewer flagged cells/legend,
    // then shorter notices and fewer fields. The newest (top) data stays.
    const rowSteps = [AiSnapshotLimits.rows, 20, 12, 6, 3, 0];
    const flaggedSteps = [AiSnapshotLimits.flagged, 40, 20, 12];
    for (final flagCap in flaggedSteps) {
      for (final rowCap in rowSteps) {
        final json = _encode(rowCap: rowCap, flaggedCap: flagCap);
        if (utf8.encode(jsonEncode(json)).length <= AiSnapshotLimits.maxBytes) {
          return json;
        }
      }
    }
    final minimal = _encode(
      rowCap: 0,
      flaggedCap: 12,
      legendCap: 12,
      fieldCap: 20,
      noticeCap: 3,
      actionCap: 8,
    );
    if (utf8.encode(jsonEncode(minimal)).length <= AiSnapshotLimits.maxBytes) {
      return minimal;
    }
    return _encode(
      rowCap: 0,
      flaggedCap: 0,
      legendCap: 0,
      fieldCap: 0,
      noticeCap: 0,
      actionCap: 4,
    );
  }

  static bool _secretCell(AiFlaggedCell cell, Set<String> secretLabels) {
    final column = cell.column;
    return column != null &&
        (secretLabels.contains(column) || aiIsSensitiveLabel(column));
  }

  Map<String, Object?> _encode({
    required int rowCap,
    required int flaggedCap,
    int legendCap = AiSnapshotLimits.legend,
    int fieldCap = AiSnapshotLimits.fields,
    int noticeCap = AiSnapshotLimits.notices,
    int actionCap = AiSnapshotLimits.actions,
  }) {
    var rowsSent = 0;
    var flaggedSent = 0;
    final tableJson = <Map<String, Object?>>[];
    for (final table in tables.take(AiSnapshotLimits.tables)) {
      final columns = table.columns.take(AiSnapshotLimits.columns).toList();
      final secret = <int>{
        for (var i = 0; i < columns.length; i++)
          if (columns[i].sensitive || aiIsSensitiveLabel(columns[i].label)) i,
      };
      for (final i in secret) {
        if (columns[i].label.isNotEmpty) withheld.add(columns[i].label);
      }
      final rows = table.rows.take(rowCap).toList();
      rowsSent += rows.length;
      final secretLabels = {for (final i in secret) columns[i].label};
      final flagged = table.flaggedCells.take(flaggedCap).toList();
      flaggedSent += flagged.length;
      tableJson.add({
        if (table.title != null && table.title!.isNotEmpty)
          'title': table.title,
        if (table.totalRows != null) 'totalRows': table.totalRows,
        if (table.visibleRows != null) 'visibleRows': table.visibleRows,
        if (table.selectedRows != null) 'selectedRows': table.selectedRows,
        'columns': [
          for (var i = 0; i < columns.length; i++)
            {
              'label': columns[i].label,
              if (!secret.contains(i) &&
                  columns[i].info != null &&
                  columns[i].info!.isNotEmpty)
                'info': columns[i].info,
              if (secret.contains(i)) 'sensitive': true,
            },
        ],
        'rows': [
          for (final row in rows)
            {
              'no': row.no,
              'cells': [
                for (var i = 0; i < row.cells.length && i < columns.length; i++)
                  secret.contains(i) ? '' : row.cells[i],
              ],
              if (row.selected) 'selected': true,
              if (row.flagged) 'flagged': true,
            },
        ],
        'legend': [
          for (final entry
              in table.legend
                  .where((entry) => !secretLabels.contains(entry.column))
                  .take(legendCap))
            {
              'column': entry.column,
              'value': entry.value,
              if (entry.color != null) 'color': entry.color,
              if (entry.tone != null) 'tone': entry.tone,
              if (entry.meaning != null && entry.meaning!.isNotEmpty)
                'meaning': entry.meaning,
              'count': entry.count,
            },
        ],
        'flaggedCells': [
          for (final cell in flagged)
            if (cell.column == null || !aiIsCredentialLabel(cell.column!))
              {
                'rowNo': cell.rowNo,
                if (cell.rowLabel != null && cell.rowLabel!.isNotEmpty)
                  'rowLabel': cell.rowLabel,
                if (cell.column != null && cell.column!.isNotEmpty)
                  'column': cell.column,
                // A reason can quote the value, so both stay local.
                if (!_secretCell(cell, secretLabels)) ...{
                  'value': ?cell.value,
                  if (cell.reason != null && cell.reason!.isNotEmpty)
                    'reason': cell.reason,
                },
                'state': cell.state.wire,
              },
        ],
        if (table.truncated || rows.length < table.rows.length)
          'truncated': true,
      });
    }
    final fieldJson = <Map<String, Object?>>[];
    for (final field in fields.take(fieldCap)) {
      if (aiIsCredentialLabel(field.label)) continue;
      final secret = field.sensitive || aiIsSensitiveLabel(field.label);
      if (secret) withheld.add(field.label);
      fieldJson.add({
        'label': field.label,
        if (secret) 'sensitive': true,
        if (!secret && field.value != null) 'value': field.value,
        'state': field.state.wire,
        if (field.required) 'required': true,
        // A message or explanation can quote the value ("超出信用额度 12,000").
        if (!secret && field.message != null && field.message!.isNotEmpty)
          'message': field.message,
        if (!secret && field.info != null && field.info!.isNotEmpty)
          'info': field.info,
      });
    }
    _attached = (rowsSent, fieldJson.length, flaggedSent);
    return {
      'version': 1,
      if (title != null && title!.isNotEmpty) 'title': title,
      'tables': tableJson,
      'fields': fieldJson,
      'badges': [
        for (final badge in badges.take(AiSnapshotLimits.badges))
          {
            'label': badge.label,
            if (badge.tone != null) 'tone': badge.tone,
            if (badge.color != null) 'color': badge.color,
            if (badge.count != null) 'count': badge.count,
          },
      ],
      'notices': [
        for (final notice in notices.take(noticeCap))
          {
            'kind': notice.kind.wire,
            if (notice.title != null && notice.title!.isNotEmpty)
              'title': notice.title,
            'text': notice.text,
          },
      ],
      'pageActions': actions.take(actionCap).toList(),
      if (focusField != null && focusField!.isNotEmpty)
        'focusField': focusField,
      if (withheld.isNotEmpty)
        'withheld': withheld.take(AiSnapshotLimits.withheld).toList(),
    };
  }
}
