import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/production_finished_inbound_task.dart';
import '../models/stock_doc.dart';
import '../providers/production_finished_inbound_task_count_provider.dart';
import '../repositories/production_finished_inbound_task_repository.dart';

class ProductionFinishedInboundTasksPage extends ConsumerStatefulWidget {
  const ProductionFinishedInboundTasksPage({super.key});

  @override
  ConsumerState<ProductionFinishedInboundTasksPage> createState() =>
      _ProductionFinishedInboundTasksPageState();
}

class _ProductionFinishedInboundTasksPageState
    extends ConsumerState<ProductionFinishedInboundTasksPage> {
  PagedResult<ProductionFinishedInboundTask>? _result;
  bool _loading = false;
  String? _error;
  String _keyword = '';
  int _requestVersion = 0;
  final Set<String> _selectedIds = <String>{};
  bool _batchConfirming = false;
  String? _batchSelectionFingerprint;
  String? _batchIdempotencyKey;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
  }

  void _onSearchInput(String value) {
    if (_keyword == value) return;
    _keyword = value;
    _requestVersion++;
  }

  Future<void> _search(String value) async {
    if (_keyword != value) _onSearchInput(value);
    await _load(1, replaceActive: true);
  }

  Future<void> _load(int page, {bool replaceActive = false}) async {
    if (_loading && !replaceActive) return;
    final requestVersion = ++_requestVersion;
    final keyword = _keyword;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(productionFinishedInboundTaskRepositoryProvider)
          .tasks(page: page, keyword: keyword);
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _result = result;
        _loading = false;
        final currentIds = result.items
            .where((task) => !task.isArrivalRegistration)
            .map((task) => task.documentId)
            .whereType<String>()
            .where((id) => id.isNotEmpty)
            .toSet();
        _selectedIds.removeWhere((id) => !currentIds.contains(id));
      });
    } on ApiException catch (error) {
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _error = '产成品入库任务加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  Future<void> _openTask(ProductionFinishedInboundTask task) async {
    if (task.isArrivalRegistration) {
      final reportId = task.reportId;
      if (reportId == null || reportId.isEmpty) {
        context.appWarning('该到货登记任务缺少报工单标识，请刷新后重试', force: true);
        return;
      }
      final changed = await context.push<bool>(
        RoutePath.warehouseProductionFinishedArrivalRegistration(
          reportId,
          returnTo: GoRouterState.of(context).matchedLocation,
        ),
      );
      if (!mounted || changed != true) return;
      await _load(_result?.page ?? 1);
      return;
    }

    final documentId = task.documentId;
    if (documentId == null || documentId.isEmpty) {
      context.appWarning('该最终点收任务缺少入库单标识，请刷新后重试', force: true);
      return;
    }
    goFrom(
      context,
      RoutePath.stockDocDetail(StockDocType.finishedIn.code, documentId),
    );
  }

  void _setSelectedIds(Set<String> next) {
    setState(() {
      _selectedIds
        ..clear()
        ..addAll(next);
    });
  }

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

  Future<void> _confirmSelected(Set<String> selectedIds) async {
    if (_batchConfirming || selectedIds.isEmpty) {
      if (selectedIds.isEmpty) context.appWarning('请先选择待最终点收任务');
      return;
    }
    final ids = selectedIds.toList()..sort();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('批量全量点收 ${ids.length} 张'),
        content: const Text(
          '系统将按每张单当前全部待点收数量执行实物全量接收，并在同一事务写入库存、生产入库完成量和审计链。'
          '任一任务状态、权限、品质放行、库存或并发校验失败，整批都会回滚。'
          '如果存在短收或拒收，请取消并双击对应任务逐单处理。',
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.inventory_rounded),
            label: const Text('确认批量入库'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _batchConfirming = true);
    try {
      final result = await ref
          .read(productionFinishedInboundTaskRepositoryProvider)
          .confirmAll(documentIds: ids, idempotencyKey: _batchKey(selectedIds));
      if (!mounted) return;
      final confirmedIds = result.confirmedDocumentIds.isEmpty
          ? ids.toSet()
          : result.confirmedDocumentIds;
      final current = _result;
      setState(() {
        if (current != null) {
          final remaining = current.items
              .where(
                (task) =>
                    task.documentId == null ||
                    !confirmedIds.contains(task.documentId),
              )
              .toList(growable: false);
          final removed = current.items.length - remaining.length;
          final total = (current.total - removed).clamp(0, 1 << 31);
          _result = PagedResult(
            items: remaining,
            page: current.page,
            size: current.size,
            total: total,
            totalPages: total == 0
                ? 0
                : (total + current.size - 1) ~/ current.size,
          );
        }
        _selectedIds.clear();
        _batchSelectionFingerprint = null;
        _batchIdempotencyKey = null;
      });
      ref.invalidate(warehouseProductionFinishedInboundPendingCountProvider);
      context.appSuccess(
        result.replay
            ? '该批次已完成，已安全重放 ${result.confirmedCount} 张结果'
            : '已批量全量点收 ${result.confirmedCount} 张产成品入库任务',
      );
      await _load(_result?.page ?? 1, replaceActive: true);
    } on ApiException catch (error) {
      if (mounted) context.appError(error.message);
    } catch (_) {
      if (mounted) context.appError('批量点收入库失败，请保持当前选择后重试');
    } finally {
      if (mounted) setState(() => _batchConfirming = false);
    }
  }

  List<Widget> _batchActions(BuildContext context, Set<String> selectedIds) {
    final count = selectedIds.length;
    return [
      Tooltip(
        message: count == 0
            ? '请选择“品质通过 · 待最终点收”的任务'
            : '按每张单全部待点收数量原子入库；短收请逐单处理',
        child: UtenButton(
          key: const Key('production-finished-inbound-batch-confirm'),
          size: UtenButtonSize.large,
          icon: Icons.inventory_rounded,
          isLoading: _batchConfirming,
          onPressed: _batchConfirming || count == 0
              ? null
              : () => _confirmSelected(selectedIds),
          onDisabledTap: count == 0
              ? () => context.appWarning('请先选择待最终点收任务')
              : null,
          child: Text(count == 0 ? '批量全量点收入库' : '批量全量点收入库($count)'),
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final permissions = ref.watch(currentPermissionsProvider);
    final canCount =
        ref.watch(isSuperAdminProvider) ||
        permissions.contains(Perm.stockDocApprove);
    return Scaffold(
      appBar: UtenAppBar(
        title: '产成品入库任务',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.warehouse),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: UtenSpacing.s8),
            child: UtenButton(
              key: const Key('production-finished-inbound-refresh'),
              size: UtenButtonSize.large,
              type: UtenButtonType.tonal,
              icon: Icons.refresh_rounded,
              isLoading: _loading && result != null,
              onPressed: _loading ? null : () => _load(result?.page ?? 1),
              child: const Text('刷新'),
            ),
          ),
        ],
      ),
      body: SafeArea(child: _buildTable(result, canCount: canCount)),
    );
  }

  Widget _buildTable(
    PagedResult<ProductionFinishedInboundTask>? value, {
    required bool canCount,
  }) {
    final result =
        value ??
        const PagedResult<ProductionFinishedInboundTask>(
          items: [],
          page: 1,
          size: 40,
          total: 0,
          totalPages: 1,
        );
    return UtenContentContainer.wide(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildToolbar(result),
            const SizedBox(height: UtenSpacing.s8),
            const _ProcessHint(),
            if (_error != null && result.items.isNotEmpty) ...[
              const SizedBox(height: UtenSpacing.s12),
              Semantics(
                liveRegion: true,
                child: Text(
                  '刷新失败：$_error',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ],
            const SizedBox(height: UtenSpacing.s12),
            Expanded(
              child: MasterDataTableView<ProductionFinishedInboundTask>(
                key: const Key('production-finished-inbound-task-table'),
                columns: _columns,
                items: result.items,
                facets: const {},
                nullCounts: const {},
                filters: const {},
                onFilterChanged: (_, _) {},
                selectable: canCount,
                idOf: (task) =>
                    task.isArrivalRegistration ? null : task.documentId,
                selectedIds: _selectedIds,
                onSelectedIdsChanged: _setSelectedIds,
                batchActionsBuilder: canCount ? _batchActions : null,
                onRowTap: _openTask,
                rowMenuBuilder: (task) => [
                  UtenMenuItem(
                    label: _taskActionLabel(task, canCount: canCount),
                    icon: canCount
                        ? task.isArrivalRegistration
                              ? Icons.edit_location_alt_outlined
                              : Icons.inventory_rounded
                        : Icons.visibility_outlined,
                    onTap: () => _openTask(task),
                  ),
                ],
                isLoading: _loading || value == null,
                loadingMore: _loading && value != null,
                error: result.items.isEmpty ? _error : null,
                onRetry: () => _load(result.page),
                emptyMessage: _keyword.isEmpty
                    ? '目前没有待处理的产成品入库任务'
                    : '没有匹配的产成品入库任务',
                currentPage: result.page,
                totalPages: result.totalPages,
                onPageChange: _load,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToolbar(PagedResult<ProductionFinishedInboundTask> result) {
    final search = UtenSearchBar(
      key: const Key('production-finished-inbound-search'),
      hint: '搜索入库单 / 生产单 / 报工单 / 货品',
      initialValue: _keyword,
      onInputChanged: _onSearchInput,
      onChanged: _search,
    );
    final count = Text(
      '共 ${result.total} 项 · 单击多选，双击详情',
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
    return Semantics(
      header: true,
      label: '共有 ${result.total} 项产成品入库任务',
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 760) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                search,
                const SizedBox(height: UtenSpacing.s8),
                count,
              ],
            );
          }
          return Row(
            children: [
              SizedBox(width: 420, child: search),
              const Spacer(),
              count,
            ],
          );
        },
      ),
    );
  }

  List<MasterColumnDef<ProductionFinishedInboundTask>> get _columns => [
    const MasterColumnDef(
      key: 'taskStage',
      label: '任务步骤',
      width: 190,
      value: _taskStageLabel,
    ),
    const MasterColumnDef(
      key: 'taskNo',
      label: '任务单号',
      width: 180,
      value: _taskDisplayNo,
    ),
    MasterColumnDef(
      key: 'planNo',
      label: '生产计划',
      width: 160,
      value: (task) => task.planNo ?? '—',
    ),
    MasterColumnDef(
      key: 'reportNos',
      label: '报工单',
      width: 180,
      value: (task) => task.reportNos ?? '—',
    ),
    MasterColumnDef(
      key: 'goodsSummary',
      label: '货品',
      width: 260,
      value: (task) => task.goodsSummary ?? '—',
    ),
    MasterColumnDef(
      key: 'warehouseName',
      label: '仓库',
      width: 160,
      value: (task) =>
          task.isArrivalRegistration ? '待本步骤选择' : task.warehouseName ?? '—',
    ),
    MasterColumnDef(
      key: 'pendingQty',
      label: '待处理数量',
      width: 120,
      type: 'number',
      value: (task) => _quantity(task.pendingQty),
    ),
    MasterColumnDef(
      key: 'lineCount',
      label: '行数',
      width: 80,
      type: 'number',
      value: (task) => '${task.lineCount}',
    ),
    MasterColumnDef(
      key: 'documentDate',
      label: '单据日期',
      width: 120,
      type: 'date',
      value: (task) => ChinaDateTime.formatDate(task.documentDate),
    ),
    MasterColumnDef(
      key: 'createdAt',
      label: '进入队列时间',
      width: 170,
      value: (task) => ChinaDateTime.formatInstant(task.createdAt),
    ),
  ];
}

