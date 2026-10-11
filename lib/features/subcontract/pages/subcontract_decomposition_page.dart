// 委外任务中心（/operations/workbench/subcontract）。
//
// 分类：草稿 / 待处理 / 进行中 / 历史记录（ADR-171 修订二，2026-10-09）。
// · 待处理 = 拍平的一张表，不再分「委外申请 / 领料」子分类行，直接显示所有
//   等本部门动手的行：
//   - 委外申请行：已下达、仍有未下单量的委外申请行(工作台投影分页)；双击看申请
//     摘要弹窗(关键数量 + 数量归属；锁行顶部红框说明为什么不能下单)；多选 +
//     右下角悬浮组「生成委外订货单」批量带入订货单编辑页。
//     委外件缺 BOM 的申请行显示「缺 BOM·已通知研发」(红，ADR-143 §二.3、ADR-169
//     锁死不能下单=深红)、不能勾选下单，勾选位显示锁图标与原因；点状态「通知研发
//     完善」可再提醒研发。ADR-156(委外价格每天不同，物料齐了才下单)：直属物料一套
//     都不够的申请行显示「等物料齐套」并锁住；够做一部分显示「可部分下单」，
//     「可下单」列给出服务端算好的这次可下单数量。点申请行状态看「齐套情况」弹窗。
//   - 领料行(钉在表格顶部，随页常驻)：已获财务批准、领料计划未结束、仍未领满的
//     委外订货明细(委外任务，自有数据源 GET /subcontract/draw-tasks)。「领料」在
//     这里只是一个状态，不是子分类：可领(红，等本部门动手) / 已提交·待仓库发
//     (黄，在跑不用动手) / 等计划安排 / 等待物料。行只有服务端标 canDraw 且账号
//     canSubmitDraw 时可勾选，多选后右下角「批量领料(n)」进入领料页；点状态
//     「可领」直达领料页(只带这一行)；点行看任务详情(物料表 + 撤回未发领料 /
//     结束领料，动作由服务端 allowedActions 决定)。
//   「待处理」分类红数 = 申请待下单行数 + 可领行数(两类不同对象相加，与模块入口
//   角标同数)；黄数 = 已提交领料、等仓库发的行数(领料中)。
// · 进行中 = 领完料(或本就无需领料)的委外订货单——V834 投影里领料未结束的整单
//   是 DRAW_OPEN 档，不在进行中三档里，只以「待处理」领料行的形态可见；状态列按
//   各明细聚合(服务端 display_stage)；「可领料」点击跳到「待处理」并按订货单定位，
//   短交三态点击去判定页。
// · 历史记录 = 终态，按时间门控查看。
//
// 统一「分类分段」范式：UtenFilterToolbar 阶段行 + 异常小类行，默认都不选，
// 内容区显示引导占位不发请求；进页面只拉一次 size=1 概览取阶段/异常计数徽章，
// 另拉一次领料计数(红/黄)。
// 深链 ?segment=draw(&orderItemId= / &orderId=) 直落「待处理」并按通知里的
// 委外任务 / 订货单定位；?segment=pending(&keyword=申请号) 直落「待处理」并按
// 申请号搜索(可下单通知)。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../shared/providers/draft_counts_provider.dart';
import '../../../shared/drafts/form_draft_category.dart';
import '../widgets/subcontract_draft_task_category.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/data_display/uten_status_cell_color.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_segment_badge_label.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/layout/uten_history_time_filter.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/formatters/quantity_display.dart';
import '../../../shared/presentation/workflow_field_guidance.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../basic_data/models/master_facet.dart';
import '../../operations_workbench/models/operations_workbench.dart';
import '../../operations_workbench/repositories/operations_workbench_repository.dart';
import '../../../shared/models/subcontract_short_delivery.dart'
    show subcontractProgressStatusLabel;
import '../models/subcontract_draw.dart';
import '../repositories/subcontract_draw_repository.dart';
import '../repositories/subcontract_kit_repository.dart';
import '../widgets/subcontract_application_kit_dialog.dart';
import '../widgets/subcontract_application_detail_dialog.dart';
import '../widgets/subcontract_draw_status.dart';
import '../widgets/subcontract_draw_task_detail_dialog.dart';

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

/// 进行中状态格的可点动作(去判定短交 / 去领料)。
typedef _StatusAction = ({String hint, String buttonLabel, VoidCallback onTap});

class SubcontractDecompositionPage extends ConsumerStatefulWidget {
  const SubcontractDecompositionPage({
    super.key,
    this.repository,
    this.drawRepository,
    this.bomGapGateway,
    this.kitGateway,
    this.initialSegment,
    this.initialOrderItemId,
    this.initialOrderId,
    this.initialKeyword,
  });

  final OperationsWorkbenchGateway? repository;

  /// 「待处理」拍平表的领料行数据源；测试注入，默认取
  /// [subcontractDrawRepositoryProvider]。
  final SubcontractDrawGateway? drawRepository;

  /// 缺 BOM 申请行「通知研发完善」；测试注入，默认取
  /// [operationsWorkbenchRepositoryProvider]。
  final SubcontractBomGapGateway? bomGapGateway;

  /// 申请行「齐套情况」弹窗(ADR-156)；测试注入，默认取 [subcontractKitRepositoryProvider]。
  final SubcontractKitGateway? kitGateway;

  /// 深链分段：'draw' = 直落「待处理」并按领料任务定位，'pending' = 直落
  /// 「待处理」(其余值忽略，保持默认不选)。
  final String? initialSegment;

  /// 深链定位：只看这一条委外任务(可领料通知)。
  final String? initialOrderItemId;

  /// 深链定位：只看这张订货单的委外任务。
  final String? initialOrderId;

  /// 深链搜索词(与 'pending' 同用)：可下单通知带委外申请号，进页即按它搜索。
  final String? initialKeyword;

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

  /// 当前选中阶段分类；null = 未选择引导态（内容不加载）。
  _DecompositionSeg? _seg;
  static const _draftStage = '__DRAFTS__';
  static const _waitingOrderStage = 'WAITING_ORDER';
  static const _inProgressStage = 'IN_PROGRESS';
  static const _financeRejectedStatus = 'FINANCE_REJECTED';

  /// 异常小类；null = 未选择（不附加过滤）。
  String? _exception;

  /// 历史记录段的时间门控值；none = 尚未选择（历史段下同样不发请求）。
  UtenHistoryTimeValue _historyTime = const UtenHistoryTimeValue.all();

  final Set<String> _selectedIds = <String>{};

  // —— 「待处理」领料行(ADR-171 修订二：拍平进待处理表)：独立数据源、独立选择集 ——
  SubcontractDrawTaskList? _drawData;
  bool _drawLoading = false;
  String? _drawError;
  int _drawRequestId = 0;
  int _drawCountRequestId = 0;

  /// 领料红数(可领行数)；null = 未知(加载中/失败，不伪装成 0)。
  int? _drawCount;

  /// 领料黄数(已提交、等仓库发的行数)；null = 未知。服务端拒绝读取委外订货
  /// (无订货查看权限)时红黄一起隐藏，拍平表只剩申请行。
  int? _submittedCount;
  bool _drawVisible = true;

