import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/warehouse/models/stock_doc.dart';
import 'package:uten_imp/features/warehouse/widgets/production_draw_detail_table.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

class _Names extends MasterNameService {
  _Names() : super(ApiClient(Dio()));
  @override
  Future<void> ensureLoaded() async {}
  @override
  Future<void> ensureWarehousesLoaded() async {}
  @override
  Future<void> loadGoodsDetails(Iterable<String> ids) async {}
  @override
  String goods(String? id) => '常规原料';
  @override
  String warehouse(String? id) => '常规仓';
}

StockDocDetail _doc(
  String id,
  String billNo,
  String batch,
  List<StockDocItem> items,
) => StockDocDetail(
  id: id,
  docType: 'DRAW',
  billNo: billNo,
  status: 1,
  warehouseId: 'w1',
  departmentId: 'workshop',
  issueStatus: 0,
  drawBatchNo: batch,
  items: items,
);

const _sameGoods = StockDocItem(
  id: 'line-same',
  goodsId: 'g1',
  colorId: 'c1',
  unitId: 'kg',
  qty: 10,
);

void main() {
  testWidgets('同批次同货品合并行能正常渲染不崩溃', (tester) async {
    final documents = [
      _doc('a', 'SL-1', 'PC-1', [_sameGoods]),
      _doc('b', 'SL-2', 'PC-1', [_sameGoods]),
      _doc('c', 'SL-3', 'PC-1', [
        const StockDocItem(
          id: 'line-other',
          goodsId: 'g2',
          unitId: 'kg',
          qty: 7,
        ),
      ]),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1600,
            height: 900,
            child: ProductionDrawDetailTable(
              documents: documents,
              names: _Names(),
              permissions: const {},
              mergeBatchGoods: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('2 张单'), findsOneWidget);
    expect(find.text('20'), findsWidgets); // 合并行应领/待出库 10+10
    expect(find.text('7'), findsWidgets); // 未合并行保持原数量
  });
}
