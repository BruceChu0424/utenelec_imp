// 新建生产计划单「从订单带明细」弹窗。
//
// 选好来源销售订单后弹出：列出该订单的货品明细（订货量 / 已排产 / 待排产缺口 / 交货日），
// 每行可展开看该货品的一层 BOM 零件清单（单件用量 × 缺口 = 需求小计 + 即时库存 + 自制标记），
// 勾选要排产的行（缺口>0 默认勾选）→ 确认返回所选行，由编辑页填入明细网格。
// 带入的行携 salesOrderItemId，计划审核时走手工 1:1 link 分支回写 planned_qty，业务链闭合。
//
// 数据源：GET /production/schedule/order-lines?orderId=（仅已审核订单）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../repositories/production_repository.dart';

/// 弹出「从订单带明细」面板；返回勾选行（null=取消）。
Future<List<ScheduleOrderLine>?> showPlanOrderImportSheet(
  BuildContext context,
  WidgetRef ref, {
  required String orderId,
  required String billNo,
}) {
  final sheet = _ImportSheet(orderId: orderId, billNo: billNo);
  if (context.breakpoint.isCompact) {
    return showModalBottomSheet<List<ScheduleOrderLine>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(UtenRadius.lg),
        ),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: SizedBox(
          height: MediaQuery.sizeOf(ctx).height * 0.9,
          child: sheet,
        ),
      ),
    );
  }
  return showGeneralDialog<List<ScheduleOrderLine>>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 250),
    pageBuilder: (ctx, _, _) => Align(
      alignment: Alignment.centerRight,
      child: Material(
        color: Theme.of(ctx).colorScheme.surface,
        child: SizedBox(width: 760, height: double.infinity, child: sheet),
      ),
    ),
    transitionBuilder: (ctx, anim, _, child) => SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
      child: child,
    ),
  );
}

class _ImportSheet extends ConsumerStatefulWidget {
  const _ImportSheet({required this.orderId, required this.billNo});

  final String orderId;
  final String billNo;

  @override
  ConsumerState<_ImportSheet> createState() => _ImportSheetState();
}

class _ImportSheetState extends ConsumerState<_ImportSheet> {
  List<ScheduleOrderLine>? _lines;
  String? _error;

