/// 定点 4 位小数分摊的「最粗守恒」呈现与整分。
///
/// 服务端的还缺/建议量按 1e-4 tick 分摊，会落在 83.3334 这类值上；对整数计量的
/// 物料，展示与编辑直接用最粗的守恒精度（优先整数），避免小数尾巴层层上屏。
/// 守恒不变量：任何 scale 下各份之和恒等于该 scale 下对总量的取整值。
///
/// 全部为纯函数、无 Flutter 依赖；输入按非负、至多 4 位小数对待（服务端与
/// 输入框的共同口径），内部一律换算成整数 tick 运算，避免浮点累积尾差。
library;

import '../../../shared/formatters/exact_decimal.dart';

const int _maxScale = 4;

const _factors = [1, 10, 100, 1000, 10000];

/// 10^-scale 粒度上的「一个 tick」的值（1、0.1、…、0.0001）。
double unitOfScale(int scale) {
  assert(scale >= 0 && scale <= _maxScale);
  return 1 / _factors[scale];
}

/// [v] 在 10^-scale 粒度上的整数 tick 数（四舍五入；输入不带负数）。
int grainOf(double v, int scale) {
  assert(scale >= 0 && scale <= _maxScale);
  return _nearInteger(v * _factors[scale]).round();
}

/// [v] 取整到 10^-scale（四舍五入，与服务端分摊的定点口径一致）。
double roundToScale(double v, int scale) => grainOf(v, scale) / _factors[scale];

/// [v] 向上取整到 10^-scale（保守向上，与服务端建议量 CEILING 口径同向）。
double ceilToScale(double v, int scale) =>
    _ceilTicks(v, scale) / _factors[scale];

/// 浮点乘除会让「本该是整数」的值带上 1e-9 级噪声；先吸掉再取整。
double _nearInteger(double v) {
  final rounded = v.roundToDouble();
  return (v - rounded).abs() < 1e-6 ? rounded : v;
}

int _ceilTicks(double v, int scale) => _nearInteger(v * _factors[scale]).ceil();

/// 已经换算成 tick 的份额取 floor（不再乘粒度因子）。
int _floorTicks(double ticks) => _nearInteger(ticks).floor();

/// 在 10^-scale 粒度上按权重做最大余数法整分：
/// 先 floor 各份额（整数 tick 运算），余数（总 tick − 已分 tick）按小数部分
/// 从大到小逐份 +1 tick，同小数部分按索引序。保证 Σshares == roundToScale(total,
/// scale)，且每份 ≥ 0；零权重份不参与分配（份额为 0），权重全零时均分。
List<double> apportionLargestRemainder(
  double total,
  List<double> weights,
  int scale,
) {
  assert(scale >= 0 && scale <= _maxScale);
  final count = weights.length;
  if (count == 0) return const [];
  final totalTicks = grainOf(total, scale);
  var weightTotal = 0.0;
  for (final weight in weights) {
    if (weight > 0) weightTotal += weight;
  }
  if (weightTotal <= 0) {
    // 权重全零：均分，余数按索引序逐份 +1。
    final base = totalTicks ~/ count;
    final extra = totalTicks - base * count;
    return [
      for (var i = 0; i < count; i++)
        (base + (i < extra ? 1 : 0)) / _factors[scale],
    ];
  }
  final exact = [
    for (final weight in weights)
      totalTicks * (weight > 0 ? weight : 0) / weightTotal,
  ];
  final ticks = [for (final share in exact) _floorTicks(share)];
  var remaining = totalTicks - ticks.fold<int>(0, (sum, tick) => sum + tick);
  if (remaining < 0) remaining = 0;
  // 小数部分从大到小补 1 tick；同小数部分按索引序（稳定排序）。
  final order = [for (var i = 0; i < count; i++) i]
    ..sort((a, b) {
      final byFraction = (exact[b] - ticks[b]).compareTo(exact[a] - ticks[a]);
      return byFraction != 0 ? byFraction : a.compareTo(b);
    });
  for (var i = 0; i < remaining && i < order.length; i++) {
    ticks[order[i]] += 1;
  }
  return [for (final tick in ticks) tick / _factors[scale]];
}

