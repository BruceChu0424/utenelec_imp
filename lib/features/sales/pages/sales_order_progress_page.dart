// 销售订单进度查询（订单进度查询卡）：已审订单的生产/发货进度看板。
//
// 2026-09-05 起列表改为 MasterDataTableView 统一表格（原进度环卡片下线）：
// 列 = 订单号/客户/开单/交货/状态/订货/已产/已发/可发/生产进度/驳回原因。
// 双击行进「订单进度详情」整页；行右键/长按菜单提供 打开详情/修改订单/
// 取消订单（财务驳回单的终止处置，避免一直挂在驳回段）/去发货。
//
// 2026-09-21(ADR-100 + 用户口径「就分三种，也可以有子分类」) 分段两层化：
//  · 大类行三段：进行中 / 可发货 / 历史记录。原来六个阶段一字排开，看起来六个
//    按钮一样重，分不出「还没能发货」和「已经能发货了」这条主线;
//  · 小类行（选中大类后出现）：进行中 = 财务驳回 / 待排产 / 生产中，
//    可发货 = 可分批发货 / 出货待财审 / 等仓库出货（用户原话「可发货里面就包含
//    财务啥的」）。没有「全部」段——大类本身就是全部;
//  · 大类同时挂两枚徽章：黄 = 本类里还在别人手上跑的单，红 = 本类里等销售动手的单
//    （财务驳回要改单重报、可分批发货要去开出货单），两枚都是各小类之和;
//  · 状态列每档一个色相、刻意拉开（salesProgressStageBadgeType），表头可排序。
//    此前六档挤在三种颜色里，一眼看不出单子卡在哪一环。
//  · 后端认识两个大类码 IN_PROGRESS / READY_TO_SHIP（SalesOrderService
//    .progressStagePredicate 各展开成一组阶段），不必前端拼多次请求。
// 历史记录 = 全部订单（stage=''，含被驳回/进行中/已发货/已中止/已结案），
// 按 时间段/全部 时间门控，未选时间不发请求；默认不选显示引导占位不发请求。
//
// 状态列文案与配色的优先级：终态 已中止/已结案 > 财务驳回 > 订单级财务闸门
// 「等待财务审核」> 生产阶段。终态必须最先判——整单取消不清 finance_confirmed，
// 闸门先判会把取消单错显成「等待财务审核」。
// 打开本页即把完工通知标记已读 → 完工徽章归零（已读语义）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_segment_badge_label.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/layout/uten_history_time_filter.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../config/sales_doc_config.dart';
import '../models/sales_doc.dart';
import '../models/sales_order_progress.dart';
import '../providers/sales_completion_count_provider.dart';
import '../repositories/sales_repository.dart';

/// 阶段分段值：真实阶段/大类（stage 非空）或历史记录哨兵（全部订单入历史）。
///
/// stage 可以是后端认识的**大类码**（IN_PROGRESS / READY_TO_SHIP，各自展开成一组
/// 阶段）或**单个阶段码**（小类行选中时）。
class _ProgressSeg {
  const _ProgressSeg.stage(String this.stage) : history = false;
  const _ProgressSeg.history() : stage = null, history = true;

  final String? stage;
  final bool history;

  @override
  bool operator ==(Object other) =>
      other is _ProgressSeg && other.stage == stage && other.history == history;

  @override
  int get hashCode => Object.hash(stage, history);
}

/// 大类 -> 它包含的阶段（顺序即小类行的展示顺序）。
///
/// 2026-09-21 用户口径：「订单进度查询的分类就分三种，也可以有子分类」。
/// 原本六个阶段并排一行，用户看到的是六个差不多长的按钮，分不出主次；
/// 现在按「单子走到哪一步」收成两个大类 + 历史记录，细分降级为小类行。
const _stageGroups = <String, List<String>>{
  // 还没走到能发货那一步。财务驳回也在这里：它是销售要改单重报的活，
  // 但订单本身仍是一张没走完的在途单，不值得单开一个顶层大类。
  'IN_PROGRESS': ['REJECTED', 'PENDING', 'PRODUCING'],
  // 已经可以开单发货、或出货单已经在财务/仓库手上走着的（用户原话
  // 「可发货里面就包含财务啥的」）。
  'READY_TO_SHIP': ['SHIPPABLE', 'SHIPMENT_PENDING', 'WAREHOUSE_PENDING'],
};

