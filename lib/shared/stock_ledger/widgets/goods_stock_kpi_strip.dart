// 单货品 KPI 条 (库存面板顶部, ADR-135 §6.3 / review/product.md §1.4):
// 「库存 12,500 个 · ≈28.9 kg | 单重 2.312 g (可参考 ±1.8%) | 最后入库 09-20 · 最后出库 09-26 |
//  90天日均出库 420 个 · 约可用 30 天 | ABC: A | 库龄: 30天内 60%」。
//
// 数字全部来自服务端 (GET /stock/insights/goods/{goodsId}); 取不到时整条隐藏,
// 不影响下面的余额/流水/单重学习。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/china_datetime.dart';
import '../../measurement/weight_prefs.dart';
import '../../measurement/widgets/weight_text.dart';
import '../stock_ledger_models.dart';
import '../stock_ledger_repository.dart';

class GoodsStockKpiStrip extends ConsumerStatefulWidget {
  const GoodsStockKpiStrip({
    super.key,
    required this.goodsId,
    this.unitName,
    this.reloadTick = 0,
    this.showInventory = true,
  });

  final String goodsId;

  /// 基本单位名 (服务端 KPI 没带单位时用)。
  final String? unitName;

  /// 宿主每次刷新 +1, 本条随之重取。
  final int reloadTick;
  final bool showInventory;

  @override
  ConsumerState<GoodsStockKpiStrip> createState() => _GoodsStockKpiStripState();
}

class _GoodsStockKpiStripState extends ConsumerState<GoodsStockKpiStrip> {
  GoodsStockInsight? _insight;
  int _version = 0;
  bool _loading = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant GoodsStockKpiStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reloadTick != widget.reloadTick ||
        oldWidget.goodsId != widget.goodsId) {
      _load();
    }
  }

  Future<void> _load() async {
    final version = ++_version;
    setState(() {
      _loading = true;
      _failed = false;
      _insight = null;
    });
    try {
      final insight = await ref
          .read(goodsStockLedgerRepositoryProvider)
          .goodsInsight(widget.goodsId);
      if (!mounted || version != _version) return;
      setState(() {
        _insight = insight;
        _loading = false;
      });
    } catch (_) {
      // KPI 只是概览: 取不到就不显示, 不打断余额/流水。
      if (!mounted || version != _version) return;
      setState(() {
        _insight = null;
        _loading = false;
        _failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Text('正在读取货品级分析参考…');
    if (_failed) {
      return Wrap(
        key: const ValueKey('goods-stock-kpi-error'),
        spacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Text('货品级分析参考读取失败'),
          TextButton(onPressed: _load, child: const Text('重试分析参考')),
        ],
      );
    }
    final insight = _insight;
    if (insight == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final display = ref.watch(warehouseWeightUnitsPrefsProvider).display;
    final parts = goodsStockKpiParts(
      insight,
      includeInventory: widget.showInventory,
      unitName: widget.unitName,
      weightText: formatWeightValue(
        insight.weightKg,
        display: display,
        estimated: insight.weightEstimated,
      ),
    );
    if (parts.isEmpty) return const SizedBox.shrink();
    return Container(
      key: const ValueKey('goods-stock-kpi-strip'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s12,
        vertical: UtenSpacing.s8,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: UtenRadius.mdAll,
      ),
      child: Wrap(
        spacing: UtenSpacing.s12,
        runSpacing: UtenSpacing.s4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (!widget.showInventory)
            const Text('货品级分析参考（服务端全局口径，与当前仓库/颜色范围不同）：'),
          for (var i = 0; i < parts.length; i++) ...[
            if (i > 0)
              Text(
                '|',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            Text(parts[i], style: theme.textTheme.bodyMedium),
          ],
        ],
      ),
    );
  }
}

/// KPI 条各段文案 (纯函数, 便于测试); 没有数据的段不出现。
List<String> goodsStockKpiParts(
  GoodsStockInsight insight, {
  String? unitName,
  required String weightText,
  bool includeInventory = true,
}) {
  final unit = (insight.unitName ?? unitName ?? '').trim();
  String qty(double v) {
    final text = NumberFormat('#,##0.####', 'zh_CN').format(v);
    if (unit.isEmpty) return text;
    return RegExp(r'^[A-Za-z]').hasMatch(unit) ? '$text $unit' : '$text$unit';
  }

  final parts = <String>[];
  if (includeInventory && insight.qty != null) {
    parts.add('库存 ${qty(insight.qty!)} · $weightText');
  }
  final unitWeight = insight.unitWeightKg;
  if (unitWeight != null && unitWeight > 0) {
    final tier = insight.tier;
    final rel = insight.relHalfWidth;
    final detail = [
      if (tier != null) tier.label,
      if (rel != null && rel.isFinite) '±${(rel * 100).toStringAsFixed(1)}%',
    ].join(' ');
    parts.add(
      '单重 ${formatUnitWeight(unitWeight)}${detail.isEmpty ? '' : ' ($detail)'}',
    );
  }
  final lastIn = _monthDay(insight.lastInAt);
  final lastOut = _monthDay(insight.lastOutAt);
  if (lastIn != null || lastOut != null) {
    parts.add(
      [
        if (lastIn != null) '最后入库 $lastIn',
        if (lastOut != null) '最后出库 $lastOut',
      ].join(' · '),
    );
  }
  final avg = insight.avgDailyOut90;
  if (avg != null && avg > 0) {
    final cover = insight.daysOfCover;
    parts.add(
      [
        '90天日均出库 ${qty(avg)}',
        if (cover != null && cover.isFinite) '约可用 ${cover.round()} 天',
      ].join(' · '),
    );
  }
  final abc = insight.abc?.trim();
  if (abc != null && abc.isNotEmpty) {
    parts.add(abc.toUpperCase() == 'N' ? 'ABC: 近90天无出库' : 'ABC: $abc');
  }
  final young = insight.agePct0To30;
  if (young != null && young.isFinite) {
    parts.add('库龄: 30天内 ${young.round()}%');
  }
  return parts;
}

String? _monthDay(String? iso) {
  final parsed = ChinaDateTime.tryParse(iso);
  if (parsed == null) return null;
  return '${parsed.month.toString().padLeft(2, '0')}-'
      '${parsed.day.toString().padLeft(2, '0')}';
}
