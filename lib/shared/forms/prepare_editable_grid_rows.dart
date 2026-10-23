import '../../components/layout/uten_editable_grid.dart';
import '../../core/performance/ui_work_budget.dart';
import '../drafts/form_draft_field_codec.dart';

/// Builds a complete private row set before transferring it to [publish].
///
/// Creation and initialization are separate so even the row whose initializer
/// throws is owned and disposed. [publish] is synchronous and takes ownership
/// of the whole list; no partial rows are exposed during preparation.
Future<void> prepareEditableGridRows<S, R extends EditableGridRow>(
  Iterable<S> source, {
  required R Function(S value) create,
  required void Function(R row, S value) initialize,
  required void Function(List<R> rows) publish,
  required bool Function() isCurrent,
  bool Function()? canPublish,
  Future<void> Function(List<R> rows)? beforePublish,
  UiWorkBudget? budget,
}) async {
  final values = List<S>.of(source, growable: false);
  final rows = <R>[];
  final work = budget ?? UiWorkBudget(debugLabel: 'editor-row-prepare');
  var transferred = false;
  void ensureCurrent() {
    work.ensureCurrent();
    if (!isCurrent()) throw const UiWorkCancelled();
  }

  try {
    ensureCurrent();
    for (final value in values) {
      final row = create(value);
      rows.add(row);
      initialize(row, value);
      await work.checkpoint();
      ensureCurrent();
    }
    if (beforePublish != null) {
      await beforePublish(rows);
      ensureCurrent();
    }
    ensureCurrent();
    if (canPublish?.call() == false) throw const UiWorkCancelled();
    // The synchronous receiver owns the rows from this point, just as with
    // addRows/replaceAll. It must not start an asynchronous partial install.
    transferred = true;
    publish(rows);
  } finally {
    if (!transferred) await disposePreparedEditableGridRows(rows);
  }
}

Future<void> disposePreparedEditableGridRows(
  Iterable<EditableGridRow> rows,
) async {
  final work = UiWorkBudget(debugLabel: 'editor-row-prepare-dispose');
  for (final row in rows) {
    row.dispose();
    await work.checkpoint();
  }
}

/// Preserves raw draft text and row-order selection while preparing privately.
Future<void> restoreDraftGridResponsive<R extends EditableGridRow>(
  UtenEditableGridController<R> grid,
  Object? value, {
  required R Function(Map<String, dynamic> value) create,
  required void Function(R row, Map<String, dynamic> value) initialize,
  required bool Function() isCurrent,
}) async {
  final maps = draftMaps(value);
  await prepareEditableGridRows(
    maps,
    create: create,
    initialize: initialize,
    isCurrent: isCurrent,
    publish: (List<R> rows) {
      grid.clearSelection();
      grid.replaceAll(rows);
      grid.setSelected([
        for (var i = 0; i < rows.length; i++)
          if (maps[i]['selected'] == true) rows[i],
      ], true);
    },
  );
}
