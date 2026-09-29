// 出库类页面测试共用的单重参数假仓储 (ADR-135): 不走网络, 按货品给固定单重参数。
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/shared/measurement/weight_params.dart';
import 'package:uten_imp/shared/measurement/weight_predictor.dart';

/// 金样 S18 供应商 A: 单重约 2.0 g, 可参考 (偏差核对生效)。
WeightParams learnedWeightParams(String goodsId) => WeightParams(
  key: WeightParams.keyOf(goodsId, null),
  goodsId: goodsId,
  basis: WeightBasis.learned,
  logMean: -6.214979467174846,
  lotPrior: 3.869930380683166e-05,
  df: 15,
  tier: WeightTier.yellow,
  nInliers: 12,
  tolerancePct: 3,
);

class FakeWeightRepository extends WeightRepository {
  FakeWeightRepository({this.byGoods = const {}}) : super(ApiClient(Dio()));

  /// 货品 id -> 参数; 没列的货品不返回 (格子退回「可选」)。
  final Map<String, WeightParams> byGoods;
  final requests = <List<String>>[];

  @override
  Future<Map<String, WeightParams>> params(
    Iterable<WeightParamsLine> lines,
  ) async {
    final list = lines.toList();
    requests.add([for (final line in list) line.goodsId]);
    return {for (final line in list) line.key: ?byGoods[line.goodsId]};
  }
}

/// ProviderScope 覆盖: 页内单重参数走假仓储。
Override fakeWeightRepositoryOverride([FakeWeightRepository? repository]) =>
    weightRepositoryProvider.overrideWithValue(
      repository ?? FakeWeightRepository(),
    );
