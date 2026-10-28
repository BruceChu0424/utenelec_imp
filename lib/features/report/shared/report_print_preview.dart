import 'package:collection/collection.dart';

import '../../../components/print/uten_print_preview.dart';
import '../../../core/network/api_client.dart';
import '../../../core/performance/ui_work_budget.dart';
import '../../../shared/paging/paged_query_identity.dart';
import '../../../shared/measurement/weight_unit.dart';
import 'report_cell.dart';
import 'report_column.dart';
import 'report_data.dart';
import 'report_metadata_reuse.dart';

/// Load the declared prefix of a report, respecting actual server paging. This
/// differs from complete entity printing: repeated document IDs are valid rows,
/// metadata counts may be disabled, and the existing 2,000-row limit stays put.
Future<UtenPrintTable> loadBoundedReportPrintPreview({
  required ApiClient api,
  required String Function() endpointOf,
  required Map<String, dynamic> Function() queryOf,
  required bool Function() isCurrent,
  int rowLimit = 2000,
  int pageSize = 500,
  WeightDisplay weightDisplay = WeightDisplay.auto,
  String? Function(ReportColumn column, Map<String, dynamic> row)? cellTextOf,
  Future<Map<String, dynamic>> Function(
    String endpoint,
    Map<String, dynamic> query,
  )?
  fetch,
}) async {
  if (rowLimit < 1 || rowLimit > 2000 || pageSize < 1 || pageSize > 500) {
    throw ArgumentError('Invalid bounded report preview limit');
  }
  const equality = DeepCollectionEquality();
  final endpoint = endpointOf();
  final query = Map<String, dynamic>.unmodifiable({
    for (final entry in queryOf().entries)
      entry.key: freezePagedReadQuery(entry.value),
  });
  var retired = false;
  bool current() {
    if (retired || !isCurrent()) {
      retired = true;
      return false;
    }
    if (endpoint != endpointOf() || !equality.equals(query, queryOf())) {
      retired = true;
    }
    return !retired;
  }

  final scope = await api.captureRequestScope(isCurrent: current);
  return scope.run(() async {
    final work = UiWorkBudget(
      isCurrent: current,
      debugLabel: 'report.print-preview',
    );
    List<ReportColumn>? columns;
    String? readScopeVersion;
    int? knownTotal, knownPages, effectiveSize;
    final rows = <List<String>>[];
    final ids = <String?>[];
    final facts = <Map<String, String?>>[];
    for (var page = 1; rows.length < rowLimit; page++) {
      work.ensureCurrent();
      final parameters = <String, dynamic>{
        ...query,
        ...reportRowsOnlyQuery,
        'page': page,
        'size': pageSize,
        'includeColumns': page == 1,
      };
      final json = await (fetch == null
          ? api.get(endpoint, query: parameters)
          : fetch(endpoint, parameters));
      work.ensureCurrent();
      if (json['page'] case final num echoedPage
          when echoedPage.toInt() != page) {
        throw const FormatException('打印分页位置已变化，请刷新后重试');
      }
      if (json['size'] case final num actualSize when actualSize > 0) {
        if (effectiveSize != null && effectiveSize != actualSize.toInt()) {
          throw const FormatException('打印分页大小已变化，请刷新后重试');
        }
        effectiveSize = actualSize.toInt();
      }
      final data = await parseReportResponseResponsive(
        json,
        page,
        isCurrent: current,
      );
      final nextVersion = data.readScopeVersion;
      if (readScopeVersion != null &&
          nextVersion != null &&
          readScopeVersion != nextVersion) {
        throw const FormatException('打印读取范围已变化，请刷新后重试');
      }
      readScopeVersion ??= nextVersion;
      if (columns == null) {
        columns = List.unmodifiable(data.columns);
      } else if (data.columns.isNotEmpty &&
          !equality.equals(
            columns.map(_columnIdentity).toList(),
            data.columns.map(_columnIdentity).toList(),
          )) {
        throw const FormatException('打印字段已变化，请刷新后重试');
      }
      if (columns.isEmpty && data.rows.isNotEmpty) {
        throw const FormatException('打印字段缺失，请刷新后重试');
      }
      if (json['total'] case final num total when total >= 0) {
        if (knownTotal != null && knownTotal != total.toInt()) {
          throw const FormatException('打印记录范围已变化，请刷新后重试');
        }
        knownTotal = total.toInt();
      }
      if (json['totalPages'] case final num pages when pages > 0) {
        if (knownPages != null && knownPages != pages.toInt()) {
          throw const FormatException('打印页数已变化，请刷新后重试');
        }
        knownPages = pages.toInt();
      }
      for (final row in data.rows) {
        if (rows.length == rowLimit) break;
        final cells = <String>[];
        for (final column in columns) {
          final text = cellTextOf == null
              ? formatReportCell(column, row, weightDisplay: weightDisplay)
              : cellTextOf(column, row);
          cells.add(text ?? '');
          await work.checkpoint();
        }
        final fact = <String, String?>{};
        for (final entry in row.entries) {
          fact[entry.key] = entry.value?.toString();
          await work.checkpoint();
        }
        rows.add(List.unmodifiable(cells));
        ids.add(row['id']?.toString());
        facts.add(Map.unmodifiable(fact));
        await work.checkpoint();
      }
      if (rows.length == rowLimit) break;
      if (data.rows.isEmpty ||
          (knownPages != null && page >= knownPages) ||
          (knownTotal != null && rows.length >= knownTotal)) {
        if (knownTotal != null && rows.length != knownTotal) {
          throw const FormatException('打印记录未完整返回，请刷新后重试');
        }
        break;
      }
      // A short page is not an end marker: this server may clamp to 20/100.
      // Each continuing page adds at least one row, so requests remain bounded.
      await work.checkpoint(256);
    }
    work.ensureCurrent();
    await scope.verify();
    final frozen = columns ?? const <ReportColumn>[];
    return UtenPrintTable(
      columnKeys: List.unmodifiable(frozen.map((column) => column.key)),
      headers: List.unmodifiable(frozen.map((column) => column.label)),
      rows: List.unmodifiable(rows),
      rowIds: List.unmodifiable(ids),
      factValues: List.unmodifiable(facts),
    );
  });
}

Object _columnIdentity(ReportColumn column) =>
    (column.key, column.label, column.type, column.unitKey, column.unitLabel);
