// 销售订单进度查询（订单进度查询卡）：已审订单的生产/发货进度看板。
//
// 2026-09-05 起列表改为 MasterDataTableView 统一表格（原进度环卡片下线）：
// 列 = 订单号/客户/开单/交货/阶段/订货/已产/已发/可发/生产进度/驳回原因，
// 阶段列为语义底色单元格（cellColor：终态 已中止/已结案 优先于财务闸门——
// 整单取消不清 finance_confirmed，闸门先判会把取消单错显「等待财务审核」；
// 行选中时色块让位深绿高亮+白字，避免透明徽章在选中行上看不清）。
// 双击行进「订单进度详情」整页；行右键/长按菜单提供 打开详情/修改订单/
// 取消订单（财务驳回单的终止处置，避免一直挂在驳回段）/去发货。
// 2026-09-03 起统一「分类分段」范式（ADR-066）：阶段行 = 财务驳回/待排产/
// 生产中/可发货（计数徽章，后端 stage-counts 全量口径）+ 搜索 + 末尾
// 「历史记录」段。历史记录 = 全部订单（stage=''，含被驳回/进行中/已发货/
// 已中止/已结案），按 时间段/全部 时间门控，未选时间不发请求；
// 默认不选显示引导占位不发请求。
// 打开本页即把完工通知标记已读 → 完工徽章归零（已读语义）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
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
import '../widgets/sales_batch_ship_panel.dart';

/// 阶段分段值：真实阶段（stage 非空）或历史记录哨兵（全部订单入历史）。
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

class SalesOrderProgressPage extends ConsumerStatefulWidget {
  const SalesOrderProgressPage({super.key});

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
      markSalesCompletionSeen(ref);
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

  /// 去发货：复用批量发货面板（选可发行 + 改数量，审核后 shipped_qty↑/状态推进）。
  Future<void> _ship() async {
    await showSalesBatchShipPanel(context, ref);
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
          onTap: _ship,
        ),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final seg = _seg;
    // 返回即刷新：从详情/编辑页回到本页时重拉当前页与计数，不再看到老数据。
    _myLocation ??= GoRouterState.of(context).matchedLocation;
    ref.onPageResume(_myLocation!, () {
      _load(_page);
      _loadStageCounts();
    });
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
      body: SafeArea(
        child: UtenContentContainer(
          child: UtenCollapsingHeaderScrollView(
            collapsingHeader: Padding(
              padding: const EdgeInsets.fromLTRB(
                UtenSpacing.s12,
                UtenSpacing.s12,
                UtenSpacing.s12,
                UtenSpacing.s8,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 阶段行（统一分段卡）：财务驳回/待排产/生产中/可发货
                  // + 搜索 + 末尾历史记录（全部订单按时间查阅）。
                  // 计数形态：只有「财务驳回」是销售自己要改单重报的待办（与
                  // salesAttentionCountProvider 同源）→ 红徽章；待排产/生产中/
                  // 可发货下一步是生产与仓库在办，是进度监控数 → 中性括号。
                  UtenFilterToolbar<_ProgressSeg>(
                    segmentsKey: const Key('sales-order-progress-stages'),
                    segments: [
                      for (final stage in [
                        'REJECTED',
                        'PENDING',
                        'PRODUCING',
                        'SHIPPABLE',
                      ])
                        UtenFilterSegment(
                          value: _ProgressSeg.stage(stage),
                          label: salesProgressStageLabel(stage),
                          count: _stageCounts?[stage],
                          countForm: stage == 'REJECTED'
                              ? UtenSegmentCountForm.actionable
                              : UtenSegmentCountForm.browsing,
                        ),
                      const UtenFilterSegment(
                        value: _ProgressSeg.history(),
                        label: '历史记录',
                      ),
                    ],
                    selected: seg == null ? const {} : {seg},
                    onSelectionChanged: _selectSeg,
                    searchHint: '搜索订单号 / 客户',
                    onSearchChanged: _applyKeyword,
                  ),
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
          ),
        ),
      ),
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
        label: '阶段',
        // 部分排产文案「待排产·部分已排 4/10」需要更宽（V545）。
        width: 170,
        value: (r) => _stageText(r),
        // 阶段语义底色（cellColor 而非自绘 chip）：深色底由表格自动切白字；
        // 行选中时表格统一深绿高亮+白字，色块自动让位，不再有深绿底上看
        // 不清彩色徽章的问题（12% 透明 chip 在选中行上对比度不足的根因）。
        cellColor: (context, r) => _stageColor(Theme.of(context), r),
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

  /// 阶段列语义底色：与文本同优先级。等待财务审核用 tertiary（与进度详情页
  /// 「待财务确认」徽章同色），已中止用中性灰（终态不抢红色警示）。
  Color _stageColor(ThemeData theme, SalesOrderProgressRow r) {
    if (r.stopped || r.stage == 'CANCELED') {
      return theme.colorScheme.onSurfaceVariant;
    }
    if (r.closed || r.stage == 'CLOSED') return Colors.green;
    if (r.financeRejected) return theme.colorScheme.error;
    if (!r.financeConfirmed) return theme.colorScheme.tertiary;
    return salesProgressStageColor(r.stage, theme);
  }

  String? _date(String? value) =>
      value == null || value.length < 10 ? value : value.substring(0, 10);

  String _fmt(double v) {
    if (v == v.roundToDouble()) return v.toInt().toString();
    return v.toStringAsFixed(2);
  }
}
