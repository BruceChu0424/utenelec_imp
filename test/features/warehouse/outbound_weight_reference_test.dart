import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_autofill_text_controller.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/warehouse/models/outbound_weight_entry.dart';
import 'package:uten_imp/features/warehouse/widgets/outbound_weight_columns.dart';
import 'package:uten_imp/shared/measurement/weight_params.dart';

class _Repository extends WeightRepository {
  _Repository() : super(ApiClient(Dio()));
  final requested = <WeightParamsLine>[];

  @override
  Future<Map<String, WeightParams>> params(
    Iterable<WeightParamsLine> lines,
  ) async {
    requested.addAll(lines);
    return {
      for (final line in lines)
        line.key: WeightParams(
          key: line.key,
          goodsId: line.goodsId,
          stockBalance: WeightStockBalance(
            warehouseId: line.warehouseId!,
            colorId: line.colorId,
            qtyBase: 1000,
            weightKg: line.warehouseId == 'source-a' ? 20 : 40,
          ),
        ),
    };
  }
}

void main() {
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
