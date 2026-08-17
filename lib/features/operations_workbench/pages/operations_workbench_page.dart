import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/connection_recovery.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/widgets/metric_filter_cards.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/operations_workbench.dart';
import '../repositories/operations_workbench_repository.dart';

class OperationsWorkbenchPage extends ConsumerStatefulWidget {
  const OperationsWorkbenchPage({
    super.key,
    required this.department,
    this.repository,
  });

  final OperationsWorkbenchDepartment department;
  final OperationsWorkbenchGateway? repository;

  @override
  ConsumerState<OperationsWorkbenchPage> createState() =>
      _OperationsWorkbenchPageState();
}

class _OperationsWorkbenchPageState
    extends ConsumerState<OperationsWorkbenchPage> {
  OperationsWorkbenchData? _data;
  String? _error;
  bool _loading = true;
  int _page = 1;
  int _requestId = 0;
  String _keyword = '';
  // 默认「待完成」（open_qty>0，后端 OPEN_ANY 哨兵）：进来先看还要做的事，而非全部。
  String? _status = kOperationsWorkbenchOpenStatus;
  String? _exception;
  final Set<String> _selectedIds = {};

  OperationsWorkbenchGateway get _repository =>
      widget.repository ?? ref.read(operationsWorkbenchRepositoryProvider);

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(_load);
  }

  Future<void> _load() async {
    if (!mounted) return;
    final requestId = ++_requestId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final next = await _repository.load(
        department: widget.department,
        page: _page,
        keyword: _keyword,
        status: _status,
        exception: _exception,
      );
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _data = next;
        _page = next.page;
        _loading = false;
        final currentIds = next.items.map((item) => item.id).toSet();
        _selectedIds.removeWhere((id) => !currentIds.contains(id));
      });
    } catch (error) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _loading = false;
        _error = error is ApiException ? error.message : '任务工作台加载失败，请稍后重试';
      });
    }
  }

  void _applyFilter({String? keyword, String? status, String? exception}) {
    final needsReload = keyword != null || status != null || exception != null;
    setState(() {
      if (keyword != null) _keyword = keyword;
      if (status != null) _status = status.isEmpty ? null : status;
      if (exception != null) {
        _exception = exception.isEmpty ? null : exception;
      }
      if (needsReload) _page = 1;
      _selectedIds.clear();
    });
    if (needsReload) _load();
  }

  void _toggleSelected(OperationsWorkbenchTask task) {
    if (task.id.isEmpty) return;
    setState(() {
      if (!_selectedIds.add(task.id)) _selectedIds.remove(task.id);
    });
  }

  /// 桌面表多选集合回写（组件勾选/表头三态都走这里；就地同步进 final 集合）。
  void _setSelectedIds(Set<String> next) {
    setState(() {
      _selectedIds
        ..clear()
        ..addAll(next);
    });
  }

  List<OperationsWorkbenchTask> get _selectedTasks {
    final selected = _selectedIds;
    return _data?.items
            .where((item) => selected.contains(item.id))
            .toList(growable: false) ??
        const [];
  }

  void _openAction(OperationsWorkbenchTask task) {
    final document = task.actionDocument;
    if (document == null || !document.canView) return;
    goFrom(context, document.path);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(
      connectionRecoveryProvider.select((state) => state.recoveryEpoch),
      (previous, next) {
        if (next <= (previous ?? 0)) return;
        // Recovery must reload the currently visible workbench without asking
        // older users to leave the page or repeatedly press refresh.
        Future<void>.microtask(_load);
      },
    );
    return Scaffold(
      appBar: UtenAppBar(
        title: widget.department.label,
        subtitle: _departmentSubtitle(widget.department),
        leading: UtenBackButton(
          onPressed: () =>
              backTo(context, defaultPath: _departmentHome(widget.department)),
        ),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
          const SizedBox(width: UtenSpacing.s8),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          padding: const EdgeInsets.only(
            top: UtenSpacing.s16,
            bottom: UtenSpacing.s16,
          ),
          child: _buildBody(context),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_data == null && _loading) {
      return Center(
        child: Semantics(
          label: '正在加载任务工作台',
          child: const CircularProgressIndicator(),
        ),
      );
    }
    if (_error != null) {
      return UtenEmpty.error(
        message: '无法加载${widget.department.label}',
        description: _error,
        actionLabel: '重试',
        onAction: _load,
      );
    }
    final data = _data;
    if (data == null) {
      return UtenEmpty.error(actionLabel: '重试', onAction: _load);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final breakpoint = breakpointForWidth(constraints.maxWidth);
        final overview = _Overview(
          metrics: data.metrics,
          activeStatus: _status,
          activeException: _exception,
          onMetricTap: (metric) {
            // 卡片单选互斥：任一时刻只允许一张筛选卡生效——点状态卡即清除异常
            // 筛选、点异常卡即清除状态筛选（修复「已完成+逾期」双卡同显）；
            // 再点已选卡取消，回到全量视图（状态/异常都为空）。
            final status = metric.statusFilter;
            final exception = metric.exceptionFilter;
            if (status != null) {
              _applyFilter(
                status: _status == status ? '' : status,
                exception: '',
              );
            } else if (exception != null) {
              _applyFilter(
                status: '',
                exception: _exception == exception ? '' : exception,
              );
            }
          },
        );
        final filters = _Filters(
          keyword: _keyword,
          status: _status,
          exception: _exception,
          statusOptions: data.statusOptions,
          exceptionOptions: data.exceptionOptions,
          onKeywordChanged: (value) => _applyFilter(keyword: value),
          // 下拉与卡片同一互斥规则：选中具体值即清除另一维度；选「全部」只清自身。
          onStatusChanged: (value) => value.isEmpty
              ? _applyFilter(status: '')
              : _applyFilter(status: value, exception: ''),
          onExceptionChanged: (value) => value.isEmpty
              ? _applyFilter(exception: '')
              : _applyFilter(status: '', exception: value),
        );
        final selectionBar = _SelectionBar(
          department: widget.department,
          selected: _selectedTasks,
          pageItems: data.items,
          canCreatePurchaseOrder: data.capabilities.canCreatePurchaseOrder,
          canCreateSubcontractOrder:
              data.capabilities.canCreateSubcontractOrder,
          onSelectPage: () => setState(
            () => _selectedIds.addAll(
              data.items
                  .where((item) => item.id.isNotEmpty)
                  .map((item) => item.id),
            ),
          ),
          onClear: () => setState(_selectedIds.clear),
          onOpen:
              _selectedTasks.length == 1 &&
                  (_selectedTasks.single.actionDocument?.canView ?? false)
              ? () => _openAction(_selectedTasks.single)
              : null,
        );

        if (breakpoint.isExpanded) {
          // 与货品资料一致的「顶部折叠 + 表格吸顶内滚」：任意位置上滑先把概览卡
          // 收完，筛选行与选中操作条随表格上移后钉在顶部常驻，之后表格内部滚动——
          // 表格占满剩余空间，不再被顶部内容挤压。
          return UtenCollapsingHeaderScrollView(
            collapsingHeader: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                overview,
                const SizedBox(height: UtenSpacing.s16),
              ],
            ),
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                filters,
                const SizedBox(height: UtenSpacing.s12),
                selectionBar,
                const SizedBox(height: UtenSpacing.s12),
                Expanded(
                  child: _DesktopTaskTable(
                    key: const Key('operations-workbench-desktop-table'),
                    data: data,
                    items: data.items,
                    selectedIds: _selectedIds,
                    loading: _loading,
                    onSelectedIdsChanged: _setSelectedIds,
                    onOpenTask: _openAction,
                    onPageChanged: (page) {
                      setState(() => _page = page);
                      _load();
                    },
                  ),
                ),
              ],
            ),
          );
        }

        return ListView(
          key: const Key('operations-workbench-mobile-list'),
          children: [
            overview,
            const SizedBox(height: UtenSpacing.s16),
            filters,
            const SizedBox(height: UtenSpacing.s12),
            selectionBar,
            const SizedBox(height: UtenSpacing.s12),
            if (data.items.isEmpty)
              const SizedBox(
                height: 320,
                child: UtenEmpty(
                  icon: Icons.task_alt_rounded,
                  message: '当前筛选下没有任务',
                  description: '可调整状态、异常或关键词筛选后重试。',
                ),
              )
            else
              for (final task in data.items) ...[
                _TaskCard(
                  task: task,
                  selected: _selectedIds.contains(task.id),
                  onSelected: () => _toggleSelected(task),
                  onOpen: !(task.actionDocument?.canView ?? false)
                      ? null
                      : () => _openAction(task),
                ),
                const SizedBox(height: UtenSpacing.s12),
              ],
            _MobilePager(
              page: data.page,
              totalPages: data.totalPages,
              loading: _loading,
              onPageChanged: (page) {
                setState(() => _page = page);
                _load();
              },
            ),
          ],
        );
      },
    );
  }
}

