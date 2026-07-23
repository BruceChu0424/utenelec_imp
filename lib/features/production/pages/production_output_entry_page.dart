// 产量录入页（Phase 4）
// 文档：docs/03-页面/产量录入页.md

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_bottom_action_bar.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/theme/uten_colors.dart';
import '../models/production.dart';
import '../providers/production_providers.dart';

class ProductionOutputEntryPage extends ConsumerStatefulWidget {
  const ProductionOutputEntryPage({super.key});

  @override
  ConsumerState<ProductionOutputEntryPage> createState() =>
      _ProductionOutputEntryPageState();
}

class _ProductionOutputEntryPageState
    extends ConsumerState<ProductionOutputEntryPage> {
  final _lines = ['一号线', '二号线', '三号线', '组装线'];
  final _products = ['产品A', '产品B', '产品C', '产品D'];
  String _line = '一号线';
  String _product = '产品A';
  Shift _shift = Shift.day;
  final _qualified = TextEditingController();
  final _unqualified = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _qualified.dispose();
    _unqualified.dispose();
    super.dispose();
  }

  Future<void> _save({required bool keepGoing}) async {
    final q = int.tryParse(_qualified.text) ?? 0;
    if (q <= 0) {
      _toast('请输入合格数');
      return;
    }
    final uq = int.tryParse(_unqualified.text) ?? 0;
    setState(() => _saving = true);
    await ref.read(productionRepositoryProvider).addOutput(ProductionOutput(
          id: 'o-${DateTime.now().millisecondsSinceEpoch}',
          line: _line,
          product: _product,
          shift: _shift,
          qualified: q,
          unqualified: uq,
          date: DateTime.now(),
          operatorName: '张优腾',
        ));
    if (mounted) {
      setState(() => _saving = false);
      ref.invalidate(productionOutputListProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(keepGoing ? '已录入，可继续' : '已保存（Mock）')),
      );
      _qualified.clear();
      _unqualified.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final outputs = ref.watch(productionOutputListProvider).valueOrNull ?? const [];

    return Scaffold(
      appBar: const UtenAppBar(title: '产量录入', showBackButton: true),
      bottomNavigationBar: UtenBottomActionBar(
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _saving ? null : () => _save(keepGoing: true),
                child: const Text('保存并继续'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: _saving ? null : () => _save(keepGoing: false),
                child: const Text('保存'),
              ),
            ),
          ],
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                UtenCard(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      _Dropdown(
                        label: '产线', value: _line, items: _lines,
                        onChanged: (v) => setState(() => _line = v!),
                      ),
                      _Dropdown(
                        label: '产品', value: _product, items: _products,
                        onChanged: (v) => setState(() => _product = v!),
                      ),
                      Row(
                        children: [
                          const Text('班次'),
                          const SizedBox(width: 12),
                          SegmentedButton<Shift>(
                            selected: {_shift},
                            onSelectionChanged: (s) =>
                                setState(() => _shift = s.first),
                            segments: const [
                              ButtonSegment(value: Shift.day, label: Text('白班')),
                              ButtonSegment(value: Shift.night, label: Text('夜班')),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _qualified,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: '合格数 *',
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: TextField(
                              controller: _unqualified,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: '不良数',
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                const UtenSectionHeader(title: '今日已录入'),
                const SizedBox(height: 8),
                if (outputs.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('暂无记录', style: TextStyle(color: UtenColors.slate400)),
                  )
                else
                  UtenCard(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      children: [
                        for (final o in outputs.take(6)) ...[
                          ListTile(
                            dense: true,
                            leading: const Icon(Icons.conveyor_belt,
                                color: UtenColors.teal600, size: 20),
                            title: Text('${o.line} · ${o.product} · ${o.shift == Shift.day ? '白班' : '夜班'}'),
                            subtitle: Text('${o.date.month}/${o.date.day}  合格 ${o.qualified}  不良 ${o.unqualified}',
                                style: theme.textTheme.bodySmall),
                          ),
                          if (o != outputs.take(6).last)
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

  void _toast(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
}

class _Dropdown extends StatelessWidget {
  const _Dropdown({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });
  final String label;
  final String value;
  final List<String> items;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: DropdownButtonFormField<String>(
          initialValue: value,
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
          ),
          items: [for (final i in items) DropdownMenuItem(value: i, child: Text(i))],
          onChanged: onChanged,
        ),
      );
}
