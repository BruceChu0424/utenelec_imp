// 产成品入库任务（可嵌入）：FQC 放行上限进入队列；先登记成品仓与库位并送检，
// 品质放行后按实物完成最终点收（支持短收余量与批量全量点收）。
//
// 2026-09-01 起「入库任务中心 · 产成品入库」待点收分段内嵌本组件（embedded=true
// 时搜索框由任务中心页级工具条接管）；独立路由 /warehouse/production-finished-in/tasks
// 由对应页面以 embedded=false 包一层继续承接。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/inputs/uten_search_bar.dart';
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
import '../providers/warehouse_count_refresh.dart';
import '../repositories/production_finished_inbound_task_repository.dart';

class ProductionFinishedInboundTasksView extends ConsumerStatefulWidget {
  const ProductionFinishedInboundTasksView({
    super.key,
    this.keyword = '',
    this.refreshTick = 0,
    this.embedded = false,
    this.onLoadingChanged,
  });

  /// 任务中心页级搜索关键字（embedded 模式生效）。
  final String keyword;

  /// 父页面「返回即刷新」信号。
  final int refreshTick;

  /// true = 嵌在入库任务中心·产成品入库分段内（搜索框由页级工具条接管）。
  final bool embedded;

  /// 加载态变化回调（独立页 AppBar 刷新按钮据此置灰/转圈）。
  final ValueChanged<bool>? onLoadingChanged;

  @override
  ConsumerState<ProductionFinishedInboundTasksView> createState() =>
      _ProductionFinishedInboundTasksViewState();
}

