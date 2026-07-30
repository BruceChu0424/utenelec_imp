// DocKpiBar - 单据列表顶部的 KPI 摘要条（总数/草稿/已审/红冲）。
//
// 把"稀疏的表格列表"升级成"一眼看懂业务"的看板：4 个可点 KPI 卡既是指标又是状态筛选。
// counter(status) 由调用方提供（通常调 list(size:1,status:X).total，并行 4 次，无需后端改）。
// 复用：采购 4 单据 / 仓库 8 单据 / 销售 / 委外… 任何"主从表单据列表"。
import 'package:flutter/material.dart';

class DocKpiBar extends StatefulWidget {
  const DocKpiBar({
    super.key,
    required this.counter,
    required this.selected,
    required this.onSelect,
  });

  /// 返回某状态的totalCount（null=全部）。调用方并行调用。
  final Future<int> Function(int? status) counter;

  /// 当前选中状态（null=全部）。
  final int? selected;

  /// 点击某状态卡。
  final ValueChanged<int?> onSelect;

  @override
  State<DocKpiBar> createState() => _DocKpiBarState();
}

class _DocKpiBarState extends State<DocKpiBar> {
  static const _statuses = <_Kpi>[
    _Kpi('全部', null, null),
    _Kpi('草稿', 0, _KpiColor.neutral),
    _Kpi('已审', 1, _KpiColor.positive),
    _Kpi('红冲', -1, _KpiColor.negative),
  ];

  final _counts = <int?, int?>{null: null, 0: null, 1: null, -1: null};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // 并行取 4 个状态计数（-1 表示失败，显示 '—'）。
    final vals = await Future.wait(
      _statuses.map((s) async {
        try {
          return await widget.counter(s.value);
        } catch (_) {
          return -1;
        }
      }),
    );
    if (!mounted) return;
    setState(() {
      for (var i = 0; i < _statuses.length; i++) {
        _counts[_statuses[i].value] = vals[i] < 0 ? null : vals[i];
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 76,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        itemCount: _statuses.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (ctx, i) {
          final s = _statuses[i];
          final isSel = widget.selected == s.value;
          return _Card(
            kpi: s,
            count: _counts[s.value],
            selected: isSel,
            onTap: () => widget.onSelect(s.value),
          );
        },
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({
    required this.kpi,
    required this.count,
    required this.selected,
    required this.onTap,
  });
  final _Kpi kpi;
  final int? count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = kpi.color == _KpiColor.positive
        ? Colors.green
        : kpi.color == _KpiColor.negative
        ? theme.colorScheme.error
        : theme.colorScheme.primary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 104,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? color.withValues(alpha: 0.12)
              : theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? color : theme.colorScheme.outlineVariant,
            width: selected ? 1.4 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              kpi.label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: selected ? color : theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              count == null ? '—' : _fmt(count!),
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                color: selected ? color : theme.colorScheme.onSurface,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _fmt(int n) {
    if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)}万';
    return n.toString();
  }
}

enum _KpiColor { neutral, positive, negative }

class _Kpi {
  const _Kpi(this.label, this.value, this.color);
  final String label;
  final int? value; // null=全部
  final _KpiColor? color;
}
