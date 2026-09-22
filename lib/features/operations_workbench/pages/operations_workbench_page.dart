// 履约任务工作台（采购/仓库/委外三部门共用）。
//
// 2026-09-03 起统一「分类分段」范式（原指标卡+状态/异常下拉退役）：
// UtenFilterToolbar 阶段行（无「全部」段；终态「已完成/已领取」不占段，
// 归入末尾「历史记录」段时间门控浏览）+ 异常小类行（选中阶段后出现，
// 无「全部异常」）——两行默认都不选，内容区显示引导占位不发请求；
// 阶段/异常分段挂后端全量计数徽章（进页面仅拉一次 size=1 概览）。
// 表格多选 + 右下悬浮「生成采购订货单」批量链路保持不变。
//
// ADR-100(2026-09-21 用户口径)：采购侧照抄委外任务中心已落地的范式
// (subcontract_decomposition_page.dart)——「等待财务审核 / 财务已通过 / 财务驳回」
// 三段合并成一段「进行中」(黄色在办徽章)，三档降级为进行中表格里可排序、可表头筛选的
// 「状态」列，颜色刻意拉开。合并不能让要本人动手的单消失：「财务驳回」继续在异常小类行
// 挂红徽章，也继续计入采购任务中心卡面红数(后端 countPending 的 FINANCE_REJECTED)。
// 仓库部门两段(待备料/待领取、部分领取)不在合并范围，原样保留。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_segment_badge_label.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_history_time_filter.dart';
import '../../../components/data_display/uten_selection_summary_pill.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/connection_recovery.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/widgets/metric_filter_cards.dart' show metricToneColor;
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/operations_workbench.dart';
import '../repositories/operations_workbench_repository.dart';

/// 阶段分段值：真实任务阶段（code 非空）或历史记录哨兵。
class _WorkbenchSeg {
  const _WorkbenchSeg.stage(String this.code) : history = false;
  const _WorkbenchSeg.history() : code = null, history = true;

  final String? code;
  final bool history;
  @override
  bool operator ==(Object other) =>
      other is _WorkbenchSeg && other.code == code && other.history == history;

