import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_autofill_text_controller.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/warehouse/models/outbound_weight_entry.dart';
import 'package:uten_imp/features/warehouse/widgets/outbound_weight_columns.dart';
import 'package:uten_imp/shared/measurement/weight_params.dart';
import 'package:uten_imp/shared/measurement/weight_unit.dart';
import 'package:uten_imp/features/warehouse/models/stock_doc.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_sales_outbound.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_form_draft_codec.dart';

class _Repository extends WeightRepository {
  _Repository() : super(ApiClient(Dio()));
  final requested = <WeightParamsLine>[];

  @override
  Future<WeightParamsResult> params(Iterable<WeightParamsLine> lines) async {
    requested.addAll(lines);
    return WeightParamsResult(
      params: {
        for (final line in lines)
          line.paramsIdentity: WeightParams(goodsId: line.goodsId),
      },
      balances: {
        for (final line in lines)
          line.balanceIdentity!: WeightStockBalance(
            warehouseId: line.warehouseId!,
            goodsId: line.goodsId,
            colorId: line.colorId,
            qtyBase: 1000,
            weightKg: line.warehouseId == 'source-a' ? 20 : 40,
          ),
      },
    );
  }
}

class _MassRepository extends WeightRepository {
  _MassRepository() : super(ApiClient(Dio()));
  @override
  Future<WeightParamsResult> params(Iterable<WeightParamsLine> lines) async =>
      WeightParamsResult(
        params: {
          for (final line in lines)
            line.paramsIdentity: WeightParams(
              goodsId: line.goodsId,
              basis: WeightBasis.exact,
              massFactorKg: 1,
              massFactorKgExact: '1',
              baseUnitDimension: 'MASS',
            ),
        },
      );
}

