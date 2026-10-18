// 采购报表页（采购管理，purchase_report:view）：月度汇总（货品×供应商×类型，MV 上卷）
// + 待交货订货汇总。明细报表复用 4 单据列表页（带日期/供应商/状态过滤）。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../core/ui/capsule_nav_metrics.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../report/shared/report_date_range.dart';

class _Monthly {
  const _Monthly(
    this.docType,
    this.ym,
    this.goodsId,
    this.supplierId,
    this.qty,
    this.amt,
  );
  final String docType;
  final String ym;
  final String? goodsId;
  final String? supplierId;
  final double qty;
  final double amt;
}

class _Pending {
  const _Pending(this.goodsId, this.colorId, this.qty, this.amt);
  final String? goodsId;
  final String? colorId;
  final double qty;
  final double amt;
}

class PurchaseReportPage extends ConsumerStatefulWidget {
  const PurchaseReportPage({super.key});

  @override
  ConsumerState<PurchaseReportPage> createState() => _PurchaseReportPageState();
}

class _PurchaseReportPageState extends ConsumerState<PurchaseReportPage> {
  String? _docType = 'ORDER'; // 订货 / 收货 RECEIPT / 退货 RETURN
  DateTime _from = defaultReportFrom();
  DateTime _to = ChinaDateTime.today();
  List<_Monthly> _monthly = const [];
  List<_Pending> _pending = const [];
  bool _loading = false;