  @override
  int get hashCode => Object.hash(code, history);
}

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

  /// 当前选中阶段分段；null = 未选择引导态（内容不加载）。
  _WorkbenchSeg? _seg;

  /// 异常小类；null = 未选择（不附加过滤）。
  String? _exception;

  /// 历史记录段的时间门控值；none = 尚未选择（历史段下同样不发请求）。
  UtenHistoryTimeValue _historyTime = const UtenHistoryTimeValue.none();

  /// 表头列筛选（服务端 facet key → 值）；repository 以 `f.{key}` 前缀回传。
  final Map<String, String?> _columnFilters = {};

  /// 表头排序(本页列 key; 发请求时换成服务端 key); null = 用服务端默认序。
  String? _sortColumn;
  bool _sortAscending = true;

  final Set<String> _selectedIds = {};

  OperationsWorkbenchGateway get _repository =>
      widget.repository ?? ref.read(operationsWorkbenchRepositoryProvider);

  /// 阶段行分段（不含终态——已完成/已领取归入历史记录）。
  ///
  /// 采购/委外两段(ADR-100): 申请待分解 + 进行中。进行中 = 等待财务审核 +
  /// 财务已通过 + 财务驳回, 三档只在状态列里分辨, 不再各占一段。
  List<({String code, String label})> get _stages {
    return switch (widget.department) {
      OperationsWorkbenchDepartment.purchase ||
      OperationsWorkbenchDepartment.subcontract => const [
        (code: 'WAITING_ORDER', label: '申请待分解'),
        (code: 'IN_PROGRESS', label: '进行中'),
      ],
      OperationsWorkbenchDepartment.warehouse => const [
        (code: 'READY_TO_PICK', label: '待备料 / 待领取'),
        (code: 'PARTIAL', label: '部分领取'),
      ],
    };
  }

  /// 合并后的大类码与它内部「等本部门动手」的那一档(服务端 statusCounts 两个键都在:
  /// 原始 task_status 逐个入表, IN_PROGRESS 是三档之和另加的派生键)。
  static const _inProgressStage = 'IN_PROGRESS';
  static const _financeRejectedStatus = 'FINANCE_REJECTED';

  /// 阶段计数的呈现形态(docs/00-项目准则/14-徽章与计数口径.md)；三形态见 ADR-100。
  ///
  /// 红徽章只给「等本部门动手」的阶段：申请待分解（采购/委外任务中心角标同源）、
  /// 仓库的待备料/部分领取(要去出库)。
  /// 进行中的单已经在财务/供应商手上滚着、没结束又不用本部门动手 -> 黄色在办徽章;
  /// 其中真要动手的「财务驳回」由异常小类行的红徽章负责喊人。
  UtenSegmentCountForm _stageCountForm(String code) => switch (code) {
    'WAITING_ORDER' ||
    'READY_TO_PICK' ||
    'PARTIAL' => UtenSegmentCountForm.actionable,
    'IN_PROGRESS' => UtenSegmentCountForm.inProgress,
    _ => UtenSegmentCountForm.browsing,
  };

  /// 状态列文案(采购「进行中」段合并掉的三档, 用户原话就是这三个名字);
  /// 未知码回落通用阶段标签, 免得后端加档时界面显示成裸代码。
  String _stageLabelOf(OperationsWorkbenchTask task) =>
      _purchaseStageLabel(task.progressStatus) ?? task.statusLabel;

  static String? _purchaseStageLabel(String code) => switch (code) {
    'ORDER_PENDING_APPROVAL' => '等待财务审核',
    'FINANCE_APPROVED' => '财务已通过',
    'FINANCE_REJECTED' => '财务驳回',
    _ => null,
  };

  /// 状态列配色(与委外任务中心同构, ADR-098/100: 刻意拉开, 不用相近色):
  /// 蓝=球在财务、青=财务已放行正在执行、红=被驳回要本人改单重报。
  static UtenStatusBadgeType _stageBadgeType(String code) => switch (code) {
    'ORDER_PENDING_APPROVAL' => UtenStatusBadgeType.info,
    'FINANCE_APPROVED' => UtenStatusBadgeType.accent,
    'FINANCE_REJECTED' => UtenStatusBadgeType.danger,
    'WAITING_ORDER' => UtenStatusBadgeType.warning,
    'COMPLETED' => UtenStatusBadgeType.success,
    _ => UtenStatusBadgeType.neutral,
  };

  /// 状态列是否按「合并掉的三档」呈现：只有采购把四段并成两段，仓库沿用纯文本。
  bool get _mergedStageColumn =>
      widget.department != OperationsWorkbenchDepartment.warehouse;

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
        department: widget.department,
        page: page ?? _page,
        // 未选阶段时只拉 1 条：仅为取 summary 阶段/异常计数，内容区仍显示引导占位。
        size: _shouldLoad ? size : 1,
        keyword: _keyword,
        status: seg == null || seg.history ? null : seg.code,
        exception: seg == null || seg.history ? null : _exception,
        dateFrom: range == null ? null : ChinaDateTime.formatDate(range.start),
        dateTo: range == null ? null : ChinaDateTime.formatDate(range.end),
        // 排序键走服务端白名单名(本页列 key 与 facet key 不同名, 见 _serverKeyByColumn)。
        sort: _sortColumn == null ? null : _serverKeyByColumn[_sortColumn],
        order: _sortAscending ? 'asc' : 'desc',
        columnFilters: _columnFilters,
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

  void _selectSeg(_WorkbenchSeg seg) {
    if (seg == _seg) return;
    setState(() {
      _seg = seg;
      _exception = null;
      _page = 1;
      if (!seg.history) _historyTime = const UtenHistoryTimeValue.none();
      _selectedIds.clear();
      // 各阶段的 facet 集合不同（与委外任务中心同口径）：切段时清表头筛选。
      // 排序键同理——「状态」列只在进行中段有意义，换段后按服务端默认序重来。
      _columnFilters.clear();
      _sortColumn = null;
      _sortAscending = true;
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

  // —— 表头筛选（与委外任务中心 subcontract_decomposition_page 同款）——
  // 端点已返回 facets/nullCounts（模型已解析），repository 以 `f.{服务端 key}`
  // 回传。本页两列的 key 与服务端 facet key 不同名（docNo/goods），用映射对齐。

  /// 本页列 key → 服务端工作台 facet/`f.` key（null = 该列不支持表头筛选）。
  static const Map<String, String> _serverKeyByColumn = {
    'planNo': 'planNo',
    'actionDocNo': 'docNo',
    'goodsName': 'goods',
    'spec': 'spec',
    'status': 'status',
    'needDate': 'needDate',
  };

  void _onColumnFilterChanged(String column, String? value) {
    final serverKey = _serverKeyByColumn[column];
    if (serverKey == null) return;
    setState(() {
      if (value == null) {
        _columnFilters.remove(serverKey);
      } else {
        _columnFilters[serverKey] = value;
      }
      _selectedIds.clear();
    });
    _load(page: 1);
  }

  /// 服务端 facets/nullCounts → 按本页列 key 提供给 MasterDataTableView。
  ///
  /// 状态桶的 value 与 label 都是服务端阶段码(display_stage 原值), 直接挂到表头
  /// 筛选里用户看到的是裸代码; 这里按状态列同一套文案翻一遍(筛选仍回传原码)。
  Map<String, List<MasterFacetBucket>> _facetsByColumn(
    OperationsWorkbenchData data,
  ) => {
    for (final entry in _serverKeyByColumn.entries)
      if (data.facets.containsKey(entry.value))
        entry.key: entry.key == 'status'
            ? [
                for (final bucket in data.facets[entry.value]!)
                  MasterFacetBucket(
                    value: bucket.value,
                    count: bucket.count,
                    label:
                        _purchaseStageLabel(bucket.value) ??
                        operationsWorkbenchStatusLabel(bucket.value),
                  ),
              ]
            : data.facets[entry.value]!,
  };

  Map<String, int> _nullCountsByColumn(OperationsWorkbenchData data) => {
    for (final entry in _serverKeyByColumn.entries)
      if (data.nullCounts.containsKey(entry.value))
        entry.key: data.nullCounts[entry.value]!,
  };

  Map<String, String?> _columnFilterValues() => {
    for (final entry in _serverKeyByColumn.entries)
      if (_columnFilters.containsKey(entry.value))
        entry.key: _columnFilters[entry.value],
  };

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

  _SelectionPrimaryAction? get _selectionPrimaryAction {
    final data = _data;
    if (data == null) return null;
    final selected = _selectedTasks;
    switch (widget.department) {
      case OperationsWorkbenchDepartment.purchase:
        if (!data.capabilities.canCreatePurchaseOrder) return null;
        // 批量生成订货单只对「申请待分解」段有意义：其余阶段的行=已生成的
        // 订货单/收货单（V466 收口后补货走原订单），在这些段提供勾选只会
        // 制造永远点不动的批量按钮（用户感知为「按钮坏了」）。
        if (_seg?.code != 'WAITING_ORDER') return null;
        final issue = _loading
            ? '正在刷新采购任务，请稍候'
            : _purchaseSelectionIssue(selected);
        return _SelectionPrimaryAction(
          buttonKey: const Key('operations-workbench-purchase-batch'),
          label: selected.isEmpty ? '生成采购订货单' : '生成采购订货单(${selected.length})',
          icon: Icons.add_shopping_cart_rounded,
          readyTooltip: '把已选采购申请明细带入采购订货单',
          unavailableReason: issue,
          route: issue == null ? _purchaseOrderRoute(selected) : null,
        );
      case OperationsWorkbenchDepartment.subcontract:
        // 委外批量分解在专属 SubcontractDecompositionPage（含四权限门禁），
        // 本页不再维护第二份委外选择逻辑。
        return null;
      case OperationsWorkbenchDepartment.warehouse:
        // 仓库任务没有安全批量业务命令：保留表格单选 + 双击打开，不显示复选框。
        return null;
    }
  }

  /// 归组行的申请明细 id 集：单货品单据仍有 actionDocItemId；多货品合并单
  /// 从 actionItemIds 整单带入（订货单编辑页内仍可删减行）。
  List<String> _purchaseItemIdsOf(OperationsWorkbenchTask task) {
    final single = task.actionDocItemId?.trim();
    if (single?.isNotEmpty == true) return [single!];
    return task.actionItemIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toList();
  }

  String? _purchaseSelectionIssue(List<OperationsWorkbenchTask> selected) {
    if (selected.isEmpty) return '请先选择采购任务';
    final hasUnlinked = selected.any(
      (task) => task.actionDocument == null || _purchaseItemIdsOf(task).isEmpty,
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
    return null;
  }

  String _purchaseOrderRoute(List<OperationsWorkbenchTask> selected) {
    final ids = [
      for (final task in selected)
        ..._purchaseItemIdsOf(task).map((id) => Uri.encodeComponent(id)),
    ].join(',');
    return '/purchase/orders/new?requestItemIds=$ids';
  }

  void _openAction(OperationsWorkbenchTask task) {
    final document = task.actionDocument;
    if (document == null || !document.canView) return;
    goFrom(context, document.path);
  }

  Widget _buildFloatingSelectionAction(_SelectionPrimaryAction action) {
    final disabledReason = action.unavailableReason ?? '当前选择不可执行此操作';
    return Tooltip(
      message: action.enabled ? action.readyTooltip : disabledReason,
      child: UtenButton(
        key: action.buttonKey,
        size: UtenButtonSize.large,
        type: UtenButtonType.danger,
        icon: action.icon,
        onPressed: action.enabled ? () => goFrom(context, action.route!) : null,
        onDisabledTap: action.enabled
            ? null
            : () => context.appWarning(disabledReason),
        child: Text(action.label),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(
      connectionRecoveryProvider.select((state) => state.recoveryEpoch),
      (previous, next) {
        if (next <= (previous ?? 0)) return;
        // Recovery must reload the currently visible workbench without asking
        // older users to leave the page or repeatedly press refresh.
        Future<void>.microtask(() => _load());
      },
    );
    final selectionAction = _selectionPrimaryAction;
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
            onPressed: _loading ? null : () => _load(page: 1),
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
          child: _buildBody(context, selectionAction),
        ),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    _SelectionPrimaryAction? selectionAction,
  ) {
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
        onAction: () => _load(),
      );
    }
    final data = _data;
    if (data == null) {
      return UtenEmpty.error(actionLabel: '重试', onAction: () => _load());
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final breakpoint = breakpointForWidth(constraints.maxWidth);
        final seg = _seg;
        final statusCounts = data.summary.statusCounts;
        final exceptionCounts = data.summary.exceptionCounts;
        final exceptionOptions = data.exceptionOptions;
        // 阶段行：真实阶段（无「全部」；终态归历史记录）+ 末尾历史记录；
        // 计数取后端全量口径（statusCounts 不随当前筛选收窄）。
        final stageRow = UtenFilterToolbar<_WorkbenchSeg>(
          segmentsKey: Key(
            'operations-workbench-stages-${widget.department.apiValue}',
          ),
          segments: [
            for (final stage in _stages)
              UtenFilterSegment(
                value: _WorkbenchSeg.stage(stage.code),
                label: stage.label,
                // 「进行中」是大类, 底下的异常小类行里有要本部门动手的档(财务驳回),
                // 所以这一段挂两枚: 黄 = 本类在跑的全量(与列表行数相等), 红 = 其中
                // 等我动手的那几张。准则 §四之七 第 1 条(2026-09-21 追加): 大类行
                // 只挂一种颜色时, 另一色的数字点进去才看得到, 等于在大类行上蒸发。
                // 两枚**刻意重叠**(被驳回的单本来就在跑) —— 跨色不算双计, 别改成相减,
                // 相减会让黄数与「进行中」列表行数对不上。
                count: stage.code == _inProgressStage
                    ? statusCounts[_financeRejectedStatus]
                    : statusCounts[stage.code],
                countForm: stage.code == _inProgressStage
                    ? UtenSegmentCountForm.actionable
                    : _stageCountForm(stage.code),
                inProgressCount: stage.code == _inProgressStage
                    ? statusCounts[_inProgressStage]
                    : null,
              ),
            const UtenFilterSegment(
              value: _WorkbenchSeg.history(),
              label: '历史记录',
            ),
          ],
          selected: seg == null ? const {} : {seg},
          onSelectionChanged: _selectSeg,
          searchHint: '搜索任务号、来源单号、货品或往来单位',
          initialSearchValue: _keyword,
          onSearchInputChanged: (_) => _requestId++,
          onSearchChanged: _applyKeyword,
        );
        // 异常小类行：选中阶段后出现；无「全部异常」，默认不选=不附加过滤。
        // 每一项都是「不处理会出事」（逾期/缺料/延期/待挂接）→ 一律红徽章。
        // 注意 OVERDUE_ANY 是其余逾期项的并集，同一张单会在两段各红一次，
        // 这是筛选面（facet）的固有重叠，不是双计（分段计数不进累加注册表）。
        final exceptionRow =
            (seg != null && !seg.history && exceptionOptions.isNotEmpty)
            ? UtenFilterToolbar<String>(
                segmentsKey: Key(
                  'operations-workbench-exceptions-${widget.department.apiValue}',
                ),
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
              )
            : null;
        final historyTimeRow = seg?.history == true
            ? UtenHistoryTimeFilter(
                key: Key(
                  'operations-workbench-history-time-${widget.department.apiValue}',
                ),
                value: _historyTime,
                onChanged: _onHistoryTime,
              )
            : null;
        final filterRows = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            stageRow,
            if (exceptionRow != null) ...[
              const SizedBox(height: UtenSpacing.s8),
              exceptionRow,
            ],
            if (historyTimeRow != null) ...[
              const SizedBox(height: UtenSpacing.s8),
              historyTimeRow,
            ],
          ],
        );

        final useTaskTable =
            breakpoint.isExpanded ||
            widget.department == OperationsWorkbenchDepartment.warehouse;
        final tableSelectable = selectionAction != null;

        if (useTaskTable) {
          // 「顶部折叠 + 表格吸顶内滚」：任意位置上滑先把分类工具条收完，
          // 筛选行随表格上移后钉在顶部常驻，之后表格内部滚动。
          // 2026-09-06 与全站对齐：已选胶囊+批量动作走表格标准右下悬浮组
          // （MasterDataTableView.batchActionsBuilder），顶部不再占选中条。
          return UtenCollapsingHeaderScrollView(
            collapsingHeader: Padding(
              padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
              child: filterRows,
            ),
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (seg == null)
                  const Expanded(
                    child: UtenFilterPlaceholder(
                      message: '在上方选择阶段后开始办理',
                      description: '阶段默认不选中；终态任务请用末尾「历史记录」按时间查阅',
                    ),
                  )
                else if (seg.history && _historyTime.isNone)
                  const Expanded(child: UtenHistoryTimePlaceholder())
                else
                  Expanded(
                    child: _DesktopTaskTable(
                      key: const Key('operations-workbench-desktop-table'),
                      data: data,
                      items: data.items,
                      selectedIds: _selectedIds,
                      selectable: tableSelectable,
                      loading: _loading,
                      onSelectedIdsChanged: _setSelectedIds,
                      onOpenTask: _openAction,
                      onPageChanged: (page) {
                        setState(() => _page = page);
                        _load(page: page);
                      },
                      facets: _facetsByColumn(data),
                      nullCounts: _nullCountsByColumn(data),
                      filters: _columnFilterValues(),
                      onColumnFilterChanged: _onColumnFilterChanged,
                      mergedStageColumn: _mergedStageColumn,
                      stageLabelOf: _stageLabelOf,
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
                      batchActions: selectionAction == null
                          ? null
                          : (_, _) => [
                              _buildFloatingSelectionAction(selectionAction),
                            ],
                    ),
                  ),
              ],
            ),
          );
        }

        // 窄屏任务卡列表：已选胶囊+全选本页+批量动作以右下悬浮组钉底
        // （与宽屏表格悬浮组、物料分桶页同款），列表尾部留透明避让。
        final mobileFloating = (selectionAction != null && _shouldLoad)
            ? PositionedDirectional(
                end: UtenSpacing.s16,
                bottom: UtenSpacing.s16,
                child: UtenFloatingActionGroup(
                  key: const Key(
                    'operations-workbench-floating-primary-action',
                  ),
                  children: [
                    UtenSelectionSummaryPill(
                      count: _selectedIds.length,
                      onClear: _selectedIds.isEmpty
                          ? null
                          : () => setState(_selectedIds.clear),
                    ),
                    if (data.items.isNotEmpty)
                      UtenButton(
                        key: const Key('operations-workbench-select-page'),
                        type: UtenButtonType.ghost,
                        size: UtenButtonSize.large,
                        onPressed: _loading
                            ? null
                            : () => setState(
                                () => _selectedIds.addAll(
                                  data.items
                                      .where((item) => item.id.isNotEmpty)
                                      .map((item) => item.id),
                                ),
                              ),
                        child: const Text('全选本页'),
                      ),
                    _buildFloatingSelectionAction(selectionAction),
                  ],
                ),
              )
            : null;
        return Stack(
          fit: StackFit.expand,
          children: [
            ListView(
              key: const Key('operations-workbench-mobile-list'),
              // 悬浮主操作不占页面布局；仅在滚动尾部留透明避让，防止遮住末张任务卡/分页器。
              padding: EdgeInsets.only(
                bottom: selectionAction == null
                    ? 0
                    : UtenFloatingActionGroup.scrollClearance,
              ),
              children: [
                filterRows,
                const SizedBox(height: UtenSpacing.s12),
                if (seg == null)
                  const SizedBox(
                    height: 320,
                    child: UtenFilterPlaceholder(
                      message: '在上方选择阶段后开始办理',
                      description: '阶段默认不选中；终态任务请用末尾「历史记录」按时间查阅',
                    ),
                  )
                else if (seg.history && _historyTime.isNone)
                  const SizedBox(
                    height: 320,
                    child: UtenHistoryTimePlaceholder(),
                  )
                else ...[
                  if (data.items.isEmpty)
                    const SizedBox(
                      height: 320,
                      child: UtenEmpty(
                        icon: Icons.task_alt_rounded,
                        message: '当前筛选下没有任务',
                        description: '可调整阶段、异常或关键词筛选后重试。',
                      ),
                    )
                  else
                    for (final task in data.items) ...[
                      _TaskCard(
                        task: task,
                        selected:
                            selectionAction != null &&
                            _selectedIds.contains(task.id),
                        onSelected: selectionAction == null
                            ? null
                            : () => _toggleSelected(task),
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
                      _load(page: page);
                    },
                  ),
                ],
              ],
            ),
            ?mobileFloating,
          ],
        );
      },
    );
  }
}