  String? _drawOrderId;
  String? _drawOrderLabel;
  String? _drawOrderItemId;
  final Set<String> _selectedDrawIds = <String>{};
  bool _drawNavigating = false;

  /// 正在「通知研发完善」的申请行(防连点)；null = 没有在途请求。
  String? _forwardingBomTaskId;

  /// 当前是否「待处理」视图——领料行、批量领料只在这一视图提供。
  bool get _pendingSeg => _seg?.code == _waitingOrderStage;

  /// 勾选与「生成委外订货单」只属于「待处理」段(2026-10-08 口径，与采购任务中心
  /// 同款收口)：进行中/历史段的行都已下单，提供勾选只会制造永远点不动的批量按钮。
  bool get _orderingSeg => _seg?.code == _waitingOrderStage;

  /// 状态列颜色（ADR-169 逐页档位锚定，刻意拉开不用相近色）：
  /// 绿=待处理可下单 / 可领料 / 已完成（「就绪可动手」与终态各自分段独立取绿），
  /// 紫=可部分下单（部分就绪），
  /// 红=等物料齐套 / 缺 BOM（锁死不能下单）、财务驳回、回厂短交待判定、
  /// 等待物料（料没到不能领）——不能执行不是等待，
  /// 黄=等财务审核 / 已回厂待入库（等仓库入库，回厂域内无其它黄档），
  /// 青=待仓库发料（第二种「等别人」，与等财务的黄拉开），
  /// 蓝=财务已通过（已批流转中），青绿=委外商加工中（他方执行中），
  /// 橙=部分回厂（风险中间态），品红=分批等待（分类强调），灰=容差内待结案。
  static UtenStatusBadgeType _progressType(String code) => switch (code) {
    'WAITING_ORDER' || 'DRAWABLE' || 'COMPLETED' => UtenStatusBadgeType.success,
    'KIT_PARTIAL' => UtenStatusBadgeType.violet,
    'WAITING_KIT' ||
    'BOM_MISSING' ||
    'FINANCE_REJECTED' ||
    'SHORT_DELIVERY' ||
    'WAITING_MATERIAL' => UtenStatusBadgeType.danger,
    'ORDER_PENDING_APPROVAL' ||
    'RECEIVED_PENDING_STOCK' => UtenStatusBadgeType.warning,
    'DRAW_SUBMITTED' => UtenStatusBadgeType.sky,
    'FINANCE_APPROVED' => UtenStatusBadgeType.info,
    'AT_SUPPLIER' => UtenStatusBadgeType.accent,
    'PARTIAL_RECEIVED' => UtenStatusBadgeType.orange,
    'WAITING_MORE_BATCH' => UtenStatusBadgeType.fuchsia,
    // 容差内待结案：不急，灰色中性；点状态同样可去判定页。
    'TOLERANT_SHORT' => UtenStatusBadgeType.neutral,
    _ => UtenStatusBadgeType.neutral,
  };

  bool _shortDelivery(OperationsWorkbenchTask task) =>
      task.progressStatus == 'SHORT_DELIVERY';

  /// 状态列文案：委外订货单按展示阶段翻译，未知码回落既有阶段文案；
  /// 缺 BOM 的申请行带上研发任务单号。
  String _progressLabelOf(OperationsWorkbenchTask task) {
    final code = task.progressStatus;
    final label = subcontractProgressStatusLabel(code);
    if (task.isBomMissing && task.rdTaskNo != null) {
      return '$label(${task.rdTaskNo})';
    }
    return label == code ? task.statusLabel : label;
  }

  /// 回厂短交待判定 / 分批等待中 / 容差内待结案：点状态直达判定页（只看这张单）；
  /// 可领料：点状态跳到「待处理」并按这张订货单定位领料行；
  /// 缺 BOM：点状态「通知研发完善」(研发任务被取消而 BOM 仍缺时重新提醒)；
  /// 待处理的委外申请行(含等物料齐套的锁行)：点状态看「齐套情况」(ADR-156)。
  _StatusAction? _statusActionOf(OperationsWorkbenchTask task) {
    if (task.isBomMissing) {
      if (!_hasDecomposePermissions || _bomItemIdsOf(task).isEmpty) return null;
      return (
        hint: _forwardingBomTaskId == task.id ? '正在通知研发' : '点击通知研发完善 BOM',
        buttonLabel: '通知研发完善',
        onTap: () => _forwardBom(task),
      );
    }
    if (_canViewKit(task)) {
      return (
        hint: task.isWaitingKit
            ? '$subcontractWaitingKitHint；点击看齐套情况'
            : '点击看齐套情况',
        buttonLabel: '齐套情况',
        onTap: () => _openKit(task),
      );
    }
    final orderId = task.actionDocument?.id;
    if (orderId == null || orderId.isEmpty) return null;
    if (const {
      'SHORT_DELIVERY',
      'WAITING_MORE_BATCH',
      'TOLERANT_SHORT',
    }.contains(task.progressStatus)) {
      return (
        hint: '点击去判定',
        buttonLabel: '去判定短交',
        onTap: () => goFrom(
          context,
          RouteName.subcontractShortDeliveriesWith(orderId: orderId),
        ),
      );
    }
    if (task.progressStatus == 'DRAWABLE' && _drawVisible) {
      return (
        hint: '点击去领料',
        buttonLabel: '去领料',
        onTap: () => _openDrawSegmentForOrder(task),
      );
    }
    return null;
  }

  OperationsWorkbenchGateway get _repository =>
      widget.repository ?? ref.read(operationsWorkbenchRepositoryProvider);

  SubcontractDrawGateway get _drawRepository =>
      widget.drawRepository ?? ref.read(subcontractDrawRepositoryProvider);

  SubcontractBomGapGateway get _bomGapGateway =>
      widget.bomGapGateway ?? ref.read(operationsWorkbenchRepositoryProvider);

  SubcontractKitGateway get _kitGateway =>
      widget.kitGateway ?? ref.read(subcontractKitRepositoryProvider);

  /// 「齐套情况」只给待处理的委外申请行(含锁行)；缺 BOM 的行没有物料可算，
  /// 走「通知研发完善」。申请受权限保护(服务端不下发 actionDocument)时不给入口。
  bool _canViewKit(OperationsWorkbenchTask task) =>
      task.taskStatus == _waitingOrderStage &&
      !task.isBomMissing &&
      task.actionDocument?.isIssuedSubcontractApplication == true &&
      _applicationItemIdsOf(task).isNotEmpty;

  /// 齐套情况弹窗(ADR-156)：逐条申请明细看剩余未下单 / 够做套数 / 可下单与直属物料。
  void _openKit(OperationsWorkbenchTask task) {
    showSubcontractApplicationKitDialog(
      context,
      gateway: _kitGateway,
      applicationItemIds: _applicationItemIdsOf(task),
      title: task.actionDocument?.number,
    );
  }

  /// 缺 BOM 申请行要通知研发的申请明细：服务端点名的缺 BOM 明细优先，
  /// 未下发时用整行明细(已有 BOM 的明细服务端不做任何事)。
  List<String> _bomItemIdsOf(OperationsWorkbenchTask task) =>
      task.bomMissingItemIds.isNotEmpty
      ? task.bomMissingItemIds
      : _applicationItemIdsOf(task);

