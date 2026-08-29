// 销售订单进度查询（订单进度查询卡）：已审订单的生产/发货进度看板。
//
// 镜像生产看板范式：每张订单一张卡，圆环 = 生产进度（已产/订货，外层总进度环口径，
// 用户决策「生产进度为主」），附阶段 chip（待排产/生产中/可发货/已发货）+ 已产/订货/已发/可发。
// 顶部指标筛选卡与任务工作台统一（MetricFilterCards）：待完成(默认)/待排产/生产中/
// 可发货/已发货，卡片即筛选、单选互斥、再点已选卡回全量视图（不显示「全部」卡）；计数走后端
// 阶段聚合计数（全量口径），阶段筛选下沉服务端（分页 total 即当前阶段真实总数）。
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
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/display_datetime.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/widgets/metric_filter_cards.dart';
import '../../production/widgets/progress_ring.dart';
import '../models/sales_doc.dart';
import '../models/sales_order_progress.dart';
import '../providers/sales_completion_count_provider.dart';
import '../repositories/sales_repository.dart';
import '../widgets/sales_batch_ship_panel.dart';

class SalesOrderProgressPage extends ConsumerStatefulWidget {
  const SalesOrderProgressPage({super.key});

  @override
  ConsumerState<SalesOrderProgressPage> createState() =>
      _SalesOrderProgressPageState();
}

class _SalesOrderProgressPageState
    extends ConsumerState<SalesOrderProgressPage> {
  /// 'OPEN' = 待完成（未发完，默认视图）；其余为具体阶段。
  /// 内部的 'ALL'（不过滤阶段）只是筛选状态，不作为卡片显示——
  /// 「全部」卡 2026-08-17 起隐藏：再点已选卡即回全量视图。
  static const _stages = <String>[
    'OPEN',
    'REJECTED',
    'PENDING',
    'PRODUCING',
    'SHIPPABLE',
    'SHIPPED',
  ];
  static const _size = 50;

  String _stage = 'OPEN';
  int _page = 1;
  bool _loading = true;
  String? _error;
  PagedResult<SalesOrderProgressRow>? _result;

  /// 阶段计数（后端全量口径）；null = 尚未返回，卡片显示 '—'。
  Map<String, int>? _stageCounts;

  @override
  void initState() {
    super.initState();
    // 打开即清完工徽章（已读语义），并加载首页。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      markSalesCompletionSeen(ref);
    });
    _load(1);
  }

  Future<void> _load(int page) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = ref.read(salesRepositoryProvider(SalesDocType.order));
      final res = await repo.progress(
        page: page,
        size: _size,
        stage: _stage == 'ALL' ? '' : _stage,
      );
      // 阶段计数失败不阻断列表（卡片降级为 '—'）。
      repo
          .progressStageCounts()
          .then((counts) {
            if (mounted) setState(() => _stageCounts = counts);
          })
          .catchError((_) {});
      if (!mounted) return;
      setState(() {
        _result = res;
        _page = page;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// 卡片单选互斥：点选即切换；再点已选卡回全量视图（内部 'ALL'，无对应卡片）。
  void _selectStage(String stage) {
    final next = _stage == stage ? 'ALL' : stage;
    if (next == _stage) return;
    setState(() => _stage = next);
    _load(1);
  }

  int? _stageCount(String stage) {
    final counts = _stageCounts;
    if (counts == null) return null;
    return switch (stage) {
      'OPEN' =>
        (counts['REJECTED'] ?? 0) +
            (counts['PENDING'] ?? 0) +
            (counts['PRODUCING'] ?? 0) +
            (counts['SHIPPABLE'] ?? 0),
      _ => counts[stage] ?? 0,
    };
  }

  List<MetricFilterCardItem> _buildStageCards() {
    const tones = <String, String>{
      'OPEN': 'warning',
      'REJECTED': 'danger',
      'PENDING': 'danger',
      'PRODUCING': 'warning',
      'SHIPPABLE': 'info',
      'SHIPPED': 'success',
    };
    const icons = <String, IconData>{
      'OPEN': Icons.pending_actions_rounded,
      'REJECTED': Icons.assignment_late_outlined,
      'PENDING': Icons.hourglass_top_rounded,
      'PRODUCING': Icons.precision_manufacturing_outlined,
      'SHIPPABLE': Icons.local_shipping_outlined,
      'SHIPPED': Icons.task_alt_rounded,
    };
    return [
      for (final s in _stages)
        MetricFilterCardItem(
          key: s,
          label: switch (s) {
            'OPEN' => '待完成',
            _ => salesProgressStageLabel(s),
          },
          value: _stageCount(s),
          tone: tones[s] ?? 'neutral',
          icon: icons[s] ?? Icons.assessment_outlined,
          selected: _stage == s,
          onTap: () => _selectStage(s),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: UtenAppBar(
        title: '订单进度查询',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.sales),
        ),
      ),
      body: SafeArea(
        child: UtenContentContainer(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                // 与货品资料/任务工作台一致的「顶部折叠 + 列表内滚」：上滑先把
                // 指标筛选卡收完腾出空间，之后订单卡列表内部滚动；分页条常驻底部。
                child: UtenCollapsingHeaderScrollView(
                  collapsingHeader: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      UtenSpacing.s12,
                      UtenSpacing.s12,
                      UtenSpacing.s12,
                      UtenSpacing.s8,
                    ),
                    // 顶部指标筛选卡：与任务工作台（仓库/采购/委外）同一组件同一交互。
                    child: MetricFilterCards(
                      key: const Key('sales-order-progress-stages'),
                      items: _buildStageCards(),
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
          child: Text(switch (_stage) {
            'OPEN' => '暂无待完成的订单',
            'ALL' => '暂无已审核的订单',
            _ => '该阶段暂无订单',
          }, style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _load(_page),
      // primary:true → 拾取外层 UtenCollapsingHeaderScrollView 注入的
      // PrimaryScrollController，参与「指标卡折叠 → 列表内滚」联动。
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