/// 从 0 到 4 找最粗的 scale p：按 p 整分后每份与原值的偏差都不超过一个粒度
/// （10^-p），且正的总量不会被取整抹成 0；找不到就用 4。
///
/// 「正量不消失」是不可省的一半：parts=[0.0005, 0.0005]、total=0.001 在 p=0
/// 时整分成 [0, 0]，偏差虽在一个粒度内，但整组缺口被显示成 0——只能退到 p=3。
int coarsestDisplayScale(double total, List<double> parts) {
  if (parts.isEmpty) return 0;
  for (var scale = 0; scale <= _maxScale; scale++) {
    final unit = unitOfScale(scale);
    final shares = apportionLargestRemainder(total, parts, scale);
    var withinOneGrain = true;
    var shareTicks = 0;
    for (var i = 0; i < parts.length; i++) {
      if ((shares[i] - parts[i]).abs() > unit + 1e-9) {
        withinOneGrain = false;
        break;
      }
      shareTicks += grainOf(shares[i], scale);
    }
    if (withinOneGrain && (total <= 0 || shareTicks > 0)) return scale;
  }
  return _maxScale;
}

/// 编辑层平分：把用户敲进汇总格的总量按各路径「还需安排」落到 10^-scale 上。
///
/// - 总量盖得住各路径 ceil 后的合计：先各路径给足 ceil 的量（0 需求路径为 0，
///   不打扰），富余按 evenShare 语义（均分、余数逐份 +1 tick）加给有需求的
///   路径，全都无需求（纯公共备货）才全体均分；
/// - 盖不住：按 needs 权重 [apportionLargestRemainder] 整分，行间仍是公平的。
///
/// Σshares == roundToScale(total, scale)；份额可超出各自的 need（总量富余时）。
List<double> splitTypedTotal(double total, List<double> needs, int scale) {
  assert(scale >= 0 && scale <= _maxScale);
  final count = needs.length;
  if (count == 0) return const [];
  final totalTicks = grainOf(total, scale);
  final ceilTicks = [
    for (final need in needs) need > 0 ? _ceilTicks(need, scale) : 0,
  ];
  final ceilTotal = ceilTicks.fold<int>(0, (sum, tick) => sum + tick);
  if (totalTicks < ceilTotal) {
    return apportionLargestRemainder(total, needs, scale);
  }
  final ticks = [...ceilTicks];
  final surplus = (totalTicks - ceilTotal).clamp(0, totalTicks);
  if (surplus > 0) {
    // 与旧 evenShare 同语义：富余只分给有需求的来源，全都无需求才全体均分。
    final withNeed = [
      for (var i = 0; i < count; i++)
        if (needs[i] > 0.0000001) i,
    ];
    final candidates = withNeed.isNotEmpty
        ? withNeed
        : [for (var i = 0; i < count; i++) i];
    final base = surplus ~/ candidates.length;
    final extra = surplus - base * candidates.length;
    for (var j = 0; j < candidates.length; j++) {
      ticks[candidates[j]] += base + (j < extra ? 1 : 0);
    }
  }
  return [for (final tick in ticks) tick / _factors[scale]];
}

/// Request quantities retain the user's decimal text even beyond double's
/// exact integer range. The floating-point helpers above serve presentation.
BigInt materialQuantityUnits(String raw, {int scale = _maxScale}) {
  final text = raw.trim().replaceFirst(RegExp(r'\.$'), '');
  final units = financeExactDecimalUnits(text, scale: scale);
  if (units == null || units.isNegative) {
    throw const FormatException('数量必须为非负数，最多 4 位小数');
  }
  return units;
}

String materialQuantityText(BigInt units, {int scale = _maxScale}) {
  final text = financeExactDecimalFromUnits(units, scale: scale);
  return scale == 0
      ? text
      : text.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
}

String materialQuantityFact(String? exact, double legacy) {
  if (exact != null) return materialQuantityText(materialQuantityUnits(exact));
  if (!legacy.isFinite || legacy.abs() >= 10000000000) return 'NaN';
  return materialQuantityText(materialQuantityUnits(legacy.toStringAsFixed(4)));
}

/// Unit rates have six decimal places, independently of four-place quantities.
String materialUnitRateFact(String? exact, double? legacy) {
  final String text;
  if (exact != null) {
    text = exact;
  } else if (legacy == null) {
    text = '1';
  } else {
    if (!legacy.isFinite || legacy <= 0 || legacy >= 1000000) {
      throw const FormatException('缺少精确单位比例，请刷新或更新服务端');
    }
    text = legacy.toStringAsFixed(6);
  }
  final units = financeExactDecimalUnits(text, scale: 6);
  if (units == null || units <= BigInt.zero) {
    throw const FormatException('单位比例必须为正数且最多6位小数');
  }
  return materialQuantityText(units, scale: 6);
}

