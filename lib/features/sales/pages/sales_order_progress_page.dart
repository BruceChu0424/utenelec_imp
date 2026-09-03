// 销售订单进度查询（订单进度查询卡）：已审订单的生产/发货进度看板。
//
// 镜像生产看板范式：每张订单一张卡，圆环 = 生产进度（已产/订货，外层总进度环口径，
// 用户决策「生产进度为主」），附阶段 chip（待排产/生产中/可发货/已发货）+ 已产/订货/已发/可发。
// 2026-09-03 起统一「分类分段」范式（ADR-066，原 MetricFilterCards 指标卡退役）：
// 阶段行 = 财务驳回/待排产/生产中/可发货（计数徽章，后端 stage-counts 全量口径）
// + 搜索 + 末尾「历史记录」段（已发货入历史：时间门控 时间段/全部，未选时间
// 不发请求，选定后按 SHIPPED + 日期加载）。默认不选显示引导占位不发请求；
// 「待完成」聚合视图由默认不选占位语义取代，不再单独成段。
// 2026-08-19 起点卡进入「订单进度详情」整页（原排产进度底表弹窗已下线）：
// 产品进度（订货/已排/已产/已发/剩余 + 计划溯源）+ 快递式履约进度时间线
// （每环带责任人与时间，最新在最上）；等待财务审核的订单同样可进入查看审核轨迹。
// 可发货行（reserved>0）显「去发货」→ 复用批量发货面板（选可发行 + 改数量，审核后 shipped_qty↑/状态推进）。
// 打开本页即把完工通知标记已读 → 完工徽章归零（已读语义）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/layout/uten_history_time_filter.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../core/utils/display_datetime.dart';
import '../../../shared/models/paged_result.dart';
import '../../production/widgets/progress_ring.dart';
import '../models/sales_doc.dart';
import '../models/sales_order_progress.dart';
import '../providers/sales_completion_count_provider.dart';
import '../repositories/sales_repository.dart';
import '../widgets/sales_batch_ship_panel.dart';

