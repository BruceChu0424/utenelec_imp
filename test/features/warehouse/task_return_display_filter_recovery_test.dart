import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/production/pages/production_material_increment_pages.dart';
import 'package:uten_imp/features/production/pages/production_overproduction_rate_pages.dart';
import 'package:uten_imp/features/warehouse/models/stock_doc.dart';
import 'package:uten_imp/features/warehouse/pages/stock_doc_list_page.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_stock_doc_segment.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/badge_summary_fixture.dart';

void main() {
  late SharedPreferences preferences;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
  });

  Widget app(Widget page, _ListApi api) {
    final router = GoRouter(
      routes: [GoRoute(path: '/', builder: (_, _) => page)],
    );
    addTearDown(router.dispose);
    return ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        sharedPreferencesProvider.overrideWithValue(preferences),
        currentPermissionsProvider.overrideWithValue({Perm.stockDocView}),
        isSuperAdminProvider.overrideWithValue(false),
        fixedBadgeSummaryOverride(badgeSummaryFixture()),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    );
  }

  for (final entry in [
    (
      const Scaffold(
        body: WarehouseStockDocSegment(docType: StockDocType.draw),
      ),
      'stock-doc-segment-issue-DRAW',
    ),
    (
      const StockDocListPage(docType: StockDocType.draw),
      'stock-doc-issue-DRAW',
    ),
  ]) {
    testWidgets('${entry.$2} 领料进度通过列头筛选并可清除', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1500, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _ListApi();
      await tester.pumpWidget(app(entry.$1, api));
      await tester.pumpAndSettle();
      await tester.tap(find.text('进行中'));
      await tester.pumpAndSettle();

      MasterDataTableView<StockDocListItem> table() =>
          tester.widget(find.byType(MasterDataTableView<StockDocListItem>));
      expect(find.byKey(Key(entry.$2)), findsNothing);
      expect(api.stockQueries.last['view'], 'ACTIVE');
      expect(api.stockQueries.last['status'], 1);
      expect(table().items.map((row) => row.issueStatus), [0, 1]);
      expect(table().facets['issueStatus']!.map((bucket) => bucket.value), [
        '0',
        '1',
      ]);

      table().onFilterChanged('issueStatus', '1');
      await tester.pumpAndSettle();
      expect(api.stockQueries.last['issueStatus'], 1);
      expect(table().items.map((row) => row.issueStatus), [1]);
      expect(table().filters['issueStatus'], '1');

      table().onFilterChanged('issueStatus', null);
      await tester.pumpAndSettle();
      expect(api.stockQueries.last.containsKey('issueStatus'), isFalse);
      expect(table().items.map((row) => row.issueStatus), [0, 1]);
      expect(table().filters['issueStatus'], isNull);
      await tester.tap(find.text('历史单据'));
      await tester.pumpAndSettle();
      expect(api.stockQueries.last['view'], 'HISTORY');
      expect(api.stockQueries.last.containsKey('status'), isFalse);
      expect(api.stockQueries.last.containsKey('issueStatus'), isFalse);
      expect(table().items.map((row) => row.issueStatus), [2]);
      expect(table().facets.containsKey('issueStatus'), isFalse);
      expect(table().selectable, isFalse);
      await tester.tap(find.text('进行中'));
      await tester.pumpAndSettle();
      expect(api.stockQueries.last['view'], 'ACTIVE');
      expect(api.stockQueries.last['status'], 1);
      expect(api.stockQueries.last.containsKey('issueStatus'), isFalse);
      expect(table().items.map((row) => row.issueStatus), [0, 1]);
      expect(table().filters['issueStatus'], isNull);
      expect(tester.takeException(), isNull);
    });
  }

  for (final entry in [
    (
      const ProductionMaterialIncrementListPage(),
      '/production/material-increments/requests',
    ),
    (
      const ProductionOverproductionRateListPage(),
      '/production/overproduction-rate/requests',
    ),
  ]) {
    testWidgets('${entry.$2} 从退回筛选恢复全部申请', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1500, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _ListApi();
      await tester.pumpWidget(app(entry.$1, api));
      await tester.pumpAndSettle();
      await tester.tap(find.text('已退回'));
      await tester.pumpAndSettle();
      expect(api.statusQueries.last, (entry.$2, 'RETURNED'));
      expect(find.text('申请-RETURNED'), findsOneWidget);
      expect(find.text('申请-PENDING'), findsNothing);

      await tester.tap(find.text('全部'));
      await tester.pumpAndSettle();
      expect(api.statusQueries.last, (entry.$2, 'ALL'));
      expect(find.text('申请-PENDING'), findsOneWidget);
      expect(find.text('申请-APPROVED'), findsOneWidget);
      expect(find.text('申请-RETURNED'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}

class _ListApi extends ApiClient {
  _ListApi() : super(Dio());
  final stockQueries = <Map<String, dynamic>>[];
  final statusQueries = <(String, String)>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/stock/docs') {
      stockQueries.add(Map<String, dynamic>.from(query ?? const {}));
      final history = query?['view'] == 'HISTORY';
      return _page([
        for (final progress in [0, 1, 2])
          // 部分出库仍有后续需求；完全发完的单据只留在历史。
          if ((progress == 2) == history &&
              (query?['issueStatus'] == null ||
                  query?['issueStatus'] == progress))
            {
              'id': 'draw-$progress',
              'docType': 'DRAW',
              'billNo': 'DRAW-$progress',
              'status': 1,
              'issueStatus': progress,
            },
      ]);
    }
    if (path == '/production/material-increments/requests' ||
        path == '/production/overproduction-rate/requests') {
      final status = query?['status'] as String;
      statusQueries.add((path, status));
      return _page([
        for (final state in ['PENDING', 'APPROVED', 'RETURNED'])
          if (status == 'ALL' || state == status)
            {
              'id': 'request-$state',
              'originalDemandId': 'demand-$state',
              'targetSegmentId': 'segment-$state',
              'segmentId': 'segment-$state',
              'goodsName': '申请-$state',
              'status': state,
              'rowVersion': 1,
            },
      ]);
    }
    return const {};
  }

  Map<String, dynamic> _page(List<Map<String, dynamic>> items) => {
    'items': items,
    'page': 1,
    'size': 20,
    'total': items.length,
    'totalPages': items.isEmpty ? 0 : 1,
  };
}
