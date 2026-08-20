import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../components/layout/uten_picker_confirm_bar.dart';
import '../../../core/theme/uten_anim.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/reportable_plan_line.dart';
import '../repositories/production_repository.dart';

/// 选择本次报工对应的生产子任务。
///
/// 桌面端右侧 840px 滑入（外壳 showUtenAdaptivePanel，带面板投影），
/// 手机端底部全屏；数据只来自服务端“可报工计划”读侧，不在客户端猜
/// 计划号或销售订单分摊。
Future<ReportablePlanLine?> showReportablePlanLinePicker(
  BuildContext context,
  WidgetRef ref, {
  String? departmentId,
  String? executionSegmentId,
}) {
  return showUtenAdaptivePanel<ReportablePlanLine>(
    context: context,
    compactHeightFactor: 0.94,
    drawerWidth: 840,
    panelElevation: 12,
    transitionDuration: UtenAnim.normal,
    builder: (_) => _ReportablePlanLineSheet(
      departmentId: departmentId,
      executionSegmentId: executionSegmentId,
    ),
  );
}

class _ReportablePlanLineSheet extends ConsumerStatefulWidget {
  const _ReportablePlanLineSheet({this.departmentId, this.executionSegmentId});

  final String? departmentId;
  final String? executionSegmentId;

  @override
  ConsumerState<_ReportablePlanLineSheet> createState() =>
      _ReportablePlanLineSheetState();
}

class _ReportablePlanLineSheetState
    extends ConsumerState<_ReportablePlanLineSheet> {
  final _search = TextEditingController();
  List<ReportablePlanLine>? _items;
  String? _error;
  int _total = 0;

  /// 已点选（高亮）的计划行；底部「确定」才 pop 返回（二次操作契约）。
  ReportablePlanLine? _picked;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _items = null;
    });
    try {
      final page = await ref
          .read(productionDailyReportRepositoryProvider)
          .reportablePlanLines(
            executionSegmentId: widget.executionSegmentId,
            size: 100,
            keyword: _search.text,
            departmentId: widget.departmentId,
          );
      if (!mounted) return;
      setState(() {
        _items = page.items;
        _total = page.total;
      });
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _error = productionErrorMessage(error, fallback: '加载可报工任务失败'),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
                          '选择报工子任务',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: UtenSpacing.s4),
                        Text(
                          '仅显示已审核、未停止且仍有可报数量的计划；合并排产按销售订单行分开。',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Container(
              margin: const EdgeInsets.symmetric(horizontal: UtenSpacing.s16),
              padding: const EdgeInsets.all(UtenSpacing.s8),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer.withValues(
                  alpha: 0.42,
                ),
                borderRadius: UtenRadius.smAll,
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.verified_user_outlined,
                    size: 18,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  Expanded(
                    child: Text(
                      '选择后会锁定计划行、销售订单行和单位换算口径。提交审核时后台再次校验剩余量，'
                      '并发报工不会超报或串单。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(UtenSpacing.s12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _search,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => _load(),
                      decoration: const InputDecoration(
                        labelText: '搜索',
                        hintText: '计划号 / 产品 / 订单号 / 客户',
                        prefixIcon: Icon(Icons.search_rounded),
                      ),
                    ),
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  UtenButton(
                    type: UtenButtonType.tonal,
                    icon: Icons.search_rounded,
                    onPressed: _load,
                    child: const Text('查询'),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(child: _body(theme)),
            UtenPickerConfirmBar(
              selectedCount: _picked == null ? 0 : 1,
              selectedLabel: _picked == null
                  ? null
                  : (_picked!.executionSegmentCode ?? _picked!.planNo),
              hint: _picked == null
                  ? (_total > 100
                        ? '共 $_total 条，当前展示前 100 条，可继续搜索缩小范围'
                        : '共 $_total 条可报工任务')
                  : null,
              onConfirm: () => Navigator.of(context).pop(_picked),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(ThemeData theme) {
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline_rounded, color: theme.colorScheme.error),
            const SizedBox(height: UtenSpacing.s8),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            const SizedBox(height: UtenSpacing.s8),
            UtenButton(
              type: UtenButtonType.tonal,
              onPressed: _load,
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    final items = _items;
    if (items == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    return Padding(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      child: MasterDataTableView<ReportablePlanLine>(
        embedded: true,
        columns: [
          MasterColumnDef(
            key: 'planNo',
            label: '计划 / 执行子计划',
            width: 180,
            value: (item) => [
              item.planNo,
              item.executionSegmentCode,
              item.productNo,
            ].where((value) => value?.isNotEmpty == true).join('\n'),
          ),
          MasterColumnDef(
            key: 'segmentStatus',
            label: '任务状态',
            width: 100,
            value: (item) => switch (item.executionSegmentStatus) {
              'DISPATCHED' => '已派工',
              'IN_PROGRESS' => '生产中',
              _ => item.executionSegmentStatus ?? '历史计划',
            },
          ),
          MasterColumnDef(
            key: 'goods',
            label: '产品',
            width: 190,
            value: (item) =>
                '${item.goodsName ?? item.goodsCode ?? '未命名'}'
                '${item.goodsSpec == null ? '' : '\n${item.goodsSpec}'}',
          ),
          MasterColumnDef(
            key: 'order',
            label: '销售订单/客户',
            width: 170,
            value: (item) => item.orderNo == null
                ? '内部计划'
                : '${item.orderNo}\n${item.clientName ?? '—'}',
          ),
          MasterColumnDef(
            key: 'workshop',
            label: '车间',
            width: 100,
            value: (item) => item.workshopName ?? '未分配',
          ),
          MasterColumnDef(
            key: 'remaining',
            label: '计划剩余',
            width: 90,
            type: 'number',
            value: (item) => _fmt(item.remainingPlanQty),
          ),
          MasterColumnDef(
            key: 'maxReport',
            label: '本行可报',
            width: 90,
            type: 'number',
            value: (item) => _fmt(item.maxReportQty),
          ),
          MasterColumnDef(
            key: 'delivery',
            label: '交货日期',
            width: 105,
            value: (item) => item.deliveryDate ?? '未定',
          ),
        ],
        items: items,
        facets: const {},
        nullCounts: const {},
        filters: const {},
        onFilterChanged: (_, _) {},
        onRowTap: (item) => setState(() => _picked = item),
        isSelected: (item) => identical(_picked, item),
        emptyMessage: '没有符合条件的可报工任务',
        rowColor: (item) {
          final date = DateTime.tryParse(item.deliveryDate ?? '');
          if (date == null) return null;
          final days = DateUtils.dateOnly(
            date,
          ).difference(DateUtils.dateOnly(DateTime.now())).inDays;
          if (days <= 3) {
            return theme.colorScheme.errorContainer.withValues(alpha: 0.28);
          }
          return null;
        },
      ),
    );
  }

  String _fmt(double? value) {
    if (value == null) return '—';
    return value == value.roundToDouble()
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(2);
  }
}