  /// 「通知研发完善」(ADR-143 §二.3)：给工程研发部建(或复用)「完善 BOM」任务并把
  /// 本人加入等待名单；研发保存 BOM 后申请行自动恢复「待处理」可下单。
  Future<void> _forwardBom(OperationsWorkbenchTask task) async {
    if (_forwardingBomTaskId != null) return;
    final ids = _bomItemIdsOf(task);
    if (ids.isEmpty) return;
    setState(() => _forwardingBomTaskId = task.id);
    try {
      final taskNos = <String>{};
      for (final id in ids) {
        final result = await _bomGapGateway.forwardBom(id);
        final taskNo = result.taskNo?.trim() ?? '';
        if (taskNo.isNotEmpty) taskNos.add(taskNo);
      }
      if (!mounted) return;
      context.appSuccess(
        taskNos.isEmpty
            ? '已通知研发完善 BOM，研发保存后这条申请会自动恢复可下单'
            : '已通知研发完善 BOM(${taskNos.join('、')})，研发保存后这条申请会自动恢复可下单',
      );
      _load();
    } catch (error) {
      if (mounted) context.appApiError(error, fallback: '通知研发失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _forwardingBomTaskId = null);
    }
  }

  /// 委外工作台列表(「待处理」申请行 / 进行中 / 历史)是否要拉正文；草稿分段与
  /// 领料行各有数据源(领料行钉在「待处理」表顶部，不占工作台分页)。
  bool get _shouldLoad {
    final seg = _seg;
    if (seg == null) return false;
    if (seg.history && _historyTime.isNone) return false;
    return true;
  }

  @override
  void initState() {
    super.initState();
    final deepLinked = _applyRoute(
      widget.initialSegment,
      widget.initialOrderItemId,
      widget.initialOrderId,
      widget.initialKeyword,
    );
    // 默认不选分类：内容不加载；仅拉一次 size=1 概览获取阶段/异常计数徽章，
    // 另拉一次领料计数(红/黄)。深链直落「待处理」时同时拉申请列表与领料行。
    Future<void>.microtask(() {
      _load(page: 1);
      _loadDrawCount();
      if (deepLinked) _loadDraw();
    });
  }

  @override
  void didUpdateWidget(covariant SubcontractDecompositionPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialSegment == widget.initialSegment &&
        oldWidget.initialOrderItemId == widget.initialOrderItemId &&
        oldWidget.initialOrderId == widget.initialOrderId &&
        oldWidget.initialKeyword == widget.initialKeyword) {
      return;
    }
    final deepLinked = _applyRoute(
      widget.initialSegment,
      widget.initialOrderItemId,
      widget.initialOrderId,
      widget.initialKeyword,
    );
    if (deepLinked) {
      Future<void>.microtask(() {
        _load(page: 1);
        _loadDraw();
      });
    }
  }

  /// 深链 ?segment=draw 直落「待处理」并按通知里的委外任务 / 订货单定位；
  /// ?segment=pending 直落「待处理」，带 keyword(委外申请号)时预填搜索
  /// (ADR-156 可下单通知)。返回 true = 需要重拉申请列表(调用方负责)。
  bool _applyRoute(
    String? segment,
    String? orderItemId,
    String? orderId,
    String? keyword,
  ) {
    final target = segment?.trim().toLowerCase();
    if (target != 'pending' && target != 'draw') return false;
    _seg = const _DecompositionSeg.stage(_waitingOrderStage);
    _exception = null;
    _page = 1;
    _columnFilters.clear();
    _selectedIds.clear();
    final normalized = keyword?.trim() ?? '';
    if (normalized.isNotEmpty) _keyword = normalized;
    // 两种深链都从确定的状态看起：定位筛选清空，不带上一段会话的残留。
    _drawOrderItemId =
        target == 'draw' && orderItemId?.trim().isNotEmpty == true
        ? orderItemId!.trim()
        : null;
    _drawOrderId = target == 'draw' && orderId?.trim().isNotEmpty == true
        ? orderId!.trim()
        : null;
    _drawOrderLabel = null;
    return true;
  }