class _SelectionPrimaryAction {
  const _SelectionPrimaryAction({
    required this.buttonKey,
    required this.label,
    required this.icon,
    required this.readyTooltip,
    required this.unavailableReason,
    required this.route,
  });

  final Key buttonKey;
  final String label;
  final IconData icon;
  final String readyTooltip;
  final String? unavailableReason;
  final String? route;

  bool get enabled => route != null;
}

class _DesktopTaskTable extends StatelessWidget {
  const _DesktopTaskTable({
    super.key,
    required this.data,
    required this.items,
    required this.selectedIds,
    required this.selectable,
    required this.loading,
    required this.onSelectedIdsChanged,
    required this.onOpenTask,
    required this.onPageChanged,
    this.facets = const {},
    this.nullCounts = const {},
    this.filters = const {},
    this.onColumnFilterChanged,
    this.mergedStageColumn = false,
    required this.stageLabelOf,
    this.sortColumn,
    this.sortAscending = true,
    this.onSortChange,
    this.batchActions,
  });

  final OperationsWorkbenchData data;
  final List<OperationsWorkbenchTask> items;
  final Set<String> selectedIds;
  final bool selectable;
  final bool loading;
  final ValueChanged<Set<String>> onSelectedIdsChanged;
  final ValueChanged<OperationsWorkbenchTask> onOpenTask;
  final ValueChanged<int> onPageChanged;
  final Map<String, List<MasterFacetBucket>> facets;
  final Map<String, int> nullCounts;
  final Map<String, String?> filters;
  final void Function(String column, String? value)? onColumnFilterChanged;

