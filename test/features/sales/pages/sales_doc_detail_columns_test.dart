import '../../../support/native_detail_reader_overrides.dart';
// 销售订货单详情页（审核页面）明细列与编辑页对齐（2026-09-25 用户口径）：
//  - 补齐编辑页列：折扣 / 机加价 / 围数 / 进仓数量；
//  - 退役进度列：业务链 / 已发 / 已退 / 可发 / 已排 / 已产 / 优先级
//   （进度看「订单进度」专页）；
//  - 2026-10-10「数量 + 单位」内联口径：独立「单位」列撤销，单位直接跟在数量后
//   （如 `10 箱`），进仓数量同样内联。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/pages/sales_doc_detail_page.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';

const _detail = {
  'id': 'order-1',
  'status': 0,
  'writable': true,
  'clientId': 'client-1',
  'sellerId': 'seller-1',
  'currencyId': 'cny',
  'settlementMethodId': 'settlement-net30',
  'deliverDate': '2026-09-30',
  'shipmentPolicy': 'ALLOW_PARTIAL',
  'items': [
    {
      'id': 'order-item-1',
      'goodsId': 'goods-1',
      'unitId': 'unit-box',
      'unitRate': 1,
      'qty': 10,
      'price': 10,
      'discount': 0.8,
      'machiningPrice': 2,
      'circumference': 55,
      'inboundQty': 3,
    },
  ],
};

void main() {
  testWidgets('订货单详情明细列与编辑页对齐', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1600, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final api = _ColumnsApi();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...nativeDetailReaderOverrides(),
          apiClientProvider.overrideWithValue(api),
          salesMasterNameServiceProvider.overrideWithValue(
            SalesMasterNameService(api),
          ),
        ],
        child: const MaterialApp(
          home: SalesDocDetailPage(id: 'order-1', docType: SalesDocType.order),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 编辑页有的列齐备（含补列与值）。
    expect(find.text('折扣'), findsOneWidget);
    expect(find.text('机加价'), findsOneWidget);
    expect(find.text('围数'), findsOneWidget);
    expect(find.text('进仓数量'), findsOneWidget);
    expect(find.text('0.8'), findsWidgets);
    expect(find.text('55.00'), findsWidgets);

    // 进度列不再挤在本表（进度看「订单进度」专页）。
    expect(find.text('业务链'), findsNothing);
    expect(find.text('已发'), findsNothing);
    expect(find.text('已退'), findsNothing);
    expect(find.text('可发'), findsNothing);
    expect(find.text('已排'), findsNothing);
    expect(find.text('已产'), findsNothing);
    expect(find.text('优先级'), findsNothing);

    // 2026-10-10「数量 + 单位」内联口径：独立「单位」列撤销，单位跟在数量后。
    // 「10 箱」两处 = 明细格 + 合计条（单行合计同值）；进仓数量同样内联为「3 箱」。
    expect(find.text('单位'), findsNothing);
    expect(find.text('10 箱'), findsWidgets);
    expect(find.text('3 箱'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _ColumnsApi extends ApiClient {
  _ColumnsApi() : super(Dio());

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/order-1')) return _detail;
    return const {
      'items': <Map<String, dynamic>>[],
      'page': 1,
      'size': 1,
      'total': 0,
      'totalPages': 0,
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/master/units/dict') {
      return const [
        {'id': 'unit-box', 'name': '箱'},
      ];
    }
    return const [];
  }
}