/// 大类文案。
const _groupLabels = <String, String>{
  'IN_PROGRESS': '进行中',
  'READY_TO_SHIP': '可发货',
};

/// 该阶段是不是「轮到销售动手」——决定小类行挂红徽章还是黄徽章。
///
/// 财务驳回要销售改单重报、可分批发货要销售去开出货单，这两档不动会卡住整条链；
/// 其余四档的球分别在生产、财务、仓库手上，销售只是看着。
bool _stageNeedsSales(String stage) =>
    stage == 'REJECTED' || stage == 'SHIPPABLE';

class SalesOrderProgressPage extends ConsumerStatefulWidget {
  const SalesOrderProgressPage({super.key, this.embedded = false});

  /// 嵌入态（2026-09-24 销售任务中心）：作为 /sales/tasks「订货进度」大类的正文，
  /// 不渲染 Scaffold/AppBar；大类/小类分段、搜索、表格与独立页完全一致。
  final bool embedded;

  @override
  ConsumerState<SalesOrderProgressPage> createState() =>
      _SalesOrderProgressPageState();
}

class _SalesOrderProgressPageState
    extends ConsumerState<SalesOrderProgressPage> {
  static const _size = 50;

  /// 当前选中分段；null = 未选择引导态（不发请求）。
  _ProgressSeg? _seg;

  /// 历史记录段的时间门控值；none = 尚未选择（历史段下同样不发请求）。
  UtenHistoryTimeValue _historyTime = const UtenHistoryTimeValue.none();

  String _keyword = '';
  int _requestVersion = 0;
  int _page = 1;
  bool _loading = false;
  bool _cancelBusy = false;
  String? _error;
  PagedResult<SalesOrderProgressRow>? _result;

  /// 阶段计数（后端全量口径）；null = 尚未返回，徽章不显示。
  Map<String, int>? _stageCounts;

  /// 本页路径（创建时捕获；被 push 页遮住后现取 matchedLocation 会拿到别人的路径）。
  /// 「返回即刷新」onPageResume 用，见 build。
  String? _myLocation;

  bool get _shouldLoad {
    final seg = _seg;
    if (seg == null) return false;
    if (seg.history && _historyTime.isNone) return false;
    return true;
  }

  @override
  void initState() {
    super.initState();
    // 打开即清完工徽章（已读语义）；并拉阶段计数（徽章，全量口径）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      markSalesCompletionSeen(context);
      _loadStageCounts();
    });
  }

  Future<void> _loadStageCounts() async {
    try {
      final counts = await ref
          .read(salesRepositoryProvider(SalesDocType.order))
          .progressStageCounts();
      if (mounted) setState(() => _stageCounts = counts);
    } catch (_) {
      // 计数失败静默：徽章不显示，不影响列表。
    }
  }

  Future<void> _load(int page) async {
    if (!_shouldLoad) return;
    final version = ++_requestVersion;
    final seg = _seg!;
    final range = seg.history ? _historyTime.range : null;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ref
          .read(salesRepositoryProvider(SalesDocType.order))
          .progress(
            page: page,
            size: _size,
            // 历史记录 = 全部订单（含被驳回/进行中/已发货/已中止/已结案），
            // 阶段不限（stage=''），只按日期/关键字过滤。
            stage: seg.history ? '' : seg.stage!,
            keyword: _keyword,
            dateFrom: range == null
                ? null
                : ChinaDateTime.formatDate(range.start),
            dateTo: range == null ? null : ChinaDateTime.formatDate(range.end),
          );
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _result = res;
        _page = page;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _selectSeg(_ProgressSeg seg) {
    if (seg == _seg) return;
    setState(() {
      _seg = seg;
      if (!seg.history) _historyTime = const UtenHistoryTimeValue.none();
    });
    if (!seg.history || !_historyTime.isNone) _load(1);
  }

  void _onHistoryTime(UtenHistoryTimeValue value) {
    if (value == _historyTime) return;
    setState(() => _historyTime = value);
    _load(1);
  }

  void _applyKeyword(String value) {
    final normalized = value.trim();
    if (normalized == _keyword) return;
    _keyword = normalized;
    _load(1);
  }

  bool _hasPerm(String code) =>
      ref.read(isSuperAdminProvider) ||
      ref.read(currentPermissionsProvider).contains(code);

  /// 财务驳回单的整单取消（终止处置）：无发货、无排产/在产/完工关联才开放，
  /// 与订货单详情页「取消订单」同一后端路径（cancel 会清驳回态并置中止）。
  bool _canCancelRejected(SalesOrderProgressRow r) =>
      r.financeRejected &&
      !r.stopped &&
      !r.closed &&
      _hasPerm(Perm.salesOrderCancel) &&
      r.shippedQty <= 0.0001 &&
      r.plannedQty <= 0.0001 &&
      r.producedQty <= 0.0001;

  Future<void> _cancelRejectedOrder(SalesOrderProgressRow r) async {
    if (_cancelBusy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('取消订单'),
        content: Text(
          '订单 ${r.billNo} 已被财务驳回。取消将释放全部库存预留并终止该订单'
          '（驳回单随之出队，不再显示在「财务驳回」段），确认取消？',
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('再想想'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认取消订单'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _cancelBusy = true);
    try {
      await ref
          .read(salesRepositoryProvider(SalesDocType.order))
          .cancel(r.orderId);
      if (!mounted) return;
      context.appSuccess('订单已取消');
      bumpListRefresh(ref, SalesDocConfig.by(SalesDocType.order).refreshKey);
      await _load(_page);
      _loadStageCounts();
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('取消失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _cancelBusy = false);
    }
  }

  /// 单个订单的发货入口先核对该单的产品进度，再选择本次发货产品。
  Future<void> _ship(SalesOrderProgressRow row) async {
    await context.push(RoutePath.salesOrderProgressDetail(row.orderId));
    if (mounted) {
      await _load(_page);
      _loadStageCounts();
    }
  }

  /// 行菜单条目（右击/长按弹出）。可用性按权限 + 行状态实时决定。
  List<UtenContextMenuEntry> _rowMenuItems(SalesOrderProgressRow r) {
    final canShip =
        r.shippable &&
        !r.financeRejected &&
        !r.stopped &&
        !r.closed &&
        r.stage != 'SHIPPED' &&
        _hasPerm(Perm.salesShipmentCreate);
    return [
      UtenMenuItem(
        label: '打开进度详情',
        icon: Icons.open_in_full_rounded,
        onTap: () =>
            context.push(RoutePath.salesOrderProgressDetail(r.orderId)),
      ),
      if (r.financeRejected) ...[
        const UtenMenuDivider(),
        UtenMenuItem(
          label: '修改订单',
          icon: Icons.edit_outlined,
          enabled: _hasPerm(Perm.salesOrderEdit),
          onTap: () =>
              context.push(RoutePath.salesDocEdit('orders', r.orderId)),
        ),
        UtenMenuItem(
          label: _cancelBusy ? '取消中…' : '取消订单',
          icon: Icons.cancel_outlined,
          destructive: true,
          enabled: _canCancelRejected(r) && !_cancelBusy,
          onTap: () => _cancelRejectedOrder(r),
        ),
      ],
      if (canShip) ...[
        const UtenMenuDivider(),
        UtenMenuItem(
          label: '去发货',
          icon: Icons.local_shipping_outlined,
          onTap: () => _ship(r),
        ),
      ],
    ];
  }

  /// 阶段分段的计数形态(三形态口径 ADR-100, 逐段问两句)。
  ///
  /// 财务驳回要销售受控修订后重报、可分批发货要销售自己开出货单 —— 这两段是
  /// 「轮到我动手, 不动会出事」, 红徽章(与 salesAttentionCountProvider 同源)。
  /// 其余四段(待排产 / 生产中 / 出货待财审 / 等仓库出货)的球分别在生产、财务、
  /// 仓库手上: 单子还在流程里跑着、没结束, 销售现在不用动手 —— 黄色进行中徽章,
  /// 2026-09-21 之前它们是中性括号, 与「已结束」的历史记录混成一种形态。
  /// 小类行某一档的计数形态：等销售动手的红、还在别人手上跑的黄。
  static UtenSegmentCountForm _stageCountForm(String stage) =>
      _stageNeedsSales(stage)
      ? UtenSegmentCountForm.actionable
      : UtenSegmentCountForm.inProgress;

  /// 某个大类下、满足 [where] 的那些阶段的计数之和；计数还没回来时返回 null
  /// （不把「未知」伪装成 0，与全站徽章口径一致）。
  int? _groupCount(String group, bool Function(String stage) where) {
    final counts = _stageCounts;
    if (counts == null) return null;
    var total = 0;
    for (final stage in _stageGroups[group]!) {
      if (where(stage)) total += counts[stage] ?? 0;
    }
    return total;
  }

  /// 当前选中的大类（选中小类时返回它所属的大类）；历史记录/未选返回 null。
  String? get _selectedGroup {
    final stage = _seg?.stage;
    if (stage == null) return null;
    if (_stageGroups.containsKey(stage)) return stage;
    for (final entry in _stageGroups.entries) {
      if (entry.value.contains(stage)) return entry.key;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final seg = _seg;
    // 返回即刷新：从详情/编辑页回到本页时重拉当前页与计数，不再看到老数据。
    // 嵌入态（任务中心「订货进度」大类）无独立路由落点时回退到进度页路径。
    _myLocation ??= currentLocationOr(context, RouteName.salesOrderProgress);
    ref.onPageResume(_myLocation!, () {
      _load(_page);
      _loadStageCounts();
    });
    // 正文（大类/小类分段 + 表格）：独立页与任务中心嵌入态共用一份。
    // 嵌入态不再自套 SafeArea/容器（宿主页已有容器，双重边距会把小类行
    // 推离父分类行与左缘，2026-09-24 用户走查修正），头部空行程也只在独立页留。
    final bodyContent = UtenCollapsingHeaderScrollView(
      collapsingHeader: Padding(
        padding: widget.embedded
            ? const EdgeInsets.only(
                left: UtenSpacing.s4,
                right: UtenSpacing.s4,
                bottom: UtenSpacing.s8,
              )
            : const EdgeInsets.fromLTRB(
                UtenSpacing.s12,
                UtenSpacing.s12,
                UtenSpacing.s12,
                UtenSpacing.s8,
              ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 大类行（ADR-100，用户口径「就分三种」）：进行中 / 可发货 /
            // 历史记录 + 搜索。每个大类同时挂两枚徽章——黄色 = 这一类里
            // 还在别人手上跑的单，红色 = 这一类里等销售动手的单；
            // 两枚都是「本大类各小类之和」，所以大类数与小类行对得上。
            UtenFilterToolbar<_ProgressSeg>(
              segmentsKey: const Key('sales-order-progress-stages'),
              segments: [
                for (final group in _stageGroups.keys)
                  UtenFilterSegment(
                    value: _ProgressSeg.stage(group),
                    label: _groupLabels[group]!,
                    count: _groupCount(group, _stageNeedsSales),
                    countForm: UtenSegmentCountForm.actionable,
                    inProgressCount: _groupCount(
                      group,
                      (stage) => !_stageNeedsSales(stage),
                    ),
                  ),
                const UtenFilterSegment(
                  value: _ProgressSeg.history(),
                  label: '历史记录',
                ),
              ],
              selected: seg == null
                  ? const {}
                  : {
                      // 选中小类时大类保持高亮：大类段的值是大类码，
                      // 直接拿 seg 去比会让整行看起来一个都没选。
                      if (_selectedGroup != null)
                        _ProgressSeg.stage(_selectedGroup!)
                      else
                        seg,
                    },
              onSelectionChanged: _selectSeg,
              searchHint: '搜索订单号 / 客户',
              onSearchChanged: _applyKeyword,
            ),
            // 小类行：选中大类后才解锁（与采购/委外任务中心的异常小类行同构）。
            // 没有「全部」段——大类本身就是全部；要看全量就点回大类。
            if (_selectedGroup != null) ...[
              const SizedBox(height: UtenSpacing.s8),
              UtenFilterToolbar<_ProgressSeg>(
                segmentsKey: const Key('sales-order-progress-substages'),
                segments: [
                  for (final stage in _stageGroups[_selectedGroup]!)
                    UtenFilterSegment(
                      value: _ProgressSeg.stage(stage),
                      label: salesProgressStageLabel(stage),
                      count: _stageCounts?[stage],
                      countForm: _stageCountForm(stage),
                    ),
                ],
                // 停在大类上时小类一个都不选（看的是整个大类）。
                selected: _stageGroups.containsKey(seg?.stage)
                    ? const {}
                    : {seg!},
                onSelectionChanged: _selectSeg,
              ),
            ],
            if (seg?.history == true) ...[
              const SizedBox(height: UtenSpacing.s8),
              UtenHistoryTimeFilter(
                key: const Key('sales-order-progress-history-time'),
                value: _historyTime,
                onChanged: _onHistoryTime,
              ),
            ],
          ],
        ),
      ),
      body: _body(theme),
    );
    // 嵌入态（销售任务中心「订货进度」大类正文）：宿主页负责 Scaffold/AppBar/容器。
    if (widget.embedded) return bodyContent;
    return Scaffold(
      appBar: UtenAppBar(
        title: '订单进度查询',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.sales),
        ),
        actions: [
          IconButton(
            tooltip: '刷新',
            // 整页刷新：列表回第 1 页 + 阶段徽章计数（与 initState 同口径）。
            onPressed: _loading
                ? null
                : () {
                    _loadStageCounts();
                    _load(1);
                  },
            icon: const Icon(Icons.refresh_rounded),
          ),
          const SizedBox(width: UtenSpacing.s8),
        ],
      ),
      body: SafeArea(child: UtenContentContainer(child: bodyContent)),
    );
  }

  Widget _body(ThemeData theme) {
    if (!_shouldLoad) {
      return segPlaceholder;
    }
    return MasterDataTableView<SalesOrderProgressRow>(
      // primary:true → 表体拾取外层 UtenCollapsingHeaderScrollView 注入的
      // PrimaryScrollController，参与「分类条折叠 → 表格内滚」联动。
      primary: true,
      columns: _columns,
      items: _result?.items ?? const <SalesOrderProgressRow>[],
      // 阶段筛选由顶部分段卡承担，表头不建 autofilter 桶。
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      // 财务驳回行淡红底：一眼定位需要处理的订单（取消/修订后自然出队）。
      rowColor: (r) => r.financeRejected
          ? theme.colorScheme.errorContainer.withValues(alpha: 0.30)
          : null,
      onRowTap: (r) =>
          context.push(RoutePath.salesOrderProgressDetail(r.orderId)),
      rowMenuBuilder: _rowMenuItems,
      isLoading: _loading && _result == null,
      loadingMore: _loading && _result != null,
      error: _error,
      onRetry: () => _load(_page),
      emptyMessage: _seg!.history ? '该时间段内暂无订单' : '该阶段暂无订单',
      currentPage: _result?.page ?? 1,
      totalPages: _result?.totalPages ?? 1,
      onPageChange: _load,
    );
  }

  Widget get segPlaceholder {
    final seg = _seg;
    if (seg == null) {
      return const UtenFilterPlaceholder(
        message: '在上方选择阶段后开始浏览',
        description:
            '阶段默认不选中；「历史记录」不限阶段按时间查阅全部订单'
            '（含被驳回/进行中/已发货/已中止/已结案）',
      );
    }
    return const UtenHistoryTimePlaceholder();
  }

  List<MasterColumnDef<SalesOrderProgressRow>> get _columns {
    return <MasterColumnDef<SalesOrderProgressRow>>[
      MasterColumnDef(
        key: 'billNo',
        label: '订单号',
        width: 150,
        value: (r) => r.billNo,
      ),
      MasterColumnDef(
        key: 'client',
        label: '客户',
        width: 180,
        value: (r) => r.clientName,
      ),
      MasterColumnDef(
        key: 'billDate',
        label: '开单日期',
        width: 110,
        type: 'date',
        value: (r) => _date(r.billDate),
      ),
      MasterColumnDef(
        key: 'deliverDate',
        label: '交货日期',
        width: 110,
        type: 'date',
        value: (r) => _date(r.deliverDate),
      ),
      MasterColumnDef(
        key: 'stage',
        label: '状态',
        // 部分排产文案「待排产·部分已排 4/10」需要更宽（V545）。
        width: 190,
        sortable: true,
        value: (r) => _stageText(r),
        // 2026-09-21(ADR-100 / 用户口径「不同状态不同颜色，色差要大」)：
        // 阶段从整格语义底色改成 UtenStatusBadge 药丸。底色版六个在途阶段只分到
        // 三种颜色（可发货/已发货/已结案同绿、驳回/待排产同红），一眼分不出单子
        // 卡在哪一环；药丸版每档一个色相，且不再整格刷色，行选中高亮也不受影响。
        cellBuilderHandlesSemantics: true,
        cellBuilder: (context, r) => Align(
          alignment: AlignmentDirectional.centerStart,
          child: UtenStatusBadge(
            label: _stageText(r),
            type: _stageBadgeType(r),
            size: UtenStatusBadgeSize.small,
          ),
        ),
      ),
      MasterColumnDef(
        key: 'orderQty',
        label: '订货量',
        width: 90,
        type: 'number',
        value: (r) => _fmt(r.orderQty),
      ),
      MasterColumnDef(
        key: 'producedQty',
        label: '已产量',
        width: 90,
        type: 'number',
        value: (r) => _fmt(r.producedQty),
      ),
      MasterColumnDef(
        key: 'shipmentInFlight',
        label: '出货在途',
        width: 200,
        value: (r) => salesProgressShipmentInFlightText(r) ?? '—',
      ),
      MasterColumnDef(
        key: 'shippedQty',
        label: '已发量',
        width: 90,
        type: 'number',
        value: (r) => _fmt(r.shippedQty),
      ),
      MasterColumnDef(
        key: 'reservedQty',
        label: '可发量',
        width: 90,
        type: 'number',
        value: (r) => _fmt(r.reservedQty),
      ),
      MasterColumnDef(
        key: 'productionPct',
        label: '生产进度',
        width: 90,
        // 财务确认前不展示排产进度（V300 口径），数量区同卡版本保持 0。
        value: (r) => '${(r.productionPct * 100).round()}%',
      ),
      MasterColumnDef(
        key: 'financeRejectedReason',
        label: '驳回原因',
        width: 260,
        value: (r) => !r.financeRejected
            ? null
            : (r.financeRejectedReason?.trim().isNotEmpty == true
                  ? r.financeRejectedReason!.trim()
                  : '未注明原因'),
      ),
    ];
  }

  /// 阶段列文本。优先级：终态（已中止/已结案）> 财务驳回 > 等待财务审核 > 生产阶段
  /// （V300 闸门只作用于在途订单）。终态必须最先判：整单取消不清 finance_confirmed，
  /// 已取消的订单该位仍为 false——若闸门优先，取消单会错显「等待财务审核」。
  String _stageText(SalesOrderProgressRow r) {
    if (r.stopped || r.stage == 'CANCELED') return '已中止';
    if (r.closed || r.stage == 'CLOSED') return '已结案';
    if (r.financeRejected) return '财务驳回';
    if (!r.financeConfirmed) return '等待财务审核';
    return salesProgressStageText(r);
  }

  /// 状态列配色：与 [_stageText] 同优先级（终态 > 财务驳回 > 财务闸门 > 生产阶段）。
  ///
  /// 「等待财务审核」是订单级财务闸门、不是 stage，取 info 蓝——与「出货待财审」
  /// 同色是有意的：两者都是「球在财务手上」。已中止走中性灰，终态不抢红色警示。
  UtenStatusBadgeType _stageBadgeType(SalesOrderProgressRow r) {
    if (r.stopped || r.stage == 'CANCELED') return UtenStatusBadgeType.neutral;
    if (r.closed || r.stage == 'CLOSED') return UtenStatusBadgeType.success;
    if (r.financeRejected) return UtenStatusBadgeType.danger;
    if (!r.financeConfirmed) return UtenStatusBadgeType.info;
    return salesProgressStageBadgeType(r.stage);
  }

  String? _date(String? value) =>
      value == null || value.length < 10 ? value : value.substring(0, 10);

  String _fmt(double v) {
    if (v == v.roundToDouble()) return v.toInt().toString();
    return v.toStringAsFixed(2);
  }
}
