import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/product_category_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_category_tree_view.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/pages/sales_scarcity_page.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/features/sales/repositories/sales_repository.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _Api extends ApiClient {
  _Api() : super(Dio());
  final listQueries = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => const {};

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path != '/sales/orders/reservations/scarce') return const [];
    listQueries.add(Map.of(query ?? const {}));
    return const [
      {
        'reservationId': 'reservation-b',
        'orderItemId': 'line-b',
        'orderId': 'order-b',
        'orderNo': 'ORDER-B',
        'reservedQty': 12,
      },
    ];
  }
}

class _SalesRepository extends Fake implements SalesRepository {
  final a = Completer<List<ScarceReservation>>();
  final b = Completer<List<ScarceReservation>>();
  final reads = <String>[];

  @override
  Future<List<ScarceReservation>> scarceReservations(
    String goodsId, {
    String? colorId,
  }) {
    reads.add(goodsId);
    return goodsId == 'goods-a' ? a.future : b.future;
  }
}

final _category = ProductCategoryNode(
  id: 'finished',
  code: 'F',
  name: '成品',
  level: 0,
  children: const [],
);

class _Categories extends Fake implements ProductCategoryRepository {
  @override
  Future<List<ProductCategoryNode>> tree() async => [_category];
}

class _Goods extends Fake implements GoodsRepository {
  @override
  Future<PagedResult<GoodsListItem>> list(
    String? categoryId, {
    int page = 1,
    int size = 20,
    String? keyword,
    Map<String, String?> filters = const {},
    String? sort,
    String? order,
    bool excludeDisabled = false,
    bool excludeStub = false,
    bool disabledOnly = false,
    bool stubOnly = false,
  }) async => const PagedResult(
    items: [GoodsListItem(id: 'goods-b', name: '货品乙', categoryId: 'finished')],
    page: 1,
    size: 20,
    total: 1,
    totalPages: 1,
  );
}

void main() {
  test(
    'scarce reservations decode array response and retain source IDs',
    () async {
      final api = _Api();
      final rows = await SalesRepository(
        api,
        SalesDocType.order,
      ).scarceReservations('goods-b', colorId: 'color-b');
      expect(api.listQueries.single, {
        'goodsId': 'goods-b',
        'colorId': 'color-b',
      });
      expect(rows.single.reservationId, 'reservation-b');
      expect(rows.single.orderItemId, 'line-b');
      expect(rows.single.orderId, 'order-b');
      expect(rows.single.reservedQty, 12);
    },
  );

  for (final oldFails in [false, true]) {
    testWidgets('changing goods ignores late ${oldFails ? 'error' : 'rows'}', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final api = _Api();
      final repository = _SalesRepository();
      tester.view.physicalSize = const Size(1500, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            sharedPreferencesProvider.overrideWithValue(preferences),
            salesMasterNameServiceProvider.overrideWithValue(
              SalesMasterNameService(api),
            ),
            salesRepositoryProvider.overrideWith((ref, type) => repository),
            productCategoryRepositoryProvider.overrideWithValue(_Categories()),
            goodsRepositoryProvider.overrideWithValue(_Goods()),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: SalesScarcityPage(initialGoodsId: 'goods-a'),
          ),
        ),
      );
      await tester.pump();
      expect(repository.reads, ['goods-a']);
      await tester.tap(find.byType(ActionChip));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      tester
          .widget<UtenCategoryTreeView<ProductCategoryNode>>(
            find.byType(UtenCategoryTreeView<ProductCategoryNode>),
          )
          .onToggleSelect!(_category);
      await tester.pump();
      await tester.tap(find.text('货品乙'));
      await tester.pump();
      await tester.tap(find.text('确定'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(repository.reads, ['goods-a', 'goods-b']);
      repository.b.complete([
        const ScarceReservation(
          orderNo: 'ORDER-B',
          clientName: '客户乙',
          reservedQty: 12,
        ),
      ]);
      await tester.pumpAndSettle();
      if (oldFails) {
        repository.a.completeError(StateError('旧货品请求失败'));
      } else {
        repository.a.complete([
          const ScarceReservation(
            orderNo: 'ORDER-A',
            clientName: '客户甲',
            reservedQty: 8,
          ),
        ]);
      }
      await tester.pumpAndSettle();
      expect(find.textContaining('ORDER-B'), findsOneWidget);
      expect(find.textContaining('ORDER-A'), findsNothing);
      expect(find.text('预留查询失败，请重试'), findsNothing);
      expect(find.text('货品乙'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