class _ProcessHint extends StatelessWidget {
  const _ProcessHint();

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(
        Icons.info_outline_rounded,
        size: 18,
        color: Theme.of(context).colorScheme.primary,
      ),
      const SizedBox(width: UtenSpacing.s8),
      const Expanded(
        child: Text(
          '先登记成品仓和库位并送检；品质放行后，再按实物执行最终点收。'
          '品质通过的任务可多选后在右下角批量全量点收；短收、拒收仍须逐单进入确认。',
        ),
      ),
    ],
  );
}

String _taskStageLabel(ProductionFinishedInboundTask task) =>
    task.isArrivalRegistration
    ? '待登记成品仓与库位'
    : task.residualTask
    ? '短收余量待点收'
    : '品质通过 · 待最终点收';

String _taskDisplayNo(ProductionFinishedInboundTask task) =>
    task.documentNo?.trim().isNotEmpty == true
    ? task.documentNo!
    : task.reportNos?.trim().isNotEmpty == true
    ? task.reportNos!
    : task.taskId;

String _taskActionLabel(
  ProductionFinishedInboundTask task, {
  required bool canCount,
}) => canCount
    ? task.isArrivalRegistration
          ? '登记成品仓和库位'
          : '进入最终点收'
    : task.isArrivalRegistration
    ? '查看到货登记详情'
    : '查看待点收详情';

String _quantity(double value) => value
    .toStringAsFixed(4)
    .replaceFirst(RegExp(r'0+$'), '')
    .replaceFirst(RegExp(r'\.$'), '');
