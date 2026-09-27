import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/widgets/purchase_grid_columns.dart';
import 'package:uten_imp/features/sales/widgets/sales_grid_columns.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/subcontract/widgets/subcontract_grid_columns.dart';
import 'package:uten_imp/shared/drafts/form_draft_values.dart';
import 'package:uten_imp/shared/models/procurement_commercial_terms.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

Map<String, dynamic> persisted(Map<String, dynamic> data) =>
    jsonDecode(jsonEncode(data)) as Map<String, dynamic>;

void main() {
  test(
    'sales recovery keeps incomplete text and independent source identities',
    () {
      final source = SalesGridRow(amountUsesDiscount: true)
        ..goods = const GoodsOption(id: 'goods', code: 'P-1', name: '产品')
        ..documentItemId = 'own-row'
        ..orderItemId = 'source-order-row'
        ..outItemId = 'source-out-row'
        ..colorId = 'color'
        ..unitId = 'unit'
        ..unitRate = 1
        ..unitRateExact = '1.000000000000000001'
        ..solution = 'repair'
        ..responsible = 'supplier'
        ..requiresOrderPriceRefresh = true;
      source.qty.text = '0.';
      source.price.text = '123456789.00000001';
      source.weight.text = '-';
      source.remark.text = '尚未填写完的备注 ';
      source.discount.text = '';
      final saved = persisted(source.exportDraft());
      final restored = SalesGridRow.fromDraft(saved);
      addTearDown(source.dispose);
      addTearDown(restored.dispose);
      expect(restored.exportDraft(), saved);
      expect(restored.qty.text, '0.');
      expect(restored.unitRateExact, '1.000000000000000001');
      expect(restored.documentItemId, isNot(restored.orderItemId));
      expect(restored.requiresOrderPriceRefresh, isTrue);
    },
  );

  test('purchase recovery keeps every row and explicit deselection', () {
    final first = PurchaseGridRow(sourceLocked: true)
      ..goods = const GoodsOption(id: 'goods')
      ..upstreamItemId = 'request-row-1'
      ..upstreamItemIds = ['request-row-1', 'request-row-2']
      ..sourceDocs = const [
        PurchaseSourceRequestRef(
          requestItemId: 'request-row-1',
          requestId: 'request-1',
          billNo: 'SQ1',
        ),
        PurchaseSourceRequestRef(
          requestItemId: 'request-row-2',
          requestId: 'request-2',
          billNo: 'SQ2',
        ),
      ]
      ..maxQty = 9.5;
    first.qty.text = '12.';
    final incomplete = PurchaseGridRow();
    incomplete.remark.text = '还没选货品';
    final original = UtenEditableGridController<PurchaseGridRow>(
      initial: [first, incomplete],
    );
    original.setSelected([incomplete], true);
    final restored = UtenEditableGridController<PurchaseGridRow>();
    addTearDown(original.dispose);
    addTearDown(restored.dispose);
    final saved = jsonDecode(
      jsonEncode(draftGridRows(original, (row) => row.exportDraft())),
    );
    restoreDraftGrid(restored, saved, PurchaseGridRow.fromDraft);
    expect(restored.length, 2);
    expect(restored.isSelected(restored[0]), isFalse);
    expect(restored.isSelected(restored[1]), isTrue);
    expect(restored[0].sourceLocked, isTrue);
    expect(restored[0].upstreamItemIds, ['request-row-1', 'request-row-2']);
    expect(restored[0].sourceDocs[1].requestId, 'request-2');
    expect(restored[0].qty.text, '12.');
    expect(restored[1].goods, isNull);
    expect(restored[1].remark.text, '还没选货品');
  });

  test('restored learned price still clears on supplier context change', () {
    final source = PurchaseGridRow()
      ..goods = const GoodsOption(id: 'goods')
      ..supplierId = 'supplier'
      ..unitId = 'unit'
      ..currencyId = 'currency';
    source.taxRate.text = '13';
    source.exchangeRate.text = '1.';
    source.price.text = '12.34';
    source.markTermsAutofilled('price', '12.34');
    source.watchDefaultPrice(
      price: source.price,
      supplier: source.supplierIdNotifier,
      context: const ProcurementPriceContext(
        supplierId: 'supplier',
        unitId: 'unit',
        currencyId: 'currency',
        taxRate: 13,
      ),
      goodsId: 'goods',
      currentGoodsId: () => source.goods?.id,
      currentColorId: () => source.colorId,
      currentUnitId: () => source.unitId,
    );
    final restored = PurchaseGridRow.fromDraft(persisted(source.exportDraft()));
    addTearDown(source.dispose);
    addTearDown(restored.dispose);
    expect(restored.price.text, '12.34');
    expect(restored.exchangeRate.text, '1.');
    restored.supplierId = 'different-supplier';
    expect(restored.price.text, isEmpty);
    expect(restored.termsAutofilled, isNot(contains('price')));
  });

  test(
    'subcontract recovery preserves plan custody and loss autofill checks',
    () {
      final source = SubcontractGridRow(sourceLocked: true)
        ..goods = const GoodsOption(id: 'goods')
        ..upstreamItemId = 'application-row'
        ..upstreamItemIds = ['application-row']
        ..planItemId = 'issue-plan-row'
        ..sourceDocNo = 'SJ1'
        ..sourceDocs = const [
          SubcontractSourceApplicationRef(
            applicationItemId: 'application-row',
            applicationId: 'application',
            billNo: 'WS1',
          ),
        ];
      source.allowedLossPct.text = '2.50';
      source.markAllowedLossAutofilled('2.50');
      source.cause.text = '待继续输入';
      source.endingQty.text = '0.';
      final restored = SubcontractGridRow.fromDraft(
        persisted(source.exportDraft()),
      );
      addTearDown(source.dispose);
      addTearDown(restored.dispose);
      expect(restored.exportDraft(), persisted(source.exportDraft()));
      expect(restored.planItemId, 'issue-plan-row');
      expect(restored.termsAutofilled, contains('allowedLoss'));
      restored.allowedLossPct.text = '3';
      expect(restored.termsAutofilled, isNot(contains('allowedLoss')));
    },
  );
}
