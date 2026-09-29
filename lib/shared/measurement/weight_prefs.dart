// 仓库重量单位偏好 (ADR-135 §6.1): 按账号服务端持久化, 全仓库页面共用一份。
//
// 三个用户级选择 (不做按页/按货品的单位记忆, 见 review/product.md issue 13):
// - entry  : 录入单位 (采集表格「实称重量(kg)」列与「称重单位: 千克▾」工具条下拉);
// - display: 显示单位 (即时库存/流水/分析等只读表格, 默认「自动」按量级);
// - sample : 抽样单位 (称样校准/称重计数的抽样重量, 默认克)。
// 存储形态 {entry:'KG', display:'AUTO', sample:'G'}; 三层同步策略继承 UtenPagePrefsNotifier。
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/uten_page_prefs_notifier.dart';
import 'weight_unit.dart';

class WeightUnitsPrefs {
  const WeightUnitsPrefs({
    this.entry = WeightUnit.kg,
    this.display = WeightDisplay.auto,
    this.sample = WeightUnit.g,
  });

  final WeightUnit entry;
  final WeightDisplay display;
  final WeightUnit sample;

  WeightUnitsPrefs copyWith({
    WeightUnit? entry,
    WeightDisplay? display,
    WeightUnit? sample,
  }) => WeightUnitsPrefs(
    entry: entry ?? this.entry,
    display: display ?? this.display,
    sample: sample ?? this.sample,
  );

  Map<String, Object?> toJson() => {
    'entry': entry.code,
    'display': display.code,
    'sample': sample.code,
  };

  /// 缓存 JSON / 服务端原值 (Map 或其 JSON 字符串) -> 偏好; 认不出返回 null。
  static WeightUnitsPrefs? fromJson(Object? raw) {
    var value = raw;
    if (value is String) {
      try {
        value = jsonDecode(value);
      } catch (_) {
        return null;
      }
    }
    if (value is! Map) return null;
    return WeightUnitsPrefs(
      entry: WeightUnit.fromCode(value['entry']?.toString()),
      display: WeightDisplay.fromCode(value['display']?.toString()),
      sample: WeightUnit.fromCode(
        value['sample']?.toString(),
        fallback: WeightUnit.g,
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is WeightUnitsPrefs &&
      other.entry == entry &&
      other.display == display &&
      other.sample == sample;

  @override
  int get hashCode => Object.hash(entry, display, sample);
}

class WarehouseWeightUnitsPrefsNotifier
    extends UtenPagePrefsNotifier<WeightUnitsPrefs> {
  static const _prefKey = 'warehouse.weightUnits';

  @override
  String get prefKey => _prefKey;

  @override
  WeightUnitsPrefs get defaultValue => const WeightUnitsPrefs();

  @override
  WeightUnitsPrefs? decode(Object? raw) => WeightUnitsPrefs.fromJson(raw);

  @override
  Object? encode(WeightUnitsPrefs state) => state.toJson();

  void setEntry(WeightUnit unit) {
    if (state.entry == unit) return;
    update(state.copyWith(entry: unit));
  }

  void setDisplay(WeightDisplay display) {
    if (state.display == display) return;
    update(state.copyWith(display: display));
  }

  void setSample(WeightUnit unit) {
    if (state.sample == unit) return;
    update(state.copyWith(sample: unit));
  }
}

final warehouseWeightUnitsPrefsProvider =
    NotifierProvider<WarehouseWeightUnitsPrefsNotifier, WeightUnitsPrefs>(
      WarehouseWeightUnitsPrefsNotifier.new,
    );