String materialQuantityProduct(String left, String right) {
  final product = financeExactMultiplyTexts([left, right]);
  if (product == null) throw const FormatException('数量单位换算缺少精确值');
  final normalized = product.contains('.')
      ? product
            .replaceFirst(RegExp(r'0+$'), '')
            .replaceFirst(RegExp(r'\.$'), '')
      : product;
  return materialQuantityText(materialQuantityUnits(normalized));
}

String materialQuantityQuotient(String quantity, String rate) {
  final value = materialQuantityUnits(quantity);
  final text = rate.trim();
  final dot = text.indexOf('.');
  final scale = dot < 0 ? 0 : text.length - dot - 1;
  final divisor = financeExactDecimalUnits(text, scale: scale);
  if (divisor == null || divisor <= BigInt.zero) {
    throw const FormatException('数量单位换算比例无效');
  }
  final numerator = value * BigInt.from(10).pow(scale);
  if (numerator % divisor != BigInt.zero) {
    throw const FormatException('数量无法按来源单位精确换算');
  }
  return materialQuantityText(numerator ~/ divisor);
}

String materialQuantityWithOrderPolicy(
  String quantity,
  String minimum,
  String multiple,
) {
  var value = materialQuantityUnits(quantity);
  if (value == BigInt.zero) return '0';
  final floor = materialQuantityUnits(minimum),
      step = materialQuantityUnits(multiple);
  if (value < floor) value = floor;
  if (step > BigInt.zero) value = ((value + step - BigInt.one) ~/ step) * step;
  return materialQuantityText(value);
}

/// The same editing split as [splitTypedTotal], with no binary conversion on
/// the request path. Granularity follows the typed total; each returned part
/// and their sum are exact on both Dart VM and JavaScript.
List<String> splitTypedTotalText(String total, List<String> needs) {
  final text = total.trim();
  final dot = text.indexOf('.');
  final scale = dot < 0 ? 0 : text.length - dot - 1;
  if (scale > _maxScale) {
    throw const FormatException('数量最多 4 位小数');
  }
  final totalTicks = materialQuantityUnits(text, scale: scale);
  if (needs.isEmpty) return const [];
  final needTicks = [for (final need in needs) materialQuantityUnits(need)];
  final divisor = BigInt.from(10).pow(_maxScale - scale);
  final ceilings = [
    for (final need in needTicks) (need + divisor - BigInt.one) ~/ divisor,
  ];
  final required = ceilings.fold(BigInt.zero, (sum, value) => sum + value);
  final ticks = [...ceilings];
  if (totalTicks >= required) {
    final positive = [
      for (var i = 0; i < needTicks.length; i++)
        if (needTicks[i] > BigInt.zero) i,
    ];
    final recipients = positive.isEmpty
        ? [for (var i = 0; i < needs.length; i++) i]
        : positive;
    final extra = totalTicks - required;
    final count = BigInt.from(recipients.length);
    final each = extra ~/ count;
    final remainder = (extra % count).toInt();
    for (var i = 0; i < recipients.length; i++) {
      ticks[recipients[i]] += each + (i < remainder ? BigInt.one : BigInt.zero);
    }
  } else {
    final weight = needTicks.fold(BigInt.zero, (sum, value) => sum + value);
    final remainders = <BigInt>[];
    for (var i = 0; i < needTicks.length; i++) {
      final product = totalTicks * needTicks[i];
      ticks[i] = product ~/ weight;
      remainders.add(product % weight);
    }
    final remaining =
        (totalTicks - ticks.fold(BigInt.zero, (sum, value) => sum + value))
            .toInt();
    final order = [for (var i = 0; i < ticks.length; i++) i]
      ..sort((a, b) {
        final byFraction = remainders[b].compareTo(remainders[a]);
        return byFraction != 0 ? byFraction : a.compareTo(b);
      });
    for (var i = 0; i < remaining; i++) {
      ticks[order[i]] += BigInt.one;
    }
  }
  return [for (final tick in ticks) materialQuantityText(tick, scale: scale)];
}