  /// 采购: 状态列承载「进行中」合并掉的三档, 用拉开颜色的状态药丸呈现(ADR-100);
  /// 仓库沿用纯文本(它的两段没有被合并, 状态列只是复述所在段)。
  final bool mergedStageColumn;
  final String Function(OperationsWorkbenchTask task) stageLabelOf;
  final String? sortColumn;
  final bool sortAscending;
  final void Function(String? column, bool ascending)? onSortChange;
  final List<Widget> Function(BuildContext, Set<String>)? batchActions;

  @override
  Widget build(BuildContext context) {
    // primary:true → 表体参与「概览卡折叠 → 表格内滚」联动（拾取外层
    // UtenCollapsingHeaderScrollView 注入的 PrimaryScrollController）。
    return MasterDataTableView<OperationsWorkbenchTask>(
      primary: true,
      selectable: selectable,
      idOf: (item) => item.id,
      selectedIds: selectable ? selectedIds : const <String>{},
      onSelectedIdsChanged: selectable ? onSelectedIdsChanged : null,
      columns: [
        MasterColumnDef(
          key: 'planNo',
          label: '计划号',
          width: 148,
          value: (item) => item.planNo,
        ),
        MasterColumnDef(
          // ADR-065 修订：行=当前执行单据（申请/订货单），单据号是首要身份；
          // 双击行或「执行入口」直达详情，明细在单据详情里逐货品查看。
          key: 'actionDocNo',
          label: '单据号',
          width: 160,
          value: (item) => item.actionDocument?.number ?? '—',
        ),
        // 2026-09-14 用户口径（全站表格统一）：名称 / 编号 / 颜色各占一列，
        // 规格再单独一列（原来「规格 / 颜色」挤在一格，两个属性都没法单独筛）。
        // 按单归组的行没有单一货品身份，编号/颜色/规格如实显示「—」。
        MasterColumnDef(
          key: 'goodsName',
          label: '货品名称',
          width: 200,
          value: (item) =>
              item.isDocumentGrouped ? item.goodsSummaryLabel : item.goodsName,
        ),
        MasterColumnDef(
          key: 'goodsCode',
          label: '编号',
          width: 130,
          value: (item) => item.isDocumentGrouped ? '—' : item.goodsCode,
        ),
        MasterColumnDef(
          key: 'colorName',
          label: '颜色',
          width: 96,
          value: (item) => item.isDocumentGrouped
              ? '—'
              : (item.colorName.isEmpty ? '—' : item.colorName),
        ),
        MasterColumnDef(
          key: 'spec',
          label: '规格',
          width: 120,
          value: (item) => item.isDocumentGrouped
              ? '—'
              : (item.spec.isEmpty ? '—' : item.spec),
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
          // 归组行不同单位不能加总：数量列让位给「未完成」的行级摘要。
          value: (item) => item.isDocumentGrouped
              ? '—'
              : _quantity(item.requiredQty, item.unitName),
        ),
        MasterColumnDef(
          key: 'allocatedQty',
          label: '已分配',
          width: 100,
          type: 'number',
          value: (item) => item.isDocumentGrouped
              ? '—'
              : _quantity(item.allocatedQty, item.unitName),
        ),
        MasterColumnDef(
          key: 'fulfilledQty',
          label: '已履约',
          width: 100,
          type: 'number',
          value: (item) => item.isDocumentGrouped
              ? '—'
              : _quantity(item.fulfilledQty, item.unitName),
        ),
        MasterColumnDef(
          key: 'openQty',
          label: '未完成',
          width: 110,
          type: 'number',
          value: (item) => item.isDocumentGrouped
              ? '${item.openLineCount} 行'
              : _quantity(item.openQty, item.unitName),
        ),
        MasterColumnDef(
          key: 'status',
          label: '状态',
          // 合并段下这列是唯一能分辨「在财务手上 / 已放行 / 被驳回」的地方,
          // 所以给足宽度并允许排序(服务端按 display_stage 排, 见 orderSql)。
          width: mergedStageColumn ? 150 : 120,
          sortable: mergedStageColumn,
          value: (item) =>
              mergedStageColumn ? stageLabelOf(item) : item.statusLabel,
          cellBuilder: !mergedStageColumn
              ? null
              : (context, item) => UtenStatusBadge(
                  label: stageLabelOf(item),
                  type: _OperationsWorkbenchPageState._stageBadgeType(
                    item.progressStatus,
                  ),
                  size: UtenStatusBadgeSize.small,
                ),
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
      facets: facets,
      nullCounts: nullCounts,
      filters: filters,
      onFilterChanged: onColumnFilterChanged ?? (_, _) {},
      sortColumn: sortColumn,
      sortAscending: sortAscending,
      onSortChange: onSortChange,
      batchActionsBuilder: batchActions,
      onRowTap: onOpenTask,
      canOpenRow: (item) => item.actionDocument?.canView ?? false,
      canShowRowMenu: (item) => item.actionDocument?.canView ?? false,
      rowMenuBuilder: (item) {
        final document = item.actionDocument;
        if (document == null || !document.canView) return const [];
        return [
          UtenMenuItem(
            label: '打开关联单据',
            icon: Icons.open_in_new_rounded,
            onTap: () => onOpenTask(item),
          ),
        ];
      },
      rowColor: (item) {
        // 选中行由组件统一高亮接管；这里只保留未选行的状态/异常着色。
        // 采购任务台：行按状态着色（全部视图下绿/蓝/黄/红一眼可辨）；
        // 仓库履约部门保留异常行高亮。
        if (data.department == OperationsWorkbenchDepartment.purchase) {
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
  final VoidCallback? onSelected;
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
        // 有下游批量动作时单击卡片切换勾选；无批量动作（仓库/无 capability）
        // 时按触屏平台习惯单击打开，卡片底部仍保留显式打开按钮。
        onTap: onSelected ?? onOpen,
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
                  if (onSelected != null) ...[
                    Checkbox(
                      value: selected,
                      onChanged: (_) => onSelected!(),
                      semanticLabel: '选择任务 ${task.taskNo}',
                    ),
                    const SizedBox(width: UtenSpacing.s4),
                  ],
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
                  child: Flexible(
                    child: Text(
                      task.actionDocument!.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
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
    OperationsWorkbenchDepartment.purchase =>
      '采购任务：申请待分解 / 进行中(等待财务审核·财务已通过·财务驳回, 见状态列) / 已完成',
    OperationsWorkbenchDepartment.subcontract =>
      '委外任务：待处理 / 进行中(等待财务审核·财务已通过·财务驳回, 见状态列) / 已完成',
    OperationsWorkbenchDepartment.warehouse => '仓库履约：待备料 / 部分领取 / 已领取',
  };
}

/// 任务状态 → 色调（与概览计数卡同色系）：申请待分解=警示黄、等待财务审核=信息蓝、
/// 财务已通过/执行中=主色青、已完成=成功绿、驳回/阻塞=红。用于行级状态药丸与行底色。
String _statusTone(String taskStatus) {
  return switch (taskStatus.toUpperCase()) {
    'WAITING_ORDER' ||
    'APPLICATION_PENDING_APPROVAL' ||
    'UNPEGGED' => 'warning',
    'ORDER_PENDING_APPROVAL' => 'info',
    'FINANCE_APPROVED' ||
    'WAITING_SUPPLY' ||
    'IN_PROGRESS' ||
    'PARTIAL' => 'neutral',
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