  /// 勾选状态：orderItemId（默认勾选缺口>0 的行）。
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    try {
      final lines = await ref
          .read(productionPlanRepositoryProvider)
          .scheduleOrderLines(widget.orderId);
      if (!mounted) return;
      setState(() {
        _lines = lines;
        _selected
          ..clear()
          ..addAll(
            lines.where((l) => (l.needQty ?? 0) > 0).map((l) => l.orderItemId),
          );
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = productionErrorMessage(e, fallback: '加载订单明细失败'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lines = _lines;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                UtenSpacing.s8,
                UtenSpacing.s12,
                UtenSpacing.s4,
                UtenSpacing.s8,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '订单 ${widget.billNo} 的货品',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                UtenSpacing.s16,
                0,
                UtenSpacing.s16,
                UtenSpacing.s8,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '勾选要排产的货品行带入计划明细；点行可展开查看该产品的零件（BOM）',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _error != null
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _error!,
                            style: TextStyle(color: theme.colorScheme.error),
                          ),
                          const SizedBox(height: UtenSpacing.s8),
                          UtenButton(
                            type: UtenButtonType.tonal,
                            onPressed: _load,
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    )
                  : lines == null
                  ? const Center(
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    )
                  : lines.isEmpty
                  ? const Center(child: Text('该订单没有可排产的货品行'))
                  : ListView.separated(
                      padding: const EdgeInsets.all(UtenSpacing.s12),
                      itemCount: lines.length,
                      separatorBuilder: (_, _) =>
                          const SizedBox(height: UtenSpacing.s8),
                      itemBuilder: (_, i) => _lineCard(lines[i]),
                    ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(UtenSpacing.s12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '已选 ${_selected.length} 行',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: UtenSpacing.s16),
                  UtenButton(
                    type: UtenButtonType.secondary,
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: UtenSpacing.s12),
                  UtenButton(
                    icon: Icons.playlist_add_rounded,
                    onPressed: _selected.isEmpty || lines == null
                        ? null
                        : () => Navigator.of(context).pop([
                            for (final l in lines)
                              if (_selected.contains(l.orderItemId)) l,
                          ]),
                    child: const Text('带入明细'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _lineCard(ScheduleOrderLine l) {
    final theme = Theme.of(context);
    final need = l.needQty ?? 0;
    final plannable = need > 0;
    final checked = _selected.contains(l.orderItemId);
    final deliver = l.deliverDate == null
        ? '交货未定'
        : '交货 ${l.deliverDate!.substring(0, 10)}';
    return Material(
      color: theme.colorScheme.surface,
      borderRadius: UtenRadius.mdAll,
      clipBehavior: Clip.antiAlias,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: theme.colorScheme.outlineVariant),
          borderRadius: UtenRadius.mdAll,
        ),
        child: ExpansionTile(
          // 无 BOM 的行不显示展开箭头（checkbox 勾选不受影响）
          trailing: l.bom.isEmpty ? const SizedBox.shrink() : null,
          tilePadding: const EdgeInsets.only(right: UtenSpacing.s8),
          leading: Checkbox(
            value: checked,
            onChanged: plannable
                ? (v) => setState(() {
                    if (v ?? false) {
                      _selected.add(l.orderItemId);
                    } else {
                      _selected.remove(l.orderItemId);
                    }
                  })
                : null,
          ),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  '${l.goodsName ?? l.goodsCode ?? '—'}'
                  '${l.spec != null && l.spec!.isNotEmpty ? ' · ${l.spec}' : ''}'
                  '${l.colorName != null ? ' · ${l.colorName}' : ''}',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (l.bom.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${l.bom.length} 种零件',
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
            ],
          ),
          subtitle: Text(
            '订货 ${_fmt(l.qty)} · 已排 ${_fmt(l.plannedQty)} · '
            '缺口 ${_fmt(l.needQty)}${l.unitName != null ? ' ${l.unitName}' : ''}'
            ' · $deliver'
            '${plannable ? '' : '（已排完）'}',
            style: TextStyle(
              fontSize: 11,
              color: plannable
                  ? theme.colorScheme.onSurfaceVariant
                  : theme.colorScheme.error,
            ),
          ),
          children: [
            if (l.bom.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  UtenSpacing.s16,
                  0,
                  UtenSpacing.s16,
                  UtenSpacing.s12,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '零件清单（按缺口 ${_fmt(l.needQty)} 折算需求）',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s4),
                    for (final b in l.bom) _bomRow(b),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _bomRow(ScheduleBomComponent b) {
    final theme = Theme.of(context);
    final shortage = (b.onhand ?? 0) < (b.needQty ?? 0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${b.name ?? b.code ?? '—'}'
              '${b.spec != null && b.spec!.isNotEmpty ? ' · ${b.spec}' : ''}'
              '${b.selfMade ? '（自制）' : ''}',
              style: const TextStyle(fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          _bomNum(theme, '单件', b.perQty),
          _bomNum(theme, '需求', b.needQty, highlight: true, danger: shortage),
          _bomNum(theme, '库存', b.onhand, danger: shortage),
        ],
      ),
    );
  }

  Widget _bomNum(
    ThemeData theme,
    String label,
    double? v, {
    bool highlight = false,
    bool danger = false,
  }) {
    return SizedBox(
      width: 72,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            _fmt(v),
            style: TextStyle(
              fontSize: 12,
              fontWeight: highlight || danger
                  ? FontWeight.w700
                  : FontWeight.normal,
              color: danger ? theme.colorScheme.error : null,
            ),
          ),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  String _fmt(double? v) => v == null
      ? '—'
      : (v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2));
}
