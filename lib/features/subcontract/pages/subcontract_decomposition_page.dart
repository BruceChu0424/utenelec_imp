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
//
// ADR-103(2026-09-22) 路线 B(单一子件直发)的申请行与路线 A 同位锁定：子件在作业
// 叶仓一件都没有时 display_stage=WAITING_COMPONENT_STOCK(等子件到货, 黄底, 不可勾选,
// 计入「待处理」段的黄枚), 到货后 COMPONENT_STOCK_READY(子件已到货·可下单, 红,
// 文案带仓内可动用量); 财务已通过的订货单在待发料之前多一档 OUTBOUND_WAITING_COMPONENT.
// 黄底 = 在办等别人到货, 红底 = 路线 A 等自己部门的车间 / 服务端明确不可下单.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_selection_summary_pill.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_segment_badge_label.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_history_time_filter.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
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
import '../../../shared/models/subcontract_short_delivery.dart'
    show subcontractProgressStatusLabel;
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
  ///
  /// ADR-098（2026-09-20 用户口径）：「等待财务审核 / 财务已通过 / 财务驳回」三段合并成
  /// 「进行中」；订货单在其中的执行状态由状态列（表头可筛、颜色拉开）表达：
  /// 等待财务审核 / 财务已退回 / 待发料出仓 / 委外加工中 / 部分回厂 / 分批等待中 /
  /// 回厂短交待判定。要本部门动手的（财务已退回、回厂短交待判定）在异常小类行挂红徽章。
  /// ADR-100(2026-09-21): 「进行中」的数字改挂黄色在办徽章, 见 _stageCountForm。
  static const _stages = <({String code, String label})>[
    (code: 'WAITING_ORDER', label: '待处理'),
    (code: 'IN_PROGRESS', label: '进行中'),
  ];

  /// 合并后的大类码与它内部「等委外动手」的那一档(服务端 statusCounts 两个键都在:
  /// 原始 task_status 逐个入表, IN_PROGRESS 是三档之和另加的派生键)。
  static const _inProgressStage = 'IN_PROGRESS';
  static const _financeRejectedStatus = 'FINANCE_REJECTED';

  /// 阶段计数的呈现形态(docs/00-项目准则/14-徽章与计数口径.md)；三形态见 ADR-100。
  ///
  /// 红徽章只给「等委外部门动手」的阶段：待处理（= 委外任务中心角标同源）；
  /// 进行中的单已发料在外加工 / 在等财务 / 在等回厂 —— 还在跑、没完, 但现在不用
  /// 委外动手, 2026-09-21 起由中性括号改成黄色在办徽章; 其中真要动手的两类
  /// (财务已退回、回厂短交待判定)仍走异常小类行的红徽章。
  /// 两个大类都是红黄两枚: 待处理的黄 = 等子件到货的路线 B 锁行(ADR-103),
  /// 进行中的红 = 财务已退回单; 两枚的搭配见 build 里的分段注释。
  static UtenSegmentCountForm _stageCountForm(String code) => switch (code) {
    'WAITING_ORDER' => UtenSegmentCountForm.actionable,
    'IN_PROGRESS' => UtenSegmentCountForm.inProgress,
    _ => UtenSegmentCountForm.browsing,
  };

  /// 状态列颜色（ADR-098：刻意拉开，不用相近色）：蓝=等财务、红=退回/短交、
  /// 紫=待发料出仓、青=加工中、橙=部分回厂、品红=分批等待、
  /// 绿=已回厂待入库(回厂量到齐只差质检入库, 与历史段的已完成同色但不同段)。
  /// ADR-103 路线 B: 黄=等子件到货(申请行锁 / 订货单待发料等子件), 绿=子件已到货可下单。
  static UtenStatusBadgeType _progressType(String code) => switch (code) {
    'WAITING_COMPONENT_STOCK' ||
    'OUTBOUND_WAITING_COMPONENT' => UtenStatusBadgeType.warning,
    'COMPONENT_STOCK_READY' => UtenStatusBadgeType.success,
    'ORDER_PENDING_APPROVAL' => UtenStatusBadgeType.info,
    'FINANCE_REJECTED' || 'SHORT_DELIVERY' => UtenStatusBadgeType.danger,
    'AWAITING_OUTBOUND' => UtenStatusBadgeType.violet,
    'AT_SUPPLIER' => UtenStatusBadgeType.accent,
    'PARTIAL_RECEIVED' => UtenStatusBadgeType.warning,
    'RECEIVED_PENDING_STOCK' => UtenStatusBadgeType.success,
    'WAITING_MORE_BATCH' => UtenStatusBadgeType.fuchsia,
    // 容差内待结案：不急，灰色中性；点状态同样可去判定页。
    'TOLERANT_SHORT' => UtenStatusBadgeType.neutral,
    'COMPLETED' => UtenStatusBadgeType.success,
    _ => UtenStatusBadgeType.neutral,
  };

  bool _shortDelivery(OperationsWorkbenchTask task) =>
      task.progressStatus == 'SHORT_DELIVERY';

  /// 状态列文案：委外订货单按展示阶段翻译，未知码回落既有阶段文案。
  /// ADR-103 路线 B 申请行追加「(仓内可动用 X 单位)」：解锁行给出此刻可发量，
  /// 锁行固定 0——用户口径「可发数量那里可以提示」。
  String _progressLabelOf(OperationsWorkbenchTask task) {
    final code = task.progressStatus;
    final label = subcontractProgressStatusLabel(code);
    if (label == code) return task.statusLabel;
    if (task.componentStockReady) {
      final qty = task.componentAvailableQty;
      final text = qty == null ? '' : '${_number(qty)} ${task.unitName}'.trim();
      return text.isEmpty ? label : '$label(仓内可动用 $text)';
    }
    if (task.waitingComponentStock) return '$label(仓内可动用 0)';
    return label;
  }

  /// ADR-103：路线 B 申请行状态药丸的悬浮说明 (锁 / 解锁各一句，说清流向)。
  String? _progressTooltipOf(OperationsWorkbenchTask task) {
    if (task.waitingComponentStock) {
      return '子件尚未入库，入库后自动解锁；仓库发出去的是子件，加工完回厂的是委外件';
    }
    if (task.componentStockReady) {
      return '子件已到货，可以生成委外订货单；订货数量可以超过仓内可动用量，仓库会按到货分批发料';
    }
    return null;
  }

  /// ADR-103：锁行的只读申请列 / 卡片脚注统一说明，不再显示申请号。
  static const _waitingComponentSourceText = '等子件到货·入库后自动解锁';

  /// 回厂短交待判定 / 分批等待中的订货单：点状态直达判定页（只看这张单）。
  void _openShortDeliveries(OperationsWorkbenchTask task) {
    final orderId = task.actionDocument?.id;
    if (orderId == null || orderId.isEmpty) return;
    goFrom(context, RouteName.subcontractShortDeliveriesWith(orderId: orderId));
  }

  bool _linksToShortDeliveries(OperationsWorkbenchTask task) =>
      const {
        'SHORT_DELIVERY',
        'WAITING_MORE_BATCH',
        'TOLERANT_SHORT',
      }.contains(task.progressStatus) &&
      task.actionDocument?.id.isNotEmpty == true;

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
    // ADR-103：路线 B 锁行本就不可勾选，这里兜底 (键盘 / 旧选中集残留)。
    if (selected.any((task) => task.waitingComponentStock)) {
      return '所选委外件的子件尚未到货，子件入库后才能生成订货单';
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

  /// 服务端 canCreateOrder 优先；老响应回落本地规则。ADR-103：路线 B 锁行
  /// (display_stage=WAITING_COMPONENT_STOCK)本地也一律判不可下单，不信回落规则放行。
  bool _canOrderTask(OperationsWorkbenchTask task) =>
      !task.waitingComponentStock &&
      (task.canCreateOrder ??
          (!_isSynthetic(task) &&
              task.taskStatus == 'WAITING_ORDER' &&
              task.actionDocument?.isIssuedSubcontractApplication == true &&
              _applicationItemIdsOf(task).isNotEmpty &&
              (task.openQty > 0 || task.openLineCount > 0)));

  bool _orderBlocked(OperationsWorkbenchTask task) =>
      _seg?.code == 'WAITING_ORDER' && !_canOrderTask(task);

  /// 行 / 卡片底色。不可下单行(含 ADR-103 路线 B 等子件到货的锁行, 与路线 A 前置
  /// 自制合成行同款)与回厂短交待判定单沿用红底(ADR-098)；锁的说明在状态列与悬浮上。
  Color? _rowColorOf(BuildContext context, OperationsWorkbenchTask task) {
    if (_orderBlocked(task) || _shortDelivery(task)) {
      return Theme.of(
        context,
      ).colorScheme.errorContainer.withValues(alpha: 0.42);
    }
    return null;
  }

  Future<void> _openTask(OperationsWorkbenchTask task) async {
    final preparationId = task.preparationTaskId;
    if (preparationId != null) {
      if (_openingPreparationTask != null) return;
      _openingPreparationTask = preparationId;
      try {
        final repository = ref.read(productionPlanRepositoryProvider);
        await showSubcontractPreparationProgressDialog(
          context,
          task: task,
          loadTask: () => repository.subcontractMakeTask(preparationId),
          onNotified: () => _load(page: 1),
        );
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
                : subcontractProgressStatusLabel(bucket.value) == bucket.value
                ? operationsWorkbenchStatusLabel(bucket.value)
                : subcontractProgressStatusLabel(bucket.value),
          ),
      ],
  };

  String _stageLabelOf(OperationsWorkbenchTask task) =>
      task.preparationTaskId == null
      ? _progressLabelOf(task)
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
    // 入库或下单后返回时，重新读取权威库存闸与已下单量；首次进入仍只加载一次。
    ref.onPageResume(RouteName.operationsSubcontractWorkbench, () => _load());
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
                    // 「进行中」大类挂两枚(准则 §四之七 第 1 条, 2026-09-21 追加):
                    // 黄 = 本类在跑的全量(与列表行数相等), 红 = 其中等委外动手的
                    // 财务已退回单。只挂黄的话, 退回件要点进异常小类行才看得见,
                    // 等于在大类行上蒸发。两枚刻意重叠(退回件本来就在跑), 跨色不算
                    // 双计, 别改成相减 —— 相减会让黄数对不上「进行中」列表行数。
                    // 回厂短交待判定同样是红, 但它是案件数、不是任务行数, 量纲不同,
                    // 留在异常小类行里单独喊, 不并进这一枚。
                    // 「待处理」只挂一枚红(ADR-103, 2026-09-22 用户实机纠偏「刚下单的
                    // 都是待处理」): 服务端 WAITING_ORDER 含等子件到货的路线 B 锁行, 与
                    // 路线 A 前置自制合成行同款计红; 锁只体现在行上, 不另挂黄枚。
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
          // 2026-09-22 全站表格滚动口径：上滑先收阶段/筛选行（表头随之顶到
          // 视口顶），继续滚动才滚表格内容；竖向滚动条由联动门控（外滚阶段隐藏）。
          return UtenCollapsingHeaderScrollView(
            collapsingHeader: Padding(
              padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
              child: header,
            ),
            body: Builder(
              builder: (context) {
                if (seg == null) {
                  return const UtenFilterPlaceholder(
                    message: '在上方选择阶段后开始办理',
                    description: '阶段默认不选中；终态任务请用末尾「历史记录」按时间查阅',
                  );
                }
                if (seg.history && _historyTime.isNone) {
                  return const UtenHistoryTimePlaceholder();
                }
                return _buildTable(data);
              },
            ),
          );
        }
        return _withCardActions(
          ListView(
            key: const Key('subcontract-decomposition-compact-list'),
            padding: const EdgeInsets.only(
              bottom: UtenFloatingActionGroup.scrollClearance,
            ),
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
                    stageType: _progressType(
                      task.preparationTaskId == null
                          ? task.progressStatus
                          : (task.preparationStatus ?? ''),
                    ),
                    stageTooltip: _progressTooltipOf(task),
                    urgent: _shortDelivery(task),
                    onOpenShortDelivery: _linksToShortDeliveries(task)
                        ? () => _openShortDeliveries(task)
                        : null,
                    synthetic: _isSynthetic(task),
                    cardColor: _rowColorOf(context, task),
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
      // primary:true → 表体参与「筛选行折叠 → 表格内滚」联动。
      primary: true,
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
        // 2026-09-14 用户口径（全站表格统一）：名称 / 编号 / 颜色各占一列，
        // 不再「编号 名称」拼一格、颜色拼进规格。
        MasterColumnDef(
          key: 'goods',
          sortable: true,
          label: '委外目标件名称',
          width: 200,
          value: (t) => t.isDocumentGrouped ? t.goodsSummaryLabel : t.goodsName,
        ),
        MasterColumnDef(
          key: 'goodsCode',
          sortable: true,
          label: '编号',
          width: 130,
          value: (t) => t.isDocumentGrouped ? '—' : t.goodsCode,
        ),
        MasterColumnDef(
          key: 'colorName',
          label: '颜色',
          width: 96,
          value: (t) => t.isDocumentGrouped ? '—' : t.colorName,
        ),
        MasterColumnDef(
          key: 'spec',
          sortable: true,
          label: '规格',
          width: 150,
          value: (t) => t.isDocumentGrouped ? '—' : t.spec,
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
          // 2026-09-15：前置自制合成行（待生产）同样显示真实待通知量
          // （required − notified），不再藏成「—」——委外的需求量与待下单量
          // 两列口径与其余行一致。
          value: (t) => t.isDocumentGrouped
              ? '${t.openLineCount} 行'
              : '${_number(t.openQty)} ${t.unitName}'.trim(),
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
          label: '状态',
          width: 190,
          value: (t) => _stageLabelOf(t),
          cellBuilderHandlesSemantics: true,
          cellBuilder: (context, t) => _ProgressStatusCell(
            label: _stageLabelOf(t),
            type: _progressType(
              t.preparationTaskId == null
                  ? t.progressStatus
                  : (t.preparationStatus ?? ''),
            ),
            urgent: _shortDelivery(t),
            tooltip: _progressTooltipOf(t),
            onTap: _linksToShortDeliveries(t)
                ? () => _openShortDeliveries(t)
                : null,
          ),
        ),
        MasterColumnDef(
          key: 'source',
          label: '只读申请',
          width: 180,
          value: (t) => _isSynthetic(t)
              ? '前置生产中'
              : t.waitingComponentStock
              ? _waitingComponentSourceText
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
      // 路线 B 锁行黄底 (ADR-103)；待处理段下其余不能下单的行、进行中段下回厂
      // 短交待判定的订货单：整行标红 (ADR-098)。
      rowColor: (task) => _rowColorOf(context, task),
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
    required this.stageType,
    required this.stageTooltip,
    required this.urgent,
    required this.onOpenShortDelivery,
    required this.synthetic,
    required this.cardColor,
    required this.selected,
    required this.selectable,
    required this.onSelected,
    required this.onTap,
    required this.onOpenSource,
  });

  final OperationsWorkbenchTask task;
  final String stageLabel;
  final UtenStatusBadgeType stageType;
  final String? stageTooltip;
  final bool urgent;
  final VoidCallback? onOpenShortDelivery;
  final bool synthetic;

  /// 阻断底色 (黄 = 路线 B 等子件到货, 红 = 不可下单 / 短交待判定)；null = 正常。
  final Color? cardColor;
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
        color:
            cardColor ?? (selected ? theme.colorScheme.primaryContainer : null),
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
                  _ProgressStatusCell(
                    label: stageLabel,
                    type: task.hasException && !urgent
                        ? UtenStatusBadgeType.danger
                        : stageType,
                    urgent: urgent,
                    tooltip: stageTooltip,
                    onTap: onOpenShortDelivery,
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
                          : task.waitingComponentStock
                          ? _SubcontractDecompositionPageState
                                ._waitingComponentSourceText
                          : task.actionDocumentRestricted
                          ? '关联申请受权限保护'
                          : task.actionDocument?.label ?? '缺少委外申请来源',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (onOpenShortDelivery != null)
                    TextButton.icon(
                      onPressed: onOpenShortDelivery,
                      icon: const Icon(Icons.rule_folder_outlined, size: 18),
                      label: const Text('去判定短交'),
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

/// 状态药丸（ADR-098）：颜色按状态拉开；回厂短交待判定加「紧急」标签；
/// 有判定页可去时整个药丸可点（工具提示「点击去判定」）；不可点的行可带一句
/// 悬浮说明 (ADR-103 路线 B 锁 / 解锁行)。
class _ProgressStatusCell extends StatelessWidget {
  const _ProgressStatusCell({
    required this.label,
    required this.type,
    required this.urgent,
    this.tooltip,
    this.onTap,
  });

  final String label;
  final UtenStatusBadgeType type;
  final bool urgent;

  /// 不可点时的悬浮说明；null = 无提示。可点时固定「点击去判定」。
  final String? tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final badge = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (urgent) ...[
          const UtenStatusBadge(
            label: '紧急',
            type: UtenStatusBadgeType.danger,
            icon: Icons.priority_high_rounded,
            size: UtenStatusBadgeSize.small,
          ),
          const SizedBox(width: UtenSpacing.s4),
        ],
        UtenStatusBadge(
          label: label,
          type: type,
          size: UtenStatusBadgeSize.small,
        ),
      ],
    );
    if (onTap == null) {
      final hint = tooltip;
      if (hint == null) return Semantics(label: label, child: badge);
      return Tooltip(
        message: hint,
        child: Semantics(label: '$label，$hint', child: badge),
      );
    }
    return Tooltip(
      message: '点击去判定',
      child: Semantics(
        button: true,
        label: '$label，点击去判定',
        child: InkWell(
          onTap: onTap,
          borderRadius: UtenRadius.pillAll,
          child: badge,
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
