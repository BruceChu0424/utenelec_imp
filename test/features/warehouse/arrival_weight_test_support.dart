// 仓库采集页测试的重量接线替身 (ADR-135): 到货登记 / 产成品登记 / 仓库单据编辑页共用。
//
// - 单重参数不走网络: [FakeWeightRepository] 按货品返回预置参数并记下每次请求;
// - 单位 -> 重量单位字典直接给值 (默认没有重量单位);
// - 录入/显示单位偏好放内存 (不推服务端、不碰本地缓存)。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/shared/measurement/weight_mass_units.dart';
import 'package:uten_imp/shared/measurement/weight_params.dart';
import 'package:uten_imp/shared/measurement/weight_predictor.dart';
import 'package:uten_imp/shared/measurement/weight_prefs.dart';
import 'package:uten_imp/shared/measurement/weight_unit.dart';

class MemoryWeightUnitsPrefs extends WarehouseWeightUnitsPrefsNotifier {
  MemoryWeightUnitsPrefs([this.initial = const WeightUnitsPrefs()]);

  final WeightUnitsPrefs initial;

  @override
  WeightUnitsPrefs build() => initial;

  @override
  void persist() {}
}

/// 按货品返回预置单重参数 (键按请求行重写); 没预置的货品不返回 (= 没学过)。
class FakeWeightRepository extends WeightRepository {
  FakeWeightRepository(super.api, {this.byGoods = const {}});

  final Map<String, WeightParams> byGoods;
  final List<List<WeightParamsLine>> requests = [];

  @override
  Future<Map<String, WeightParams>> params(
    Iterable<WeightParamsLine> lines,
  ) async {
    final list = lines.toList(growable: false);
    requests.add(list);
    return {for (final line in list) line.key: ?byGoods[line.goodsId]};
  }
}

/// 页面测试的重量 overrides: 追加到各 ProviderScope / ProviderContainer 的 overrides 里。
List<Override> warehouseWeightTestOverrides(
  ApiClient api, {
  FakeWeightRepository? repository,
  Map<String, WeightUnit> massUnits = const {},
  WeightUnitsPrefs prefs = const WeightUnitsPrefs(),
}) => [
  weightRepositoryProvider.overrideWithValue(
    repository ?? FakeWeightRepository(api),
  ),
  warehouseUnitMassUnitsProvider.overrideWith((ref) async => massUnits),
  warehouseWeightUnitsPrefsProvider.overrideWith(
    () => MemoryWeightUnitsPrefs(prefs),
  ),
];

/// 学准了的单重: 约 2.0 g/个, 可参考 (金样 S18 供应商 A 口径)。
const learnedTwoGramParams = WeightParams(
  key: '',
  goodsId: '',
  basis: WeightBasis.learned,
  evidence: 'REFERENCE',
  logMean: -6.214979467174846,
  lotPrior: 3.869930380683166e-05,
  df: 15,
  tier: WeightTier.yellow,
  nInliers: 12,
  tolerancePct: 3,
);

/// 货品按千克计 (重量由数量精确换算)。
const exactKgParams = WeightParams(
  key: '',
  goodsId: '',
  basis: WeightBasis.exact,
  massFactorKg: 1,
);
