import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/components/print/uten_print_preview.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/platform_tables/table_column_projection.dart';
import 'package:uten_imp/features/sales/config/sales_report_config.dart';
import 'package:uten_imp/features/sales/pages/sales_report_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  testWidgets(
    'client detail print binds its own selectable rows while retaining client and currency filters',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final projections = TableColumnProjectionController();
      addTearDown(projections.dispose);
      final api = _SalesReportApi(withDetails: true);
      await tester.binding.setSurfaceSize(const Size(1500, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            sharedPreferencesProvider.overrideWithValue(prefs),
            currentPermissionsProvider.overrideWithValue(const <String>{}),
          ],
          child: MaterialApp(
            home: TableColumnProjectionScope(
              controller: projections,
              child: const SalesClientDetailDialog(
                docType: SalesReportDocType.order,
                docSeg: 'orders',
                clientId: 'client-1',
                currencyId: 'currency-usd',
                clientName: '甲客户',
                dateFrom: '2026-10-01',
                dateTo: '2026-11-01',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
        find.byType(MasterDataTableView<Map<String, dynamic>>),
      );
      final print = tester.widget<UtenPrintPreviewButton>(
        find.byType(UtenPrintPreviewButton),
      );
      expect(table.outputSelectionEnabled, isTrue);
      expect(print.tableKey, table.tableKey);
      await tester.tap(find.text('明细物料一'));
      await tester.pumpAndSettle();
      final selection = await tester.runAsync(
        () => projections.tables.single.outputSelection.snapshot(),
      );
      expect(selection!.count, 1);
      expect(selection.rows.single['lineId'], 'line-1');
      final all = await tester.runAsync(print.loader);
      final selected = await tester.runAsync(
        () => selectUtenPrintRows(all!, selection),
      );
      expect(selected!.rows, hasLength(1));
      expect(selected.rows.single.single, '明细物料一');
      expect(
        api.detailQueries.every(
          (query) =>
              query['clientId'] == 'client-1' &&
              query['currencyId'] == 'currency-usd',
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'order summary drills the same client into the selected currency only',
    (tester) async {
      SharedPreferences.setMockInitialValues(const {});
      final prefs = await SharedPreferences.getInstance();
      final api = _SalesReportApi();

      await tester.binding.setSurfaceSize(const Size(1500, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            sharedPreferencesProvider.overrideWithValue(prefs),
            currentPermissionsProvider.overrideWithValue(const <String>{}),
          ],
          child: const MaterialApp(
            home: SalesReportPage(kind: SalesReportKind.summary),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('USD'), findsOneWidget);
      expect(find.text('CNY'), findsOneWidget);

      // 新交互契约：报表行单击只选中，双击才下钻。
      await tester.tap(find.text('USD'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('USD'));
      await tester.pumpAndSettle();

      expect(api.detailQueries, hasLength(1));
      expect(api.detailQueries.single, containsPair('clientId', 'client-1'));
      expect(
        api.detailQueries.single,
        containsPair('currencyId', 'currency-usd'),
      );

      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('CNY'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('CNY'));
      await tester.pumpAndSettle();

      expect(api.detailQueries, hasLength(2));
      expect(api.detailQueries.last, containsPair('clientId', 'client-1'));
      expect(
        api.detailQueries.last,
        containsPair('currencyId', 'currency-cny'),
      );
      expect(api.detailQueries.map((query) => query['currencyId']).toSet(), {
        'currency-usd',
        'currency-cny',
      });
    },
  );
}

class _SalesReportApi extends ApiClient {
  _SalesReportApi({this.withDetails = false}) : super(Dio());
  final bool withDetails;

  final detailQueries = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/sales/reports/ORDER/summary') {
      return const <String, dynamic>{
        'columns': <Map<String, dynamic>>[
          {'key': 'clientName', 'label': '客户', 'type': 'text', 'width': 200},
          {'key': 'currencyCode', 'label': '币别', 'type': 'text', 'width': 80},
          {
            'key': 'totalAmount',
            'label': '订货总额',
            'type': 'money',
            'width': 120,
          },
        ],
        'rows': <Map<String, dynamic>>[
          {
            '__clientId': 'client-1',
            '__currencyId': 'currency-usd',
            'clientName': '甲客户',
            'currencyCode': 'USD',
            'totalAmount': 100,
          },
          {
            '__clientId': 'client-1',
            '__currencyId': 'currency-cny',
            'clientName': '甲客户',
            'currencyCode': 'CNY',
            'totalAmount': 720,
          },
        ],
        'facets': <String, dynamic>{},
        'page': 1,
        'size': 50,
        'total': 2,
        'totalPages': 1,
      };
    }
    if (path == '/sales/reports/ORDER/detail') {
      detailQueries.add(Map<String, dynamic>.of(query ?? const {}));
      if (withDetails) {
        return {
          'columns': [
            {'key': 'goodsName', 'label': '货品名称', 'type': 'text', 'width': 220},
          ],
          'rows': [
            {'lineId': 'line-1', '__srcId': 'order-1', 'goodsName': '明细物料一'},
            {'lineId': 'line-2', '__srcId': 'order-1', 'goodsName': '明细物料二'},
          ],
          'facets': <String, dynamic>{},
          'page': 1,
          'size': query?['size'] ?? 50,
          'total': 2,
          'totalPages': 1,
        };
      }
      return const <String, dynamic>{
        'columns': <Map<String, dynamic>>[],
        'rows': <Map<String, dynamic>>[],
        'facets': <String, dynamic>{},
        'page': 1,
        'size': 50,
        'total': 0,
        'totalPages': 1,
      };
    }
    throw StateError('unexpected GET $path');
  }
}
