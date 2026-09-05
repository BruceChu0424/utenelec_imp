import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/idempotency_key.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/providers/master_name_provider.dart' as mn;
import '../../../shared/widgets/warehouse_hierarchy_dropdown.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../production/models/production_material_analysis.dart';
import '../../production/repositories/production_repository.dart';
import '../../production/widgets/subcontract_make_task_tile.dart';

/// 委外准备中心：有子层级委外件的「先自制、后通知委外」双视角。
///
/// 「分析来源」页签展示物料分析下达的前置自制账本（produced/notified/available
/// 权威数量），支持按可通知量分批通知委外；「订货来源」页签是直接委外订货
/// 财务批准后的前置自制待办。服务端拥有 BOM 判断、状态、数量、阻断原因和
/// allowedActions；Flutter 只展示任务并转发显式命令。
///
/// 2026-09-03 统一「分类分段」范式（原生 SegmentedButton/状态下拉退役）：
/// 来源大类行 + 订货来源页签下的准备状态小类行（无「全部状态」段）——
/// 两行默认都不选（未选不发请求，显示引导占位）。
/// 本页两个任务接口不支持日期范围，终态（目标件已出仓/已取消）保留为显式
/// 阶段段，不另设时间门控历史段。
class SubcontractPreparationPage extends ConsumerStatefulWidget {
  const SubcontractPreparationPage({
    super.key,
    this.planItemId,
    this.sourceAnalysisId,
    this.sourceMaterialLineId,
  });

  final String? planItemId;
  final String? sourceAnalysisId;
  final String? sourceMaterialLineId;

  @override
  ConsumerState<SubcontractPreparationPage> createState() =>
      _SubcontractPreparationPageState();
}

