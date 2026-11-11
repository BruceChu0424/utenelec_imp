import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/feedback/uten_date_range_picker.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/components/inputs/uten_date_range_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/stock_ledger/stock_ledger_models.dart';
import 'package:uten_imp/core/utils/china_datetime.dart';
import 'package:uten_imp/core/utils/date_range_defaults.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/stock_ledger/widgets/goods_stock_ledger_view.dart';

class _LedgerApi extends ApiClient {
  _LedgerApi({this.rowCount = 1}) : super(Dio());
  final int rowCount;
  final queries = <Map<String, dynamic>>[];
  Completer<void>? ledgerGate;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/ledger')) {
      queries.add({...?query});
      await ledgerGate?.future;
      final page = query?['page'] as int? ?? 1;
      final size = query?['size'] as int? ?? 50;
      return {
        'items': [
          for (
            var index = (page - 1) * size;
            index < rowCount && index < page * size;
            index++
          )
            {
              'rowKind': 'M',
              'id': 'movement-${index + 1}',
              'transactionDate': '2024-02-01T00:00:00Z',
              'movementType': '1',
              'direction': 1,
              'qtySigned': 1,
            },
        ],
        'page': page,
        'size': size,
        'total': rowCount,
        'totalPages': (rowCount / size).ceil(),
        'summary': {'openingQty': 10, 'closingQty': 10},
      };
    }
    return {};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];
}

void main() {
  testWidgets('流水201条按50→50→100→200阶梯完整读取，保留最后业务身份', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final api = _LedgerApi(rowCount: 201);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          sharedPreferencesProvider.overrideWithValue(preferences),
          currentPermissionsProvider.overrideWithValue(const {Perm.stockView}),
          isSuperAdminProvider.overrideWithValue(false),
        ],
        child: const MaterialApp(
          locale: Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: GoodsStockLedgerView(goodsId: 'goods-1')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final table = tester.widget<MasterDataTableView<StockLedgerRow>>(
      find.byType(MasterDataTableView<StockLedgerRow>),
    );
    expect(table.items, hasLength(201));
    expect(table.items.last.id, 'movement-201');
    // 渐进阶梯：首批 50，续批按 offset 对齐 50 → 100 → 200。
    expect(api.queries.map((query) => query['page']), [1, 2, 2, 2]);
    expect(api.queries.map((query) => query['size']), [50, 50, 100, 200]);
    expect(table.totalPages, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets('流水默认近月，单入口取消保留范围并用完整新范围重查', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final api = _LedgerApi();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          sharedPreferencesProvider.overrideWithValue(preferences),
          currentPermissionsProvider.overrideWithValue(const {Perm.stockView}),
          isSuperAdminProvider.overrideWithValue(false),
        ],
        child: const MaterialApp(
          locale: Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: GoodsStockLedgerView(goodsId: 'goods-1')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final defaults = recentMonthDateRange();
    expect(
      api.queries.single['dateFrom'],
      ChinaDateTime.formatDate(defaults.start),
    );
    expect(
      api.queries.single['dateTo'],
      ChinaDateTime.formatDate(defaults.end),
    );
    final entry = find.byType(UtenDateRangeButton);
    expect(entry, findsOneWidget);
    expect(tester.widget<UtenDateRangeButton>(entry).onClear, isNull);
    final button = find.descendant(
      of: entry,
      matching: find.byType(UtenButton),
    );
    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(api.queries, hasLength(1));
    await tester.tap(button);
    await tester.pumpAndSettle();
    Navigator.of(
      tester.element(find.byType(UtenDateRangePickerDialog)),
    ).pop((start: DateTime(2024, 2), end: DateTime(2024, 2, 29)));
    await tester.pumpAndSettle();
    expect(api.queries, hasLength(2));
    expect(api.queries.last['dateFrom'], '2024-02-01');
    expect(api.queries.last['dateTo'], '2024-02-29');
    expect(api.queries.last['page'], 1);
    await tester.tap(find.textContaining(RegExp(r'^日期')));
    await tester.pumpAndSettle();
    expect(find.byType(UtenBusyOverlay), findsNothing);
    api.ledgerGate = Completer<void>();
    Navigator.of(
      tester.element(find.byType(UtenDateRangePickerDialog)),
    ).pop(DateTimeRange(start: DateTime(2024, 3), end: DateTime(2024, 3, 31)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(UtenBusyOverlay), findsOneWidget);
    expect(api.queries.last['dateFrom'], '2024-03-01');
    expect(api.queries.last['dateTo'], '2024-03-31');
    api.ledgerGate!.complete();
    await tester.pumpAndSettle();
    expect(find.byType(UtenBusyOverlay), findsNothing);
    await tester.tap(button);
    await tester.pumpAndSettle();
    api.ledgerGate = Completer<void>();
    Navigator.of(
      tester.element(find.byType(UtenDateRangePickerDialog)),
    ).pop((start: DateTime(2024, 4), end: DateTime(2024, 4, 30)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    MasterDataTableView<StockLedgerRow> table() =>
        tester.widget(find.byKey(const Key('stock-item-ledger-table')));
    expect(table().items, isEmpty);
    expect(table().summaryBar, isNull);
    api.ledgerGate!.completeError(ApiException('TEMPORARY', '当前日期暂时无法读取'));
    await tester.pumpAndSettle();
    expect(find.byType(UtenBusyOverlay), findsNothing);
    expect(table().items, isEmpty);
    expect(table().summaryBar, isNull);
    // 2026-11-09 起完整读取失败消息追加匿名关联号（a7a54d709），按前缀匹配。
    expect(table().error, startsWith('当前日期暂时无法读取（关联号 '));
    expect(tester.takeException(), isNull);
  });
}
