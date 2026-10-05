import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/shared/measurement/weight_params.dart';

class _Repository extends WeightRepository {
  _Repository() : super(ApiClient(Dio()));
  final requests = <List<WeightParamsLine>>[];
  final replies = <Completer<WeightParamsResult>>[];

  @override
  Future<WeightParamsResult> params(Iterable<WeightParamsLine> lines) {
    requests.add(lines.toList());
    final reply = Completer<WeightParamsResult>();
    replies.add(reply);
    return reply.future;
  }
}

WeightStockBalance _balance(String warehouse, String? color, double kg) =>
    WeightStockBalance(
      warehouseId: warehouse,
      goodsId: 'g',
      colorId: color,
      qtyBase: 1000,
      weightKg: kg,
    );

void main() {
  test('单重按(货品,供应商)共用, 库存参考按(仓库,货品,颜色)分开, 并发重复请求只取一次', () async {
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
    final balances = [
      _balance('w1', 'red', 20),
      _balance('w1', 'blue', 30),
      _balance('w2', 'red', 40),
    ];
    repository.replies.single.complete(
      WeightParamsResult(
        params: {
          (goodsId: 'g', supplierId: null): const WeightParams(
            goodsId: 'g',
            unitWeightKg: 0.02,
          ),
        },
        balances: {for (final b in balances) b.identity: b},
      ),
    );
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
    // 不带仓库只拿单重, 不会退回成任意仓库的库存参考。
    expect(cache.of('g')!.unitWeightKg, 0.02);
    expect(cache.of('g')!.stockBalance, isNull);
    // 同一仓库没有这种颜色的余额 = 已知没有参考, 不再重复取。
    await cache.ensure([
      const WeightParamsLine(goodsId: 'g', warehouseId: 'w1', colorId: 'red'),
    ]);
    expect(repository.requests.length, 1);
  });

  test('货品失效后旧异步回包不能覆盖新数据或清掉新请求标记', () async {
    final repository = _Repository();
    final cache = WeightParamsCache(repository);
    addTearDown(cache.dispose);
    const line = WeightParamsLine(goodsId: 'g', warehouseId: 'w');
    WeightParamsResult reply(double kg) => WeightParamsResult(
      params: {
        (goodsId: 'g', supplierId: null): WeightParams(
          goodsId: 'g',
          unitWeightKg: kg,
        ),
      },
    );
    final oldLoad = cache.ensure([line]);
    cache.invalidateGoods('g');
    final newLoad = cache.ensure([line]);
    repository.replies.first.complete(reply(1));
    await oldLoad;
    expect(cache.of('g', warehouseId: 'w'), isNull);
    expect(cache.isLoading('g', warehouseId: 'w'), isTrue);
    repository.replies.last.complete(reply(2));
    await newLoad;
    expect(cache.of('g', warehouseId: 'w')!.unitWeightKg, 2);
    expect(cache.isLoading('g', warehouseId: 'w'), isFalse);
  });

  test('取参失败不再静默: 记录原因, 重试只重取失败的行, 成功后清除', () async {
    final repository = _Repository();
    final cache = WeightParamsCache(repository);
    addTearDown(cache.dispose);
    const ok = WeightParamsLine(goodsId: 'a');
    const failing = WeightParamsLine(
      goodsId: 'b',
      supplierId: 's',
      warehouseId: 'w',
      colorId: 'c',
    );
    final first = cache.ensure([ok]);
    repository.replies.last.complete(
      const WeightParamsResult(
        params: {(goodsId: 'a', supplierId: null): WeightParams(goodsId: 'a')},
      ),
    );
    await first;
    final second = cache.ensure([failing]);
    repository.replies.last.completeError(
      ApiException('VALIDATION_FAILED', '参数校验失败', httpStatus: 422),
    );
    await second;
    expect(cache.hasFailed, isTrue);
    expect((cache.lastError as ApiException).httpStatus, 422);
    final retry = cache.retryFailed();
    expect(cache.lastError, isNull);
    expect(repository.requests.last, [failing]);
    repository.replies.last.complete(
      const WeightParamsResult(
        params: {
          (goodsId: 'b', supplierId: 's'): WeightParams(
            goodsId: 'b',
            supplierId: 's',
          ),
        },
      ),
    );
    await retry;
    expect(cache.hasFailed, isFalse);
    expect(
      cache.of('b', supplierId: 's', warehouseId: 'w', colorId: 'c'),
      isNotNull,
    );
    expect(repository.requests.length, 3);
  });

  test('请求行只发结构化身份, 不再拼 key; 空串当作没有', () {
    const line = WeightParamsLine(
      goodsId: 'g',
      supplierId: '',
      warehouseId: 'w',
      colorId: '',
    );
    expect(line.toJson(), {'goodsId': 'g', 'warehouseId': 'w'});
    expect(line.toJson().containsKey('key'), isFalse);
    expect(line.paramsIdentity, (goodsId: 'g', supplierId: null));
    expect(line.balanceIdentity, (
      warehouseId: 'w',
      goodsId: 'g',
      colorId: null,
    ));
    expect(
      line,
      const WeightParamsLine(goodsId: 'g', warehouseId: 'w'),
      reason: '同一身份的行视为同一行',
    );
  });
}
