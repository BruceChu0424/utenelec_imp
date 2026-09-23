import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/warehouse/models/stock_doc.dart';
import 'package:uten_imp/features/warehouse/pages/stock_doc_detail_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_draw_task_center_page.dart';
import 'package:uten_imp/features/warehouse/repositories/stock_doc_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import '../../helpers/document_scope_fixture.dart';

import '../../helpers/badge_summary_fixture.dart';

class _Repository extends StockDocRepository {
  _Repository() : super(ApiClient(Dio()), StockDocType.wdraw);
  final filters = <StockDocFilter>[];
  int approvals = 0;
  @override
  Future<PagedResult<StockDocListItem>> list({
    int page = 1,
    int size = 20,
    StockDocFilter filter = const StockDocFilter(),
    String? sort,
    String? order,
  }) async {
    filters.add(filter);
    return PagedResult(
      items: [
        StockDocListItem(
          id: 'return',
          docType: 'WDRAW',
          billNo: 'TL001',
          warehouseId: 'leaf',
          status: approvals > 0 ? 1 : 0,
        ),
      ],
      page: page,
      size: size,
      total: 1,
      totalPages: 1,
    );
  }

  @override
  Future<StockDocDetail> detail(String id) async => StockDocDetail(
    id: id,
    docType: 'WDRAW',
    billNo: 'TL001',
    warehouseId: 'leaf',
    status: approvals > 0 ? 1 : 0,
    productionLinked: true,
    items: const [
      StockDocItem(
        id: 'return-item',
        goodsId: 'goods',
        unitId: 'unit',
        qty: 2,
        unitRate: 1,
        upstreamItemId: 'draw-item',
      ),
    ],
  );
  @override
  Future<StockDocDetail> approve(String id) async {
    approvals++;
    return detail(id);
  }
}

class _Names extends MasterNameService {
  _Names() : super(ApiClient(Dio()));
  @override
  Future<void> ensureLoaded() async {}
  @override
  Future<void> loadGoodsDetails(Iterable<String> ids) async {}
  @override
  String goods(String? id) => '铝件';
  @override
  String warehouse(String? id) => '五金分仓';
  @override
  String unit(String? id) => '件';
}

Future<void> _pump(
  WidgetTester tester,
  _Repository repository, {
  bool detail = false,
  bool approve = true,
}) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        currentPermissionsProvider.overrideWithValue({
          Perm.stockDocView,
          if (approve) Perm.stockDocApprove,
        }),
        isSuperAdminProvider.overrideWithValue(false),
        stockDocRepositoryProvider(
          StockDocType.wdraw,
        ).overrideWithValue(repository),
        masterNameServiceProvider.overrideWithValue(_Names()),
        documentScopeOverride(writeAll: true),
        fixedBadgeSummaryOverride(
          badgeSummaryFixture(
            facts: {
              BadgeFact.productionDraw: 0,
              BadgeFact.productionReturn: repository.approvals > 0 ? 0 : 1,
            },
          ),
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: detail
            ? const StockDocDetailPage(
                docType: StockDocType.wdraw,
                id: 'return',
              )
            : const WarehouseDrawTaskCenterPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

void main() {
  test(
    'formal return filter uses the dedicated source-scoped list contract',
    () async {
      final requests = <RequestOptions>[];
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            requests.add(request);
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: {
                  'items': <Object>[],
                  'page': 1,
                  'size': 20,
                  'total': 0,
                  'totalPages': 0,
                },
              ),
            );
          },
        ),
      );
      final repository = StockDocRepository(ApiClient(dio), StockDocType.wdraw);
      await repository.list(
        filter: const StockDocFilter(status: 0, productionReturnRequests: true),
      );
      expect(requests.last.queryParameters['docType'], 'WDRAW');
      expect(requests.last.queryParameters['productionReturnRequests'], isTrue);
      expect(requests.last.queryParameters['status'], 0);
    },
  );

  testWidgets(
    'warehouse return lane shows formal pending receipts without outbound progress',
    (tester) async {
      final repository = _Repository();
      await _pump(tester, repository);
      await tester.tap(find.text('生产退料'));
      await tester.pumpAndSettle();
      expect(repository.filters, isEmpty);
      await tester.tap(find.text('待仓库收料'));
      await tester.pumpAndSettle();
      expect(repository.filters.last.productionReturnRequests, isTrue);
      expect(repository.filters.last.status, 0);
      expect(repository.filters.last.issueStatus, isNull);
      expect(find.text('未出库'), findsNothing);
      expect(find.text('TL001'), findsOneWidget);
      expect(repository.approvals, 0);
    },
  );

  testWidgets('return receipt requires warehouse approval permission', (
    tester,
  ) async {
    final repository = _Repository();
    await _pump(tester, repository, detail: true, approve: false);
    expect(find.text('确认实收并入库'), findsNothing);
    expect(repository.approvals, 0);
  });

  testWidgets(
    'opening a return does not receive stock until warehouse explicitly confirms physical receipt',
    (tester) async {
      final repository = _Repository();
      await _pump(tester, repository, detail: true);
      expect(repository.approvals, 0);
      await tester.tap(find.text('确认实收并入库'));
      await tester.pumpAndSettle();
      expect(find.textContaining('本单全部实物已收齐'), findsOneWidget);
      expect(repository.approvals, 0);
      await tester.tap(find.widgetWithText(FilledButton, '确认收料'));
      await tester.pumpAndSettle();
      expect(repository.approvals, 1);
      expect(find.text('确认实收并入库'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
