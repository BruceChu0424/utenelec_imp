import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/widgets/doc_link_picker.dart';
import 'package:uten_imp/features/purchase/widgets/purchase_grid_columns.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

void main() {
  test('purchase request item exposes already ordered quantity', () {
    final item = PurchaseDocItem.fromJson({
      'id': 'request-item-1',
      'goodsId': 'goods-1',
      'qty': 10,
      'orderedQty': 4,
    });

    expect(item.orderedQty, 4);
    expect((item.qty ?? 0) - (item.orderedQty ?? 0), 6);
  });

  test('linked purchase row locks source identity and keeps remaining cap', () {
    final row = PurchaseGridRow.fromLinked(
      const LinkedItem(
        goodsId: 'goods-1',
        qty: 6,
        maxQty: 6,
        upstreamItemId: 'request-item-1',
      ),
      const GoodsOption(id: 'goods-1', name: '轴套'),
    );
    addTearDown(row.dispose);

    expect(row.sourceLocked, isTrue);
    expect(row.upstreamItemId, 'request-item-1');
    expect(row.maxQty, 6);
    expect(row.qty.text, '6.0');
  });

  test('order source column surfaces request lineage for imported rows', () {
    final columns = purchaseGridColumns(
      (_) async {},
      showSource: true,
    );
    final source = columns.firstWhere((c) => c.key == 'source');
    expect(source.label, '申请来源');

    final row = PurchaseGridRow()
      ..sourceRequestNo = 'CG20260901-001'
      ..sourceRequestId = 'request-1';
    addTearDown(row.dispose);
    expect(source.textOf!(row), 'CG20260901-001');

    // 手动添加的无来源行不显示单号（列内以「—」占位），不参与来源谱系。
    final blank = PurchaseGridRow();
    addTearDown(blank.dispose);
    expect(source.textOf!(blank), '');
  });
}