class _Overview extends StatelessWidget {
  const _Overview({
    required this.metrics,
    required this.activeStatus,
    required this.activeException,
    required this.onMetricTap,
  });

  final List<OperationsWorkbenchMetric> metrics;

  final String? activeStatus;
  final String? activeException;
  final ValueChanged<OperationsWorkbenchMetric> onMetricTap;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (metrics.isEmpty) {
      return Container(
        key: const Key('operations-workbench-overview-unavailable'),
        padding: const EdgeInsets.all(UtenSpacing.s16),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: UtenRadius.lgAll,
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Row(
          children: [
            Icon(
              Icons.info_outline_rounded,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: UtenSpacing.s12),
            const Expanded(child: Text('后端尚未返回概览数据，系统不会用任务列表推算或伪造计数。')),
          ],
        ),
      );
    }
    return MetricFilterCards(
      key: const Key('operations-workbench-overview'),
      items: [
        for (final metric in metrics)
          MetricFilterCardItem(
            key: metric.key,
            label: metric.label,
            value: metric.value,
            tone: metric.tone,
            selected:
                (metric.statusFilter != null &&
                    metric.statusFilter == activeStatus) ||
                (metric.exceptionFilter != null &&
                    metric.exceptionFilter == activeException),
            onTap: metric.statusFilter == null && metric.exceptionFilter == null
                ? null
                : () => onMetricTap(metric),
          ),
      ],
    );
  }
}

