// 履约任务工作台（采购/仓库/委外三部门共用）。
//
// 2026-09-03 起统一「分类分段」范式（原指标卡+状态/异常下拉退役）：
// UtenFilterToolbar 阶段行（无「全部」段；终态「已完成/已领取」不占段，
// 归入末尾「历史记录」段时间门控浏览）+ 异常小类行（选中阶段后出现，
// 无「全部异常」）——两行默认都不选，内容区显示引导占位不发请求；
// 阶段/异常分段挂后端全量计数徽章（进页面仅拉一次 size=1 概览）。
// 表格多选 + 右下悬浮「生成采购订货单」批量链路保持不变。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_history_time_filter.dart';
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

  final Set<String> _selectedIds = {};

  OperationsWorkbenchGateway get _repository =>
      widget.repository ?? ref.read(operationsWorkbenchRepositoryProvider);

  /// 阶段行分段（不含终态——已完成/已领取归入历史记录）。
  List<({String code, String label})> get _stages {
    return switch (widget.department) {
      OperationsWorkbenchDepartment.purchase ||
      OperationsWorkbenchDepartment.subcontract => const [
        (code: 'WAITING_ORDER', label: '申请待分解'),
        (code: 'ORDER_PENDING_APPROVAL', label: '等待财务审核'),
        (code: 'FINANCE_APPROVED', label: '财务已通过'),
        (code: 'FINANCE_REJECTED', label: '财务驳回'),
      ],
      OperationsWorkbenchDepartment.warehouse => const [
        (code: 'READY_TO_PICK', label: '待备料 / 待领取'),
        (code: 'PARTIAL', label: '部分领取'),
      ],
    };
  }

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
    return UtenFloatingActionGroup(
      key: const Key('operations-workbench-floating-primary-action'),
      children: [
        Tooltip(
          message: action.enabled ? action.readyTooltip : disabledReason,
          child: UtenButton(
            key: action.buttonKey,
            size: UtenButtonSize.large,
            icon: action.icon,
            onPressed: action.enabled
                ? () => goFrom(context, action.route!)
                : null,
            onDisabledTap: action.enabled
                ? null
                : () => context.appWarning(disabledReason),
            child: Text(action.label),
          ),
        ),
      ],
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
            onPressed: _loading ? null : () => _load(),
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
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
      floatingActionButton: selectionAction == null
          ? null
          : _buildFloatingSelectionAction(selectionAction),
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
                count: statusCounts[stage.code],
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
        final selectionBar = selectionAction == null || !_shouldLoad
            ? null
            : _SelectionBar(
                selected: _selectedTasks,
                pageItems: data.items,
                unavailableReason:
                    _selectedIds.isNotEmpty && !selectionAction.enabled
                    ? selectionAction.unavailableReason
                    : null,
                onSelectPage: () => setState(
                  () => _selectedIds.addAll(
                    data.items
                        .where((item) => item.id.isNotEmpty)
                        .map((item) => item.id),
                  ),
                ),
                onClear: () => setState(_selectedIds.clear),
              );

        final useTaskTable =
            breakpoint.isExpanded ||
            widget.department == OperationsWorkbenchDepartment.warehouse;
        final tableSelectable = selectionAction != null;

        if (useTaskTable) {
          // 「顶部折叠 + 表格吸顶内滚」：任意位置上滑先把分类工具条收完，
          // 筛选行与选中操作条随表格上移后钉在顶部常驻，之后表格内部滚动。
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
                else ...[
                  if (selectionBar != null) ...[
                    selectionBar,
                    const SizedBox(height: UtenSpacing.s12),
                  ],
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
                    ),
                  ),
                ],
              ],
            ),
          );
        }

        return ListView(
          key: const Key('operations-workbench-mobile-list'),
          // 悬浮主操作不占页面布局；仅在滚动尾部留透明避让，防止遮住末张任务卡/分页器。
          padding: EdgeInsets.only(bottom: selectionAction == null ? 0 : 96),
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
              const SizedBox(height: 320, child: UtenHistoryTimePlaceholder())
            else ...[
              if (selectionBar != null) ...[
                selectionBar,
                const SizedBox(height: UtenSpacing.s12),
              ],
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

class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.selected,
    required this.pageItems,
    required this.unavailableReason,
    required this.onSelectPage,
    required this.onClear,
  });

  final List<OperationsWorkbenchTask> selected;
  final List<OperationsWorkbenchTask> pageItems;
  final String? unavailableReason;
  final VoidCallback onSelectPage;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('operations-workbench-selection-bar'),
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
            // 选择条与共享表格工具条统一 large（52）；主业务动作移到右下悬浮区。
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
          if (unavailableReason != null)
            Text(
              unavailableReason!,
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
    required this.selectable,
    required this.loading,
    required this.onSelectedIdsChanged,
    required this.onOpenTask,
    required this.onPageChanged,
  });

  final OperationsWorkbenchData data;
  final List<OperationsWorkbenchTask> items;
  final Set<String> selectedIds;
  final bool selectable;
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
        MasterColumnDef(
          key: 'goodsCode',
          label: '货品编码',
          width: 140,
          value: (item) => item.isDocumentGrouped ? '—' : item.goodsCode,
        ),
        MasterColumnDef(
          key: 'goodsName',
          label: '货品名称',
          width: 200,
          value: (item) =>
              item.isDocumentGrouped ? item.goodsSummaryLabel : item.goodsName,
        ),
        MasterColumnDef(
          key: 'spec',
          label: '规格 / 颜色',
          width: 180,
          value: (item) => item.isDocumentGrouped
              ? '—'
              : [
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
      '采购任务：申请待分解 / 等待财务审核 / 财务已通过 / 财务驳回 / 已完成',
    OperationsWorkbenchDepartment.subcontract =>
      '委外任务：申请待分解 / 等待财务审核 / 财务已通过 / 财务驳回 / 已完成',
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
