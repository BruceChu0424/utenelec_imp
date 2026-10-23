import 'dart:convert';

import '../../core/performance/responsive_data_codec.dart';
import 'form_draft.dart';

enum FormDraftHistoryAction { saved, deleted, completed, imported }

/// Safe index metadata: never persist a payload preview or a free-text title.
class FormDraftHistoryEntry {
  const FormDraftHistoryEntry({
    required this.id,
    required this.draftId,
    required this.module,
    required this.route,
    required this.permission,
    required this.revision,
    required this.recordedAt,
    required this.action,
    this.draftKind,
  });

  final String id;
  final String draftId;
  final BadgeModule module;
  final String route;
  final String permission;
  final String? draftKind;
  final String revision;
  final DateTime recordedAt;
  final FormDraftHistoryAction action;

  Map<String, dynamic> toJson() => {
    'id': id,
    'draftId': draftId,
    'module': module.name,
    'route': route,
    'permission': permission,
    'draftKind': draftKind,
    'revision': revision,
    'recordedAt': recordedAt.toUtc().toIso8601String(),
    'action': action.name,
  };

  factory FormDraftHistoryEntry.fromJson(Map<String, dynamic> json) =>
      FormDraftHistoryEntry(
        id: json['id'] as String,
        draftId: json['draftId'] as String,
        module: BadgeModule.values.byName(json['module'] as String),
        route: json['route'] as String,
        permission: json['permission'] as String,
        draftKind: json['draftKind'] as String?,
        revision: json['revision'] as String,
        recordedAt: DateTime.parse(json['recordedAt'] as String),
        action: FormDraftHistoryAction.values.byName(json['action'] as String),
      );
}

class FormDraftHistoryPage {
  const FormDraftHistoryPage({required this.entries, this.nextCursor});
  final List<FormDraftHistoryEntry> entries;

  /// Exclusive seek position; remains meaningful after new writes or reopen.
  final String? nextCursor;
}

class FormDraftHistoryRecord {
  const FormDraftHistoryRecord({required this.entry, required this.draft});
  final FormDraftHistoryEntry entry;
  final FormDraft draft;
}

/// Prepared outside an IndexedDB write transaction. [raw] is retained exactly:
/// neither CAS nor immutable history may use a re-encoded equivalent instead.
class PreparedFormDraftHistoryValue {
  const PreparedFormDraftHistoryValue._({
    required this.raw,
    required this.validJson,
    required this.json,
    required this.draft,
    required this.compact,
  });
  final String? raw;
  final bool validJson;
  final Map<String, dynamic>? json;
  final FormDraft? draft;
  final String? compact;
  bool get terminal => json?['completed'] == true && json?['id'] is String;
}

Future<PreparedFormDraftHistoryValue> prepareFormDraftHistoryValue(
  String? value,
) async {
  if (value == null) {
    return const PreparedFormDraftHistoryValue._(
      raw: null,
      validJson: true,
      json: null,
      draft: null,
      compact: null,
    );
  }
  Map<String, dynamic>? json;
  try {
    json = await decodeJsonResponsive(value) as Map<String, dynamic>;
  } on FormatException {
    // Unsupported/corrupt originals stay unchanged and outside the index.
  } on TypeError {
    // Preserve the same malformed-envelope behavior as the synchronous API.
  }
  FormDraft? draft;
  if (json != null) {
    try {
      draft = FormDraft.fromJson(json);
    } on FormatException {
      // Terminal and future-version envelopes need not be restorable drafts.
    } on TypeError {
      // Keep the original bytes for recovery.
    } on ArgumentError {
      // Unknown metadata does not hide healthy sibling records.
    }
  }
  final compact = json?['completed'] == true
      ? await encodeJsonResponsive({
          for (final key in const [
            'version',
            'id',
            'completed',
            'revision',
            'completedAt',
            'historyAction',
            'storageVersion',
          ])
            if (json!.containsKey(key)) key: json[key],
        })
      : value;
  return PreparedFormDraftHistoryValue._(
    raw: value,
    validJson: json != null,
    json: json,
    draft: draft,
    compact: compact,
  );
}

Future<FormDraft?> decodeFormDraftHistoryPayloadResponsive(
  String? value,
) async => (await prepareFormDraftHistoryValue(value)).draft;

Future<bool> isFormDraftTerminalMarkerResponsive(String? value) async =>
    (await prepareFormDraftHistoryValue(value)).terminal;

Future<String?> compactFormDraftTerminalMarkerResponsive(String? value) async =>
    (await prepareFormDraftHistoryValue(value)).compact;