/// 阶段分段值：真实阶段（stage 非空）或历史记录哨兵（已发货入历史）。
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
  String? _error;
  PagedResult<SalesOrderProgressRow>? _result;

  /// 阶段计数（后端全量口径）；null = 尚未返回，徽章不显示。
  Map<String, int>? _stageCounts;

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
            stage: seg.history ? 'SHIPPED' : seg.stage!,
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final seg = _seg;
    return Scaffold(
      appBar: UtenAppBar(
        title: '订单进度查询',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.sales),
        ),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : () => _load(_page),
            icon: const Icon(Icons.refresh_rounded),
          ),
          const SizedBox(width: UtenSpacing.s8),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                // 与货品资料/任务工作台一致的「顶部折叠 + 列表内滚」：上滑先把
                // 分类工具条收完腾出空间，之后订单卡列表内部滚动；分页条常驻底部。
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
                        // + 搜索 + 末尾历史记录（已发货入历史，时间门控）。
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
              if (_result != null && !_loading) _pager(theme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(ThemeData theme) {
    if (!_shouldLoad) {
      return segPlaceholder;
    }
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s16),
          child: Text(
            '加载失败：$_error',
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ),
      );
    }
    final items = _result?.items ?? const <SalesOrderProgressRow>[];
    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s16),
          child: Text(
            _seg!.history ? '该时间段内暂无已发货订单' : '该阶段暂无订单',
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _load(_page),
      // primary:true → 拾取外层 UtenCollapsingHeaderScrollView 注入的
      // PrimaryScrollController，参与「分类条折叠 → 列表内滚」联动。
      child: ListView.separated(
        primary: true,
        // 行少时 body 也要能滚 → 头部才收（与 MasterDataTableView primary 模式同理）。
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s12),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(height: UtenSpacing.s8),
        itemBuilder: (context, i) => _orderCard(theme, items[i]),
      ),
    );
  }

  Widget get segPlaceholder {
    final seg = _seg;
    if (seg == null) {
      return const UtenFilterPlaceholder(
        message: '在上方选择阶段后开始浏览',
        description: '阶段默认不选中；已发货订单请用末尾「历史记录」按时间查阅',
      );
    }
    return const UtenHistoryTimePlaceholder();
  }

  Widget _orderCard(ThemeData theme, SalesOrderProgressRow r) {
    final done = r.stage == 'SHIPPED';
    // V300：财务确认前不展示排产进度——卡片呈现「等待财务审核」，点按不弹排产底表。
    final financeRejected = r.financeRejected;
    final awaitingFinance = !r.financeConfirmed && !financeRejected;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ProgressRing(
              value: !r.financeConfirmed ? 0 : r.productionPct,
              done: done,
              size: 52,
              fontSize: 11,
            ),
            const SizedBox(width: UtenSpacing.s12),
            Expanded(
              child: InkWell(
                onTap: () =>
                    context.push(RoutePath.salesOrderProgressDetail(r.orderId)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            r.billNo,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (financeRejected)
                          _financeRejectedChip(theme)
                        else if (awaitingFinance)
                          _financePendingChip(theme)
                        else
                          _stageChip(theme, r.stage),
                      ],
                    ),
                    if (r.clientName != null && r.clientName!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          r.clientName!,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    if (r.deliverDate != null && r.deliverDate!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          '交货日 ${r.deliverDate!.substring(0, 10)}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    const SizedBox(height: UtenSpacing.s4),
                    if (financeRejected) ...[
                      Text(
                        '驳回原因：${r.financeRejectedReason?.trim().isNotEmpty == true ? r.financeRejectedReason!.trim() : '未注明原因'}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if ((r.financeRejectedByName?.isNotEmpty ?? false) ||
                          (r.financeRejectedAt?.isNotEmpty ?? false))
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            [
                              if (r.financeRejectedByName?.isNotEmpty ?? false)
                                r.financeRejectedByName!,
                              if (r.financeRejectedAt?.isNotEmpty ?? false)
                                DisplayDateTime.beijing(
                                  r.financeRejectedAt,
                                  fallback: r.financeRejectedAt!,
                                ),
                            ].join(' · '),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ] else if (awaitingFinance)
                      Text(
                        '等待财务审核 · 审核通过后显示排产进度',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      )
                    else
                      Wrap(
                        spacing: UtenSpacing.s12,
                        runSpacing: UtenSpacing.s4,
                        children: [
                          _kv(theme, '已产', _fmt(r.producedQty)),
                          _kv(theme, '订货', _fmt(r.orderQty)),
                          _kv(theme, '已发', _fmt(r.shippedQty)),
                          if (r.remainingQty > 0.0001)
                            _kv(theme, '未交', _fmt(r.remainingQty)),
                          if (r.reservedQty > 0.0001)
                            _kv(
                              theme,
                              '可发',
                              _fmt(r.reservedQty),
                              emphasis: true,
                            ),
                        ],
                      ),
                    if (r.shippable && !done && !financeRejected) ...[
                      const SizedBox(height: UtenSpacing.s8),
                      Align(
                        alignment: Alignment.centerRight,
                        child: UtenButton(
                          size: UtenButtonSize.small,
                          icon: Icons.local_shipping_outlined,
                          onPressed: () async {
                            await showSalesBatchShipPanel(context, ref);
                            if (mounted) _load(_page);
                          },
                          child: const Text('去发货'),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stageChip(ThemeData theme, String stage) {
    final color = salesProgressStageColor(stage, theme);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        salesProgressStageLabel(stage),
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  /// 「等待财务审核」徽章（V300：财务确认前替代阶段 chip 与排产进度）。
  Widget _financePendingChip(ThemeData theme) {
    final color = theme.colorScheme.onSurfaceVariant;
    return Container(
      key: const ValueKey('sales-order-progress-finance-pending'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '等待财务审核',
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _financeRejectedChip(ThemeData theme) {
    final color = theme.colorScheme.error;
    return Container(
      key: const ValueKey('sales-order-progress-finance-rejected'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        '财务驳回',
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _kv(
    ThemeData theme,
    String label,
    String value, {
    bool emphasis = false,
  }) {
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$label ',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          TextSpan(
            text: value,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: emphasis ? theme.colorScheme.primary : null,
            ),
          ),
        ],
      ),
    );
  }

  Widget _pager(ThemeData theme) {
    final r = _result!;
    final hasPrev = r.page > 1;
    final hasNext = r.page < r.totalPages;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s12,
        vertical: UtenSpacing.s8,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          UtenButton(
            type: UtenButtonType.ghost,
            size: UtenButtonSize.small,
            onPressed: hasPrev ? () => _load(_page - 1) : null,
            child: const Text('上一页'),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s12),
            child: Text(
              '${r.page} / ${r.totalPages}(共 ${r.total})',
              style: theme.textTheme.bodySmall,
            ),
          ),
          UtenButton(
            type: UtenButtonType.ghost,
            size: UtenButtonSize.small,
            onPressed: hasNext ? () => _load(_page + 1) : null,
            child: const Text('下一页'),
          ),
        ],
      ),
    );
  }

  String _fmt(double v) {
    if (v == v.roundToDouble()) return v.toInt().toString();
    return v.toStringAsFixed(2);
  }
}
