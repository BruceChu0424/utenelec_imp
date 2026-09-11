// 委外任务中心（/operations/workbench/subcontract）。
//
// 2026-09-06 改版：计划委外申请页并入本页——「待处理」段 = 已下达、仍有未下单
// 量的委外申请行 + 待生产合成行（有子层先自制、未全部通知前还没有真实申请单，
// 以合成行展示车间进度，不可勾选）。双击行一律先看「产品进度」弹窗（待生产=
// 车间进度时间线；已下达申请=申请→订货→财务→出仓→回厂全链路时间线，可再深链
// 只读申请详情）；后续阶段的行（订货/财务态）双击仍直达关联单据详情。
// 多选 + 右下角悬浮组（已选胶囊 + 生成委外订货单）批量带入订货单编辑页。
//
// 2026-09-03 起统一「分类分段」范式（原概览卡+阶段/异常下拉退役）：
// UtenFilterToolbar 阶段行（无「全部阶段」；终态已完成归末尾「历史记录」段时间
// 门控）+ 异常小类行（无「全部异常」）——两行默认都不选，内容区显示引导占位
// 不发请求；分段挂后端全量计数徽章（进页面仅拉一次 size=1 概览；
// 「待处理」徽章与前置生产行均包含在后端WAITING_ORDER计数和分页中。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_selection_summary_pill.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_segment_badge_label.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_history_time_filter.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/presentation/workflow_field_guidance.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../basic_data/models/master_facet.dart';
import '../../operations_workbench/models/operations_workbench.dart';
import '../../operations_workbench/repositories/operations_workbench_repository.dart';
import '../../production/models/production_material_analysis.dart';
import '../../production/repositories/production_repository.dart';
import '../widgets/subcontract_application_progress_dialog.dart';

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
  String? _sortColumn;
  bool _sortAscending = true;
  final Map<String, String?> _columnFilters = {};

  /// 当前选中阶段分段；null = 未选择引导态（内容不加载）。
  _DecompositionSeg? _seg;

  /// 异常小类；null = 未选择（不附加过滤）。
  String? _exception;

  /// 历史记录段的时间门控值；none = 尚未选择（历史段下同样不发请求）。
  UtenHistoryTimeValue _historyTime = const UtenHistoryTimeValue.none();

  final Set<String> _selectedIds = <String>{};

  String? _openingPreparationTask;

  /// 阶段行分段（不含终态——已完成归入历史记录）。
  static const _stages = <({String code, String label})>[
    (code: 'WAITING_ORDER', label: '待处理'),
    (code: 'ORDER_PENDING_APPROVAL', label: '等待财务审核'),
    (code: 'FINANCE_APPROVED', label: '财务已通过'),
    (code: 'FINANCE_REJECTED', label: '财务驳回'),
  ];

  /// 阶段计数的呈现形态（docs/00-项目准则/14-徽章与计数口径.md）。
  ///
  /// 红徽章只给「等委外部门动手」的阶段：待处理（= 委外任务中心角标同源）与
  /// 财务驳回（要改单重报）；等待财务审核 / 财务已通过下一步是别人在办，
  /// 是监控数 → 中性括号。
  static UtenSegmentCountForm _stageCountForm(String code) => switch (code) {
    'WAITING_ORDER' || 'FINANCE_REJECTED' => UtenSegmentCountForm.actionable,
    _ => UtenSegmentCountForm.browsing,
  };

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
    // 默认不选阶段：内容不加载；仅拉一次 size=1 概览获取阶段/异常计数徽章
    // 待生产任务已经纳入同一服务端计数。
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
        sort: _sortColumn,
        order: _sortAscending ? 'asc' : 'desc',
        columnFilters: _columnFilters,
      );
      if (!mounted || requestId != _requestId) return;
      final visibleIds = next.items
          .where(_canOrderTask)
          .map((item) => item.id)
          .toSet();
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
        _error = error is ApiException ? error.message : '委外任务加载失败，请稍后重试';
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
      _columnFilters.clear();
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
      return '缺少委外申请查看、订货查看、新建或下单权限，请联系管理员按岗位授权';
    }
    if (!(_data?.capabilities.canCreateSubcontractOrder ?? false)) {
      return '服务端未授予本账号委外订货能力，请刷新或联系管理员';
    }
    if (_loading) return '正在刷新委外任务，请稍候';
    final selected = _selectedTasks;
    if (selected.isEmpty) return '请先选择待处理的委外任务';
    if (selected.any(
      (task) =>
          task.actionDocument == null || _applicationItemIdsOf(task).isEmpty,
    )) {
      return '所选任务缺少不可变的委外申请明细来源，请刷新后重试';
    }
    if (selected.any((task) => task.taskStatus != 'WAITING_ORDER')) {
      return '只能选择「待处理」的任务';
    }
    if (selected.any(
      (task) =>
          task.actionDocument!.docType.toUpperCase() !=
              'SUBCONTRACT_APPLICATION' &&
          task.actionDocument!.docType.toUpperCase() != 'APPLICATION',
    )) {
      return '所选任务已进入订货、出仓或回厂阶段，不能再次下单';
    }
    if (selected.any(
      (task) => !task.actionDocument!.isIssuedSubcontractApplication,
    )) {
      return '计划申请尚未下达，请刷新后重试';
    }
    return null;
  }

  /// 归组行（一行=一张委外申请）的明细 id 集：整单带入订货，
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
    if (!_canOrderTask(task)) return;
    setState(() {
      if (!_selectedIds.add(task.id)) _selectedIds.remove(task.id);
    });
  }

  bool _isSynthetic(OperationsWorkbenchTask task) =>
      task.preparationTaskId != null;

  bool _canOrderTask(OperationsWorkbenchTask task) =>
      task.canCreateOrder ??
      (!_isSynthetic(task) &&
          task.taskStatus == 'WAITING_ORDER' &&
          task.actionDocument?.isIssuedSubcontractApplication == true &&
          _applicationItemIdsOf(task).isNotEmpty &&
          (task.openQty > 0 || task.openLineCount > 0));

  bool _orderBlocked(OperationsWorkbenchTask task) =>
      _seg?.code == 'WAITING_ORDER' && !_canOrderTask(task);

  Future<void> _openTask(OperationsWorkbenchTask task) async {
    final preparationId = task.preparationTaskId;
    if (preparationId != null) {
      if (_openingPreparationTask != null) return;
      _openingPreparationTask = preparationId;
      final requestId = _requestId;
      try {
        final makeTask = await ref
            .read(productionPlanRepositoryProvider)
            .subcontractMakeTask(preparationId);
        if (!mounted || requestId != _requestId) return;
        await showSubcontractApplicationProgressDialog(
          context,
          makeTask: makeTask,
          onNotified: () => _load(page: 1),
        );
      } catch (error) {
        if (mounted && requestId == _requestId) {
          context.appError(
            error is ApiException ? error.message : '前置生产任务加载失败，请稍后重试',
          );
        }
      } finally {
        if (_openingPreparationTask == preparationId) {
          _openingPreparationTask = null;
        }
      }
      return;
    }
    if (task.taskStatus == 'WAITING_ORDER') {
      showSubcontractApplicationProgressDialog(context, task: task);
      return;
    }
    _openSource(task);
  }

  void _openSource(OperationsWorkbenchTask task) {
    final source = task.actionDocument;
    if (source == null || !source.canView) return;
    goFrom(context, source.path);
  }

  List<OperationsWorkbenchTask> get _displayItems => _data?.items ?? const [];

  Map<String, List<MasterFacetBucket>> _tableFacets(
    OperationsWorkbenchData data,
  ) => {
    ...data.facets,
    if (data.facets.containsKey('status'))
      'status': [
        for (final bucket in data.facets['status']!)
          MasterFacetBucket(
            value: bucket.value,
            count: bucket.count,
            label:
                const {
                  'NOTIFYING_WORKSHOP',
                  'WAITING_MATERIALS',
                  'IN_PRODUCTION',
                  'PRODUCED',
                  'FULLY_NOTIFIED',
                }.contains(bucket.value)
                ? SubcontractMakeTask.workshopStatusLabelFor(bucket.value)
                : operationsWorkbenchStatusLabel(bucket.value),
          ),
      ],
  };

  String _stageLabelOf(OperationsWorkbenchTask task) =>
      task.preparationTaskId == null
      ? task.statusLabel
      : SubcontractMakeTask.workshopStatusLabelFor(task.preparationStatus);

  Widget _createOrderButton() {
    final issue = _selectionIssue;
    return Semantics(
      button: true,
      enabled: issue == null,
      label: issue == null ? '把已选委外任务带入订货单' : '暂不能生成委外订货单，$issue',
      child: Tooltip(
        message: issue ?? '把已选申请明细带入委外订货单',
        child: UtenButton(
          key: const Key('subcontract-decomposition-create-order'),
          size: UtenButtonSize.large,
          type: UtenButtonType.danger,
          icon: Icons.precision_manufacturing_outlined,
          onPressed: issue == null ? _createOrder : null,
          onDisabledTap: issue == null ? null : () => context.appWarning(issue),
          child: Text(
            _selectedIds.isEmpty
                ? '生成委外订货单'
                : '生成委外订货单(${_selectedIds.length})',
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: UtenAppBar(
        title: '委外任务中心',
        subtitle: '计划申请只读 · 待处理（含前置生产进度）· 一商一单 · 保存后提交财务',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.subcontract),
        ),
        actions: [
          IconButton(
            tooltip: '刷新委外任务',
            onPressed: _loading ? null : () => _load(page: 1),
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

  /// Cards own one floating group; desktop and fullscreen tables own theirs.
  /// Keep ownership inside the same content-width branch that selects cards.
  Widget _withCardActions(Widget child) {
    if (!_hasDecomposePermissions ||
        (_seg?.history == true && _historyTime.isNone)) {
      return child;
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        PositionedDirectional(
          start: UtenSpacing.s16,
          end: UtenSpacing.s16,
          bottom: UtenSpacing.s16,
          child: Align(
            alignment: AlignmentDirectional.bottomEnd,
            child: UtenFloatingActionGroup(
              children: [
                UtenSelectionSummaryPill(
                  count: _selectedIds.length,
                  onClear: _selectedIds.isEmpty
                      ? null
                      : () => setState(_selectedIds.clear),
                ),
                _createOrderButton(),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBody() {
    if (_data == null && _loading) {
      return Center(
        child: Semantics(
          label: '正在加载委外任务',
          child: const CircularProgressIndicator(),
        ),
      );
    }
    if (_error != null) {
      return UtenEmpty.error(
        message: '无法加载委外任务',
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
            // 阶段行：真实阶段（无「全部阶段」；终态归历史记录）+ 末尾历史记录；
            // 前置生产与真实申请共用服务端WAITING_ORDER计数。
            UtenFilterToolbar<_DecompositionSeg>(
              segmentsKey: const Key('subcontract-decomposition-stages'),
              segments: [
                for (final stage in _stages)
                  UtenFilterSegment(
                    value: _DecompositionSeg.stage(stage.code),
                    label: stage.label,
                    count: statusCounts[stage.code],
                    countForm: _stageCountForm(stage.code),
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
            // 每一项都是「不处理会出事」（逾期/缺料/延期/待挂接）→ 一律红徽章。
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
                      countForm: UtenSegmentCountForm.actionable,
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
          ],
        );

        if (desktop) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              // 分类/筛选行与表格工具条（表头设置/全屏）行之间的呼吸间距——
              // 窄屏列表同款 s12，避免两行零间距紧贴（2026-09-06 用户反馈）。
              const SizedBox(height: UtenSpacing.s12),
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
        return _withCardActions(
          ListView(
            key: const Key('subcontract-decomposition-compact-list'),
            padding: const EdgeInsets.only(bottom: 160),
            children: [
              header,
              const SizedBox(height: UtenSpacing.s12),
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
              else if (_displayItems.isEmpty)
                SizedBox(
                  height: 280,
                  child: UtenEmpty(
                    icon: Icons.task_alt_rounded,
                    message: seg.history ? '该时间段内暂无委外任务' : '当前阶段没有委外任务',
                    description: seg.history
                        ? '可调整时间段后重试。'
                        : '可切换其它阶段或调整异常筛选后重试。',
                  ),
                )
              else
                for (final task in _displayItems) ...[
                  _SubcontractDemandCard(
                    task: task,
                    stageLabel: _stageLabelOf(task),
                    synthetic: _isSynthetic(task),
                    blocked: _orderBlocked(task),
                    selected: _selectedIds.contains(task.id),
                    selectable:
                        _canOrderTask(task) &&
                        _hasDecomposePermissions &&
                        data.capabilities.canCreateSubcontractOrder,
                    onSelected: () => _toggle(task),
                    onTap: () => _openTask(task),
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
          ),
        );
      },
    );
  }

  Widget _buildTable(OperationsWorkbenchData data) {
    return MasterDataTableView<OperationsWorkbenchTask>(
      key: const Key('subcontract-decomposition-table'),
      columns: [
        MasterColumnDef(
          key: 'planNo',
          sortable: true,
          label: '来源计划',
          width: 140,
          value: (t) => t.planNo,
        ),
        MasterColumnDef(
          // ADR-065 修订：行=当前执行单据；归组行（多货品合并申请）显示
          // 物料规模摘要；待生产合成行显示「待生产」。
          key: 'docNo',
          sortable: true,
          label: '委外申请号',
          width: 160,
          value: (t) => _isSynthetic(t)
              ? '待生产'
              : (t.actionDocumentRestricted
                    ? '—'
                    : (t.actionDocument?.number ?? '—')),
        ),
        MasterColumnDef(
          key: 'goods',
          sortable: true,
          label: '委外目标件',
          width: 240,
          value: (t) => t.isDocumentGrouped
              ? t.goodsSummaryLabel
              : '${t.goodsCode} ${t.goodsName}'.trim(),
        ),
        MasterColumnDef(
          key: 'spec',
          sortable: true,
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
          value: (t) => _isSynthetic(t)
              ? '—'
              : (t.isDocumentGrouped
                    ? '${t.openLineCount} 行'
                    : '${_number(t.openQty)} ${t.unitName}'.trim()),
        ),
        MasterColumnDef(
          key: 'issuedAt',
          label: workflowFieldText(context).subcontractPlanIssuedDate,
          info: workflowFieldText(context).subcontractPlanIssuedDateHint,
          width: 160,
          type: 'date',
          sortable: true,
          value: (task) => _issuedDate(task.issuedAt),
        ),
        MasterColumnDef(
          key: 'needDate',
          sortable: true,
          label: '需求日期',
          width: 120,
          type: 'date',
          value: (t) => t.needDate,
        ),
        MasterColumnDef(
          key: 'status',
          sortable: true,
          label: '阶段',
          width: 170,
          value: (t) => _stageLabelOf(t),
        ),
        MasterColumnDef(
          key: 'source',
          label: '只读申请',
          width: 180,
          value: (t) => _isSynthetic(t)
              ? '前置生产中'
              : (t.actionDocumentRestricted
                    ? '无权查看关联申请'
                    : (t.actionDocument?.number.isNotEmpty == true
                          ? t.actionDocument!.number
                          : '缺少申请来源')),
        ),
      ],
      items: _displayItems,
      facets: _tableFacets(data),
      nullCounts: data.nullCounts,
      filters: _columnFilters,
      onFilterChanged: (column, value) {
        setState(() {
          if (value == null) {
            _columnFilters.remove(column);
          } else {
            _columnFilters[column] = value;
          }
          _selectedIds.clear();
        });
        _load(page: 1);
      },
      sortColumn: _sortColumn,
      sortAscending: _sortAscending,
      onSortChange: (column, ascending) {
        setState(() {
          _sortColumn = column;
          _sortAscending = ascending;
          _selectedIds.clear();
        });
        _load(page: 1);
      },
      onRowTap: _openTask,
      rowColor: (task) => _orderBlocked(task)
          ? Theme.of(context).colorScheme.errorContainer.withValues(alpha: 0.42)
          : null,
      // 合成行双击=产品进度弹窗（视为可打开）；真实行=关联申请/订货详情。
      canOpenRow: (task) =>
          _isSynthetic(task) || task.actionDocument?.canView == true,
      selectable:
          _hasDecomposePermissions &&
          data.capabilities.canCreateSubcontractOrder,
      // 待生产合成行没有申请单，不提供勾选（批量下单只对真实申请行）。
      idOf: (task) => _canOrderTask(task) ? task.id : null,
      selectedIds: _selectedIds,
      onSelectedIdsChanged: (next) => setState(() {
        _selectedIds
          ..clear()
          ..addAll(next);
      }),
      batchActionsBuilder: _data == null || !_hasDecomposePermissions
          ? null
          : (_, _) => [_createOrderButton()],
      isLoading: _loading,
      error: _error,
      onRetry: () => _load(),
      emptyMessage: _seg?.history == true ? '该时间段内暂无委外任务' : '当前筛选下没有委外任务',
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

  static String? _issuedDate(String? value) {
    final date = ChinaDateTime.tryParse(value);
    return date == null ? null : ChinaDateTime.formatDate(date);
  }
}

class _SubcontractDemandCard extends StatelessWidget {
  const _SubcontractDemandCard({
    required this.task,
    required this.stageLabel,
    required this.synthetic,
    required this.blocked,
    required this.selected,
    required this.selectable,
    required this.onSelected,
    required this.onTap,
    required this.onOpenSource,
  });

  final OperationsWorkbenchTask task;
  final String stageLabel;
  final bool synthetic;
  final bool blocked;
  final bool selected;
  final bool selectable;
  final VoidCallback onSelected;
  final VoidCallback onTap;
  final VoidCallback? onOpenSource;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      selected: selected,
      label: '${task.title}，$stageLabel',
      child: Card(
        margin: EdgeInsets.zero,
        color: blocked
            ? theme.colorScheme.errorContainer.withValues(alpha: 0.42)
            : selected
            ? theme.colorScheme.primaryContainer
            : null,
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
                            !synthetic &&
                            (task.actionDocument?.number.isNotEmpty == true))
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
                  _StatusPill(label: stageLabel, danger: task.hasException),
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
                  if (!synthetic) Text('待下单 ${task.quantityText}'),
                  if ((task.needDate ?? '').isNotEmpty)
                    Text('需求日 ${task.needDate}'),
                  Text(
                    '${workflowFieldText(context).subcontractPlanIssuedDate} '
                    '${_SubcontractDecompositionPageState._issuedDate(task.issuedAt) ?? '—'}',
                  ),
                ],
              ),
              const SizedBox(height: UtenSpacing.s8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      synthetic
                          ? '前置生产中 · 完成后自动生成委外申请'
                          : task.actionDocumentRestricted
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
