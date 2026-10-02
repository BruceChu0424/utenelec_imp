import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/shared/measurement/weight_params.dart';

class _Repository extends WeightRepository {
  _Repository() : super(ApiClient(Dio()));
  final requests = <List<WeightParamsLine>>[];
  final replies = <Completer<Map<String, WeightParams>>>[];

  @override
  Future<Map<String, WeightParams>> params(Iterable<WeightParamsLine> lines) {
    requests.add(lines.toList());
    final reply = Completer<Map<String, WeightParams>>();
    replies.add(reply);
    return reply.future;
  }
}

void main() {
  test('库存缓存不会串仓库或颜色，并发重复请求只取一次', () async {
    final repository = _Repository();
    final cache = WeightParamsCache(repository);
    addTearDown(cache.dispose);
    const red = WeightParamsLine(
      goodsId: 'g',
      warehouseId: 'w1',
      colorId: 'red',
    );
    const blue = WeightParamsLine(
      goodsId: 'g',
      warehouseId: 'w1',
      colorId: 'blue',
    );
    const other = WeightParamsLine(
      goodsId: 'g',
      warehouseId: 'w2',
      colorId: 'red',
    );
    final loading = cache.ensure([red, blue, other]);
    await cache.ensure([red]);
    expect(repository.requests.length, 1);
    expect(cache.isLoading('g', warehouseId: 'w1', colorId: 'red'), isTrue);
    repository.replies.single.complete({
      red.key: WeightParams(
        key: red.key,
        goodsId: 'g',
        stockBalance: const WeightStockBalance(
          warehouseId: 'w1',
          colorId: 'red',
          qtyBase: 1000,
          weightKg: 20,
        ),
      ),
      blue.key: WeightParams(
        key: blue.key,
        goodsId: 'g',
        stockBalance: const WeightStockBalance(
          warehouseId: 'w1',
          colorId: 'blue',
          qtyBase: 1000,
          weightKg: 30,
        ),
      ),
      other.key: WeightParams(
        key: other.key,
        goodsId: 'g',
        stockBalance: const WeightStockBalance(
          warehouseId: 'w2',
          colorId: 'red',
          qtyBase: 1000,
          weightKg: 40,
        ),
      ),
    });
    await loading;
    expect(
      cache.of('g', warehouseId: 'w1', colorId: 'red')!.stockBalance!.weightKg,
      20,
    );
    expect(
      cache.of('g', warehouseId: 'w1', colorId: 'blue')!.stockBalance!.weightKg,
      30,
    );
    expect(
      cache.of('g', warehouseId: 'w2', colorId: 'red')!.stockBalance!.weightKg,
      40,
    );
    expect(cache.of('g'), isNull);
  });

  test('货品失效后旧异步回包不能覆盖新数据或清掉新请求标记', () async {
    final repository = _Repository();
    final cache = WeightParamsCache(repository);
    addTearDown(cache.dispose);
    const line = WeightParamsLine(goodsId: 'g', warehouseId: 'w');
    final oldLoad = cache.ensure([line]);
    cache.invalidateGoods('g');
    final newLoad = cache.ensure([line]);
    repository.replies.first.complete({
      line.key: WeightParams(key: line.key, goodsId: 'g', unitWeightKg: 1),
    });
    await oldLoad;
    expect(cache.of('g', warehouseId: 'w'), isNull);
    expect(cache.isLoading('g', warehouseId: 'w'), isTrue);
    repository.replies.last.complete({
      line.key: WeightParams(key: line.key, goodsId: 'g', unitWeightKg: 2),
    });
    await newLoad;
    expect(cache.of('g', warehouseId: 'w')!.unitWeightKg, 2);
    expect(cache.isLoading('g', warehouseId: 'w'), isFalse);
  });
}