  Future<void> _load({int? page, int size = 50}) async {
    if (!mounted) return;
    if (_seg?.code == _draftStage) return;
    final requestId = ++_requestId;
    final seg = _seg;
    final listing = _shouldLoad;
    final range = seg?.history == true ? _historyTime.range : null;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final next = await _repository.load(
        department: OperationsWorkbenchDepartment.subcontract,
        page: page ?? _page,
        // 未选分类时只拉 1 条：仅为取 summary 阶段/异常计数。
        size: listing ? size : 1,
        keyword: _keyword,
        status: listing && seg != null && !seg.history ? seg.code : null,
        exception: listing && seg != null && !seg.history ? _exception : null,
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

  /// 领料计数(红=可领、黄=已提交待仓库发)。无订货查看权限时服务端拒绝 →
  /// 红黄一起隐藏，拍平表只剩申请行。
  Future<void> _loadDrawCount() async {
    if (!mounted) return;
    final requestId = ++_drawCountRequestId;
    try {
      final counts = await _drawRepository.drawCounts();
      if (!mounted || requestId != _drawCountRequestId) return;
      setState(() {
        _drawCount = counts.drawable;
        _submittedCount = counts.submitted;
        _drawVisible = true;
      });
    } on ApiException catch (error) {
      if (!mounted || requestId != _drawCountRequestId) return;
      final forbidden = error.httpStatus == 403 || error.code == 'FORBIDDEN';
      setState(() {
        _drawCount = null;
        _submittedCount = null;
        if (forbidden) {
          _drawVisible = false;
          _selectedDrawIds.clear();
        }
      });
    } catch (_) {
      if (!mounted || requestId != _drawCountRequestId) return;
      setState(() {
        _drawCount = null;
        _submittedCount = null;
      });
    }
  }

  /// 领料行(「待处理」拍平表顶部)：一次拉全(服务端上限 200)，不走表格分页。
  Future<void> _loadDraw() async {
    if (!mounted) return;
    final requestId = ++_drawRequestId;
    setState(() {
      _drawLoading = true;
      _drawError = null;
    });
    try {
      final next = await _drawRepository.list(
        size: SubcontractDrawRepository.listLimit,
        keyword: _keyword,
        orderId: _drawOrderId,
        orderItemIds: _drawOrderItemId == null ? const [] : [_drawOrderItemId!],
      );
      if (!mounted || requestId != _drawRequestId) return;
      final selectable = next.canSubmitDraw
          ? next.page.items
                .where((row) => row.canDraw)
                .map((row) => row.orderItemId)
                .toSet()
          : const <String>{};
      setState(() {
        _drawData = next;
        _selectedDrawIds.removeWhere((id) => !selectable.contains(id));
        _drawLoading = false;
      });
    } catch (error) {
      if (!mounted || requestId != _drawRequestId) return;
      // 无订货查看权限(403)与计数口径一致：领料行整体静默隐藏，不向用户报错——
      // 拍平表照常显示申请行。
      final forbidden =
          error is ApiException &&
          (error.httpStatus == 403 || error.code == 'FORBIDDEN');
      setState(() {
        _drawLoading = false;
        if (forbidden) {
          _drawVisible = false;
          _selectedDrawIds.clear();
          _drawError = null;
        } else {
          _drawError = error is ApiException
              ? error.message
              : '委外领料任务加载失败，请稍后重试';
        }
      });
    }
  }

  void _refreshDraw() {
    _loadDraw();
    _loadDrawCount();
  }

  void _refreshAll() {
    _load(page: 1);
    _loadDrawCount();
    if (_pendingSeg) _loadDraw();
  }

  void _selectSeg(_DecompositionSeg seg) {
    if (seg == _seg) return;
    setState(() {
      _seg = seg;
      _exception = null;
      _page = 1;
      if (!seg.history) _historyTime = const UtenHistoryTimeValue.all();
      _selectedIds.clear();
      _columnFilters.clear();
    });
    // 「待处理」= 申请行 + 领料行两个数据源一起拉。
    if (seg.code == _waitingOrderStage) {
      _load(page: 1);
      _loadDraw();
      return;
    }
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
    setState(() => _keyword = normalized);
    _load(page: 1);
    // 领料行有自己的关键字匹配面(订货单号/委外商/委外件)，在「待处理」里一起搜。
    if (_pendingSeg) _loadDraw();
  }

  /// 进行中「可领料」：跳到「待处理」，领料行只看这张订货单的委外任务。
  void _openDrawSegmentForOrder(OperationsWorkbenchTask task) {
    final orderId = task.actionDocument?.id;
    if (orderId == null || orderId.isEmpty) return;
    setState(() {
      _seg = const _DecompositionSeg.stage(_waitingOrderStage);
      _exception = null;
      _selectedIds.clear();
      _columnFilters.clear();
      _drawOrderId = orderId;
      _drawOrderItemId = null;
      final number = task.actionDocument?.number.trim() ?? '';
      _drawOrderLabel = number.isEmpty ? null : number;
    });
    _load(page: 1);
    _loadDraw();
    _loadDrawCount();
  }

  void _clearDrawScope() {
    setState(() {
      _drawOrderId = null;
      _drawOrderItemId = null;
      _drawOrderLabel = null;
    });
    _loadDraw();
  }

  /// 进入领料页(一次最多 50 个委外任务)；提交成功返回后清掉已领的勾选并重拉。
  Future<void> _openDrawRequest(List<String> orderItemIds) async {
    if (orderItemIds.isEmpty || _drawNavigating) return;
    if (orderItemIds.length > SubcontractDrawRepository.batchLimit) {
      context.appWarning(
        '一次最多领 ${SubcontractDrawRepository.batchLimit} 个委外任务，请分批勾选',
      );
      return;
    }
    setState(() => _drawNavigating = true);
    try {
      final submitted = await context.push<bool>(
        RouteName.operationsSubcontractDrawRequestFor(orderItemIds),
      );
      if (!mounted) return;
      if (submitted == true) {
        setState(() => _selectedDrawIds.removeAll(orderItemIds));
      }
      _refreshDraw();
    } finally {
      if (mounted) setState(() => _drawNavigating = false);
    }
  }

  Future<void> _openDrawTask(SubcontractDrawTaskRow row) async {
    final drawId = await showSubcontractDrawTaskDetailDialog(
      context,
      gateway: _drawRepository,
      orderItemId: row.orderItemId,
      canSubmitDraw: _drawData?.canSubmitDraw ?? false,
      onChanged: _refreshDraw,
    );
    if (!mounted || drawId == null) return;
    await _openDrawRequest([drawId]);
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
      return '所选任务找不到对应的委外申请明细，请刷新后重试';
    }
    if (selected.any((task) => task.taskStatus != _waitingOrderStage)) {
      return '只能选择「待处理」的任务';
    }
    if (selected.any(
      (task) =>
          task.actionDocument!.docType.toUpperCase() !=
              'SUBCONTRACT_APPLICATION' &&
          task.actionDocument!.docType.toUpperCase() != 'APPLICATION',
    )) {
      return '所选任务已进入订货或回厂阶段，不能再次下单';
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

  /// 服务端 canCreateOrder 优先；未下发时按申请事实判断。缺 BOM、等物料齐套
  /// (ADR-156 锁住)的申请行一律不可下单。
  bool _canOrderTask(OperationsWorkbenchTask task) =>
      !task.isBomMissing &&
      !task.isWaitingKit &&
      (task.canCreateOrder ??
          (task.taskStatus == _waitingOrderStage &&
              task.actionDocument?.isIssuedSubcontractApplication == true &&
              _applicationItemIdsOf(task).isNotEmpty &&
              (task.openQty > 0 || task.openLineCount > 0)));

  void _openTask(OperationsWorkbenchTask task) {
    if (task.taskStatus == _waitingOrderStage) {
      showSubcontractApplicationDetailDialog(
        context,
        task: task,
        locked: !_canOrderTask(task),
      );
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
            label: subcontractProgressStatusLabel(bucket.value) == bucket.value
                ? operationsWorkbenchStatusLabel(bucket.value)
                : subcontractProgressStatusLabel(bucket.value),
          ),
      ],
  };

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

  /// 「待处理·领料」子视图的批量领料：按表格当前顺序带入已勾选的委外任务。
  Widget _drawBatchButton() {
    final rows = _drawData?.page.items ?? const <SubcontractDrawTaskRow>[];
    final ids = [
      for (final row in rows)
        if (_selectedDrawIds.contains(row.orderItemId)) row.orderItemId,
    ];
    final issue = ids.isEmpty
        ? '请先勾选可领料的委外任务'
        : _drawNavigating
        ? '正在打开领料页'
        : null;
    return UtenButton(
      key: const Key('subcontract-draw-batch'),
      size: UtenButtonSize.large,
      type: UtenButtonType.danger,
      icon: Icons.move_to_inbox_rounded,
      onPressed: issue == null ? () => _openDrawRequest(ids) : null,
      onDisabledTap: issue == null ? null : () => context.appWarning(issue),
      child: Text('批量领料(${ids.length})'),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 入库或下单后返回时，重新读取权威事实；首次进入仍只加载一次。
    ref.onPageResume(RouteName.operationsSubcontractWorkbench, () {
      _load();
      _loadDrawCount();
      if (_pendingSeg) _loadDraw();
    });
    return Scaffold(
      appBar: UtenAppBar(
        title: '委外任务中心',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.subcontract),
        ),
        actions: [
          IconButton(
            tooltip: '刷新委外任务',
            onPressed: (_pendingSeg && (_drawLoading || _loading)) || _loading
                ? null
                : _refreshAll,
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

  /// 「待处理」红数 = 申请待下单行数 + 可领行数(两类都等本部门动手，与模块入口
  /// 角标同数)；两者都未知才算未知(加载中)。
  int? _pendingCount(Map<String, int> statusCounts) {
    final applications = statusCounts[_waitingOrderStage];
    final drawable = _drawVisible ? _drawCount : null;
    if (applications == null && drawable == null) return null;
    return (applications ?? 0) + (drawable ?? 0);
  }

  Widget _buildStageToolbar(Map<String, int> statusCounts) {
    final seg = _seg;
    return UtenFilterToolbar<_DecompositionSeg>(
      segmentsKey: const Key('subcontract-decomposition-stages'),
      segments: [
        UtenFilterSegment(
          value: const _DecompositionSeg.stage(_draftStage),
          label: '草稿',
          count:
              ref.watch(draftCountsProvider).sumOf(const [
                DraftDocKind.subcontractOrder,
                DraftDocKind.subcontractReturn,
                DraftDocKind.subcontractMaterialReturn,
                DraftDocKind.subcontractWaste,
              ]) +
              ref.watch(
                formDraftCategoryCountProvider(
                  const FormDraftCategoryScope(
                    module: BadgeModule.subcontract,
                    excludeKinds: {
                      'subcontractOrder',
                      'subcontractReturn',
                      'subcontractMaterialReturn',
                      'subcontractWaste',
                    },
                  ),
                ),
              ),
          countForm: UtenSegmentCountForm.actionable,
        ),
        // 「待处理」两枚(准则 §四之七 第 1 条，ADR-171 修订二拍平)：红 = 申请待下单
        // 行数 + 可领行数(两类不同对象相加不算双计，都在这张表里)；黄 = 已提交领料、
        // 等仓库发的行数(领料中，球在仓库手上但活还在跑)。
        UtenFilterSegment(
          value: const _DecompositionSeg.stage(_waitingOrderStage),
          label: '待处理',
          count: _pendingCount(statusCounts),
          countForm: UtenSegmentCountForm.actionable,
          inProgressCount: _drawVisible ? _submittedCount : null,
        ),
        // 「进行中」大类挂两枚(准则 §四之七 第 1 条)：黄 = 本类在跑的全量(与列表行数
        // 相等)，红 = 其中等委外动手的财务已退回单。两枚刻意重叠(退回件本来就在跑)，
        // 跨色不算双计，别改成相减。回厂短交待判定是案件数、不是任务行数，量纲不同，
        // 留在异常小类行里单独喊。
        UtenFilterSegment(
          value: const _DecompositionSeg.stage(_inProgressStage),
          label: '进行中',
          count: statusCounts[_financeRejectedStatus],
          countForm: UtenSegmentCountForm.actionable,
          inProgressCount: statusCounts[_inProgressStage],
        ),
        const UtenFilterSegment(
          value: _DecompositionSeg.history(),
          label: '历史记录',
        ),
      ],
      selected: seg == null ? const {} : {seg},
      onSelectionChanged: _selectSeg,
      searchHint: seg?.code == _draftStage
          ? '搜索草稿类别、单据号、往来单位或备注'
          : _pendingSeg
          ? '搜索计划号、申请号、订货单号、委外商或货品'
          : '搜索计划号、申请号、货品编码或名称',
      initialSearchValue: _keyword,
      onSearchInputChanged: (_) {
        _requestId++;
        _drawRequestId++;
      },
      onSearchChanged: _applyKeyword,
    );
  }

  Widget _buildBody() {
    if (_seg?.code == _draftStage) {
      return SubcontractDraftTaskCategory(
        search: _keyword,
        externalHeader: _buildStageToolbar(
          _data?.summary.statusCounts ?? const {},
        ),
      );
    }
    if (_data == null && _loading) {
      return _withInitialStages(
        Center(
          child: Semantics(
            label: '正在加载委外任务',
            child: const CircularProgressIndicator(),
          ),
        ),
      );
    }
    if (_error != null) {
      return _withInitialStages(
        UtenEmpty.error(
          message: '无法加载委外任务',
          description: _error,
          actionLabel: '重试',
          onAction: () => _load(),
        ),
      );
    }
    final data = _data;
    if (data == null) {
      return _withInitialStages(
        UtenEmpty.error(actionLabel: '重试', onAction: () => _load()),
      );
    }

    // 大小屏同一张表（2026-10-09 用户口径：窄屏横向滚动，窄屏卡片列表退役，
    // 不再单独维护两套渲染）。
    final seg = _seg;
    final statusCounts = data.summary.statusCounts;
    final exceptionCounts = data.summary.exceptionCounts;
    final exceptionOptions = data.exceptionOptions;
    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 分类行：真实阶段（无「全部阶段」；终态归历史记录）+ 末尾历史记录。
        _buildStageToolbar(statusCounts),
        // 「待处理」的领料定位芯片(可领料通知 / 进行中「去领料」深链)；
        // 领料计数被 403 隐藏时不出现。
        if (seg?.code == _waitingOrderStage && _drawVisible && _drawScoped) ...[
          const SizedBox(height: UtenSpacing.s8),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: InputChip(
              key: const Key('subcontract-draw-scope'),
              avatar: const Icon(Icons.filter_alt_outlined, size: 18),
              label: Text(
                _drawOrderItemId != null
                    ? '领料行只看通知里的这条委外任务'
                    : _drawOrderLabel != null
                    ? '领料行只看订货单 $_drawOrderLabel 的委外任务'
                    : '领料行只看所选订货单的委外任务',
              ),
              deleteButtonTooltipMessage: '看全部委外任务',
              onDeleted: _clearDrawScope,
            ),
          ),
        ],
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

  Widget _withInitialStages(Widget body) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _buildStageToolbar(_data?.summary.statusCounts ?? const {}),
      Expanded(child: body),
    ],
  );

  Widget _buildTable(OperationsWorkbenchData data) {
    // 「待处理」= 拍平的一张表(ADR-171 修订二)：领料行钉顶(自有数据源一次拉全) +
    // 委外申请行(工作台投影服务端分页)，不再分「委外申请 / 领料」子分类。
    if (_pendingSeg) return _buildPendingTable(data);
    // 勾选列只属于「待处理」段(2026-10-08 口径)：进行中/历史的行都已下单，
    // 摆一列点不动的勾选框只会让人以为按钮坏了。
    final canOrder =
        _orderingSeg &&
        _hasDecomposePermissions &&
        data.capabilities.canCreateSubcontractOrder;
    return MasterDataTableView<OperationsWorkbenchTask>(
      tableKey:
          'features.subcontract.pages.subcontract_decomposition_page.SubcontractDecompositionPageState._buildTable.1',
      key: const Key('subcontract-decomposition-table'),
      // primary:true → 表体参与「筛选行折叠 → 表格内滚」联动。
      primary: true,
      columns: [
        MasterColumnDef(
          key: 'status',
          sortable: true,
          label: '状态',
          width: 72,
          value: _progressLabelOf,
          cellBuilderHandlesSemantics: true,
          // 2026-09-27 用户口径「格内胶囊改单元格背景色」：状态分类色铺整格，
          // 格内只剩文字与「紧急」前缀（_ProgressStatusCell 保留点击/悬浮行为）。
          cellColor: (context, t) =>
              utenStatusBadgeCellColor(_progressType(t.progressStatus)),
          cellBuilder: (context, t) => _ProgressStatusCell(
            label: _progressLabelOf(t),
            urgent: _shortDelivery(t),
            action: _statusActionOf(t),
          ),
        ),
        MasterColumnDef(
          key: 'planNo',
          sortable: true,
          label: '来源计划',
          width: 140,
          value: (t) => t.planNo,
        ),
        MasterColumnDef(
          // ADR-065 修订：行=当前执行单据；归组行（多货品合并申请）显示物料规模摘要。
          key: 'docNo',
          sortable: true,
          label: '委外申请号',
          width: 160,
          value: (t) => t.actionDocumentRestricted
              ? '—'
              : (t.actionDocument?.number ?? '—'),
        ),
        // 2026-09-14 用户口径（全站表格统一）：名称 / 编号 / 颜色各占一列，
        // 不再「编号 名称」拼一格、颜色拼进规格。
        MasterColumnDef(
          key: 'goods',
          sortable: true,
          label: '委外件名称',
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
              : '${formatWorkbenchQuantity(t.requiredQty)} ${t.unitName}'
                    .trim(),
        ),
        MasterColumnDef(
          key: 'openQty',
          label: '待下单量',
          width: 120,
          type: 'number',
          value: (t) => t.isDocumentGrouped
              ? '${t.openLineCount} 行'
              : '${formatWorkbenchQuantity(t.openQty)} ${t.unitName}'.trim(),
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
        // ADR-156：紧挨状态列，「可部分下单 | 4 / 剩余 6 件」一眼读完。
        MasterColumnDef(
          key: 'orderableQty',
          label: '可下单',
          info:
              '这次能生成订货单的数量：剩余未下单与现有直属物料够做的套数取小，'
              '由服务端实时算好；订货数量超出会被拒绝。点状态列可看每种物料的齐套情况。',
          width: 130,
          type: 'number',
          value: (t) => t.orderableQtyText ?? '—',
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
      // 整行底色已退役（2026-10-08 用户口径）：状态色只在状态列整格底色，
      // 不能下单的锁行/回厂短交待判定行不再铺红。
      // 待处理行双击 = 申请摘要弹窗；其余行 = 关联申请 / 订货详情。
      canOpenRow: (task) =>
          task.taskStatus == _waitingOrderStage ||
          task.actionDocument?.canView == true,
      selectable: canOrder,
      idOf: (task) => _canOrderTask(task) ? task.id : null,
      // idOf 会返回 null 的锁行仍要有稳定行键(否则回落下标键)。
      rowKeyOf: (task) => task.taskId,
      // 锁行的勾选位换锁图标，悬浮说明为什么不能下单(缺 BOM / 等物料齐套)。
      unselectableLeadingBuilder: (context, task) => Tooltip(
        message: subcontractTaskLockReason(task),
        child: Icon(
          Icons.lock_outline_rounded,
          size: 20,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      selectedIds: _selectedIds,
      onSelectedIdsChanged: (next) => setState(() {
        _selectedIds
          ..clear()
          ..addAll(next);
      }),
      // 批量按钮随段门控；服务端能力缺失时保留灰按钮兜底解释(能力面问题要能被发现)。
      // 悬浮组只在 selectable 时挂载：行不可选(能力缺失)时灰按钮改驻表头上方
      // 工具条，大小屏同一张表后两态都有入口（2026-10-09）。
      batchActionsBuilder: !_orderingSeg || !_hasDecomposePermissions
          ? null
          : (_, _) => [_createOrderButton()],
      toolbarActions: !_orderingSeg || !_hasDecomposePermissions || canOrder
          ? null
          : [_createOrderButton()],
      isLoading: _loading,
      error: _error,
      onRetry: () => _load(),
      emptyMessage: _seg?.history == true ? '该时间段内暂无委外任务' : '当前筛选下没有委外任务',
      currentPage: data.page,
      totalPages: data.totalPages,
      paginationScope: (_keyword, _seg, _exception, _historyTime),
      onPageChange: (page) {
        setState(() => _page = page);
        _load(page: page);
      },
    );
  }

  // —— 「待处理」领料行(ADR-171 修订二：拍平进待处理表) ——

  bool get _drawScoped => _drawOrderId != null || _drawOrderItemId != null;

  /// 领料行是否允许勾选(批量领料)：领料行可见且账号有提交权、服务端标了可领。
  bool get _canSubmitDraw =>
      _drawVisible && (_drawData?.canSubmitDraw ?? false);

  bool _actionableDraw(SubcontractDrawTaskRow row) =>
      _canSubmitDraw && row.canDraw && row.status.isDrawable;

  /// 「待处理」拍平表：领料行(钉顶，一次拉全) + 委外申请行(工作台投影服务端分页)。
  Widget _buildPendingTable(OperationsWorkbenchData data) {
    final canOrder =
        _hasDecomposePermissions && data.capabilities.canCreateSubcontractOrder;
    final selectable = canOrder || _canSubmitDraw;
    final drawRows = [
      if (_drawVisible)
        for (final row
            in _drawData?.page.items ?? const <SubcontractDrawTaskRow>[])
          SubcontractPendingDrawRow(row),
    ];
    final applicationRows = [
      for (final task in data.items) SubcontractApplicationRow(task),
    ];
    String rowId(SubcontractPendingRow row) => switch (row) {
      SubcontractApplicationRow(:final task) =>
        _canOrderTask(task) ? task.id : '',
      SubcontractPendingDrawRow(:final row) =>
        _actionableDraw(row) ? 'draw-${row.orderItemId}' : '',
    };
    Widget lockLeading(BuildContext context, SubcontractPendingRow row) =>
        Tooltip(
          message: switch (row) {
            SubcontractApplicationRow(:final task) => subcontractTaskLockReason(
              task,
            ),
            SubcontractPendingDrawRow(:final row) =>
              subcontractDrawStatusTooltip(row) ?? '当前状态不能领料',
          },
          child: Icon(
            Icons.lock_outline_rounded,
            size: 20,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        );
    return MasterDataTableView<SubcontractPendingRow>(
      tableKey:
          'features.subcontract.pages.subcontract_decomposition_page.SubcontractDecompositionPageState._buildPendingTable.1',
      key: const Key('subcontract-decomposition-pending-table'),
      // primary:true → 表体参与「筛选行折叠 → 表格内滚」联动。
      primary: true,
      // 领料行钉在已加载页之前(与草稿表钉本地草稿同一范式)：翻页常驻、即改即换。
      unpagedItems: drawRows,
      columns: [
        MasterColumnDef(
          key: 'status',
          label: '状态',
          width: 72,
          value: (row) => switch (row) {
            SubcontractApplicationRow(:final task) => _progressLabelOf(task),
            SubcontractPendingDrawRow(:final row) => subcontractDrawStatusLabel(
              row,
              actionable: _actionableDraw(row),
            ),
          },
          cellBuilderHandlesSemantics: true,
          // 状态分类色铺整格(2026-09-27 用户口径)：红=等本部门动手(可领/待下单/
          // 锁行)，黄=已提交领料等仓库发(在跑不用动手)，其余沿用各域既有配色。
          cellColor: (context, row) => switch (row) {
            SubcontractApplicationRow(:final task) => utenStatusBadgeCellColor(
              _progressType(task.progressStatus),
            ),
            SubcontractPendingDrawRow(:final row) => subcontractDrawCellColor(
              subcontractDrawToneOf(row.status),
            ),
          },
          cellBuilder: (context, row) => switch (row) {
            SubcontractApplicationRow(:final task) => _ProgressStatusCell(
              label: _progressLabelOf(task),
              urgent: _shortDelivery(task),
              action: _statusActionOf(task),
            ),
            SubcontractPendingDrawRow(:final row) => _DrawStatusCell(
              row: row,
              actionable: _actionableDraw(row),
              onDraw: _drawNavigating
                  ? null
                  : () => _openDrawRequest([row.orderItemId]),
            ),
          },
        ),
        MasterColumnDef(
          key: 'planNo',
          sortable: true,
          label: '来源计划',
          width: 140,
          value: (row) => switch (row) {
            SubcontractApplicationRow(:final task) => task.planNo,
            // 2026-10-10：领料行的来源计划改由服务端下发(plan_no=WL 分析编号，
            // 为空时回落订货单号)，与申请行同列；无值仍显示「—」。
            SubcontractPendingDrawRow(:final row) => _label(row.planNo),
          },
        ),
        MasterColumnDef(
          // 申请行=委外申请号；领料行=委外订货单号(行=当前执行单据)。
          key: 'docNo',
          sortable: true,
          label: '单据号',
          width: 160,
          value: (row) => switch (row) {
            SubcontractApplicationRow(:final task) =>
              task.actionDocumentRestricted
                  ? '—'
                  : (task.actionDocument?.number ?? '—'),
            SubcontractPendingDrawRow(:final row) => _label(row.orderBillNo),
          },
        ),
        MasterColumnDef(
          key: 'supplierName',
          label: '委外商',
          width: 150,
          // 2026-10-10：申请行的委外商改由服务端投影下发(V836，申请头上的
          // supplier_id→suppliers.name)；空=尚未定商，是业务事实，照旧显示「—」。
          value: (row) => switch (row) {
            SubcontractApplicationRow(:final task) => _label(task.supplierName),
            SubcontractPendingDrawRow(:final row) => _label(row.supplierName),
          },
        ),
        // 2026-09-14 用户口径（全站表格统一）：名称 / 编号 / 颜色各占一列。
        MasterColumnDef(
          key: 'goods',
          sortable: true,
          label: '委外件名称',
          width: 200,
          value: (row) => switch (row) {
            SubcontractApplicationRow(:final task) =>
              task.isDocumentGrouped ? task.goodsSummaryLabel : task.goodsName,
            SubcontractPendingDrawRow(:final row) => _label(row.goodsName),
          },
        ),
        MasterColumnDef(
          key: 'goodsCode',
          sortable: true,
          label: '编号',
          width: 130,
          value: (row) => switch (row) {
            SubcontractApplicationRow(:final task) =>
              task.isDocumentGrouped ? '—' : task.goodsCode,
            SubcontractPendingDrawRow(:final row) => _label(row.goodsCode),
          },
        ),
        MasterColumnDef(
          key: 'colorName',
          label: '颜色',
          width: 96,
          value: (row) => switch (row) {
            SubcontractApplicationRow(:final task) =>
              task.isDocumentGrouped ? '—' : task.colorName,
            SubcontractPendingDrawRow(:final row) => _label(row.colorName),
          },
        ),
        MasterColumnDef(
          key: 'spec',
          sortable: true,
          label: '规格',
          width: 150,
          value: (row) => switch (row) {
            SubcontractApplicationRow(:final task) =>
              task.isDocumentGrouped ? '—' : task.spec,
            SubcontractPendingDrawRow() => '—',
          },
        ),
        MasterColumnDef(
          key: 'requiredQty',
          label: '需求量',
          width: 110,
          type: 'number',
          value: (row) => switch (row) {
            SubcontractApplicationRow(:final task) =>
              task.isDocumentGrouped
                  ? '—'
                  : '${formatWorkbenchQuantity(task.requiredQty)} ${task.unitName}'
                        .trim(),
            SubcontractPendingDrawRow() => '—',
          },
        ),
        MasterColumnDef(
          key: 'openQty',
          label: '待下单量',
          width: 120,
          type: 'number',
          value: (row) => switch (row) {
            SubcontractApplicationRow(:final task) =>
              task.isDocumentGrouped
                  ? '${task.openLineCount} 行'
                  : '${formatWorkbenchQuantity(task.openQty)} ${task.unitName}'
                        .trim(),
            SubcontractPendingDrawRow() => '—',
          },
        ),
        // ADR-156：紧挨数量列，「可部分下单 | 4 / 剩余 6 件」一眼读完。
        MasterColumnDef(
          key: 'orderableQty',
          label: '可下单',
          info:
              '这次能生成订货单的数量：剩余未下单与现有直属物料够做的套数取小，'
              '由服务端实时算好；订货数量超出会被拒绝。点状态列可看每种物料的齐套情况。',
          width: 130,
          type: 'number',
          value: (row) => switch (row) {
            SubcontractApplicationRow(:final task) =>
              task.orderableQtyText ?? '—',
            SubcontractPendingDrawRow() => '—',
          },
        ),
        _pendingDrawQtyColumn('orderQty', '订货数量', (row) => row.orderQty),
        _pendingDrawQtyColumn('drawnQty', '已领', (row) => row.drawnQty),
        _pendingDrawQtyColumn('pendingQty', '待仓库发', (row) => row.pendingQty),
        _pendingDrawQtyColumn('drawableQty', '可领', (row) => row.drawableQty),
        _pendingDrawQtyColumn('shortQty', '还缺', (row) => row.shortQty),
        // 「单位」列 2026-10-10 删除（数量+单位口径）：领料行各数量列已内联订货单位
        // （row.unitName），申请行本就没有单位。
        MasterColumnDef(
          key: 'needDate',
          sortable: true,
          label: '需求日期',
          width: 120,
          type: 'date',
          value: (row) => switch (row) {
            SubcontractApplicationRow(:final task) => task.needDate,
            SubcontractPendingDrawRow(:final row) => row.deliverDate,
          },
        ),
        MasterColumnDef(
          key: 'issuedAt',
          label: workflowFieldText(context).subcontractPlanIssuedDate,
          info: workflowFieldText(context).subcontractPlanIssuedDateHint,
          width: 160,
          type: 'date',
          sortable: true,
          value: (row) => switch (row) {
            SubcontractApplicationRow(:final task) => _issuedDate(
              task.issuedAt,
            ),
            SubcontractPendingDrawRow() => null,
          },
        ),
      ],
      items: applicationRows,
      // 拍平表不做列头筛选：两类行的状态/单据语义不同，服务端 facets 只覆盖申请行；
      // 筛选用阶段搜索框与领料定位芯片。
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      sortColumn: _sortColumn,
      sortAscending: _sortAscending,
      // 排序/翻页走申请行的服务端链路；领料行钉顶不参与(顺序由服务端按
      // 状态优先级排好)。
      onSortChange: (column, ascending) {
        setState(() {
          _sortColumn = column;
          _sortAscending = ascending;
          _selectedIds.clear();
        });
        _load(page: 1);
      },
      onRowTap: (row) => switch (row) {
        SubcontractApplicationRow(:final task) => _openTask(task),
        SubcontractPendingDrawRow(:final row) => _openDrawTask(row),
      },
      canOpenRow: (row) => switch (row) {
        SubcontractApplicationRow(:final task) =>
          task.taskStatus == _waitingOrderStage ||
              task.actionDocument?.canView == true,
        SubcontractPendingDrawRow() => true,
      },
      selectable: selectable,
      idOf: (row) {
        final id = rowId(row);
        return id.isEmpty ? null : id;
      },
      rowKeyOf: (row) => row.rowKey,
      unselectableLeadingBuilder: lockLeading,
      selectedIds: {
        ..._selectedIds,
        for (final id in _selectedDrawIds) 'draw-$id',
      },
      onSelectedIdsChanged: (next) => setState(() {
        _selectedIds
          ..clear()
          ..addAll(next.where((id) => !id.startsWith('draw-')));
        _selectedDrawIds
          ..clear()
          ..addAll(
            next
                .where((id) => id.startsWith('draw-'))
                .map((id) => id.substring('draw-'.length)),
          );
      }),
      // 悬浮组双按钮：勾了申请行 → 生成委外订货单；勾了领料行 → 批量领料。
      // 各自按自己的选择数算启用，互不拦截(两类行同时勾选时两个都在)。
      batchActionsBuilder: !selectable
          ? null
          : (_, _) => [
              if (canOrder) _createOrderButton(),
              if (_canSubmitDraw) _drawBatchButton(),
            ],
      // 有下单权限但服务端能力缺失时保留灰按钮兜底解释(能力面问题要能被发现)；
      // 连权限都没有的账号不摆死按钮。大小屏同一张表后两态都有入口(2026-10-09)。
      toolbarActions: _orderingSeg && _hasDecomposePermissions && !canOrder
          ? [_createOrderButton()]
          : null,
      isLoading: _loading || _drawLoading,
      error: _error ?? _drawError,
      onRetry: _refreshAll,
      emptyMessage: _drawScoped || _keyword.isNotEmpty
          ? '当前筛选下没有待处理的委外任务'
          : '暂无待处理的委外任务；计划下达的申请与财务批准后的领料任务会出现在这里',
      currentPage: data.page,
      totalPages: data.totalPages,
      paginationScope: (_keyword, _seg, _exception),
      onPageChange: (page) {
        setState(() => _page = page);
        _load(page: page);
      },
    );
  }

  MasterColumnDef<SubcontractPendingRow> _pendingDrawQtyColumn(
    String key,
    String label,
    double Function(SubcontractDrawTaskRow row) qty,
  ) => MasterColumnDef(
    key: key,
    label: label,
    width: 96,
    type: 'number',
    // 2026-10-10 数量+单位口径：单位(订货单位=委外件单位)内联进数字，
    // 独立「单位」列已删除；排序由表格组件剥单位后缀兜底。
    value: (row) => switch (row) {
      SubcontractApplicationRow() => '—',
      SubcontractPendingDrawRow(:final row) =>
        formatQtyWithUnit(qty(row), row.unitName),
    },
  );

  static String _label(String? value) =>
      value?.trim().isNotEmpty == true ? value!.trim() : '—';

  static String? _issuedDate(String? value) {
    final date = ChinaDateTime.tryParse(value);
    return date == null ? null : ChinaDateTime.formatDate(date);
  }
}

/// 「待处理」拍平表的一行：委外申请(工作台投影分页行)或领料任务(钉顶行)。
/// 公开给测试做表格字段的类型化访问(页面自身只有这一处使用)。
sealed class SubcontractPendingRow {
  const SubcontractPendingRow();

  String get rowKey;
}

class SubcontractApplicationRow extends SubcontractPendingRow {
  const SubcontractApplicationRow(this.task);

  final OperationsWorkbenchTask task;

  @override
  String get rowKey => 'app-${task.taskId}';
}

class SubcontractPendingDrawRow extends SubcontractPendingRow {
  const SubcontractPendingDrawRow(this.row);

  final SubcontractDrawTaskRow row;

  @override
  String get rowKey => 'draw-${row.orderItemId}';
}

/// 「待处理·领料」状态格：图标 + 文案；可领且可提交时点击直达领料页(只带这一行)。
/// 文字色由表格 cellColor 通道黑白自适应注入，勿写死。
class _DrawStatusCell extends StatelessWidget {
  const _DrawStatusCell({
    required this.row,
    required this.actionable,
    required this.onDraw,
  });

  final SubcontractDrawTaskRow row;
  final bool actionable;
  final VoidCallback? onDraw;

  @override
  Widget build(BuildContext context) {
    final label = subcontractDrawStatusLabel(row, actionable: actionable);
    final tooltip = subcontractDrawStatusTooltip(row);
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          subcontractDrawToneIcon(subcontractDrawToneOf(row.status)),
          size: 16,
        ),
        const SizedBox(width: UtenSpacing.s4),
        Flexible(
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ],
    );
    if (!actionable) {
      return Tooltip(
        message: tooltip ?? label,
        child: Semantics(label: label, child: content),
      );
    }
    return Tooltip(
      message: tooltip ?? '点击去领料',
      child: Semantics(
        button: true,
        label: '$label，点击去领料',
        child: InkWell(
          key: ValueKey('subcontract-draw-go-${row.orderItemId}'),
          onTap: onDraw,
          // 不垫垂直内边距（2026-10-06 行高统一口径）：格子的 8×2 纵向留白
          // 已是点击区，再叠 16px 会把整行撑到 51+，与其它任务表不齐。
          child: content,
        ),
      ),
    );
  }
}

class _ProgressStatusCell extends StatelessWidget {
  const _ProgressStatusCell({
    required this.label,
    this.urgent = false,
    this.action,
  });

  final String label;

  /// 回厂短交待判定（红色前缀「紧急」）。
  final bool urgent;

  /// 点状态的动作；null = 不可点。
  final _StatusAction? action;

  @override
  Widget build(BuildContext context) {
    // 表格列形态：底色在列 cellColor，文字必须继承表格注入的对比度前景
    // （深底白字）——不许在这里写死颜色，否则红底黑字看不清（2026-10-08
    // 用户反馈的根因）。状态列文字加粗由表格统一处理，这里只继承。
    final inherited = DefaultTextStyle.of(context).style;
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (urgent) ...[
          const Icon(Icons.priority_high_rounded, size: 14),
          const SizedBox(width: 2),
          Text(
            '紧急',
            style: inherited.copyWith(
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: UtenSpacing.s4),
        ],
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: inherited,
          ),
        ),
      ],
    );
    final action = this.action;
    if (action == null) return Semantics(label: label, child: content);
    return Tooltip(
      message: action.hint,
      child: Semantics(
        button: true,
        label: '$label，${action.hint}',
        child: InkWell(
          onTap: action.onTap,
          borderRadius: UtenRadius.pillAll,
          child: content,
        ),
      ),
    );
  }
}
