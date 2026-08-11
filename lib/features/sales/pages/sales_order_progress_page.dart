// 销售订单进度查询（订单进度查询卡）：已审订单的生产/发货进度看板。
//
// 镜像生产看板范式：每张订单一张卡，圆环 = 生产进度（已产/订货，外层总进度环口径，
// 用户决策「生产进度为主」），附阶段 chip（待排产/生产中/可发货/已发货）+ 已产/订货/已发/可发。
// 点卡弹按单排产进度底表（各产品 订货/已排/已产/已发/剩余 + 计划溯源，复用 showPlanProgressSheet）；
// 可发货行（reserved>0）显「去发货」→ 复用批量发货面板（选可发行 + 改数量，审核后 shipped_qty↑/状态推进）。
// 打开本页即把完工通知标记已读 → 完工徽章归零（已读语义）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/models/paged_result.dart';
import '../../production/widgets/progress_ring.dart';
import '../models/sales_doc.dart';
import '../models/sales_order_progress.dart';
import '../providers/sales_completion_count_provider.dart';
import '../repositories/sales_repository.dart';
import '../widgets/sales_batch_ship_panel.dart';
import '../widgets/sales_plan_progress_sheet.dart';

class SalesOrderProgressPage extends ConsumerStatefulWidget {
  const SalesOrderProgressPage({super.key});

  @override
  ConsumerState<SalesOrderProgressPage> createState() =>
      _SalesOrderProgressPageState();
}

class _SalesOrderProgressPageState
    extends ConsumerState<SalesOrderProgressPage> {
  static const _stages = <String>[
    'ALL',
    'PENDING',
    'PRODUCING',
    'SHIPPABLE',
    'SHIPPED',
  ];
  static const _size = 50;

  String _stage = 'ALL';
  int _page = 1;
  bool _loading = true;
  String? _error;
  PagedResult<SalesOrderProgressRow>? _result;

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
      final res = await ref
          .read(salesRepositoryProvider(SalesDocType.order))
          .progress(page: page, size: _size);
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

  List<SalesOrderProgressRow> get _visible {
    final items = _result?.items ?? const <SalesOrderProgressRow>[];
    if (_stage == 'ALL') return items;
    return items.where((r) => r.stage == _stage).toList();
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
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  UtenSpacing.s12,
                  UtenSpacing.s12,
                  UtenSpacing.s12,
                  UtenSpacing.s8,
                ),
                child: Wrap(
                  spacing: UtenSpacing.s8,
                  runSpacing: UtenSpacing.s4,
                  children: [
                    for (final s in _stages)
                      ChoiceChip(
                        label: Text(
                          s == 'ALL' ? '全部' : salesProgressStageLabel(s),
                        ),
                        selected: _stage == s,
                        onSelected: (_) => setState(() => _stage = s),
                      ),
                  ],
                ),
              ),
              Expanded(child: _body(theme)),
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
    final items = _visible;
    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s16),
          child: Text(
            _stage == 'ALL' ? '暂无进行中的订单' : '该阶段暂无订单',
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _load(_page),
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s12),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(height: UtenSpacing.s8),
        itemBuilder: (context, i) => _orderCard(theme, items[i]),
      ),
    );
  }

  Widget _orderCard(ThemeData theme, SalesOrderProgressRow r) {
    final done = r.stage == 'SHIPPED';
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ProgressRing(
              value: r.productionPct,
              done: done,
              size: 52,
              fontSize: 11,
            ),
            const SizedBox(width: UtenSpacing.s12),
            Expanded(
              child: InkWell(
                onTap: () => showPlanProgressSheet(context, ref, r.orderId),
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
                          _kv(theme, '可发', _fmt(r.reservedQty), emphasis: true),
                      ],
                    ),
                    if (r.shippable && !done) ...[
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
              '${r.page} / ${r.totalPages}（共 ${r.total}）',
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
