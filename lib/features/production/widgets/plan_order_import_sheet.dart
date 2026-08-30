// 新建生产计划单「从订单带明细」面板。
//
// 有子层级物料时默认全部展开：每个产品卡片直接展示统一只读表格，不提供折叠控件。
// 无子层级物料时按直接自制带入。这里的库存仅用于初筛，正式可生产数量由物料分析
// 按目标仓、安全库存、锁定量与合格供给统一确认。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_anim.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/production_plan.dart';
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
          height: MediaQuery.sizeOf(ctx).height * 0.94,
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
    transitionDuration: UtenAnim.normal,
    pageBuilder: (ctx, _, _) {
      final viewportWidth = MediaQuery.sizeOf(ctx).width;
      final panelWidth = viewportWidth < 920 ? viewportWidth * 0.92 : 840.0;
      return Align(
        alignment: Alignment.centerRight,
        child: Material(
          color: Theme.of(ctx).colorScheme.surface,
          elevation: 12,
          child: SizedBox(
            width: panelWidth,
            height: double.infinity,
            child: sheet,
          ),
        ),
      );
    },
    transitionBuilder: (ctx, anim, _, child) => SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: anim, curve: UtenAnim.standard)),
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

  /// orderItemId；所有仍有排产缺口的产品都可选择。
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
        _error = null;
        _lines = lines;
        _selected
          ..clear()
          ..addAll(
            lines
                .where((line) => (line.needQty ?? 0) > 0)
                .map((line) => line.orderItemId),
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
                UtenSpacing.s16,
                UtenSpacing.s12,
                UtenSpacing.s8,
                UtenSpacing.s8,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '订单 ${widget.billNo} 的产品与物料',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: UtenSpacing.s4),
                        Text(
                          '有子层级物料时在下方展开；无子层级物料时按直接自制带入，不生成领料明细。',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            _inventoryScopeNotice(theme),
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
                  ? const Center(child: Text('该订单没有可排产的产品行'))
                  : ListView.separated(
                      padding: const EdgeInsets.all(UtenSpacing.s12),
                      itemCount: lines.length,
                      separatorBuilder: (_, _) =>
                          const SizedBox(height: UtenSpacing.s12),
                      itemBuilder: (_, i) => _lineCard(lines[i]),
                    ),
            ),
            const Divider(height: 1),
            _footer(lines),
          ],
        ),
      ),
    );
  }

  Widget _inventoryScopeNotice(ThemeData theme) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(
        UtenSpacing.s16,
        0,
        UtenSpacing.s16,
        UtenSpacing.s8,
      ),
      padding: const EdgeInsets.all(UtenSpacing.s8),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.45),
        borderRadius: UtenRadius.smAll,
        border: Border.all(
          color: theme.colorScheme.tertiary.withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline_rounded,
            size: 18,
            color: theme.colorScheme.onTertiaryContainer,
          ),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Text(
              '库存口径：下表只显示当前即时库存，未扣安全库存、其他计划锁定量，也未判断在途是否能在开工前到达。'
              '带入后以物料分析的子层级齐套结果为准；无子层级物料按直接自制处理。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onTertiaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _footer(List<ScheduleOrderLine>? lines) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Wrap(
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: UtenSpacing.s12,
          runSpacing: UtenSpacing.s8,
          children: [
            Text(
              '已选 ${_selected.length} 个产品',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            UtenButton(
              type: UtenButtonType.secondary,
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            UtenButton(
              icon: Icons.playlist_add_rounded,
              onPressed: _selected.isEmpty || lines == null
                  ? null
                  : () => Navigator.of(context).pop([
                      for (final line in lines)
                        if (_selected.contains(line.orderItemId)) line,
                    ]),
              child: const Text('带入计划明细'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _lineCard(ScheduleOrderLine line) {
    final theme = Theme.of(context);
    final need = line.needQty ?? 0;
    final hasChildMaterials = line.bom.isNotEmpty;
    final plannable = need > 0;
    final checked = _selected.contains(line.orderItemId);
    final shortageCount = line.bom.where((item) {
      final onhand = item.onhand;
      final required = item.needQty;
      return onhand != null && required != null && onhand + 1e-6 < required;
    }).length;
    final unknownCount = line.bom
        .where((item) => item.onhand == null || item.needQty == null)
        .length;
    final deliver = line.deliverDate == null
        ? '交货未定'
        : '交货 ${productionDateOnly(line.deliverDate)}';

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Checkbox(
                  value: checked,
                  onChanged: plannable
                      ? (value) => setState(() {
                          if (value ?? false) {
                            _selected.add(line.orderItemId);
                          } else {
                            _selected.remove(line.orderItemId);
                          }
                        })
                      : null,
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${line.goodsName ?? line.goodsCode ?? '未命名产品'}'
                        '${line.spec?.isNotEmpty == true ? ' · ${line.spec}' : ''}'
                        '${line.colorName?.isNotEmpty == true ? ' · ${line.colorName}' : ''}',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: UtenSpacing.s4),
                      Text(
                        '产品编码 ${line.goodsCode ?? '—'} · 订货 ${_fmt(line.qty)} · '
                        '已排 ${_fmt(line.plannedQty)} · 待排 ${_fmt(line.needQty)}'
                        '${line.unitName == null ? '' : ' ${line.unitName}'} · $deliver',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: plannable
                              ? theme.colorScheme.onSurfaceVariant
                              : theme.colorScheme.error,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: UtenSpacing.s8),
                _materialCountBadge(theme, line.bom.length),
              ],
            ),
            const SizedBox(height: UtenSpacing.s8),
            if (!hasChildMaterials)
              _directMakeHint(theme)
            else ...[
              Text(
                '物料明细(按待排数量 ${_fmt(line.needQty)} 折算)',
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: UtenSpacing.s8),
              MasterDataTableView<ScheduleBomComponent>(
                embedded: true,
                columns: [
                  MasterColumnDef(
                    key: 'code',
                    label: '物料编码',
                    width: 130,
                    value: (item) => item.code,
                  ),
                  MasterColumnDef(
                    key: 'name',
                    label: '物料名称',
                    width: 180,
                    value: (item) => item.name,
                  ),
                  MasterColumnDef(
                    key: 'spec',
                    label: '规格',
                    width: 150,
                    value: (item) => item.spec,
                  ),
                  MasterColumnDef(
                    key: 'source',
                    label: '来源',
                    width: 80,
                    value: (item) => item.selfMade ? '自制' : '外购',
                  ),
                  MasterColumnDef(
                    key: 'perQty',
                    label: '单台用量',
                    width: 90,
                    type: 'number',
                    value: (item) => _fmt(item.perQty),
                  ),
                  MasterColumnDef(
                    key: 'needQty',
                    label: '总需求',
                    width: 90,
                    type: 'number',
                    value: (item) => _fmt(item.needQty),
                  ),
                  MasterColumnDef(
                    key: 'onhand',
                    label: '即时库存',
                    width: 90,
                    type: 'number',
                    value: (item) => _fmt(item.onhand),
                  ),
                  MasterColumnDef(
                    key: 'status',
                    label: '初筛状态',
                    width: 110,
                    value: _availabilityStatus,
                  ),
                ],
                items: line.bom,
                facets: const {},
                nullCounts: const {},
                filters: const {},
                onFilterChanged: (_, _) {},
                rowColor: (item) {
                  final onhand = item.onhand;
                  final required = item.needQty;
                  if (onhand == null || required == null) return null;
                  return onhand + 1e-6 < required
                      ? theme.colorScheme.errorContainer.withValues(alpha: 0.28)
                      : theme.colorScheme.primaryContainer.withValues(
                          alpha: 0.18,
                        );
                },
                emptyMessage: '暂无子层级物料',
              ),
              const SizedBox(height: UtenSpacing.s8),
              Text(
                '即时初筛：共 ${line.bom.length} 种，已知缺 $shortageCount 种'
                '${unknownCount == 0 ? '' : '，待复核 $unknownCount 种'}。'
                '物料单位可能不同，不汇总缺口数量；最终以物料分析齐套结果为准。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: shortageCount > 0
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _materialCountBadge(ThemeData theme, int count) {
    final directMake = count == 0;
    final color = theme.colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: UtenRadius.smAll,
      ),
      child: Text(
        directMake ? '无下层物料' : '$count 种物料',
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  /// 无子层级物料的产品按「直接自制」处理，不阻断带入排产。
  Widget _directMakeHint(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: UtenRadius.smAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(
            Icons.info_outline_rounded,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Text(
              '该产品无子层级物料，按直接自制处理：可带入计划，不生成生产领料明细；'
              '最终可生产数量由物料分析确认。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _availabilityStatus(ScheduleBomComponent item) {
    final onhand = item.onhand;
    final required = item.needQty;
    if (onhand == null || required == null) return '待物料分析复核';
    return onhand + 1e-6 >= required ? '即时库存够' : '即时库存不足';
  }

  String _fmt(double? value) {
    if (value == null) return '—';
    return value == value.roundToDouble()
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(2);
  }
}
