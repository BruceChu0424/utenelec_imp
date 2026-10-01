import '../platform_tables/platform_row_draft.dart';

/// One persisted business row. Derived presentation rows must not be included.
/// The local identity is independent of goods/source IDs and server record IDs.
class IdentifiedPlatformDraftRow {
  const IdentifiedPlatformDraftRow(this.localId, this.fields);
  final String localId;
  final PlatformRowDraft fields;
}

const _format = 'identified-platform-rows-v1';

Map<String, PlatformRowDraft> _targets(
  Iterable<IdentifiedPlatformDraftRow> rows,
) {
  final result = <String, PlatformRowDraft>{};
  for (final row in rows) {
    if (row.localId.trim().isEmpty || result.containsKey(row.localId)) {
      throw StateError('草稿产品行身份缺失或重复，原草稿保留，请核对后恢复');
    }
    result[row.localId] = row.fields;
  }
  return result;
}

Object captureIdentifiedPlatformDrafts(
  Iterable<IdentifiedPlatformDraftRow> rows,
) => {
  'format': _format,
  'rows': [
    for (final entry in _targets(rows).entries)
      {'localId': entry.key, 'fields': entry.value.exportDraft()},
  ],
};

/// Blank catalog metadata is not user input. Explicit clears and touched cells
/// are input too, even when the resulting value is an empty string or null.
bool _hasInput(Object? raw) {
  if (raw is! Map) return raw != null;
  if (raw['dirty'] == true ||
      (raw['touched'] is List && (raw['touched'] as List).isNotEmpty)) {
    return true;
  }
  final cells = raw['cells'];
  if (cells == null) return false;
  if (cells is! List) return true;
  return cells.any((cell) {
    if (cell is! Map) return true;
    final value = cell['value'];
    return value != null && (value is! String || value.isNotEmpty);
  });
}

/// Validate the whole association before mutating any row. A legacy positional
/// snapshot cannot establish identity merely by having the same row count.
void restoreIdentifiedPlatformDrafts(
  Object? snapshot,
  Iterable<IdentifiedPlatformDraftRow> rows,
) {
  if (snapshot == null) return;
  final targets = _targets(rows);
  if (snapshot is List) {
    for (final grid in snapshot) {
      if (grid is! List || grid.any(_hasInput)) {
        throw StateError(
          '旧草稿含扩展字段，但未记录产品行身份，无法安全对应。'
          '原草稿和扩展值已保留，请核对原产品行；不会按行号或货品猜配。',
        );
      }
    }
    return;
  }
  if (snapshot is! Map ||
      snapshot['format'] != _format ||
      snapshot['rows'] is! List) {
    throw StateError('草稿扩展字段格式无法核对，原草稿保留');
  }
  final values = <String, Map<dynamic, dynamic>>{};
  for (final raw in snapshot['rows'] as List) {
    if (raw is! Map ||
        raw['localId'] is! String ||
        (raw['localId'] as String).trim().isEmpty ||
        raw['fields'] is! Map ||
        values.containsKey(raw['localId'])) {
      throw StateError('草稿扩展字段产品行身份缺失或重复，原草稿保留');
    }
    final id = raw['localId'] as String;
    final fields = raw['fields'] as Map;
    if (!targets.containsKey(id) && _hasInput(fields)) {
      throw StateError('草稿中的部分扩展字段找不到原产品行，原草稿保留，请核对后恢复');
    }
    values[id] = fields;
  }
  if (values.length != targets.length ||
      !values.keys.toSet().containsAll(targets.keys)) {
    throw StateError('草稿产品行与扩展字段身份清单不完整，原草稿保留，请核对后恢复');
  }
  // Parsing must also finish before mutating targets: malformed cells in a later
  // row must not leave earlier rows partially restored.
  final parsed = <String, PlatformRowDraft>{};
  try {
    for (final entry in values.entries) {
      if (!targets.containsKey(entry.key)) continue;
      final draft = PlatformRowDraft();
      parsed[entry.key] = draft;
      draft.restoreDraft(entry.value);
    }
    for (final entry in parsed.entries) {
      targets[entry.key]!.restoreDraft(entry.value.exportDraft());
    }
  } finally {
    for (final draft in parsed.values) {
      draft.dispose();
    }
  }
}