class _ProductionFinishedInboundTasksViewState
    extends ConsumerState<ProductionFinishedInboundTasksView> {
  PagedResult<ProductionFinishedInboundTask>? _result;
  bool _loading = false;
  String? _error;
  String _keyword = '';
  int _requestVersion = 0;
  final Set<String> _selectedIds = <String>{};

  @override
  void initState() {
    super.initState();
    _keyword = widget.keyword;
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
  }

  @override
  void didUpdateWidget(ProductionFinishedInboundTasksView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.keyword != widget.keyword ||
        oldWidget.refreshTick != widget.refreshTick) {
      _keyword = widget.keyword;
      // build 期不能同步触发加载（onLoadingChanged 会 setState 父级）——post-frame。
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _load(1, replaceActive: true),
      );
    }
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
    widget.onLoadingChanged?.call(true);
    try {
      final result = await ref
          .read(productionFinishedInboundTaskRepositoryProvider)
          .tasks(page: page, keyword: keyword);
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _result = result;
        _loading = false;
        final currentIds = <String>{
          for (final task in result.items)
            if (task.isArrivalRegistration)
              'reg:${task.reportId ?? ''}'
            else if ((task.documentId ?? '').isNotEmpty)
              'doc:${task.documentId}',
        }..removeWhere((id) => id.endsWith(':') || id.endsWith(':null'));
        _selectedIds.removeWhere((id) => !currentIds.contains(id));
      });
    } on ApiException catch (error) {
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
      widget.onLoadingChanged?.call(false);
    } catch (_) {
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _error = '产成品入库任务加载失败，请检查网络后重试';
        _loading = false;
      });
      widget.onLoadingChanged?.call(false);
    }
    widget.onLoadingChanged?.call(false);
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
      // 登记页只失效了待点收计数；返回后统一失效，保证分段徽章/hub/工作台即时联动。
      invalidateWarehouseTaskCounts(ref);
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

  /// 多选「批量全量点收入库」（2026-09-12 弹窗改页，与入库中心统一口径）：
  /// 进批量点收页（所选任务一张表 + 底部确认批量入库，小结确认后整批同事务提交）。
  Future<void> _confirmSelected(Set<String> selectedIds) async {
    final documentIds = selectedIds
        .where((id) => id.startsWith('doc:'))
        .map((id) => id.substring(4))
        .toSet();
    if (documentIds.isEmpty) {
      if (documentIds.isEmpty) context.appWarning('请先选择待最终点收任务');
      return;
    }
    final targets = (_result?.items ?? const <ProductionFinishedInboundTask>[])
        .where(
          (task) =>
              (task.documentId ?? '').isNotEmpty &&
              documentIds.contains(task.documentId),
        )
        .toList(growable: false);
    if (targets.isEmpty) {
      context.appWarning('所选任务状态已变化，请刷新后重新选择');
      return;
    }
    final changed = await context.push<bool>(
      RouteName.warehouseProductionFinishedBatchStockIn,
      extra: targets,
    );
    if (!mounted || changed != true) return;
    setState(() => _selectedIds.clear());
    invalidateWarehouseTaskCounts(ref);
    await _load(_result?.page ?? 1, replaceActive: true);
  }

  /// 多选「批量登记成品仓并送检」：进入多报工单汇总登记页（页头默认仓+行内批量设）。
  Future<void> _openBatchRegistration(Set<String> selectedIds) async {
    final currentItems =
        _result?.items ?? const <ProductionFinishedInboundTask>[];
    final reportIds = <String>{
      for (final id in selectedIds)
        if (id.startsWith('reg:')) id.substring(4),
    }.toList()..sort();
    if (reportIds.isEmpty) {
      context.appWarning('请先选择“待登记成品仓与库位”的任务');
      return;
    }
    if (reportIds.length != selectedIds.length) {
      context.appWarning('混选了不同步骤的任务：批量登记送检只处理“待登记成品仓与库位”，请分开操作');
      return;
    }
    final knownReports = currentItems
        .where((task) => task.isArrivalRegistration)
        .map((task) => task.reportId ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();
    if (!knownReports.containsAll(reportIds)) {
      context.appWarning('所选任务状态已变化，请刷新后重新选择');
      return;
    }
    final changed = await context.push<bool>(
      RoutePath.warehouseProductionFinishedArrivalBatchRegistration(
        reportIds,
        returnTo: GoRouterState.of(context).matchedLocation,
      ),
    );
    if (!mounted || changed != true) return;
    invalidateWarehouseTaskCounts(ref);
    _selectedIds.clear();
    await _load(_result?.page ?? 1, replaceActive: true);
  }

  List<Widget> _batchActions(BuildContext context, Set<String> selectedIds) {
    final count = selectedIds.where((id) => id.startsWith('doc:')).length;
    final registerCount = selectedIds
        .where((id) => id.startsWith('reg:'))
        .length;
    return [
      Tooltip(
        message: registerCount == 0
            ? '请选择“待登记成品仓与库位”的任务'
            : '多张报工单汇总到一页统一登记成品仓与库位，一次提交逐单送检',
        child: UtenButton(
          key: const Key('production-finished-inbound-batch-register'),
          size: UtenButtonSize.large,
          type: UtenButtonType.danger,
          icon: Icons.edit_location_alt_outlined,
          onPressed: registerCount == 0
              ? null
              : () => _openBatchRegistration(selectedIds),
          onDisabledTap: registerCount == 0
              ? () => context.appWarning('请先选择“待登记成品仓与库位”的任务')
              : null,
          child: Text(
            registerCount == 0 ? '批量登记成品仓并送检' : '批量登记成品仓并送检($registerCount)',
          ),
        ),
      ),
      Tooltip(
        message: count == 0
            ? '请选择“品质通过 · 待最终点收”的任务'
            : '按每张单全部待点收数量原子入库；短收请逐单处理',
        child: UtenButton(
          key: const Key('production-finished-inbound-batch-confirm'),
          size: UtenButtonSize.large,
          type: UtenButtonType.danger,
          icon: Icons.inventory_rounded,
          onPressed: count == 0 ? null : () => _confirmSelected(selectedIds),
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
    return _buildTable(result, canCount: canCount);
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
    return Column(
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
            // 两类任务分别可选：待登记任务键 reg:<reportId>（批量登记送检），
            // 待点收任务键 doc:<documentId>（批量全量点收）；两个批量按钮各取各的。
            idOf: (task) => task.isArrivalRegistration
                ? (task.reportId?.isNotEmpty == true
                      ? 'reg:${task.reportId}'
                      : null)
                : ((task.documentId ?? '').isEmpty
                      ? null
                      : 'doc:${task.documentId}'),
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
            emptyMessage: _keyword.isEmpty ? '目前没有待处理的产成品入库任务' : '没有匹配的产成品入库任务',
            currentPage: result.page,
            totalPages: result.totalPages,
            onPageChange: _load,
          ),
        ),
      ],
    );
  }

  Widget _buildToolbar(PagedResult<ProductionFinishedInboundTask> result) {
    if (widget.embedded) {
      return Semantics(
        header: true,
        label: '共有 ${result.total} 项产成品入库任务',
        child: Align(
          alignment: Alignment.centerRight,
          child: Text(
            '共 ${result.total} 项 · 单击多选，双击详情',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
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
          '「待登记成品仓与库位」可多选后进入汇总登记页，一次提交统一送检；'
          '品质通过的任务可多选批量全量点收；短收、拒收仍须逐单进入确认。',
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
