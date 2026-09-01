import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../operations_workbench/models/operations_workbench.dart';
import '../../operations_workbench/repositories/operations_workbench_repository.dart';

/// 委外申请分解专页。
///
/// 只复用服务端任务投影与 gateway；信息架构、选择守卫和动作门禁独立于采购工作台。
/// 计划申请是只读事实，本页唯一写动作是把已下达、仍待分解的申请明细带入委外订货单。
class SubcontractDecompositionPage extends ConsumerStatefulWidget {
  const SubcontractDecompositionPage({super.key, this.repository});

  final OperationsWorkbenchGateway? repository;

  @override
  ConsumerState<SubcontractDecompositionPage> createState() =>
      _SubcontractDecompositionPageState();
}

class _SubcontractDecompositionPageState
    extends ConsumerState<SubcontractDecompositionPage> {
  OperationsWorkbenchData? _data;
  String? _error;
  bool _loading = true;
  int _page = 1;
  int _requestId = 0;
  String _keyword = '';
  String? _status;
  String? _exception;
  final Set<String> _selectedIds = <String>{};

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
        department: OperationsWorkbenchDepartment.subcontract,
        page: _page,
        keyword: _keyword,
        status: _status,
        exception: _exception,
      );
      if (!mounted || requestId != _requestId) return;
      final visibleIds = next.items.map((item) => item.id).toSet();
      setState(() {
        _data = next;
        _page = next.page;
        _selectedIds.removeWhere((id) => !visibleIds.contains(id));
        _loading = false;
      });
    } catch (error) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _loading = false;
        _error = error is ApiException ? error.message : '委外申请分解任务加载失败，请稍后重试';
      });
    }
  }

  void _applyFilter({String? keyword, String? status, String? exception}) {
    setState(() {
      if (keyword != null) _keyword = keyword;
      if (status != null) _status = status.isEmpty ? null : status;
      if (exception != null) {
        _exception = exception.isEmpty ? null : exception;
      }
      _page = 1;
      _selectedIds.clear();
    });
    _load();
  }

  List<OperationsWorkbenchTask> get _selectedTasks {
    final selected = _selectedIds;
    return _data?.items
            .where((item) => selected.contains(item.id))
            .toList(growable: false) ??
        const [];
  }

  bool get _hasDecomposePermissions {
    final permissions = ref.read(currentPermissionsProvider);
    final superAdmin = ref.read(isSuperAdminProvider);
    return superAdmin ||
        (permissions.contains(Perm.subcontractApplicationView) &&
            permissions.contains(Perm.subcontractOrderView) &&
            permissions.contains(Perm.subcontractOrderCreate) &&
            permissions.contains(Perm.subcontractOrderDecompose));
  }

  String? get _selectionIssue {
    if (!_hasDecomposePermissions) {
      return '缺少委外申请查看、订货查看、新建或申请分解权限，请联系管理员按岗位授权';
    }
    if (!(_data?.capabilities.canCreateSubcontractOrder ?? false)) {
      return '服务端未授予本账号委外订货分解能力，请刷新或联系管理员';
    }
    if (_loading) return '正在刷新委外申请，请稍候';
    final selected = _selectedTasks;
    if (selected.isEmpty) return '请先选择待分解的申请明细';
    if (selected.any(
      (task) =>
          task.actionDocument == null ||
          (task.actionDocItemId?.trim().isEmpty ?? true),
    )) {
      return '所选任务缺少不可变的委外申请明细来源，请刷新后重试';
    }
    if (selected.any((task) => task.taskStatus != 'WAITING_ORDER')) {
      return '只能选择“申请待分解”的任务';
    }
    if (selected.any(
      (task) =>
          task.actionDocument!.docType.toUpperCase() !=
              'SUBCONTRACT_APPLICATION' &&
          task.actionDocument!.docType.toUpperCase() != 'APPLICATION',
    )) {
      return '所选任务已进入订货、出仓或回厂阶段，不能再次分解';
    }
    if (selected.any(
      (task) => !task.actionDocument!.isIssuedSubcontractApplication,
    )) {
      return '计划申请尚未下达，请刷新后重试';
    }
    return null;
  }

  String _orderRoute() {
    final ids = _selectedTasks
        .map((task) => Uri.encodeComponent(task.actionDocItemId!.trim()))
        .join(',');
    return '/subcontract/orders/new?applicationItemIds=$ids';
  }

  void _createOrder() {
    final issue = _selectionIssue;
    if (issue != null) {
      context.appWarning(issue);
      return;
    }
    goFrom(context, _orderRoute());
  }

  void _toggle(OperationsWorkbenchTask task) {
    setState(() {
      if (!_selectedIds.add(task.id)) _selectedIds.remove(task.id);
    });
  }

  void _openSource(OperationsWorkbenchTask task) {
    final source = task.actionDocument;
    if (source == null || !source.canView) return;
    goFrom(context, source.path);
  }

  @override
  Widget build(BuildContext context) {
    final issue = _selectionIssue;
    return Scaffold(
      appBar: UtenAppBar(
        title: '委外申请分解',
        subtitle: '计划申请只读 · 选择明细 · 一商一单 · 保存后提交财务',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.subcontract),
        ),
        actions: [
          IconButton(
            tooltip: '刷新委外申请',
            onPressed: _loading ? null : _load,
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
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButton: _data == null || !_hasDecomposePermissions
          ? null
          : Semantics(
              button: true,
              enabled: issue == null,
              label: issue == null ? '把已选委外申请明细带入订货单' : '暂不能生成委外订货单，$issue',
              child: Tooltip(
                message: issue ?? '把已选申请明细带入委外订货单',
                child: UtenButton(
                  key: const Key('subcontract-decomposition-create-order'),
                  size: UtenButtonSize.large,
                  icon: Icons.precision_manufacturing_outlined,
                  onPressed: issue == null ? _createOrder : null,
                  onDisabledTap: issue == null
                      ? null
                      : () => context.appWarning(issue),
                  child: Text(
                    _selectedIds.isEmpty
                        ? '生成委外订货单'
                        : '生成委外订货单(${_selectedIds.length})',
                  ),
                ),
              ),
            ),
    );
  }

  Widget _buildBody() {
    if (_data == null && _loading) {
      return Center(
        child: Semantics(
          label: '正在加载委外申请分解任务',
          child: const CircularProgressIndicator(),
        ),
      );
    }
    if (_error != null) {
      return UtenEmpty.error(
        message: '无法加载委外申请',
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
        final desktop = constraints.maxWidth >= 840;
        final header = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildResponsibilityPanel(),
            const SizedBox(height: UtenSpacing.s12),
            _buildMetrics(data),
            const SizedBox(height: UtenSpacing.s12),
            _buildFilters(data, desktop: desktop),
            const SizedBox(height: UtenSpacing.s12),
            _buildSelectionSummary(),
            const SizedBox(height: UtenSpacing.s12),
          ],
        );

        if (desktop) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              Expanded(child: _buildTable(data)),
            ],
          );
        }
        return ListView(
          key: const Key('subcontract-decomposition-compact-list'),
          padding: const EdgeInsets.only(bottom: 96),
          children: [
            header,
            if (data.items.isEmpty)
              SizedBox(
                height: 280,
                child: UtenEmpty(
                  icon: Icons.task_alt_rounded,
                  message: _status == null ? '当前没有委外任务' : '当前阶段没有委外任务',
                  description: _status == null
                      ? '后续物料分析下达、订货、财务、委外和回厂任务会在这里统一显示。'
                      : '可切换“全部阶段”查看其它委外记录。',
                ),
              )
            else
              for (final task in data.items) ...[
                _SubcontractDemandCard(
                  task: task,
                  selected: _selectedIds.contains(task.id),
                  selectable:
                      _hasDecomposePermissions &&
                      data.capabilities.canCreateSubcontractOrder,
                  onSelected: () => _toggle(task),
                  onOpenSource: task.actionDocument?.canView == true
                      ? () => _openSource(task)
                      : null,
                ),
                const SizedBox(height: UtenSpacing.s8),
              ],
            _Pager(
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

  Widget _buildResponsibilityPanel() {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      label: '委外申请由物料分析下达，本页只负责选择尚未分解明细并生成商业订货单',
      child: Container(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.42),
          borderRadius: UtenRadius.lgAll,
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.account_tree_outlined, color: theme.colorScheme.primary),
            const SizedBox(width: UtenSpacing.s12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '这里分解物料分析下达的委外申请',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s4),
                  Text(
                    '申请数量、需求日和来源计划不可在委外端修改。可跨申请选择明细、按本次数量下单；'
                    '每张订货单只归一个委外商，保存后进入财务审核。直接委外不走本页，可从委外首页新建订货。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetrics(OperationsWorkbenchData data) {
    final theme = Theme.of(context);
    final summary = data.summary;
    final facts = <(String, num, IconData)>[
      (
        '待分解',
        summary.statusCounts['WAITING_ORDER'] ?? 0,
        Icons.call_split_rounded,
      ),
      ('未下单数量', summary.openQty, Icons.inventory_2_outlined),
      (
        '等待财务',
        summary.statusCounts['ORDER_PENDING_APPROVAL'] ?? 0,
        Icons.account_balance_outlined,
      ),
      ('逾期 / 异常', summary.overdueTasks, Icons.warning_amber_rounded),
    ];
    return Wrap(
      spacing: UtenSpacing.s8,
      runSpacing: UtenSpacing.s8,
      children: [
        for (final fact in facts)
          Container(
            constraints: const BoxConstraints(minWidth: 156, minHeight: 64),
            padding: const EdgeInsets.symmetric(
              horizontal: UtenSpacing.s12,
              vertical: UtenSpacing.s8,
            ),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: UtenRadius.mdAll,
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(fact.$3, size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: UtenSpacing.s8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(fact.$1, style: theme.textTheme.labelMedium),
                    Text(
                      _number(fact.$2),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildFilters(OperationsWorkbenchData data, {required bool desktop}) {
    final statusOptions = <OperationsWorkbenchFilterOption>[
      const OperationsWorkbenchFilterOption(value: '', label: '全部阶段'),
      ...data.statusOptions,
    ];
    final exceptionOptions = <OperationsWorkbenchFilterOption>[
      const OperationsWorkbenchFilterOption(value: '', label: '全部异常'),
      ...data.exceptionOptions,
    ];
    final children = <Widget>[
      SizedBox(
        width: desktop ? 320 : double.infinity,
        child: UtenSearchBar(
          key: const Key('subcontract-decomposition-search'),
          hint: '搜索计划号、申请号、货品编码或名称',
          initialValue: _keyword,
          onChanged: (value) => _applyFilter(keyword: value),
        ),
      ),
      SizedBox(
        width: desktop ? 210 : double.infinity,
        child: DropdownButtonFormField<String>(
          key: const Key('subcontract-decomposition-status'),
          initialValue: _status ?? '',
          decoration: const InputDecoration(labelText: '业务阶段'),
          items: [
            for (final option in _ensureSelected(statusOptions, _status))
              DropdownMenuItem(value: option.value, child: Text(option.label)),
          ],
          onChanged: _loading
              ? null
              : (value) => _applyFilter(status: value ?? ''),
        ),
      ),
      SizedBox(
        width: desktop ? 210 : double.infinity,
        child: DropdownButtonFormField<String>(
          key: const Key('subcontract-decomposition-exception'),
          initialValue: _exception ?? '',
          decoration: const InputDecoration(labelText: '异常'),
          items: [
            for (final option in _ensureSelected(exceptionOptions, _exception))
              DropdownMenuItem(value: option.value, child: Text(option.label)),
          ],
          onChanged: _loading
              ? null
              : (value) => _applyFilter(exception: value ?? ''),
        ),
      ),
    ];
    return desktop
        ? Wrap(
            spacing: UtenSpacing.s12,
            runSpacing: UtenSpacing.s8,
            children: children,
          )
        : Column(
            children: [
              for (var i = 0; i < children.length; i++) ...[
                children[i],
                if (i != children.length - 1)
                  const SizedBox(height: UtenSpacing.s8),
              ],
            ],
          );
  }

  List<OperationsWorkbenchFilterOption> _ensureSelected(
    List<OperationsWorkbenchFilterOption> options,
    String? selected,
  ) {
    if (selected == null ||
        selected.isEmpty ||
        options.any((o) => o.value == selected)) {
      return options;
    }
    return [
      ...options,
      OperationsWorkbenchFilterOption(
        value: selected,
        label: operationsWorkbenchStatusLabel(selected),
      ),
    ];
  }

  Widget _buildSelectionSummary() {
    final theme = Theme.of(context);
    final issue = _selectedIds.isEmpty ? null : _selectionIssue;
    return Container(
      key: const Key('subcontract-decomposition-selection'),
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s12),
      decoration: BoxDecoration(
        color: issue == null
            ? theme.colorScheme.surfaceContainerLow
            : theme.colorScheme.errorContainer.withValues(alpha: 0.45),
        borderRadius: UtenRadius.mdAll,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _selectedIds.isEmpty
                  ? '尚未选择申请明细'
                  : issue ??
                        '已选 ${_selectedIds.length} 项，可进入委外订货单填写委外商、单价和结算方式',
              style: theme.textTheme.bodySmall,
            ),
          ),
          if (_selectedIds.isNotEmpty)
            TextButton(
              onPressed: () => setState(_selectedIds.clear),
              child: const Text('清除选择'),
            ),
        ],
      ),
    );
  }

  Widget _buildTable(OperationsWorkbenchData data) {
    return MasterDataTableView<OperationsWorkbenchTask>(
      key: const Key('subcontract-decomposition-table'),
      columns: [
        MasterColumnDef(
          key: 'planNo',
          label: '来源计划',
          width: 140,
          value: (t) => t.planNo,
        ),
        MasterColumnDef(
          key: 'goods',
          label: '委外目标件',
          width: 240,
          value: (t) => '${t.goodsCode} ${t.goodsName}'.trim(),
        ),
        MasterColumnDef(
          key: 'spec',
          label: '规格 / 颜色',
          width: 180,
          value: (t) =>
              [t.spec, t.colorName].where((v) => v.isNotEmpty).join(' / '),
        ),
        MasterColumnDef(
          key: 'requiredQty',
          label: '需求量',
          width: 110,
          type: 'number',
          value: (t) => '${_number(t.requiredQty)} ${t.unitName}'.trim(),
        ),
        MasterColumnDef(
          key: 'openQty',
          label: '待下单量',
          width: 120,
          type: 'number',
          value: (t) => '${_number(t.openQty)} ${t.unitName}'.trim(),
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
          label: '阶段',
          width: 160,
          value: (t) => t.statusLabel,
        ),
        MasterColumnDef(
          key: 'source',
          label: '只读申请',
          width: 180,
          value: (t) => t.actionDocumentRestricted
              ? '无权查看关联申请'
              : (t.actionDocument?.number.isNotEmpty == true
                    ? t.actionDocument!.number
                    : '缺少申请来源'),
        ),
      ],
      items: data.items,
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      onRowTap: _openSource,
      canOpenRow: (task) => task.actionDocument?.canView == true,
      selectable:
          _hasDecomposePermissions &&
          data.capabilities.canCreateSubcontractOrder,
      idOf: (task) => task.id,
      selectedIds: _selectedIds,
      onSelectedIdsChanged: (next) => setState(() {
        _selectedIds
          ..clear()
          ..addAll(next);
      }),
      isLoading: _loading,
      error: _error,
      onRetry: _load,
      emptyMessage: '当前筛选下没有委外申请任务',
      currentPage: data.page,
      totalPages: data.totalPages,
      onPageChange: (page) {
        setState(() => _page = page);
        _load();
      },
    );
  }

  static String _number(num value) => value == value.roundToDouble()
      ? value.toInt().toString()
      : value
            .toStringAsFixed(3)
            .replaceFirst(RegExp(r'0+$'), '')
            .replaceFirst(RegExp(r'\.$'), '');
}

class _SubcontractDemandCard extends StatelessWidget {
  const _SubcontractDemandCard({
    required this.task,
    required this.selected,
    required this.selectable,
    required this.onSelected,
    required this.onOpenSource,
  });

  final OperationsWorkbenchTask task;
  final bool selected;
  final bool selectable;
  final VoidCallback onSelected;
  final VoidCallback? onOpenSource;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      selected: selected,
      label:
          '${task.goodsCode} ${task.goodsName}，待下单 ${task.quantityText}，${task.statusLabel}',
      child: Card(
        margin: EdgeInsets.zero,
        color: selected ? theme.colorScheme.primaryContainer : null,
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (selectable)
                    SizedBox(
                      width: 48,
                      height: 48,
                      child: Checkbox(
                        value: selected,
                        onChanged: (_) => onSelected(),
                      ),
                    ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${task.goodsCode} ${task.goodsName}'.trim(),
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (task.spec.isNotEmpty || task.colorName.isNotEmpty)
                          Text(
                            [
                              task.spec,
                              task.colorName,
                            ].where((v) => v.isNotEmpty).join(' · '),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  _StatusPill(
                    label: task.statusLabel,
                    danger: task.hasException,
                  ),
                ],
              ),
              const SizedBox(height: UtenSpacing.s8),
              Wrap(
                spacing: UtenSpacing.s16,
                runSpacing: UtenSpacing.s4,
                children: [
                  Text('来源计划 ${task.planNo}'),
                  Text(
                    '需求 ${_SubcontractDecompositionPageState._number(task.requiredQty)} ${task.unitName}',
                  ),
                  Text('待下单 ${task.quantityText}'),
                  Text('需求日 ${task.needDate ?? '—'}'),
                ],
              ),
              const SizedBox(height: UtenSpacing.s8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      task.actionDocumentRestricted
                          ? '关联申请受权限保护'
                          : task.actionDocument?.label ?? '缺少委外申请来源',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (onOpenSource != null)
                    TextButton.icon(
                      onPressed: onOpenSource,
                      icon: const Icon(Icons.open_in_new_rounded, size: 18),
                      label: const Text('查看只读申请'),
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
  const _StatusPill({required this.label, required this.danger});

  final String label;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final background = danger
        ? theme.colorScheme.errorContainer
        : theme.colorScheme.secondaryContainer;
    final foreground = danger
        ? theme.colorScheme.onErrorContainer
        : theme.colorScheme.onSecondaryContainer;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: background,
        borderRadius: UtenRadius.pillAll,
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: foreground,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _Pager extends StatelessWidget {
  const _Pager({
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
