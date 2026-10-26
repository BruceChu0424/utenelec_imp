import '../../core/performance/ui_work_budget.dart';
import '../../shared/models/paged_result.dart';
import '../../shared/paging/complete_paged_snapshot.dart';
import 'uten_print_preview.dart';

/// Freezes full membership before producing paper rows; a page/size request is
/// never assumed to override the server's page-size ceiling.
Future<UtenPrintTable> loadCompletePrintSnapshot<T>({
  required Future<PagedResult<T>> Function(int page, int size) loadPage,
  required String Function(T row) idOf,
  required List<String> headers,
  required List<String> columnKeys,
  required List<String> Function(T row) cellsOf,
  required bool Function() isCurrent,
  Map<String, String?> Function(T row)? factsOf,
  bool includeRowIds = true,
  UiWorkBudget? budget,
}) async {
  final work = budget ?? UiWorkBudget(isCurrent: isCurrent);
  final frozenHeaders = List<String>.unmodifiable(headers);
  final frozenKeys = List<String>.unmodifiable(columnKeys);
  if (frozenHeaders.length != frozenKeys.length ||
      frozenKeys.toSet().length != frozenKeys.length) {
    throw const FormatException('打印字段缺失或重复，请刷新后重试');
  }
  final items = await loadCompletePagedSnapshot(
    loadPage: loadPage,
    idOf: idOf,
    isCurrent: isCurrent,
    budget: work,
  );
  final rows = <List<String>>[], ids = <String>[];
  final facts = factsOf == null ? null : <Map<String, String?>>[];
  for (final item in items) {
    final cells = cellsOf(item);
    if (cells.length != frozenKeys.length) {
      throw const FormatException('打印数据列数不一致，请刷新后重试');
    }
    final copy = <String>[];
    for (final cell in cells) {
      copy.add(cell);
      await work.checkpoint();
    }
    rows.add(copy);
    ids.add(idOf(item));
    if (factsOf != null) facts!.add(Map.unmodifiable(factsOf(item)));
    await work.checkpoint();
  }
  work.ensureCurrent();
  if (!isCurrent()) throw const UiWorkCancelled();
  return UtenPrintTable(
    headers: frozenHeaders,
    columnKeys: frozenKeys,
    rows: rows,
    rowIds: includeRowIds ? ids : null,
    factValues: facts,
  );
}
