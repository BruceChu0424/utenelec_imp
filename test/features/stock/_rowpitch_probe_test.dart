
// 临时探针：量盘点会话页的行距与输入格高度（验证读表 37 口径后即删）。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/stock/counts/models/stock_count_request.dart';
import 'package:uten_imp/features/stock/counts/pages/stock_count_session_page.dart';
import 'package:uten_imp/features/stock/counts/repositories/stock_count_request_repository.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

const _w = StockCountWarehouse(id: 'leaf-a', name: '原料仓 A', kind: 'NORMAL', reviewRoute: 'FINANCE');
const _screw = '11111111-1111-1111-1111-111111111111';
const _nut = '22222222-2222-2222-2222-222222222222';

CountStockRow _row(String id, String qty) => CountStockRow(
  goodsId: id, goodsName: id == _screw ? '螺丝' : '螺母', goodsCode: id,
  categoryId: 'raw', unitId: 'u', unitName: '个', qty: qty,
  goodsVersion: 7, allowedActions: const ['EDIT'],
);

class _Repo extends StockCountRequestRepository {
  _Repo() : super(ApiClient(Dio()));
  @override
  Future<StockCountScope> scope({String? warehouseId}) async =>
      const StockCountScope(warehouses: [_w], allowedActions: ['SUBMIT']);
  @override
  Future<PagedResult<CountStockRow>> candidates({
    required String warehouseId, String? keyword, String? categoryId,
    List<String> goodsIds = const [], bool stockedOnly = false,
    bool sheet = false, int page = 1, int size = 50,
  }) async => PagedResult(
    items: [_row(_screw, '10'), _row(_nut, '0')],
    page: 1, size: size, total: 2, totalPages: 1,
  );
  @override
  Future<List<ProductCategoryNode>> candidateCategories(String warehouseId, {bool sheet = false}) async => [];
}

void main() {
  testWidgets('measure row pitch', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(2200, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(Dio())),
        sharedPreferencesProvider.overrideWithValue(prefs),
        stockCountRequestRepositoryProvider.overrideWithValue(_Repo()),
      ],
      child: MaterialApp.router(
        routerConfig: GoRouter(initialLocation: RouteName.stockCountSession, routes: [
          GoRoute(path: '/', builder: (_, _) => const SizedBox()),
          GoRoute(path: RouteName.stockCountSession, builder: (_, _) => const StockCountSessionPage(warehouseId: 'leaf-a')),
          GoRoute(path: RouteName.stockCountRequests, builder: (_, _) => const SizedBox()),
          GoRoute(path: RouteName.stockInstantInventory, builder: (_, _) => const SizedBox()),
        ]),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
      ),
    ));
    await tester.pumpAndSettle();
    final a = tester.getTopLeft(find.byKey(ValueKey('stock-count-qty-$_screw|'))).dy;
    final b = tester.getTopLeft(find.byKey(ValueKey('stock-count-qty-$_nut|'))).dy;
    debugPrint('ROW_PITCH=${b - a}');
    debugPrint('CELL_H=${tester.getSize(find.byKey(ValueKey('stock-count-qty-$_screw|'))).height}');
  });
}
