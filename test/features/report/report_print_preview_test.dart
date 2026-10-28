import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';
import 'package:uten_imp/features/report/shared/report_print_preview.dart';
import 'package:uten_imp/features/report/shared/account_statement_column_query.dart';
import 'package:uten_imp/features/report/shared/report_column.dart';

class _Api extends ApiClient {
  _Api(this.pages) : super(Dio());
  final List<List<Map<String, dynamic>>> pages;
  final requests = <Map<String, dynamic>>[];
  int? total;
  int? totalPages;
  int? actualSize;
  bool changeSchema = false;
  bool changeVersion = false;
  void Function(int page)? afterRead;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    final page = query!['page'] as int;
    requests.add(Map.of(query));
    afterRead?.call(page);
    return {
      'page': page,
      if (actualSize != null) 'size': actualSize,
      if (total != null) 'total': total,
      if (totalPages != null) 'totalPages': totalPages,
      'readScopeVersion': changeVersion && page > 1 ? 'changed' : 'same',
      if (page == 1 || changeSchema)
        'columns': [
          {
            'key': changeSchema && page > 1 ? 'different' : 'value',
            'label': '值',
            'type': 'text',
          },
        ],
      'rows': page <= pages.length ? pages[page - 1] : <Map<String, dynamic>>[],
    };
  }
}

void main() {
  test(
    'domain display overrides preserve explicit null rather than falling back to a raw fact',
    () async {
      final api =
          _Api([
              [
                {'value': 'raw-must-not-return'},
              ],
            ])
            ..total = 1
            ..totalPages = 1;
      final result = await loadBoundedReportPrintPreview(
        api: api,
        endpointOf: () => '/report',
        queryOf: () => const {},
        isCurrent: () => true,
        cellTextOf: (_, _) => null,
      );
      expect(result.rows, [
        [''],
      ]);
      expect(
        formatAccountStatementReportCell(
          const ReportColumn(key: 'entryKind', label: '流水', type: 'text'),
          {'entryKind': 'REVERSAL'},
        ),
        '反向流水',
      );
      expect(
        formatAccountStatementReportCell(
          const ReportColumn(key: 'sourceDocType', label: '来源', type: 'text'),
          {'sourceDocType': 'PAYMENT'},
        ),
        '付款',
      );
    },
  );
  test(
    'unknown counts and a server-clamped short page continue until the real end',
    () async {
      final api = _Api([
        [
          {'id': 'same-document', 'value': 'A'},
          {'id': 'same-document', 'value': 'B'},
        ],
        [
          {'id': 'same-document', 'value': 'C'},
        ],
      ])..actualSize = 2;
      final result = await loadBoundedReportPrintPreview(
        api: api,
        endpointOf: () => '/report',
        queryOf: () => {'search.name': '条件', 'order': 'asc'},
        isCurrent: () => true,
      );
      expect(result.rows, [
        ['A'],
        ['B'],
        ['C'],
      ]);
      expect(result.rowIds, [
        'same-document',
        'same-document',
        'same-document',
      ]);
      expect(api.requests.map((query) => query['page']), [1, 2, 3]);
      expect(api.requests.map((query) => query['size']), everyElement(500));
      expect(
        api.requests.map((query) => query['search.name']),
        everyElement('条件'),
      );
      expect(
        api.requests.map((query) => query['includeCount']),
        everyElement(false),
      );
      expect(api.requests.map((query) => query['includeColumns']), [
        true,
        false,
        false,
      ]);
    },
  );

  test(
    'preview prefix is bounded without changing page size or removing duplicate head IDs',
    () async {
      final api =
          _Api([
              [
                {'id': 'head', 'value': 'A'},
                {'id': 'head', 'value': 'B'},
              ],
              [
                {'id': 'head', 'value': 'C'},
                {'id': 'head', 'value': 'D'},
              ],
            ])
            ..total = 100
            ..totalPages = 50
            ..actualSize = 2;
      final result = await loadBoundedReportPrintPreview(
        api: api,
        endpointOf: () => '/report',
        queryOf: () => const {},
        isCurrent: () => true,
        rowLimit: 3,
      );
      expect(result.rows, [
        ['A'],
        ['B'],
        ['C'],
      ]);
      expect(api.requests.map((query) => query['size']), [500, 500]);
      expect(result.factValues!.last['value'], 'C');
    },
  );

  test(
    'known end avoids an extra request and premature empty pages fail closed',
    () async {
      final api =
          _Api([
              [
                {'value': 'A'},
                {'value': 'B'},
              ],
              [
                {'value': 'C'},
              ],
            ])
            ..total = 3
            ..totalPages = 2;
      final result = await loadBoundedReportPrintPreview(
        api: api,
        endpointOf: () => '/report',
        queryOf: () => const {},
        isCurrent: () => true,
      );
      expect(result.rows.length, 3);
      expect(api.requests.length, 2);
      final missing = _Api([
        [
          {'value': 'A'},
        ],
      ])..total = 3;
      await expectLater(
        loadBoundedReportPrintPreview(
          api: missing,
          endpointOf: () => '/report',
          queryOf: () => const {},
          isCurrent: () => true,
        ),
        throwsFormatException,
      );
    },
  );

  for (final schema in [true, false]) {
    test(
      '${schema ? 'column schema' : 'read scope'} cannot change between preview pages',
      () async {
        final api =
            _Api([
                [
                  {'value': 'A'},
                ],
                [
                  {'value': 'B'},
                ],
              ])
              ..changeSchema = schema
              ..changeVersion = !schema;
        await expectLater(
          loadBoundedReportPrintPreview(
            api: api,
            endpointOf: () => '/report',
            queryOf: () => const {},
            isCurrent: () => true,
          ),
          throwsFormatException,
        );
      },
    );
  }

  test(
    'query changes retire the entire preview before any partial publication',
    () async {
      var filter = 'first';
      final api = _Api([
        [
          {'value': 'A'},
        ],
      ])..afterRead = (_) => filter = 'second';
      await expectLater(
        loadBoundedReportPrintPreview(
          api: api,
          endpointOf: () => '/report',
          queryOf: () => {'search.value': filter},
          isCurrent: () => true,
        ),
        throwsA(isA<UiWorkCancelled>()),
      );
      expect(api.requests.length, 1);
    },
  );
}
