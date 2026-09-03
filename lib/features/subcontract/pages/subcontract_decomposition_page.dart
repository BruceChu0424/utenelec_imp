// 委外申请分解专页。
//
// 只复用服务端任务投影与 gateway；信息架构、选择守卫和动作门禁独立于采购工作台。
// 计划申请是只读事实，本页唯一写动作是把已下达、仍待分解的申请明细带入委外订货单。
//
// 2026-09-03 起统一「分类分段」范式（原概览卡+阶段/异常下拉退役）：
// UtenFilterToolbar 阶段行（无「全部阶段」；终态已完成归末尾「历史记录」段时间
// 门控）+ 异常小类行（无「全部异常」）——两行默认都不选，内容区显示引导占位
// 不发请求；分段挂后端全量计数徽章（进页面仅拉一次 size=1 概览）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/layout/uten_history_time_filter.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../operations_workbench/models/operations_workbench.dart';
import '../../operations_workbench/repositories/operations_workbench_repository.dart';

/// 阶段分段值：真实任务阶段（code 非空）或历史记录哨兵。
class _DecompositionSeg {
  const _DecompositionSeg.stage(String this.code) : history = false;
  const _DecompositionSeg.history() : code = null, history = true;

  final String? code;
  final bool history;
  @override
  bool operator ==(Object other) =>
      other is _DecompositionSeg &&
      other.code == code &&
      other.history == history;