class _Filters extends StatelessWidget {
  const _Filters({
    required this.keyword,
    required this.status,
    required this.exception,
    required this.statusOptions,
    required this.exceptionOptions,
    required this.onKeywordChanged,
    required this.onStatusChanged,
    required this.onExceptionChanged,
  });

  final String keyword;
  final String? status;
  final String? exception;
  final List<OperationsWorkbenchFilterOption> statusOptions;
  final List<OperationsWorkbenchFilterOption> exceptionOptions;
  final ValueChanged<String> onKeywordChanged;
  final ValueChanged<String> onStatusChanged;
  final ValueChanged<String> onExceptionChanged;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < UtenBreakpoints.mediumStart;
        final children = [
          SizedBox(
            width: compact ? constraints.maxWidth : 360,
            // 与状态下拉（DropdownButtonFormField + labelText 固有 56）同高，
            // 避免紧凑搜索框（isDense，48）比旁边下拉矮一截。
            height: _kFilterFieldHeight,
            child: UtenSearchBar(
              key: const Key('operations-workbench-keyword'),
              initialValue: keyword,
              hint: '搜索任务号、来源单号、货品或往来单位',
              onChanged: onKeywordChanged,
            ),
          ),
          SizedBox(
            width: compact ? constraints.maxWidth : 220,
            height: _kFilterFieldHeight,
            child: _FilterDropdown(
              key: const Key('operations-workbench-status-filter'),
              label: '状态',
              value: status,
              allLabel: '全部状态',
              options: statusOptions,
              valueLabel: operationsWorkbenchStatusLabel,
              onChanged: onStatusChanged,
            ),
          ),
          SizedBox(
            width: compact ? constraints.maxWidth : 220,
            height: _kFilterFieldHeight,
            child: _FilterDropdown(
              key: const Key('operations-workbench-exception-filter'),
              label: '异常',
              value: exception,
              allLabel: '全部异常',
              options: exceptionOptions,
              valueLabel: operationsWorkbenchExceptionLabel,
              onChanged: onExceptionChanged,
            ),
          ),
        ];
        return Wrap(
          spacing: UtenSpacing.s12,
          runSpacing: UtenSpacing.s12,
          children: children,
        );
      },
    );
  }
}

