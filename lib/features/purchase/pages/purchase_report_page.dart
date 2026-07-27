// 采购报表页（采购管理，purchase_report:view）：月度汇总（货品×供应商×类型，MV 上卷）
// + 待交货订货汇总。明细报表复用 4 单据列表页（带日期/供应商/状态过滤）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../providers/master_name_provider.dart';
import '../../report/shared/report_date_range.dart';

class _Monthly {
  const _Monthly(this.docType, this.ym, this.goodsId, this.supplierId, this.qty, this.amt);
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
  DateTime _to = DateTime.now();
  List<_Monthly> _monthly = const [];
  List<_Pending> _pending = const [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(masterNameServiceProvider).ensureLoaded().then((_) => _load());
    });
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final api = ref.read(apiClientProvider);
    try {
      final m = await api.getList(ApiEndpoints.purchaseReportMonthly, query: {
        'docType': _docType,
        'dateFrom': _fmt(_from),
        'dateTo': _fmt(_to),
        'limit': 200,
      });
      final p = await api.getList(ApiEndpoints.purchaseReportPending, query: {'limit': 200});
      final allGoods = <String?>[
        ...m.map((e) => e['goodsId'] as String?),
        ...p.map((e) => e['goodsId'] as String?),
      ];
      final goodsIds = allGoods
          .where((s) => s != null && s.isNotEmpty)
          .map((s) => s!)
          .toSet();
      await ref.read(masterNameServiceProvider).loadGoodsNames(goodsIds);
      if (!mounted) return;
      setState(() {
        _monthly = m
            .map((e) => _Monthly(
                  (e['docType'] ?? '') as String,
                  (e['ym'] ?? '') as String,
                  e['goodsId'] as String?,
                  e['supplierId'] as String?,
                  (e['qty'] as num?)?.toDouble() ?? 0,
                  (e['amt'] as num?)?.toDouble() ?? 0,
                ))
            .toList();
        _pending = p
            .map((e) => _Pending(
                  e['goodsId'] as String?,
                  e['colorId'] as String?,
                  (e['pendingQty'] as num?)?.toDouble() ?? 0,
                  (e['pendingAmt'] as num?)?.toDouble() ?? 0,
                ))
            .toList();
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('加载报表失败')));
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
    return Scaffold(
      appBar: UtenAppBar(
        title: '采购报表',
        leading: UtenBackButton(
            onPressed: () => backTo(context, defaultPath: RouteName.purchase)),
      ),
      body: SafeArea(
        child: UtenContentContainer(
          child: _loading
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
              : ListView(
                  padding: const EdgeInsets.all(UtenSpacing.s12),
                  children: [
                    // 筛选条
                    Wrap(
                      spacing: 12,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        for (final t in const ['ORDER', 'RECEIPT', 'RETURN'])
                          ChoiceChip(
                            label: Text(_docLabel(t)),
                            selected: _docType == t,
                            onSelected: (_) => setState(() => _docType = t),
                          ),
                        TextButton.icon(
                          onPressed: () async {
                            final p = await showDatePicker(
                              context: context,
                              initialDate: _from,
                              firstDate: DateTime(2010),
                              lastDate: DateTime(2100),
                            );
                            if (p != null) setState(() => _from = p);
                          },
                          icon: const Icon(Icons.event_outlined, size: 18),
                          label: Text('起 ${_fmt(_from)}'),
                        ),
                        TextButton.icon(
                          onPressed: () async {
                            final p = await showDatePicker(
                              context: context,
                              initialDate: _to,
                              firstDate: DateTime(2010),
                              lastDate: DateTime(2100),
                            );
                            if (p != null) setState(() => _to = p);
                          },
                          icon: const Icon(Icons.event_outlined, size: 18),
                          label: Text('止 ${_fmt(_to)}'),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: _load,
                          icon: const Icon(Icons.search_rounded, size: 18),
                          label: const Text('查询'),
                        ),
                      ],
                    ),
                    const SizedBox(height: UtenSpacing.s12),
                    Text('月度汇总（${_docLabel(_docType!)}，共 ${_monthly.length} 条）',
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    if (_monthly.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('暂无数据'),
                      ),
                    for (final r in _monthly)
                      ListTile(
                        dense: true,
                        title: Text(names.goods(r.goodsId)),
                        subtitle: Text(
                          '${r.ym.substring(0, 10)}  ·  ${names.supplier(r.supplierId)}',
                          style: const TextStyle(fontSize: 11),
                        ),
                        trailing: Text(
                            '¥${r.amt.toStringAsFixed(0)} · ${r.qty.toStringAsFixed(1)}'),
                      ),
                    const SizedBox(height: UtenSpacing.s12),
                    Text('待交货订货汇总（共 ${_pending.length} 条）',
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    if (_pending.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('暂无数据'),
                      ),
                    for (final r in _pending)
                      ListTile(
                        dense: true,
                        title: Text(names.goods(r.goodsId)),
                        subtitle: Text(names.color(r.colorId),
                            style: const TextStyle(fontSize: 11)),
                        trailing: Text('待 ${r.qty.toStringAsFixed(1)}'),
                      ),
                  ],
                ),
        ),
      ),
    );
  }
}
