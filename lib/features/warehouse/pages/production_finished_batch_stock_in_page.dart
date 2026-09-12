// 产成品「批量全量点收入库」页（2026-09-12 弹窗改页，对齐入库中心统一口径）。
//
// 用户口径：入库中心点击入库不要弹窗，都去对应页面。原「批量全量点收」的
// 确认弹窗 + 原地执行，改为独立页：所选待点收任务列成一张表（默认全勾），
// 底部「确认批量入库」→ 小结确认弹窗（UtenDialog 短要点）→ confirmAll 整批
// 同事务提交。幂等键按选择集指纹派生，选择不变重试复用同键，安全重放。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_selection_summary_pill.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_bottom_action_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/production_finished_inbound_task.dart';
import '../repositories/production_finished_inbound_task_repository.dart';

class ProductionFinishedBatchStockInPage extends ConsumerStatefulWidget {
  const ProductionFinishedBatchStockInPage({super.key, required this.targets});

  /// 列表页多选的待点收任务（doc 类型；documentId 必须在场）。
  final List<ProductionFinishedInboundTask> targets;

  @override
  ConsumerState<ProductionFinishedBatchStockInPage> createState() =>
      _ProductionFinishedBatchStockInPageState();
}

class _ProductionFinishedBatchStockInPageState
    extends ConsumerState<ProductionFinishedBatchStockInPage> {
  final Set<String> _selectedDocumentIds = {};
  bool _saving = false;
  String? _batchSelectionFingerprint;
  String? _batchIdempotencyKey;

  @override
  void initState() {
    super.initState();
    _selectedDocumentIds.addAll(
      widget.targets
          .map((task) => task.documentId)
          .whereType<String>()
          .where((id) => id.isNotEmpty),
    );
  }

  /// 幂等键随选择集派生：选择不变重试复用同键（服务端按 用户+键 去重安全重放）。
  String _batchKey(Set<String> ids) {
    final sorted = ids.toList()..sort();
    final fingerprint = sorted.join('|');
    if (_batchSelectionFingerprint != fingerprint ||
        _batchIdempotencyKey == null) {
      _batchSelectionFingerprint = fingerprint;
      _batchIdempotencyKey = 'finished-in-batch-${const Uuid().v4()}';
    }
    return _batchIdempotencyKey!;
  }

  Future<void> _submit() async {
    if (_saving || _selectedDocumentIds.isEmpty) return;
    final ids = _selectedDocumentIds.toList()..sort();
    // 2026-09-12：原一整段连排确认文案改「短要点」，高度与宽度由 UtenDialog
    // 统一兜（限宽 460 / 限高 60% 屏高 / 超出自滚）。
    final confirmed = await UtenDialog.show(
      context,
      title: '批量全量点收（${ids.length} 张）',
      confirmLabel: '确认批量入库',
      content: _confirmPoints(Theme.of(context), const [
        '按每张单当前全部待点收数量执行实物全量接收。',
        '同一事务写入库存、生产入库完成量和审计链；任一校验失败整批回滚。',
        '存在短收或拒收时，请取消并返回逐单处理。',
      ]),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _saving = true);
    try {
      final result = await ref
          .read(productionFinishedInboundTaskRepositoryProvider)
          .confirmAll(
            documentIds: ids,
            idempotencyKey: _batchKey(_selectedDocumentIds),
          );
      if (!mounted) return;
      context.appSuccess(
        result.replay
            ? '该批次已完成，已安全重放 ${result.confirmedCount} 张结果'
            : '已批量全量点收 ${result.confirmedCount} 张产成品入库任务',
      );
      if (context.canPop()) context.pop(true);
    } on ApiException catch (error) {
      if (mounted) context.appError(error.message);
    } catch (_) {
      if (mounted) context.appError('批量点收入库失败，请保持当前选择后重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _confirmPoints(ThemeData theme, List<String> points) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final point in points)
        Padding(
          padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
          child: Text('· $point', style: theme.textTheme.bodyMedium),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = widget.targets
        .where((task) => (task.documentId ?? '').isNotEmpty)
        .toList(growable: false);
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: UtenAppBar(
          title: '批量全量点收 · ${rows.length} 张',
          leading: UtenBackButton(
            color: _saving ? theme.disabledColor : null,
            onPressed: _saving
                ? null
                : () => popOrBackTo(
                    context,
                    defaultPath:
                        RouteName.warehouseProductionFinishedInboundTasks,
                  ),
          ),
        ),
        body: SafeArea(
          child: AbsorbPointer(
            absorbing: _saving,
            child: UtenContentContainer.wide(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: rows.isEmpty
                        ? const UtenEmpty(
                            icon: Icons.inventory_rounded,
                            message: '所选任务状态已变化',
                            description: '请返回任务中心刷新后重新选择。',
                          )
                        : _buildTable(rows),
                  ),
                  _buildBottomBar(theme, rows.length),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTable(List<ProductionFinishedInboundTask> rows) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s16,
        vertical: UtenSpacing.s12,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '按每张单全部待点收数量原子入库；短收、拒收请取消并逐单进入确认。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: UtenSpacing.s8),
          Expanded(
            child: MasterDataTableView<ProductionFinishedInboundTask>(
              key: const Key('production-finished-batch-stock-in-table'),
              columns: _columns,
              items: rows,
              facets: const {},
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, _) {},
              selectable: !_saving,
              idOf: (task) => task.documentId,
              selectedIds: _selectedDocumentIds,
              onSelectedIdsChanged: (next) => setState(() {
                _selectedDocumentIds
                  ..clear()
                  ..addAll(next);
              }),
              emptyMessage: '没有可点收任务',
              showFullscreenToggle: false,
            ),
          ),
        ],
      ),
    );
  }

  /// 吸底操作栏（对齐品质批量审批页）：已选计数胶囊 + 说明 + 确认批量入库。
  /// 窄屏竖排（横排会在 375px 溢出），大屏同款横排。
  Widget _buildBottomBar(ThemeData theme, int totalCount) {
    final count = _selectedDocumentIds.length;
    final confirm = UtenButton(
      key: const Key('production-finished-batch-confirm'),
      type: UtenButtonType.danger,
      size: UtenButtonSize.large,
      icon: Icons.inventory_rounded,
      isLoading: _saving,
      onPressed: _saving || count == 0 ? null : _submit,
      onDisabledTap: count == 0 ? () => context.appWarning('请先勾选待点收任务') : null,
      child: Text('确认批量入库($count)'),
    );
    final summary = Row(
      children: [
        UtenSelectionSummaryPill(
          key: const Key('production-finished-batch-selected-count'),
          count: count,
          onClear: count == 0 || _saving
              ? null
              : () => setState(() => _selectedDocumentIds.clear()),
        ),
        const SizedBox(width: UtenSpacing.s12),
        Expanded(
          child: Text(
            '共 $totalCount 张待点收 · 全量接收写入库存与生产入库完成量',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
    return UtenBottomActionBar(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 560) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                summary,
                const SizedBox(height: UtenSpacing.s8),
                Align(alignment: Alignment.centerRight, child: confirm),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: summary),
              const SizedBox(width: UtenSpacing.s12),
              confirm,
            ],
          );
        },
      ),
    );
  }

  List<MasterColumnDef<ProductionFinishedInboundTask>> get _columns => [
    MasterColumnDef<ProductionFinishedInboundTask>(
      key: 'taskNo',
      label: '入库单号',
      width: 180,
      value: (task) => task.documentNo ?? task.taskId,
    ),
    MasterColumnDef<ProductionFinishedInboundTask>(
      key: 'planNo',
      label: '生产计划',
      width: 160,
      value: (task) => task.planNo ?? '—',
    ),
    MasterColumnDef<ProductionFinishedInboundTask>(
      key: 'reportNos',
      label: '报工单',
      width: 180,
      value: (task) => task.reportNos ?? '—',
    ),
    MasterColumnDef<ProductionFinishedInboundTask>(
      key: 'goodsSummary',
      label: '货品',
      width: 260,
      value: (task) => task.goodsSummary ?? '—',
    ),
    MasterColumnDef<ProductionFinishedInboundTask>(
      key: 'warehouseName',
      label: '仓库',
      width: 150,
      value: (task) => task.warehouseName ?? '—',
    ),
    MasterColumnDef<ProductionFinishedInboundTask>(
      key: 'pendingQty',
      label: '待点收数量',
      width: 120,
      type: 'number',
      value: (task) => _quantity(task.pendingQty),
    ),
    MasterColumnDef<ProductionFinishedInboundTask>(
      key: 'lineCount',
      label: '行数',
      width: 80,
      type: 'number',
      value: (task) => '${task.lineCount}',
    ),
    MasterColumnDef<ProductionFinishedInboundTask>(
      key: 'documentDate',
      label: '单据日期',
      width: 120,
      type: 'date',
      value: (task) => ChinaDateTime.formatDate(task.documentDate),
    ),
  ];

  static String _quantity(double value) => value
      .toStringAsFixed(4)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}