class _SubcontractPreparationPageState
    extends ConsumerState<SubcontractPreparationPage> {
  static const _statuses = <String, String>{
    'ACTION_REQUIRED': '待开始物料分析',
    'IN_PREPARATION': '前置自制中',
    'WAITING_FQC': '等待品质检查',
    'WAITING_INBOUND': '等待成品实收入仓',
    'READY_OUTBOUND': '已备齐，等待目标件出仓',
    'OUTBOUND_COMPLETE': '目标件已出仓',
    'CANCELLED': '已取消',
  };

  final _search = TextEditingController();
  Timer? _debounce;
  PagedResult<SubcontractPreparationTask>? _page;
  bool _loading = false;
  String? _error;
  String? _status;
  int _requestId = 0;
  String? _startingPlanItemId;

  // 来源大类：0 = 分析来源（先自制、后通知委外的账本投影）；
  // 1 = 订货来源经典队列。null = 未选择引导态（未选不发请求）。
  int? _sourceTab;
  PagedResult<SubcontractMakeTask>? _makePage;
  bool _makeLoading = false;
  String? _makeError;
  int _makeRequestId = 0;

  String? get _focusedPlanItemId => widget.planItemId?.trim().isNotEmpty == true
      ? widget.planItemId!.trim()
      : null;

  String? get _sourceAnalysisId =>
      widget.sourceAnalysisId?.trim().isNotEmpty == true
      ? widget.sourceAnalysisId!.trim()
      : null;

  String? get _sourceMaterialLineId =>
      widget.sourceMaterialLineId?.trim().isNotEmpty == true
      ? widget.sourceMaterialLineId!.trim()
      : null;

  bool get _sourceScoped =>
      _sourceAnalysisId != null && _sourceMaterialLineId != null;

  @override
  void initState() {
    super.initState();
    // 默认不选来源：进页面不发列表请求，选页签后才加载对应视角。
  }

  void _selectSourceTab(int tab) {
    if (_sourceTab == tab) return;
    setState(() {
      _sourceTab = tab;
      _status = null;
    });
    if (tab == 0) {
      _loadMake();
    } else {
      _load();
    }
  }

  Future<void> _loadMake({int page = 1}) async {
    final requestId = ++_makeRequestId;
    if (mounted) {
      setState(() {
        _makeLoading = true;
        _makeError = null;
      });
    }
    try {
      final next = await ref
          .read(productionPlanRepositoryProvider)
          .subcontractMakeTasks(
            page: page,
            keyword: _search.text,
            status: _status,
          );
      if (!mounted || requestId != _makeRequestId) return;
      setState(() {
        _makePage = next;
        _makeLoading = false;
      });
    } catch (error) {
      if (!mounted || requestId != _makeRequestId) return;
      setState(() {
        _makeLoading = false;
        _makeError = productionErrorMessage(
          error,
          fallback: '委外前置自制进度加载失败，请稍后重试',
        );
      });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load({int page = 1}) async {
    final requestId = ++_requestId;
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final next = await ref
          .read(productionPlanRepositoryProvider)
          .subcontractPreparationTasks(
            page: page,
            keyword: _search.text,
            status: _status,
            planItemId: _focusedPlanItemId,
            sourceAnalysisId: _sourceAnalysisId,
            sourceMaterialLineId: _sourceMaterialLineId,
          );
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _page = next;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _loading = false;
        _error = productionErrorMessage(error, fallback: '委外前置自制任务加载失败，请稍后重试');
      });
    }
  }

  void _searchChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted || _sourceTab == null) return;
      if (_sourceTab == 0) {
        _loadMake();
      } else {
        _load();
      }
    });
  }

  bool get _canStartByPermission {
    if (ref.read(isSuperAdminProvider)) return true;
    return ref
        .read(currentPermissionsProvider)
        .contains(Perm.subcontractPreparationStart);
  }

  bool get _canViewProductionAnalysis {
    if (ref.read(isSuperAdminProvider)) return true;
    return ref
        .read(currentPermissionsProvider)
        .contains(Perm.productionMaterialAnalysisView);
  }

  bool get _canViewOrder {
    if (ref.read(isSuperAdminProvider)) return true;
    return ref
        .read(currentPermissionsProvider)
        .contains(Perm.subcontractOrderView);
  }

  Future<String?> _selectWarehouse(SubcontractPreparationTask task) async {
    if (!task.warehouseSelectionRequired) return task.preparationWarehouseId;
    await ref.read(mn.masterNameServiceProvider).ensureLoaded();
    if (!mounted) return null;
    final entries = ref.read(mn.masterNameServiceProvider).warehouseEntries;
    if (entries.isEmpty) {
      context.appError('没有可选择的前置自制目标仓，请先维护仓库主数据');
      return null;
    }
    final hierarchy = ref.read(mn.masterNameServiceProvider).warehouseHierarchy;
    String? selected;
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('选择前置自制目标仓'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('目标仓会冻结到本任务。后续领料、报工、FQC、成品实收入仓和委外出仓必须沿用同一仓库。'),
                const SizedBox(height: UtenSpacing.s12),
                // V476：主/子层级（父仓置灰分组，目标仓必须是具体仓）。
                WarehouseHierarchyDropdown(
                  key: const Key('subcontract-preparation-warehouse'),
                  entries: hierarchy,
                  value: selected,
                  labelText: '目标仓库(必选)',
                  onChanged: (value) => setDialogState(() => selected = value),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('subcontract-preparation-warehouse-confirm'),
              onPressed: selected == null
                  ? null
                  : () => Navigator.pop(dialogContext, selected),
              child: const Text('确认并开始'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _start(SubcontractPreparationTask task) async {
    if (_startingPlanItemId != null) return;
    if (!_canStartByPermission || !task.allows('START_PREPARATION')) {
      context.appInfo(task.blocker ?? '当前账号或任务状态不允许开始前置自制');
      return;
    }
    final warehouseId = await _selectWarehouse(task);
    if (!mounted || (task.warehouseSelectionRequired && warehouseId == null)) {
      return;
    }
    setState(() => _startingPlanItemId = task.planItemId);
    try {
      final result = await ref
          .read(productionPlanRepositoryProvider)
          .startSubcontractPreparation(
            planItemId: task.planItemId,
            expectedVersion: task.version,
            warehouseId: warehouseId,
            idempotencyKey: businessIdempotencyKey(
              'subcontract-preparation-start',
              '${task.planItemId}|${task.version}|${warehouseId ?? ''}',
            ),
          );
      if (!mounted) return;
      final analysisId = result.analysisId?.trim();
      if (analysisId == null || analysisId.isEmpty) {
        context.appWarning('服务端已受理前置自制，但未返回物料分析编号；请刷新后继续');
        await _load(page: _page?.page ?? 1);
        return;
      }
      final handoffActive = result.handoffStatus == 'ACTIVE';
      final handoffSummary = handoffActive
          ? '；已接管原分析目标量 ${_qty(result.takeoverQty)}，'
                '已移交合格权益 ${_qty(result.handedOffEntitlementQty)}'
          : '';
      context.appSuccess('前置自制物料分析已创建$handoffSummary；请继续领料、生产、FQC 和成品入仓');
      if (!_canViewProductionAnalysis) {
        context.appInfo('任务已创建；具备生产物料分析查看权限的计划员可继续执行');
        await _load(page: _page?.page ?? 1);
        return;
      }
      await _openAnalysis(
        task,
        analysisId: analysisId,
        warehouseId: warehouseId,
        fromSuccessfulStart: true,
      );
    } catch (error) {
      if (!mounted) return;
      context.appError(
        productionErrorMessage(error, fallback: '开始前置自制失败，请刷新后重试'),
      );
      await _load(page: _page?.page ?? 1);
    } finally {
      if (mounted) setState(() => _startingPlanItemId = null);
    }
  }

  Future<void> _openAnalysis(
    SubcontractPreparationTask task, {
    String? analysisId,
    String? warehouseId,
    bool fromSuccessfulStart = false,
  }) async {
    if (!_canViewProductionAnalysis ||
        (!fromSuccessfulStart && !task.allows('OPEN_ANALYSIS'))) {
      context.appInfo(task.blocker ?? '当前账号没有打开生产物料分析的权限');
      return;
    }
    final stableId = (analysisId ?? task.analysisId)?.trim();
    if (stableId == null || stableId.isEmpty) {
      context.appInfo(task.blocker ?? '当前任务尚未形成可打开的物料分析');
      return;
    }
    await context.push(
      RouteName.productionMaterialAnalysis,
      extra: ProductionMaterialAnalysisSeed(
        analysisId: stableId,
        warehouseId: warehouseId ?? task.preparationWarehouseId,
      ),
    );
    if (mounted) await _load(page: _page?.page ?? 1);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: UtenAppBar(
        title: '委外准备中心',
        subtitle: '有子层级的委外件先自制，成品入库后通知委外；满批自动，可分批',
        leading: UtenBackButton(
          onPressed: () =>
              popOrBackTo(context, defaultPath: RouteName.subcontract),
        ),
        actions: [
          IconButton(
            tooltip: '刷新前置自制任务',
            onPressed: _loading ? null : () => _load(page: _page?.page ?? 1),
            icon: const Icon(Icons.refresh_rounded),
          ),
          const SizedBox(width: UtenSpacing.s8),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          padding: const EdgeInsets.only(
            top: UtenSpacing.s12,
            bottom: UtenSpacing.s16,
          ),
          child: _buildBody(),
        ),
      ),
    );
  }

  Widget _buildBody() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final desktop = constraints.maxWidth >= 840;
        final tab = _sourceTab;
        // 来源大类行（统一工具条：分段 + 搜索；默认不选）。
        final header = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            UtenFilterToolbar<int>(
              segmentsKey: const Key('subcontract-preparation-source-tab'),
              searchKey: const Key('subcontract-preparation-search'),
              segments: const [
                UtenFilterSegment(value: 0, label: '分析来源·前置自制'),
                UtenFilterSegment(value: 1, label: '订货来源·前置自制'),
              ],
              selected: tab == null ? const {} : {tab},
              onSelectionChanged: _loading || _makeLoading
                  ? (_) {}
                  : _selectSourceTab,
              searchHint: tab == 0 ? '搜索目标件编码、名称或任务号' : '搜索订货单号、目标件编码或名称',
              searchController: _search,
              onSearchChanged: (_) => _searchChanged(_search.text),
            ),
            // 订货来源小类行：准备状态（无「全部状态」段；默认不选=不过滤）。
            if (tab == 1) ...[
              const SizedBox(height: UtenSpacing.s8),
              UtenFilterToolbar<String>(
                segmentsKey: const Key('subcontract-preparation-status'),
                segments: [
                  for (final entry in _statuses.entries)
                    UtenFilterSegment(value: entry.key, label: entry.value),
                ],
                selected: _status == null ? const {} : {_status!},
                onSelectionChanged: _loading
                    ? (_) {}
                    : (value) {
                        setState(() => _status = value);
                        _load();
                      },
              ),
            ],
            const SizedBox(height: UtenSpacing.s12),
          ],
        );
        if (tab == null) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              const Expanded(
                child: UtenFilterPlaceholder(
                  message: '在上方选择来源后开始办理',
                  description: '来源默认不选中，选择后加载对应视角的前置自制任务',
                ),
              ),
            ],
          );
        }
        if (tab == 0) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              Expanded(child: _buildMakeList(desktop: desktop)),
            ],
          );
        }
        return _buildOrderSourcedBody(header: header, desktop: desktop);
      },
    );
  }

  /// V458 分析来源页签：先自制、后通知委外的账本进度 + 分批通知入口。
  Widget _buildMakeList({required bool desktop}) {
    if (_makeLoading && _makePage == null) {
      return Center(
        child: Semantics(
          label: '正在加载委外前置自制进度',
          child: const CircularProgressIndicator(),
        ),
      );
    }
    if (_makeError != null && _makePage == null) {
      return UtenEmpty.error(
        message: '无法加载委外前置自制进度',
        description: _makeError,
        actionLabel: '重试',
        onAction: _loadMake,
      );
    }
    final page = _makePage;
    if (page == null) {
      return UtenEmpty.error(actionLabel: '重试', onAction: _loadMake);
    }
    if (page.items.isEmpty) {
      return const UtenEmpty(
        icon: Icons.precision_manufacturing_outlined,
        message: '当前没有委外件前置自制任务',
        description:
            '物料分析准备对有子层级的委外件「下达委外」后，会在这里形成前置自制进度；'
            '自制成品入库并通知委外前，委外部不会参与。',
      );
    }
    final canNotify = _permissionsLikeAnalysisNotify;
    return ListView(
      key: const Key('subcontract-preparation-make-list'),
      children: [
        for (final task in page.items)
          Card(
            margin: const EdgeInsets.only(bottom: UtenSpacing.s8),
            child: Padding(
              padding: const EdgeInsets.all(UtenSpacing.s12),
              child: SubcontractMakeTaskTile(
                task: task,
                canNotify: canNotify,
                compact: true,
                onOpenAnalysis: _canViewProductionAnalysis
                    ? () => context.push(
                        RouteName.productionMaterialAnalysis,
                        extra: ProductionMaterialAnalysisSeed(
                          analysisId: task.analysisId,
                        ),
                      )
                    : null,
                onNotified: _loadMake,
              ),
            ),
          ),
        _PreparationPager(
          page: page.page,
          totalPages: page.totalPages,
          loading: _makeLoading,
          onPageChanged: (next) => _loadMake(page: next),
        ),
      ],
    );
  }

  Widget _buildOrderSourcedBody({
    required Widget header,
    required bool desktop,
  }) {
    if (_page == null && _loading) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          const Expanded(child: Center(child: CircularProgressIndicator())),
        ],
      );
    }
    if (_error != null && _page == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          Expanded(
            child: UtenEmpty.error(
              message: '无法加载订货来源前置自制任务',
              description: _error,
              actionLabel: '重试',
              onAction: _load,
            ),
          ),
        ],
      );
    }
    final page = _page;
    if (page == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          Expanded(
            child: UtenEmpty.error(actionLabel: '重试', onAction: _load),
          ),
        ],
      );
    }
    if (desktop) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          Expanded(child: _buildTable(page)),
        ],
      );
    }
    return ListView(
      key: const Key('subcontract-preparation-compact-list'),
      children: [
        header,
        if (page.items.isEmpty)
          SizedBox(
            height: 300,
            child: UtenEmpty(
              icon: Icons.precision_manufacturing_outlined,
              message: _sourceScoped ? '该委外节点尚未形成前置自制待办' : '当前没有订货来源前置自制任务',
              description: _sourceScoped
                  ? '请先在委外任务中心完成订货并通过财务审批；有 BOM 的目标件随后会在这里开放前置自制。'
                  : '直接委外下单且有 BOM 子层级的目标件，经财务批准后会在这里出现。',
            ),
          )
        else
          for (final task in page.items) ...[
            _PreparationCard(
              task: task,
              starting: _startingPlanItemId == task.planItemId,
              canStart:
                  _canStartByPermission && task.allows('START_PREPARATION'),
              onStart: () => _start(task),
              onOpenAnalysis:
                  task.analysisId?.trim().isNotEmpty == true &&
                      task.allows('OPEN_ANALYSIS') &&
                      _canViewProductionAnalysis
                  ? () => _openAnalysis(task)
                  : null,
              onOpenOrder: task.orderId.isEmpty || !_canViewOrder
                  ? null
                  : () => context.push('/subcontract/orders/${task.orderId}'),
            ),
            const SizedBox(height: UtenSpacing.s8),
          ],
        _PreparationPager(
          page: page.page,
          totalPages: page.totalPages,
          loading: _loading,
          onPageChanged: (next) => _load(page: next),
        ),
      ],
    );
  }

  bool get _permissionsLikeAnalysisNotify {
    if (ref.read(isSuperAdminProvider)) return true;
    return ref
        .read(currentPermissionsProvider)
        .contains(Perm.productionMaterialAnalysisNotify);
  }

  Widget _buildTable(PagedResult<SubcontractPreparationTask> page) {
    return MasterDataTableView<SubcontractPreparationTask>(
      key: const Key('subcontract-preparation-table'),
      columns: [
        MasterColumnDef(
          key: 'order',
          label: '委外订货',
          width: 150,
          value: (t) => t.orderBillNo ?? t.orderId,
        ),
        MasterColumnDef(
          key: 'goods',
          label: '目标件',
          width: 240,
          value: (t) =>
              '${t.targetGoodsCode ?? ''} ${t.targetGoodsName ?? ''}'.trim(),
        ),
        MasterColumnDef(
          key: 'color',
          label: '颜色',
          width: 110,
          value: (t) => t.colorName,
        ),
        MasterColumnDef(
          key: 'qty',
          label: '目标 / 已备齐',
          width: 150,
          value: (t) =>
              '${_qty(t.requiredQty)} / ${_qty(t.preparedQty)} ${t.unitName ?? ''}'
                  .trim(),
        ),
        MasterColumnDef(
          key: 'warehouse',
          label: '冻结目标仓',
          width: 170,
          value: (t) => t.preparationWarehouseName ?? '待选择',
        ),
        const MasterColumnDef(
          key: 'handoff',
          label: '原分析物料交接',
          width: 210,
          value: _handoffLabel,
        ),
        MasterColumnDef(
          key: 'needDate',
          label: '需求日期',
          width: 120,
          type: 'date',
          value: (t) => t.needDate,
        ),
        MasterColumnDef(
          key: 'status',
          label: '准备状态',
          width: 170,
          value: (t) => _statusLabel(t.status),
        ),
        MasterColumnDef(
          key: 'blocker',
          label: '阻断 / 下一步',
          width: 260,
          value: (t) => _effectiveBlocker(t) ?? _nextHint(t.status),
        ),
      ],
      items: page.items,
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      onRowTap: (task) => _openAnalysis(task),
      canOpenRow: (task) =>
          _canViewProductionAnalysis &&
          task.allows('OPEN_ANALYSIS') &&
          task.analysisId?.trim().isNotEmpty == true,
      rowMenuBuilder: (task) => [
        if (_canStartByPermission && task.allows('START_PREPARATION'))
          UtenMenuItem(
            label: '开始前置自制',
            icon: Icons.play_arrow_rounded,
            enabled: _startingPlanItemId == null,
            onTap: () => _start(task),
          ),
        if (_canViewProductionAnalysis &&
            task.allows('OPEN_ANALYSIS') &&
            task.analysisId?.trim().isNotEmpty == true)
          UtenMenuItem(
            label: '打开物料分析',
            icon: Icons.open_in_new_rounded,
            onTap: () => _openAnalysis(task),
          ),
        if (_canViewOrder && task.orderId.isNotEmpty)
          UtenMenuItem(
            label: '查看委外订货',
            icon: Icons.receipt_long_outlined,
            onTap: () => context.push('/subcontract/orders/${task.orderId}'),
          ),
      ],
      canShowRowMenu: (task) =>
          (_canStartByPermission && task.allows('START_PREPARATION')) ||
          (_canViewProductionAnalysis &&
              task.allows('OPEN_ANALYSIS') &&
              task.analysisId?.trim().isNotEmpty == true) ||
          (_canViewOrder && task.orderId.isNotEmpty),
      isLoading: _loading && _page == null,
      loadingMore: _loading && _page != null,
      error: _error,
      onRetry: () => _load(page: page.page),
      emptyMessage: _sourceScoped
          ? '该委外节点尚未形成前置自制待办；请先完成委外订货与财务审批'
          : '当前筛选下没有前置自制任务',
      currentPage: page.page,
      totalPages: page.totalPages,
      onPageChange: (next) => _load(page: next),
    );
  }

  static String _statusLabel(String status) =>
      _statuses[status] ?? '状态待确认($status)';

  static String _nextHint(String status) => switch (status) {
    'ACTION_REQUIRED' => '选择目标仓并开始物料分析',
    'IN_PREPARATION' => '按分析完成领料、生产和报工',
    'WAITING_FQC' => '等待品质完成 FQC',
    'WAITING_INBOUND' => '等待仓库实收前置成品',
    'READY_OUTBOUND' => '仓库已收到目标件出仓任务',
    'OUTBOUND_COMPLETE' => '目标件已交付委外商加工',
    'CANCELLED' => '任务已取消',
    _ => '等待服务端给出下一步',
  };

  static String? _effectiveBlocker(SubcontractPreparationTask task) {
    final handoff = task.handoffBlocker?.trim();
    if (handoff?.isNotEmpty == true) return handoff;
    final taskBlocker = task.blocker?.trim();
    return taskBlocker?.isNotEmpty == true ? taskBlocker : null;
  }

  static String _handoffLabel(SubcontractPreparationTask task) {
    if (task.sourceAnalysisId == null || task.sourceMaterialLineId == null) {
      return '直接委外，无原分析交接';
    }
    if (task.handoffStatus == 'ACTIVE') {
      return '已接管 ${_qty(task.takeoverQty)} · 合格权益 ${_qty(task.handedOffEntitlementQty)}';
    }
    if (task.handoffStatus == 'RESTORED') return '已原路恢复';
    return task.handoffBlocker ?? '等待建立精确交接';
  }

  static String _qty(double value) => value == value.roundToDouble()
      ? value.toInt().toString()
      : value
            .toStringAsFixed(3)
            .replaceFirst(RegExp(r'0+$'), '')
            .replaceFirst(RegExp(r'\.$'), '');
}