/// 筛选行统一控件高度：与 DropdownButtonFormField(labelText:) 固有高度（实测 56）对齐。
const double _kFilterFieldHeight = 56;

class _FilterDropdown extends StatelessWidget {
  const _FilterDropdown({
    super.key,
    required this.label,
    required this.value,
    required this.allLabel,
    required this.options,
    required this.valueLabel,
    required this.onChanged,
  });

  final String label;
  final String? value;
  final String allLabel;
  final List<OperationsWorkbenchFilterOption> options;
  final String Function(String) valueLabel;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final selectedValue = value?.trim() ?? '';
    final optionsByValue = <String, OperationsWorkbenchFilterOption>{};
    for (final option in options) {
      final optionValue = option.value.trim();
      if (optionValue.isEmpty) continue;
      optionsByValue.putIfAbsent(
        optionValue,
        () => OperationsWorkbenchFilterOption(
          value: optionValue,
          label: option.label.trim().isEmpty
              ? valueLabel(optionValue)
              : option.label.trim(),
        ),
      );
    }
    if (selectedValue.isNotEmpty) {
      optionsByValue.putIfAbsent(
        selectedValue,
        () => OperationsWorkbenchFilterOption(
          value: selectedValue,
          label: valueLabel(selectedValue),
        ),
      );
    }
    final normalizedOptions = optionsByValue.values.toList(growable: false);