void main() {
  test(
    'readonly MASS uses original basic quantity and never promotes preview doubles to exact',
    () async {
      final cache = WeightParamsCache(_MassRepository());
      final qty = UtenAutofillTextController(text: '99999999999999.9999');
      final exact = OutboundWeightEntry(
        goodsId: 'mass',
        qtyOf: () => double.tryParse(qty.text),
        qtyController: qty,
        unitRate: 1,
        unitRateExact: '1',
      );
      final unknown = OutboundWeightEntry(
        goodsId: 'unknown',
        qtyOf: () => 100000000000000,
        unitRate: 1,
        unitRateExact: '1',
      );
      addTearDown(() {
        exact.dispose();
        unknown.dispose();
        qty.dispose();
        cache.dispose();
      });
      await ensureOutboundWeightParams(cache, [exact, unknown]);
      expect(exact.qtyBase, 100000000000000);
      expect(exact.qtyBaseText, '99999999999999.9999');
      expect(exact.exactKgTextIn(cache), '99999999999999.9999');
      expect(exact.kgText, isNull);
      final column = outboundWeightColumn<OutboundWeightEntry>(
        entryOf: (entry) => entry,
        entryUnit: WeightUnit.kg,
        params: cache,
      );
      expect(column.exactValueOf!(exact), '99999999999999.9999');
      expect(unknown.qtyBaseText, isNull);
      expect(column.exactValueOf!(unknown), isNull);
      qty.text = 'not a quantity';
      expect(exact.exactKgTextIn(cache), isNull);
      expect(qty.text, 'not a quantity');
    },
  );

  test(
    'readonly rate and sales quantity retain recorded-text provenance beside legacy display',
    () {
      final stockLegacy = StockDocItem.fromJson({
        'id': 'stock',
        'qtyExact': '3',
        'unitRate': 1,
      });
      expect(stockLegacy.unitRateText, '1');
      expect(stockLegacy.recordedUnitRateText, isNull);
      final restoredStock = StockDocDetail.fromJson(
        stockDocumentDraftFacts(
          StockDocDetail(id: 'doc', items: [stockLegacy]),
        ),
      );
      expect(restoredStock.items.single.unitRateText, '1');
      expect(restoredStock.items.single.recordedUnitRateText, isNull);
      final stockExact = StockDocItem.fromJson({
        'id': 'stock',
        'qtyExact': '3',
        'unitRateExact': '1.0001',
      });
      expect(stockExact.recordedUnitRateText, '1.0001');
      final subcontractLegacy = SubcontractDocItem.fromJson({
        'id': 'sub',
        'qtyExact': '3',
        'unitRate': 1,
      });
      expect(subcontractLegacy.unitRateText, '1');
      expect(subcontractLegacy.recordedUnitRateText, isNull);
      final subcontractExact = SubcontractDocItem.fromJson({
        'id': 'sub',
        'qtyExact': '3',
        'unitRateExact': '1.0001',
      });
      expect(subcontractExact.recordedUnitRateText, '1.0001');
      final salesLegacy = WarehouseSalesOutboundLine.fromJson({
        'id': 'sales',
        'quantity': 1.5,
        'unitRate': 1,
      });
      expect(salesLegacy.quantity, '1.5');
      expect(salesLegacy.recordedQuantityText, isNull);
      expect(salesLegacy.unitRateText, isNull);
      final salesExact = WarehouseSalesOutboundLine.fromJson({
        'id': 'sales',
        'quantityExact': '99999999999999.9999',
        'unitRateExact': '1',
      });
      expect(salesExact.recordedQuantityText, '99999999999999.9999');
      expect(salesExact.unitRateText, '1');
    },
  );

  test('出库按当前仓与颜色取库存基本数量，换仓不沿用旧仓参数', () async {
    final repository = _Repository();
    final cache = WeightParamsCache(repository);
    final qty = UtenAutofillTextController(text: '5');
    var warehouse = 'source-a';
    final entry = OutboundWeightEntry(
      goodsId: 'screw',
      colorId: 'black',
      warehouseIdOf: () => warehouse,
      qtyOf: () => double.tryParse(qty.text),
      qtyController: qty,
      unitRate: 100,
    );
    addTearDown(() {
      entry.dispose();
      qty.dispose();
      cache.dispose();
    });
    await ensureOutboundWeightParams(cache, [entry]);
    expect(repository.requested.single.colorId, 'black');
    expect(entry.qtyBase, 500);
    expect(entry.suggestion(cache)!.kg, 10);
    warehouse = 'source-b';
    expect(entry.suggestion(cache), isNull);
    await ensureOutboundWeightParams(cache, [entry]);
    expect(entry.suggestion(cache)!.kg, 20);
    expect(repository.requested.last.warehouseId, 'source-b');
  });

  test('无学习历史仍按库存20kg核对1kg，预填不进实称汇总或提交指纹', () async {
    final repository = _Repository();
    final cache = WeightParamsCache(repository);
    final entry = OutboundWeightEntry(
      goodsId: 'screw',
      warehouseId: 'source-a',
      qtyOf: () => 1000,
      unitRate: 1,
    );
    addTearDown(() {
      entry.dispose();
      cache.dispose();
    });
    await ensureOutboundWeightParams(cache, [entry]);
    final originalKey = entry.keyPart;
    entry.weight.setSuggestedKg(entry.suggestion(cache)!.kg);
    expect(entry.weight.displayKg, 20);
    expect(entry.kg, isNull);
    expect(entry.keyPart, originalKey);
    expect(entry.hasWeightDeviation(cache), isFalse);
    entry.weight.setKg(1);
    expect(entry.hasWeightDeviation(cache), isTrue);
    final column = outboundWeightCheckColumn<OutboundWeightEntry>(
      entryOf: (entry) => entry,
      params: cache,
    );
    expect(column.value(entry), contains('预计约 20 kg'));
    entry.weight.setKg(20);
    expect(entry.hasWeightDeviation(cache), isFalse);
  });
}