class _PreparationCard extends StatelessWidget {
  const _PreparationCard({
    required this.task,
    required this.starting,
    required this.canStart,
    required this.onStart,
    required this.onOpenAnalysis,
    required this.onOpenOrder,
  });

  final SubcontractPreparationTask task;
  final bool starting;
  final bool canStart;
  final VoidCallback onStart;
  final VoidCallback? onOpenAnalysis;
  final VoidCallback? onOpenOrder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final blocker = _SubcontractPreparationPageState._effectiveBlocker(task);
    return Semantics(
      container: true,
      label:
          '${task.orderBillNo ?? task.orderId}，${task.targetGoodsCode ?? ''} ${task.targetGoodsName ?? ''}，${_SubcontractPreparationPageState._statusLabel(task.status)}',
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      '${task.targetGoodsCode ?? ''} ${task.targetGoodsName ?? '未命名目标件'}'
                          .trim(),
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  Chip(
                    label: Text(
                      _SubcontractPreparationPageState._statusLabel(
                        task.status,
                      ),
                    ),
                  ),
                ],
              ),
              Wrap(
                spacing: UtenSpacing.s12,
                runSpacing: UtenSpacing.s4,
                children: [
                  Text('订货 ${task.orderBillNo ?? task.orderId}'),
                  Text(
                    '目标 ${_SubcontractPreparationPageState._qty(task.requiredQty)} ${task.unitName ?? ''}',
                  ),
                  Text(
                    '已备齐 ${_SubcontractPreparationPageState._qty(task.preparedQty)} ${task.unitName ?? ''}',
                  ),
                  Text('目标仓 ${task.preparationWarehouseName ?? '待选择'}'),
                  Text(
                    '物料交接 ${_SubcontractPreparationPageState._handoffLabel(task)}',
                  ),
                  Text('需求日 ${task.needDate ?? '—'}'),
                ],
              ),
              const SizedBox(height: UtenSpacing.s8),
              Text(
                blocker?.isNotEmpty == true
                    ? '阻断：$blocker'
                    : _SubcontractPreparationPageState._nextHint(task.status),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: blocker?.isNotEmpty == true
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurfaceVariant,
                  fontWeight: blocker?.isNotEmpty == true
                      ? FontWeight.w600
                      : null,
                ),
              ),
              const SizedBox(height: UtenSpacing.s8),
              Wrap(
                spacing: UtenSpacing.s8,
                runSpacing: UtenSpacing.s8,
                alignment: WrapAlignment.end,
                children: [
                  if (onOpenOrder != null)
                    UtenButton(
                      type: UtenButtonType.secondary,
                      icon: Icons.receipt_long_outlined,
                      onPressed: onOpenOrder,
                      child: const Text('查看委外订货'),
                    ),
                  if (onOpenAnalysis != null)
                    UtenButton(
                      type: UtenButtonType.tonal,
                      icon: Icons.open_in_new_rounded,
                      onPressed: onOpenAnalysis,
                      child: const Text('打开物料分析'),
                    ),
                  if (canStart)
                    UtenButton(
                      key: Key(
                        'subcontract-preparation-start-${task.planItemId}',
                      ),
                      icon: Icons.play_arrow_rounded,
                      isLoading: starting,
                      onPressed: starting ? null : onStart,
                      child: const Text('开始前置自制'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PreparationPager extends StatelessWidget {
  const _PreparationPager({
    required this.page,
    required this.totalPages,
    required this.loading,
    required this.onPageChanged,
  });

  final int page;
  final int totalPages;
  final bool loading;
  final ValueChanged<int> onPageChanged;

  @override
  Widget build(BuildContext context) {
    if (totalPages <= 1) return const SizedBox.shrink();
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          tooltip: '上一页',
          onPressed: loading || page <= 1
              ? null
              : () => onPageChanged(page - 1),
          icon: const Icon(Icons.chevron_left_rounded),
        ),
        Text('$page / $totalPages'),
        IconButton(
          tooltip: '下一页',
          onPressed: loading || page >= totalPages
              ? null
              : () => onPageChanged(page + 1),
          icon: const Icon(Icons.chevron_right_rounded),
        ),
      ],
    );
  }
}
