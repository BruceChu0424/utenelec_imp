import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../components/layout/uten_picker_confirm_bar.dart';
import '../../../core/theme/uten_anim.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/reportable_plan_line.dart';
import '../repositories/production_repository.dart';

/// 选择本次报工对应的生产子任务（2026-09-11 起**支持多选**）。
///
/// 桌面端右侧 840px 滑入（外壳 showUtenAdaptivePanel，带面板投影），
/// 手机端底部全屏；数据只来自服务端“可报工计划”读侧，不在客户端猜
/// 计划号或销售订单分摊。
///
/// 返回**按点选顺序**的列表：调用方把第一条填进当前行，其余各开一行
/// （用户原话：「新建生产日报里面应该可以多选，现在只是单选」）。
/// 取消/关闭返回 null；确认但一条没选返回空列表不可能发生（确认键会禁用）。
Future<List<ReportablePlanLine>?> showReportablePlanLinePicker(
  BuildContext context,
  WidgetRef ref, {
  String? departmentId,
  String? executionSegmentId,
}) {
  return showUtenAdaptivePanel<List<ReportablePlanLine>>(
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

  /// 已点选（高亮）的计划行，**按点选先后保序**；底部「确定」才 pop 返回
  /// （二次操作契约）。保序是因为调用方按这个顺序建行，用户点的顺序=行序。
  final List<ReportablePlanLine> _picked = [];

  /// 行身份：同一执行段的同一计划行只能选一次。执行段为空（老数据）时
  /// 退回计划行 id，仍然唯一。
  String _lineKey(ReportablePlanLine item) =>
      '${item.executionSegmentId ?? ''}|${item.planItemId}';

  bool _isPicked(ReportablePlanLine item) =>
      _picked.any((picked) => _lineKey(picked) == _lineKey(item));

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
                          '显示普通可报任务和 FQC 恢复任务；返工可再检报工，报废/拒收补产须重新齐套发料。',
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
                      '选择后会锁定计划行、销售订单行、单位口径和 FQC 恢复授权。'
                      '提交审核时后台再次校验剩余量，并发报工不会超报、串单或重复贡献。',
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
                  // 2026-09-11 撤掉「查询」按钮（全站同改）：防抖到点即查，回车立刻查。
                  Expanded(
                    child: UtenSearchBar(
                      controller: _search,
                      hint: '计划号 / 产品 / 订单号 / 客户',
                      onChanged: (_) => _load(),
                      onSubmitted: (_) => _load(),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(child: _body(theme)),
            UtenPickerConfirmBar(
              selectedCount: _picked.length,
              selectedLabel: _picked.isEmpty
                  ? null
                  : _picked
                        .map(
                          (picked) =>
                              picked.executionSegmentCode ?? picked.planNo,
                        )
                        .join('、'),
              hint: _picked.isEmpty
                  ? (_total > 100
                        ? '共 $_total 条，当前展示前 100 条，可继续搜索缩小范围'
                        : '共 $_total 条报工/恢复任务；可勾选多条，一条一行')
                  : null,
              onConfirm: () => Navigator.of(
                context,
              ).pop(List<ReportablePlanLine>.unmodifiable(_picked)),
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
              'IN_PROGRESS' when item.fqcRecoveryRequiresMaterial => '待补料/待发料',
              'IN_PROGRESS' when item.isFqcRecovery => '恢复报工',
              'IN_PROGRESS' => '普通报工',
              _ => item.executionSegmentStatus ?? '历史计划',
            },
          ),
          MasterColumnDef(
            key: 'sourceType',
            label: '报工类型',
            width: 120,
            value: (item) =>
                item.fqcRecoveryLabel ??
                (item.isFqcRecovery ? 'FQC恢复' : '正常生产'),
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
            label: '计划/恢复余量',
            width: 90,
            type: 'number',
            value: (item) => _fmt(
              item.isFqcRecovery
                  ? item.fqcRecoveryAvailableQty
                  : item.remainingPlanQty,
            ),
          ),
          MasterColumnDef(
            key: 'maxReport',
            label: '当前可报',
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
        // embedded 表单击 = selectRow()（表格自己切勾选）+ onRowTap。
        // 所以这里**只负责提示**，不再自己 _toggle，否则一次点击切两下。
        onRowTap: (item) {
          if (!item.canReport) {
            context.appWarning(
              item.blockedReason ?? '当前来源没有可报数量，请刷新后重试',
              force: true,
            );
          }
        },
        // 勾选列与点行是同一个选择集：点行切换、勾选框也切换，
        // 不可报工的行 idOf 返回 null → 勾不上（与点行的拦截同口径）。
        selectable: true,
        idOf: (item) => item.canReport ? _lineKey(item) : null,
        selectedIds: {for (final picked in _picked) _lineKey(picked)},
        onSelectedIdsChanged: (next) => setState(() {
          _picked.removeWhere((picked) => !next.contains(_lineKey(picked)));
          for (final item in items) {
            if (next.contains(_lineKey(item)) && !_isPicked(item)) {
              _picked.add(item);
            }
          }
        }),
        isSelected: (item) => _isPicked(item),
        emptyMessage: '没有符合条件的可报工任务',
        rowColor: (item) {
          if (!item.canReport) {
            return theme.colorScheme.tertiaryContainer.withValues(alpha: 0.28);
          }
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