  /// 请求代际守卫：快速连改日期/类型时旧响应不得回写（2026-10-18 修复——此前
  /// 本页是四域里唯一无守卫的报表页，慢响应晚到会覆盖新条件的结果）。
  final _requests = LatestRequestGuard();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(masterNameServiceProvider).ensureLoaded().then((_) => _load());
    });
  }

  Future<void> _load() async {
    final generation = _requests.begin();
    setState(() => _loading = true);
    final api = ref.read(apiClientProvider);
    try {
      // 月度汇总与待交货互不依赖，并行拉取（此前串行两趟往返）。
      final results = await Future.wait([
        api.getList(
          ApiEndpoints.purchaseReportMonthly,
          query: {
            'docType': _docType,
            'dateFrom': _fmt(_from),
            'dateTo': _fmt(_to),
            'limit': 200,
          },
        ),
        api.getList(ApiEndpoints.purchaseReportPending, query: {'limit': 200}),
      ]);
      final m = results[0];
      final p = results[1];
      final allGoods = <String?>[
        ...m.map((e) => e['goodsId'] as String?),
        ...p.map((e) => e['goodsId'] as String?),
      ];
      final goodsIds = allGoods
          .where((s) => s != null && s.isNotEmpty)
          .map((s) => s!)
          .toSet();
      await ref.read(masterNameServiceProvider).loadGoodsNames(goodsIds);
      if (!mounted || !_requests.isCurrent(generation)) return;
      setState(() {
        _monthly = m
            .map(
              (e) => _Monthly(
                (e['docType'] ?? '') as String,
                (e['ym'] ?? '') as String,
                e['goodsId'] as String?,
                e['supplierId'] as String?,
                (e['qty'] as num?)?.toDouble() ?? 0,
                (e['amt'] as num?)?.toDouble() ?? 0,
              ),
            )
            .toList();
        _pending = p
            .map(
              (e) => _Pending(
                e['goodsId'] as String?,
                e['colorId'] as String?,
                (e['pendingQty'] as num?)?.toDouble() ?? 0,
                (e['pendingAmt'] as num?)?.toDouble() ?? 0,
              ),
            )
            .toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted || !_requests.isCurrent(generation)) return;
      context.appApiError(e, fallback: '加载报表失败');
      setState(() => _loading = false);
    }
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  String _docLabel(String t) =>
      {'ORDER': '订货', 'RECEIPT': '收货', 'RETURN': '退货'}[t] ?? t;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(masterNameServiceProvider);
    // 懒列表：月度 200 + 待交货 200 共 400 行，此前 ListView(children:) 一次性
    // 全量构建；改为先铺一张轻量条目计划（小对象，非 widget），再按可见行构建。
    final entries = <(_RowKind, Object?)>[
      (_RowKind.toolbar, null),
      (_RowKind.dates, null),
      (_RowKind.monthlyHeader, null),
      if (_monthly.isEmpty)
        (_RowKind.empty, null)
      else
        for (final r in _monthly) (_RowKind.monthly, r),
      (_RowKind.pendingHeader, null),
      if (_pending.isEmpty)
        (_RowKind.empty, null)
      else
        for (final r in _pending) (_RowKind.pending, r),
    ];
    return Scaffold(
      appBar: UtenAppBar(
        title: '采购报表',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.purchase),
        ),
      ),
      body: SafeArea(
        child: UtenContentContainer(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 已有数据时重查不清屏：顶部细进度条随查询走（2026-10-18 口径）。
              if (_loading && entries.length > 4)
                const LinearProgressIndicator(minHeight: 2),
              Expanded(
                child: _loading && _monthly.isEmpty && _pending.isEmpty
                    ? const Center(
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      )
                    : ListView.builder(
                        // compact 悬浮胶囊避让：滚到底末卡要能越过胶囊
                        padding: EdgeInsets.fromLTRB(
                          UtenSpacing.s12,
                          UtenSpacing.s12,
                          UtenSpacing.s12,
                          math.max(
                            UtenSpacing.s12,
                            UtenCapsuleNavScope.occlusionOf(context),
                          ),
                        ),
                        itemCount: entries.length,
                        itemBuilder: (context, index) {
                          final (kind, data) = entries[index];
                          switch (kind) {
                            case _RowKind.toolbar:
                              return UtenFilterToolbar<String>(
                                segments: [
                                  for (final t in const [
                                    'ORDER',
                                    'RECEIPT',
                                    'RETURN',
                                  ])
                                    UtenFilterSegment(
                                      value: t,
                                      label: _docLabel(t),
                                    ),
                                ],
                                selected: {_docType!},
                                // 切类型即刻重查：此前只切标题不重查，数据还是旧类型。
                                onSelectionChanged: (v) {
                                  if (v == _docType) return;
                                  setState(() => _docType = v);
                                  _load();
                                },
                              );
                            case _RowKind.dates:
                              return Padding(
                                padding: const EdgeInsets.only(
                                  top: UtenSpacing.s8,
                                ),
                                child: Wrap(
                                  spacing: 12,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    TextButton.icon(
                                      onPressed: () async {
                                        final picked = await showDatePicker(
                                          context: context,
                                          initialDate: _from,
                                          firstDate: DateTime(2010),
                                          lastDate: DateTime(2100),
                                        );
                                        // 撤掉「查询」按钮后，选完日期即刻重查。
                                        if (picked != null) {
                                          setState(() => _from = picked);
                                          _load();
                                        }
                                      },
                                      icon: const Icon(
                                        Icons.event_outlined,
                                        size: 18,
                                      ),
                                      label: Text('起 ${_fmt(_from)}'),
                                    ),
                                    TextButton.icon(
                                      onPressed: () async {
                                        final picked = await showDatePicker(
                                          context: context,
                                          initialDate: _to,
                                          firstDate: DateTime(2010),
                                          lastDate: DateTime(2100),
                                        );
                                        if (picked != null) {
                                          setState(() => _to = picked);
                                          _load();
                                        }
                                      },
                                      icon: const Icon(
                                        Icons.event_outlined,
                                        size: 18,
                                      ),
                                      label: Text('止 ${_fmt(_to)}'),
                                    ),
                                  ],
                                ),
                              );
                            case _RowKind.monthlyHeader:
                              return Padding(
                                padding: const EdgeInsets.only(
                                  top: UtenSpacing.s12,
                                ),
                                child: Text(
                                  '月度汇总(${_docLabel(_docType!)}，共 ${_monthly.length} 条)',
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              );
                            case _RowKind.pendingHeader:
                              return Padding(
                                padding: const EdgeInsets.only(
                                  top: UtenSpacing.s12,
                                ),
                                child: Text(
                                  '待交货订货汇总(共 ${_pending.length} 条)',
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              );
                            case _RowKind.empty:
                              return const UtenEmpty();
                            case _RowKind.monthly:
                              final r = data as _Monthly;
                              return ListTile(
                                dense: true,
                                title: Text(names.goods(r.goodsId)),
                                subtitle: Text(
                                  '${r.ym.substring(0, 10)}  ·  ${names.supplier(r.supplierId)}',
                                  style: theme.textTheme.labelSmall,
                                ),
                                trailing: Text(
                                  '¥${r.amt.toStringAsFixed(0)} · ${r.qty.toStringAsFixed(1)}',
                                ),
                              );
                            case _RowKind.pending:
                              final r = data as _Pending;
                              return ListTile(
                                dense: true,
                                title: Text(names.goods(r.goodsId)),
                                subtitle: Text(
                                  names.color(r.colorId),
                                  style: theme.textTheme.labelSmall,
                                ),
                                trailing: Text('待 ${r.qty.toStringAsFixed(1)}'),
                              );
                          }
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _RowKind {
  toolbar,
  dates,
  monthlyHeader,
  monthly,
  pendingHeader,
  pending,
  empty,
}
