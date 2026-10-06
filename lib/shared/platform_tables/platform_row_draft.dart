import 'package:flutter/widgets.dart';
import 'platform_table_models.dart';

/// Uncommitted metadata belongs to the business form, never account preferences.
class PlatformRowDraft extends ChangeNotifier {
  String? sourceRecordId;
  int version = 0;
  bool loaded = false;
  bool dirty = false;
  bool canWrite = false;
  bool priceVisible = true;
  final Map<String, PlatformColumnCell> _cells = {};
  final Map<String, TextEditingController> _controllers = {};
  final Set<String> _touched = {};
  Iterable<PlatformColumnCell> get cells => _cells.values.map(
    (cell) => PlatformColumnCell(
      columnId: cell.columnId,
      value: cell.masked || (!priceVisible && cell.definition.priceProtected)
          ? null
          : _controllers[cell.columnId]?.text ?? cell.value,
      definition: cell.definition,
      masked: cell.masked || (!priceVisible && cell.definition.priceProtected),
      persisted: cell.persisted,
    ),
  );
  bool ownsColumn(String id) =>
      _cells[id]?.persisted == true || _touched.contains(id);
  PlatformRowValues get snapshot => PlatformRowValues(
    recordId: sourceRecordId ?? '',
    version: version,
    canWrite: canWrite,
    cells: cells.toList(),
  );
  void adopt(PlatformRowValues row) {
    canWrite = row.canWrite;
    if (dirty ||
        (loaded && version > row.version) ||
        (sourceRecordId != null && sourceRecordId != row.recordId)) {
      return;
    }
    sourceRecordId = row.recordId;
    version = row.version;
    loaded = true;
    canWrite = row.canWrite;
    _cells
      ..clear()
      ..addEntries(row.cells.map((cell) => MapEntry(cell.columnId, cell)));
    // Metadata is normally adopted before an editor is opened. Do not touch any
    // controller already held by a user editor, even when its text is unchanged.
  }

  void setValue(PlatformColumnDefinition definition, String? value) {
    final previous = _cells[definition.id];
    _cells[definition.id] = PlatformColumnCell(
      columnId: definition.id,
      value: value,
      definition: definition,
      persisted: previous?.persisted ?? false,
    );
    final controller = _controllers[definition.id];
    if (controller != null) controller.text = value ?? '';
    _touched.add(definition.id);
    dirty = true;
    notifyListeners();
  }

  Map<String, dynamic> exportDraft() => {
    'sourceRecordId': sourceRecordId,
    'version': version,
    'loaded': loaded,
    'dirty': dirty,
    'canWrite': canWrite,
    'touched': _touched.toList(),
    'cells': [
      for (final cell in cells)
        {
          'columnId': cell.columnId,
          'value': cell.value,
          'definition': cell.definition.toJson(),
          'masked': cell.masked,
          'persisted': cell.persisted,
        },
    ],
  };
  void restoreDraft(Object? value) {
    if (value is! Map) return;
    final data = Map<String, dynamic>.from(value);
    sourceRecordId = data['sourceRecordId']?.toString();
    version = (data['version'] as num?)?.toInt() ?? 0;
    loaded = data['loaded'] == true;
    dirty = data['dirty'] == true;
    canWrite = data['canWrite'] == true;
    _cells.clear();
    _touched
      ..clear()
      ..addAll((data['touched'] as List? ?? []).whereType<String>());
    for (final raw in data['cells'] as List? ?? []) {
      if (raw is Map) {
        final cell = PlatformColumnCell.fromJson(
          Map<String, dynamic>.from(raw),
        );
        _cells[cell.columnId] = cell;
      }
    }
  }

  void copyFrom(PlatformRowDraft source) {
    restoreDraft(source.exportDraft());
    sourceRecordId = null;
    version = 0;
    loaded = false;
    canWrite = false;
    dirty = _cells.isNotEmpty;
  }

  Map<String, dynamic>? savePayload() => !loaded && !dirty
      ? null
      : {
          'sourceRecordId': ?sourceRecordId,
          'expectedVersion': version,
          'cells': [
            for (final cell in cells)
              if (cell.persisted || _touched.contains(cell.columnId))
                {
                  'columnId': cell.columnId,
                  'value': cell.masked || cell.definition.calculated
                      ? null
                      : cell.value,
                },
          ],
        };
  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    _controllers.clear();
    super.dispose();
  }
}
