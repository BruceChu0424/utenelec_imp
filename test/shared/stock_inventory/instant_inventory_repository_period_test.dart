import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/shared/stock_inventory/instant_inventory_repository.dart';

void main() {
  for (final attention in <String?>[null, 'NEGATIVE_BALANCE']) {
    test(
      'period query and server values survive ${attention ?? 'inventory'}',
      () async {
        late RequestOptions request;
        final dio = Dio();
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              request = options;
              handler.resolve(
                Response<dynamic>(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'items': [
                      {
                        'goodsId': 'goods',
                        'qty': 170,
                        'periodSelected': true,
                        'periodInQty': 30,
                        'periodOutQty': 8,
                        'closingQty': 162,
                        'costMasked': true,
                        'costPrice': 5,
                        'periodCostAmount': 810,
                      },
                    ],
                    'total': 1,
                  },
                ),
              );
            },
          ),
        );
        final result = await InstantInventoryRepository(ApiClient(dio))
            .instantInventory(
              page: 2,
              warehouseId: 'warehouse',
              warehouseRelatedOnly: true,
              attention: attention,
              dateFrom: '2026-10-04',
              dateTo: '2026-11-04',
            );
        expect(
          request.path,
          attention == null
              ? '/stock/instant-inventory'
              : '/stock/instant-inventory/attention',
        );
        expect(request.queryParameters['dateFrom'], '2026-10-04');
        expect(request.queryParameters['dateTo'], '2026-11-04');
        expect(request.queryParameters['warehouseRelatedOnly'], isTrue);
        expect(request.queryParameters['warehouseId'], 'warehouse');
        expect(request.queryParameters['page'], 2);
        final row = result.items.single;
        expect(row.periodSelected, isTrue);
        expect(row.qty, 170);
        expect(row.periodInQty, 30);
        expect(row.periodOutQty, 8);
        expect(row.closingQty, 162);
        expect(row.costPrice, isNull);
        expect(row.periodCostAmount, isNull);
      },
    );
  }

  test(
    'old server preserves current quantity and leaves period values unknown',
    () async {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'items': [
                    {'goodsId': 'goods', 'qty': 170},
                  ],
                  'total': 1,
                },
              ),
            );
          },
        ),
      );
      final result = await InstantInventoryRepository(
        ApiClient(dio),
      ).instantInventory(dateFrom: '2026-10-04', dateTo: '2026-11-04');
      final row = result.items.single;
      expect(row.qty, 170);
      expect(row.periodSelected, isFalse);
      expect(row.periodInQty, isNull);
      expect(row.periodOutQty, isNull);
      expect(row.closingQty, isNull);
      expect(row.costPrice, isNull);
      expect(row.periodCostAmount, isNull);
    },
  );
}
