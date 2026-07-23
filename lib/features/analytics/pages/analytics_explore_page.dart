// 多维分析页（Phase 5）
// 文档：docs/03-页面/多维分析页.md

import 'package:flutter/material.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/theme/uten_colors.dart';

class AnalyticsExplorePage extends StatefulWidget {
  const AnalyticsExplorePage({super.key});

  @override
  State<AnalyticsExplorePage> createState() => _AnalyticsExplorePageState();
}

class _AnalyticsExplorePageState extends State<AnalyticsExplorePage> {
  String _dim = '部门'; // 维度
  String _metric = '产量'; // 指标

  static const _dims = ['部门', '产线', '产品'];
  static const _metrics = ['产量', '合格率', '成本'];

  // mock 透视数据
  Map<String, num> get _data {
    if (_dim == '部门') {
      return switch (_metric) {
        '产量' => {'生产部': 8500, '质量部': 0, '人事部': 0, '财务部': 0, '其他': 4300},
        '合格率' => {'生产部': 98.6, '质量部': 99.1, '人事部': 0, '财务部': 0, '其他': 97.8},
        _ => {'生产部': 96, '质量部': 24, '人事部': 30, '财务部': 18, '其他': 92},
      };
    }
    if (_dim == '产线') {
      return switch (_metric) {
        '产量' => {'一号线': 2380, '二号线': 1740, '三号线': 1280, '组装线': 0},
        '合格率' => {'一号线': 98.9, '二号线': 98.5, '三号线': 98.6, '组装线': 0},
        _ => {'一号线': 80, '二号线': 70, '三号线': 60, '组装线': 50},
      };
    }
    return switch (_metric) {
      '产量' => {'产品A': 3500, '产品B': 1740, '产品C': 1280, '产品D': 4280},
      '合格率' => {'产品A': 99.1, '产品B': 98.5, '产品C': 98.0, '产品D': 98.8},
      _ => {'产品A': 90, '产品B': 70, '产品C': 60, '产品D': 40},
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final data = _data;
    final max = data.values.fold<num>(1, (a, b) => a > b ? a : b);
    final unit = _metric == '产量' ? '件' : _metric == '合格率' ? '%' : '万';

    return Scaffold(
      appBar: const UtenAppBar(title: '多维分析', subtitle: '本月 · 全公司', showBackButton: true),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 维度/指标选择
                UtenCard(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: _dim,
                          decoration: const InputDecoration(
                              labelText: '维度', border: OutlineInputBorder(), isDense: true),
                          items: [for (final d in _dims) DropdownMenuItem(value: d, child: Text(d))],
                          onChanged: (v) => setState(() => _dim = v!),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: _metric,
                          decoration: const InputDecoration(
                              labelText: '指标', border: OutlineInputBorder(), isDense: true),
                          items: [for (final m in _metrics) DropdownMenuItem(value: m, child: Text(m))],
                          onChanged: (v) => setState(() => _metric = v!),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                UtenSectionHeader(title: '$_dim × $_metric'),
                const SizedBox(height: 8),
                UtenCard(
                  child: Column(
                    children: [
                      for (final e in data.entries) ...[
                        Row(
                          children: [
                            SizedBox(width: 70, child: Text(e.key, style: theme.textTheme.bodyMedium)),
                            const SizedBox(width: 8),
                            Expanded(
                              child: FractionallySizedBox(
                                alignment: Alignment.centerLeft,
                                widthFactor: (e.value / max).clamp(0.01, 1),
                                child: Container(
                                  height: 16,
                                  decoration: BoxDecoration(
                                    color: UtenColors.teal600,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 70,
                              child: Text('${e.value.toStringAsFixed(1)} $unit',
                                  textAlign: TextAlign.right,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                      fontWeight: FontWeight.w600,
                                      fontFeatures: const [FontFeature.tabularFigures()])),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                const UtenSectionHeader(title: '透视表'),
                const SizedBox(height: 8),
                UtenCard(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        color: theme.colorScheme.surfaceContainerHigh,
                        child: Row(
                          children: [
                            Expanded(child: Text(_dim, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
                            SizedBox(
                                width: 100,
                                child: Text(_metric,
                                    textAlign: TextAlign.right,
                                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
                          ],
                        ),
                      ),
                      for (final e in data.entries) ...[
                        ListTile(
                          dense: true,
                          title: Text(e.key),
                          trailing: Text('${e.value.toStringAsFixed(1)} $unit',
                              style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
                        ),
                        if (e.key != data.keys.last)
                          Divider(height: 1, color: theme.colorScheme.outlineVariant),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