FormDraftHistoryChange? preparedFormDraftHistoryChange(
  String key,
  PreparedFormDraftHistoryValue existing,
  PreparedFormDraftHistoryValue next, {
  bool importing = false,
}) {
  if (!next.validJson) return null;
  final terminal = next.raw == null || next.json?['completed'] == true;
  final source = importing || !terminal ? next : existing;
  final draft = source.draft;
  if (draft == null || key != '${formDraftHistoryPrefix(key)}${draft.id}') {
    return null;
  }
  return FormDraftHistoryChange(
    draft,
    source.raw!,
    importing
        ? FormDraftHistoryAction.imported
        : terminal
        ? (next.raw == null || next.json?['historyAction'] == 'deleted'
              ? FormDraftHistoryAction.deleted
              : FormDraftHistoryAction.completed)
        : FormDraftHistoryAction.saved,
  );
}

Future<FormDraftHistoryChange?> formDraftHistoryChangeResponsive(
  String key,
  String? existing,
  String? value, {
  bool importing = false,
}) async => preparedFormDraftHistoryChange(
  key,
  await prepareFormDraftHistoryValue(existing),
  await prepareFormDraftHistoryValue(value),
  importing: importing,
);

String? formDraftHistoryPrefix(String key) {
  final split = key.lastIndexOf('_');
  return split < 1 ? null : key.substring(0, split + 1);
}

void validateFormDraftHistoryPrefix(String prefix) {
  if (!RegExp(r'^[a-zA-Z0-9_-]+_$').hasMatch(prefix)) {
    throw const FormatException('草稿历史身份无效');
  }
}

int formDraftHistorySequence(String id) {
  if (!RegExp(r'^[1-9][0-9]{0,14}$').hasMatch(id)) {
    throw const FormatException('草稿历史游标无效');
  }
  return int.parse(id);
}

int formDraftHistoryLimit(int limit) {
  if (limit < 1 || limit > 100) throw RangeError.range(limit, 1, 100, 'limit');
  return limit;
}

FormDraft? decodeFormDraftHistoryPayload(String? value) {
  if (value == null) return null;
  try {
    return FormDraft.fromJson(jsonDecode(value) as Map<String, dynamic>);
  } on FormatException {
    return null;
  } on TypeError {
    return null;
  } on ArgumentError {
    return null;
  }
}

bool isFormDraftTerminalMarker(String? value) {
  if (value == null) return false;
  try {
    final json = jsonDecode(value) as Map<String, dynamic>;
    return json['completed'] == true && json['id'] is String;
  } on FormatException {
    return false;
  } on TypeError {
    return false;
  }
}

/// A terminal marker fences stale writers while the original immutable payload
/// is retained separately. Memory/test stores may retain the full marker too.
String? compactFormDraftTerminalMarker(String? value) {
  if (value == null) return null;
  try {
    final json = jsonDecode(value) as Map<String, dynamic>;
    if (json['completed'] != true) return value;
    return jsonEncode({
      for (final key in [
        'version',
        'id',
        'completed',
        'revision',
        'completedAt',
        'historyAction',
        'storageVersion',
      ])
        if (json.containsKey(key)) key: json[key],
    });
  } on FormatException {
    return value;
  } on TypeError {
    return value;
  }
}

class FormDraftHistoryChange {
  const FormDraftHistoryChange(this.draft, this.payload, this.action);
  final FormDraft draft;
  final String payload;
  final FormDraftHistoryAction action;

  FormDraftHistoryEntry entry(int sequence) => FormDraftHistoryEntry(
    id: '$sequence',
    draftId: draft.id,
    module: draft.module,
    route: draft.route,
    permission: draft.permission,
    draftKind: draft.draftKind,
    revision: draft.revision,
    recordedAt: DateTime.now().toUtc(),
    action: action,
  );
}

FormDraftHistoryChange? formDraftHistoryChange(
  String key,
  String? existing,
  String? value, {
  bool importing = false,
}) {
  Map<String, dynamic>? next;
  try {
    if (value != null) next = jsonDecode(value) as Map<String, dynamic>;
  } on FormatException {
    return null;
  } on TypeError {
    return null;
  }
  final terminal = value == null || next?['completed'] == true;
  final payload = importing
      ? value
      : terminal
      ? existing
      : value;
  final draft = decodeFormDraftHistoryPayload(payload);
  if (draft == null || key != '${formDraftHistoryPrefix(key)}${draft.id}') {
    return null;
  }
  return FormDraftHistoryChange(
    draft,
    payload!,
    importing
        ? FormDraftHistoryAction.imported
        : terminal
        ? (value == null || next?['historyAction'] == 'deleted'
              ? FormDraftHistoryAction.deleted
              : FormDraftHistoryAction.completed)
        : FormDraftHistoryAction.saved,
  );
}