    return DropdownButtonFormField<String>(
      key: ValueKey<String>('filter-$label-$selectedValue'),
      initialValue: selectedValue,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [
        DropdownMenuItem(value: '', child: Text(allLabel)),
        for (final option in normalizedOptions)
          DropdownMenuItem(
            value: option.value,
            child: Text(option.label, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (next) => onChanged(next ?? ''),
    );
  }
}

class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.department,
    required this.selected,
    required this.pageItems,
    required this.canCreatePurchaseOrder,
    required this.canCreateSubcontractOrder,
    required this.onSelectPage,
    required this.onClear,
    required this.onOpen,
  });

  final OperationsWorkbenchDepartment department;
  final List<OperationsWorkbenchTask> selected;
  final List<OperationsWorkbenchTask> pageItems;
  final bool canCreatePurchaseOrder;
  final bool canCreateSubcontractOrder;
  final VoidCallback onSelectPage;
  final VoidCallback onClear;
  final VoidCallback? onOpen;

  OperationsActionDocument? get _purchaseSource {
    if (selected.isEmpty) return null;
    final source = selected.first.actionDocument;
    if (source == null || !_isPurchaseRequest(source)) return null;
    final everyItemCanBeCarried = selected.every((task) {
      final itemId = task.actionDocItemId?.trim();
      final taskSource = task.actionDocument;
      return itemId != null &&
          itemId.isNotEmpty &&
          taskSource != null &&
          _isPurchaseRequest(taskSource) &&
          taskSource.isApprovedPurchaseRequest;
    });
    return everyItemCanBeCarried && source.isApprovedPurchaseRequest
        ? source
        : null;
  }

  bool get _purchaseBatchReady => _purchaseSource != null;

  String get _purchaseUnavailableReason {
    if (selected.isEmpty) return '请先选择采购任务';
    final hasUnlinked = selected.any(
      (task) =>
          (task.actionDocItemId?.trim().isEmpty ?? true) ||
          task.actionDocument == null,
    );
    if (hasUnlinked) return '先生成/挂接采购申请';
    final hasLaterStage = selected.any(
      (task) => !_isPurchaseRequest(task.actionDocument!),
    );
    if (hasLaterStage) return '所选任务已进入采购订单或收货阶段';
    final hasUnapproved = selected.any(
      (task) => !task.actionDocument!.isApprovedPurchaseRequest,
    );
    if (hasUnapproved) return '计划申请尚未下达，请刷新后重试';
    return '所选采购申请明细不可生成采购单，请刷新后重试';
  }

  void _openPurchaseBatch(BuildContext context) {
    final ids = selected
        .map((task) => Uri.encodeComponent(task.actionDocItemId!.trim()))
        .join(',');
    goFrom(context, '/purchase/orders/new?requestItemIds=$ids');
  }

  bool get _subcontractBatchReady {
    if (selected.isEmpty) return false;
    return selected.every((task) {
      final itemId = task.actionDocItemId?.trim();
      final source = task.actionDocument;
      return task.taskStatus.toUpperCase() == 'WAITING_ORDER' &&
          itemId != null &&
          itemId.isNotEmpty &&
          source != null &&
          _isSubcontractApplication(source) &&
          source.isIssuedSubcontractApplication;
    });
  }

  String get _subcontractUnavailableReason {
    if (selected.isEmpty) return '请先选择委外申请任务';
    final hasUnlinked = selected.any(
      (task) =>
          (task.actionDocItemId?.trim().isEmpty ?? true) ||
          task.actionDocument == null,
    );
    if (hasUnlinked) return '所选任务缺少委外申请来源，请刷新后重试';
    final hasWrongStage = selected.any(
      (task) => task.taskStatus.toUpperCase() != 'WAITING_ORDER',
    );
    if (hasWrongStage) return '只能选择“申请待分解”的任务';
    final hasLaterDocument = selected.any(
      (task) => !_isSubcontractApplication(task.actionDocument!),
    );
    if (hasLaterDocument) return '所选任务已进入委外订货或回厂阶段';
    final hasUnissued = selected.any(
      (task) => !task.actionDocument!.isIssuedSubcontractApplication,
    );
    if (hasUnissued) return '计划申请尚未下达，请刷新后重试';
    return '所选委外申请明细不可生成订货单，请刷新后重试';
  }

  void _openSubcontractBatch(BuildContext context) {
    final ids = selected
        .map((task) => Uri.encodeComponent(task.actionDocItemId!.trim()))
        .join(',');
    goFrom(context, '/subcontract/orders/new?applicationItemIds=$ids');
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: UtenRadius.lgAll,
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Wrap(
        spacing: UtenSpacing.s8,
        runSpacing: UtenSpacing.s8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Semantics(
            liveRegion: true,
            child: Text(
              '已选 ${selected.length} 项',
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          UtenButton(
            type: UtenButtonType.secondary,
            // 操作条内所有按钮统一 large（52），与「选中并生成订货单」同高。
            size: UtenButtonSize.large,
            onPressed: pageItems.isEmpty ? null : onSelectPage,
            child: const Text('全选本页'),
          ),
          UtenButton(
            type: UtenButtonType.ghost,
            size: UtenButtonSize.large,
            onPressed: selected.isEmpty ? null : onClear,
            child: const Text('清空'),
          ),
          if (onOpen != null)
            UtenButton(
              key: const Key('operations-workbench-open-selected'),
              size: UtenButtonSize.large,
              icon: Icons.open_in_new_rounded,
              onPressed: onOpen,
              child: const Text('打开所选单据'),
            ),
          if (department == OperationsWorkbenchDepartment.purchase &&
              canCreatePurchaseOrder)
            Tooltip(
              message: _purchaseBatchReady
                  ? '把所选采购申请明细带入采购单'
                  : _purchaseUnavailableReason,
              child: UtenButton(
                key: const Key('operations-workbench-purchase-batch'),
                size: UtenButtonSize.large,
                icon: Icons.add_shopping_cart_rounded,
                onPressed: _purchaseBatchReady
                    ? () => _openPurchaseBatch(context)
                    : null,
                child: const Text('选中并生成订货单'),
              ),
            ),
          if (department == OperationsWorkbenchDepartment.purchase &&
              canCreatePurchaseOrder &&
              selected.isNotEmpty &&
              !_purchaseBatchReady)
            Text(
              _purchaseUnavailableReason,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          if (department == OperationsWorkbenchDepartment.subcontract &&
              canCreateSubcontractOrder)
            Tooltip(
              message: _subcontractBatchReady
                  ? '把所选计划委外申请明细带入委外订货单'
                  : _subcontractUnavailableReason,
              child: UtenButton(
                key: const Key('operations-workbench-subcontract-batch'),
                size: UtenButtonSize.large,
                icon: Icons.precision_manufacturing_outlined,
                onPressed: _subcontractBatchReady
                    ? () => _openSubcontractBatch(context)
                    : null,
                child: const Text('选中并生成委外订货单'),
              ),
            ),
          if (department == OperationsWorkbenchDepartment.subcontract &&
              canCreateSubcontractOrder &&
              selected.isNotEmpty &&
              !_subcontractBatchReady)
            Text(
              _subcontractUnavailableReason,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
        ],
      ),
    );
  }
}

class _DesktopTaskTable extends StatelessWidget {
  const _DesktopTaskTable({
    super.key,
    required this.data,
    required this.items,
    required this.selectedIds,
    required this.loading,
    required this.onSelectedIdsChanged,
    required this.onOpenTask,
    required this.onPageChanged,
  });

  final OperationsWorkbenchData data;
  final List<OperationsWorkbenchTask> items;
  final Set<String> selectedIds;
  final bool loading;
  final ValueChanged<Set<String>> onSelectedIdsChanged;
  final ValueChanged<OperationsWorkbenchTask> onOpenTask;
  final ValueChanged<int> onPageChanged;

  @override
  Widget build(BuildContext context) {
    // primary:true → 表体参与「概览卡折叠 → 表格内滚」联动（拾取外层
    // UtenCollapsingHeaderScrollView 注入的 PrimaryScrollController）。
    return MasterDataTableView<OperationsWorkbenchTask>(
      primary: true,
      selectable: true,
      idOf: (item) => item.id,
      selectedIds: selectedIds,
      onSelectedIdsChanged: onSelectedIdsChanged,
      columns: [
        MasterColumnDef(
          key: 'planNo',
          label: '计划号',
          width: 148,
          value: (item) => item.planNo,
        ),
        MasterColumnDef(
          key: 'goodsCode',
          label: '货品编码',
          width: 140,
          value: (item) => item.goodsCode,
        ),
        MasterColumnDef(
          key: 'goodsName',
          label: '货品名称',
          width: 200,
          value: (item) => item.goodsName,
        ),
        MasterColumnDef(
          key: 'spec',
          label: '规格 / 颜色',
          width: 180,
          value: (item) => [
            item.spec,
            item.colorName,
          ].where((value) => value.isNotEmpty).join(' / '),
        ),
        MasterColumnDef(
          key: 'supplyRoute',
          label: '供给方式',
          width: 120,
          // 后端返回路由码（BUY/MAKE/SUBCONTRACT），界面统一显示中文标签。
          value: (item) =>
              operationsWorkbenchSupplyRouteLabel(item.supplyRoute),
        ),
        MasterColumnDef(
          key: 'requiredQty',
          label: '需求数量',
          width: 110,
          type: 'number',
          value: (item) => _quantity(item.requiredQty, item.unitName),
        ),
        MasterColumnDef(
          key: 'allocatedQty',
          label: '已分配',
          width: 100,
          type: 'number',
          value: (item) => _quantity(item.allocatedQty, item.unitName),
        ),
        MasterColumnDef(
          key: 'fulfilledQty',
          label: '已履约',
          width: 100,
          type: 'number',
          value: (item) => _quantity(item.fulfilledQty, item.unitName),
        ),
        MasterColumnDef(
          key: 'openQty',
          label: '未完成',
          width: 100,
          type: 'number',
          value: (item) => _quantity(item.openQty, item.unitName),
        ),
        MasterColumnDef(
          key: 'status',
          label: '状态',
          width: 120,
          value: (item) => item.statusLabel,
        ),
        MasterColumnDef(
          key: 'exception',
          label: '异常',
          width: 140,
          value: (item) => item.exceptionLabel,
        ),
        MasterColumnDef(
          key: 'warehouseName',
          label: '仓库',
          width: 180,
          value: (item) => item.warehouseName,
        ),
        MasterColumnDef(
          key: 'needDate',
          label: '需求日期',
          width: 130,
          type: 'date',
          value: (item) => item.needDate ?? '—',
        ),
        MasterColumnDef(
          key: 'expectedDate',
          label: '预计日期',
          width: 130,
          type: 'date',
          value: (item) => item.expectedDate ?? '—',
        ),
        MasterColumnDef(
          key: 'action',
          label: '执行入口',
          width: 160,
          value: (item) => item.actionDocumentRestricted
              ? '无权查看关联单据'
              : item.actionDocument?.label ?? '待生成/待挂接',
        ),
      ],
      items: items,
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      onRowTap: onOpenTask,
      rowColor: (item) {
        // 选中行由组件勾选列 + 深绿高亮接管；这里只保留未选行的状态/异常着色。
        // 采购/委外任务台：行按状态着色（全部视图下绿/蓝/黄/红一眼可辨）；
        // 仓库履约部门保留异常行高亮。
        if (data.department == OperationsWorkbenchDepartment.purchase ||
            data.department == OperationsWorkbenchDepartment.subcontract) {
          return metricToneColor(
            _statusTone(item.taskStatus),
            Theme.of(context),
          ).withValues(alpha: 0.10);
        }
        return item.hasException
            ? Theme.of(
                context,
              ).colorScheme.errorContainer.withValues(alpha: 0.35)
            : null;
      },
      isLoading: loading,
      emptyMessage: '当前筛选下没有任务',
      currentPage: data.page,
      totalPages: data.totalPages,
      onPageChange: onPageChanged,
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({
    required this.task,
    required this.selected,
    required this.onSelected,
    required this.onOpen,
  });

  final OperationsWorkbenchTask task;
  final bool selected;
  final VoidCallback onSelected;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: selected
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.35)
          : theme.colorScheme.surface,
      borderRadius: UtenRadius.lgAll,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onSelected,
        child: Container(
          padding: const EdgeInsets.all(UtenSpacing.s16),
          decoration: BoxDecoration(
            borderRadius: UtenRadius.lgAll,
            border: Border.all(
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outlineVariant,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Checkbox(
                    value: selected,
                    onChanged: (_) => onSelected(),
                    semanticLabel: '选择任务 ${task.taskNo}',
                  ),
                  const SizedBox(width: UtenSpacing.s4),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          task.title,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: UtenSpacing.s4),
                        Text(
                          '${task.taskNo} · 来源 ${task.sourceNo}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _StatusPill(
                    label: task.statusLabel,
                    color: metricToneColor(_statusTone(task.taskStatus), theme),
                  ),
                ],
              ),
              const SizedBox(height: UtenSpacing.s12),
              Wrap(
                spacing: UtenSpacing.s12,
                runSpacing: UtenSpacing.s8,
                children: [
                  _TaskFact(
                    icon: Icons.business_outlined,
                    label: task.counterparty,
                  ),
                  _TaskFact(icon: Icons.event_outlined, label: task.dueDate),
                  _TaskFact(
                    icon: Icons.numbers_rounded,
                    label: task.quantityText,
                  ),
                  _StatusPill(
                    label: task.exceptionLabel,
                    color: task.hasException
                        ? theme.colorScheme.error
                        : UtenColors.success,
                  ),
                ],
              ),
              const SizedBox(height: UtenSpacing.s16),
              if (onOpen != null)
                UtenButton(
                  key: Key('operations-task-action-${task.id}'),
                  onPressed: onOpen,
                  icon: Icons.open_in_new_rounded,
                  isExpanded: true,
                  child: Text(task.actionDocument!.label),
                )
              else
                Row(
                  children: [
                    Icon(
                      task.actionDocumentRestricted
                          ? Icons.lock_outline_rounded
                          : Icons.link_off_rounded,
                      size: UtenSpacing.s20,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                    Expanded(
                      child: Text(
                        task.actionDocumentRestricted
                            ? '无权查看关联单据'
                            : '待生成/待挂接执行单据',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
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

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s8,
        vertical: UtenSpacing.s4,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: UtenRadius.pillAll,
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _TaskFact extends StatelessWidget {
  const _TaskFact({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 18,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: UtenSpacing.s4),
        Text(label),
      ],
    );
  }
}

class _MobilePager extends StatelessWidget {
  const _MobilePager({
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          UtenButton(
            size: UtenButtonSize.small,
            type: UtenButtonType.ghost,
            onPressed: !loading && page > 1
                ? () => onPageChanged(page - 1)
                : null,
            child: const Text('上一页'),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s16),
            child: Text('$page / $totalPages'),
          ),
          UtenButton(
            size: UtenButtonSize.small,
            type: UtenButtonType.ghost,
            onPressed: !loading && page < totalPages
                ? () => onPageChanged(page + 1)
                : null,
            child: const Text('下一页'),
          ),
        ],
      ),
    );
  }
}

String _departmentHome(OperationsWorkbenchDepartment department) {
  return switch (department) {
    OperationsWorkbenchDepartment.warehouse => RouteName.warehouse,
    OperationsWorkbenchDepartment.purchase => RouteName.purchase,
    OperationsWorkbenchDepartment.subcontract => RouteName.subcontract,
  };
}

String _departmentSubtitle(OperationsWorkbenchDepartment department) {
  return switch (department) {
    OperationsWorkbenchDepartment.purchase => '采购任务：申请待分解 / 财务已通过 / 财务驳回 / 已完成',
    OperationsWorkbenchDepartment.subcontract =>
      '委外任务：申请待分解 / 财务已通过 / 财务驳回 / 已完成',
    OperationsWorkbenchDepartment.warehouse => '仓库履约：待备料 / 部分领取 / 已领取',
  };
}

/// 任务状态 → 色调（与概览计数卡同色系）：待分解=警示黄、待采购完成/执行中=信息蓝、
/// 已完成=成功绿、阻塞=红、其余=主色。用于行级状态药丸着色。
String _statusTone(String taskStatus) {
  return switch (taskStatus.toUpperCase()) {
    'WAITING_ORDER' ||
    'APPLICATION_PENDING_APPROVAL' ||
    'UNPEGGED' => 'warning',
    'FINANCE_APPROVED' ||
    'WAITING_SUPPLY' ||
    'IN_PROGRESS' ||
    'PARTIAL' ||
    'ORDER_PENDING_APPROVAL' => 'info',
    'COMPLETED' || 'DONE' || 'COVERED' => 'success',
    'BLOCKED' || 'FINANCE_REJECTED' => 'danger',
    _ => 'neutral',
  };
}

String _quantity(num value, String unitName) {
  final number = value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toString();
  return unitName.isEmpty ? number : '$number $unitName';
}

bool _isPurchaseRequest(OperationsActionDocument document) {
  final type = document.docType.toUpperCase();
  return type == 'PURCHASE_REQUEST' || type == 'REQUEST';
}

bool _isSubcontractApplication(OperationsActionDocument document) {
  final type = document.docType.toUpperCase();
  return type == 'SUBCONTRACT_APPLICATION' || type == 'APPLICATION';
}