  @override
  int get hashCode => Object.hash(code, history);
}

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

  /// 当前选中阶段分段；null = 未选择引导态（内容不加载）。
  _DecompositionSeg? _seg;

  /// 异常小类；null = 未选择（不附加过滤）。
  String? _exception;

  /// 历史记录段的时间门控值；none = 尚未选择（历史段下同样不发请求）。
  UtenHistoryTimeValue _historyTime = const UtenHistoryTimeValue.none();

  final Set<String> _selectedIds = <String>{};

  /// 阶段行分段（不含终态——已完成归入历史记录）。
  static const _stages = <({String code, String label})>[
    (code: 'WAITING_ORDER', label: '申请待分解'),
    (code: 'ORDER_PENDING_APPROVAL', label: '等待财务审核'),
    (code: 'FINANCE_APPROVED', label: '财务已通过'),
    (code: 'FINANCE_REJECTED', label: '财务驳回'),
  ];

  OperationsWorkbenchGateway get _repository =>
      widget.repository ?? ref.read(operationsWorkbenchRepositoryProvider);

  bool get _shouldLoad {
    final seg = _seg;
    if (seg == null) return false;
    if (seg.history && _historyTime.isNone) return false;
    return true;
  }

  @override
  void initState() {
    super.initState();
    // 默认不选阶段：内容不加载；仅拉一次 size=1 概览获取阶段/异常计数徽章。
    Future<void>.microtask(() => _load(page: 1));
  }

  Future<void> _load({int? page, int size = 50}) async {
    if (!mounted) return;
    final requestId = ++_requestId;
    final seg = _seg;
    final range = seg?.history == true ? _historyTime.range : null;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final next = await _repository.load(
        department: OperationsWorkbenchDepartment.subcontract,
        page: page ?? _page,
        // 未选阶段时只拉 1 条：仅为取 summary 阶段/异常计数。
        size: _shouldLoad ? size : 1,
        keyword: _keyword,
        status: seg == null || seg.history ? null : seg.code,
        exception: seg == null || seg.history ? null : _exception,
        dateFrom: range == null ? null : ChinaDateTime.formatDate(range.start),
        dateTo: range == null ? null : ChinaDateTime.formatDate(range.end),
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

  void _selectSeg(_DecompositionSeg seg) {
    if (seg == _seg) return;
    setState(() {
      _seg = seg;
      _exception = null;
      _page = 1;
      if (!seg.history) _historyTime = const UtenHistoryTimeValue.none();
      _selectedIds.clear();
    });
    if (!seg.history || !_historyTime.isNone) {
      _load(page: 1);
    }
  }

  void _selectException(String code) {
    if (_exception == code) return;
    setState(() {
      _exception = code;
      _page = 1;
      _selectedIds.clear();
    });
    _load(page: 1);
  }

  void _onHistoryTime(UtenHistoryTimeValue value) {
    if (value == _historyTime) return;
    setState(() {
      _historyTime = value;
      _page = 1;
      _selectedIds.clear();
    });
    _load(page: 1);
  }

  void _applyKeyword(String value) {
    final normalized = value.trim();
    if (normalized == _keyword) return;
    _keyword = normalized;
    _load(page: 1);
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
          task.actionDocument == null || _applicationItemIdsOf(task).isEmpty,
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

  /// 归组行（一行=一张委外申请）的明细 id 集：整单带入订货分解，
  /// 订货单编辑页内仍可删减行。
  List<String> _applicationItemIdsOf(OperationsWorkbenchTask task) {
    final single = task.actionDocItemId?.trim();
    if (single?.isNotEmpty == true) return [single!];
    return task.actionItemIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toList();
  }

  String _orderRoute() {
    final ids = [
      for (final task in _selectedTasks)
        ..._applicationItemIdsOf(task).map((id) => Uri.encodeComponent(id)),
    ].join(',');
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
            onPressed: _loading ? null : () => _load(),
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
        onAction: () => _load(),
      );
    }
    final data = _data;
    if (data == null) {
      return UtenEmpty.error(actionLabel: '重试', onAction: () => _load());
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final desktop = constraints.maxWidth >= 840;
        final seg = _seg;
        final statusCounts = data.summary.statusCounts;
        final exceptionCounts = data.summary.exceptionCounts;
        final exceptionOptions = data.exceptionOptions;
        final header = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 阶段行：真实阶段（无「全部阶段」；终态归历史记录）+ 末尾历史记录。
            UtenFilterToolbar<_DecompositionSeg>(
              segmentsKey: const Key('subcontract-decomposition-stages'),
              segments: [
                for (final stage in _stages)
                  UtenFilterSegment(
                    value: _DecompositionSeg.stage(stage.code),
                    label: stage.label,
                    count: statusCounts[stage.code],
                  ),
                const UtenFilterSegment(
                  value: _DecompositionSeg.history(),
                  label: '历史记录',
                ),
              ],
              selected: seg == null ? const {} : {seg},
              onSelectionChanged: _selectSeg,
              searchHint: '搜索计划号、申请号、货品编码或名称',
              initialSearchValue: _keyword,
              onSearchInputChanged: (_) => _requestId++,
              onSearchChanged: _applyKeyword,
            ),
            // 异常小类行：选中阶段后出现；无「全部异常」，默认不选=不附加过滤。
            if (seg != null && !seg.history && exceptionOptions.isNotEmpty) ...[
              const SizedBox(height: UtenSpacing.s8),
              UtenFilterToolbar<String>(
                segmentsKey: const Key('subcontract-decomposition-exceptions'),
                segments: [
                  for (final option in exceptionOptions)
                    UtenFilterSegment(
                      value: option.value,
                      label: option.label,
                      count: exceptionCounts[option.value],
                    ),
                ],
                selected: _exception == null ? const {} : {_exception!},
                onSelectionChanged: _selectException,
              ),
            ],
            if (seg?.history == true) ...[
              const SizedBox(height: UtenSpacing.s8),
              UtenHistoryTimeFilter(
                key: const Key('subcontract-decomposition-history-time'),
                value: _historyTime,
                onChanged: _onHistoryTime,
              ),
            ],
            const SizedBox(height: UtenSpacing.s12),
            if (_shouldLoad) ...[
              _buildSelectionSummary(),
              const SizedBox(height: UtenSpacing.s12),
            ],
          ],
        );

        if (desktop) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              Expanded(
                child: seg == null
                    ? const UtenFilterPlaceholder(
                        message: '在上方选择阶段后开始办理',
                        description: '阶段默认不选中；终态任务请用末尾「历史记录」按时间查阅',
                      )
                    : seg.history && _historyTime.isNone
                    ? const UtenHistoryTimePlaceholder()
                    : _buildTable(data),
              ),
            ],
          );
        }
        return ListView(
          key: const Key('subcontract-decomposition-compact-list'),
          padding: const EdgeInsets.only(bottom: 96),
          children: [
            header,
            if (seg == null)
              const SizedBox(
                height: 280,
                child: UtenFilterPlaceholder(
                  message: '在上方选择阶段后开始办理',
                  description: '阶段默认不选中；终态任务请用末尾「历史记录」按时间查阅',
                ),
              )
            else if (seg.history && _historyTime.isNone)
              const SizedBox(height: 280, child: UtenHistoryTimePlaceholder())
            else if (data.items.isEmpty)
              SizedBox(
                height: 280,
                child: UtenEmpty(
                  icon: Icons.task_alt_rounded,
                  message: seg.history ? '该时间段内暂无委外任务' : '当前阶段没有委外任务',
                  description: seg.history
                      ? '可调整时间段或改用「全部」后重试。'
                      : '可切换其它阶段或调整异常筛选后重试。',
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
                _load(page: page);
              },
            ),
          ],
        );
      },
    );
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
          // ADR-065 修订：行=当前执行单据；归组行（多货品合并申请）显示
          // 物料规模摘要，双击进申请详情看逐货品明细。
          key: 'docNo',
          label: '委外申请号',
          width: 160,
          value: (t) => t.actionDocumentRestricted
              ? '—'
              : (t.actionDocument?.number ?? '—'),
        ),
        MasterColumnDef(
          key: 'goods',
          label: '委外目标件',
          width: 240,
          value: (t) => t.isDocumentGrouped
              ? t.goodsSummaryLabel
              : '${t.goodsCode} ${t.goodsName}'.trim(),
        ),
        MasterColumnDef(
          key: 'spec',
          label: '规格 / 颜色',
          width: 180,
          value: (t) => t.isDocumentGrouped
              ? '—'
              : [t.spec, t.colorName].where((v) => v.isNotEmpty).join(' / '),
        ),
        MasterColumnDef(
          key: 'requiredQty',
          label: '需求量',
          width: 110,
          type: 'number',
          value: (t) => t.isDocumentGrouped
              ? '—'
              : '${_number(t.requiredQty)} ${t.unitName}'.trim(),
        ),
        MasterColumnDef(
          key: 'openQty',
          label: '待下单量',
          width: 120,
          type: 'number',
          value: (t) => t.isDocumentGrouped
              ? '${t.openLineCount} 行'
              : '${_number(t.openQty)} ${t.unitName}'.trim(),
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
      onRetry: () => _load(),
      emptyMessage: _seg?.history == true ? '该时间段内暂无委外申请任务' : '当前筛选下没有委外申请任务',
      currentPage: data.page,
      totalPages: data.totalPages,
      onPageChange: (page) {
        setState(() => _page = page);
        _load(page: page);
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
      label: '${task.title}，待下单 ${task.quantityText}，${task.statusLabel}',
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
                          task.isDocumentGrouped
                              ? task.goodsSummaryLabel
                              : '${task.goodsCode} ${task.goodsName}'.trim(),
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (!task.isDocumentGrouped &&
                            (task.spec.isNotEmpty || task.colorName.isNotEmpty))
                          Text(
                            [
                              task.spec,
                              task.colorName,
                            ].where((v) => v.isNotEmpty).join(' · '),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        if (!task.isDocumentGrouped &&
                            task.actionDocument?.number.isNotEmpty == true)
                          Text(
                            task.actionDocument!.number,
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
                  if (!task.isDocumentGrouped)
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
