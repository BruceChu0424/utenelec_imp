// 销售报表页（销售管理，sales_report:view）：
//
// 后端三接口（GET /api/sales/reports/*）：
//  - /{docType}/detail?dateFrom=&dateTo=&clientId=&goodsId=&billNo=&status=&page=&size=
//    （明细行 SalesDetailRow；docType ∈ QUOTE|ORDER|SHIPMENT|OTHER_SHIPMENT|RETURN）
//  - /monthly?docType=&dateFrom=&dateTo=&clientId=&goodsId=&limit=
//    （月度汇总 MonthlySummaryRow；MV 上卷：货品 × 客户 × 类型 × 月）
//  - /pending?clientId=&limit= （待交货订货汇总 PendingRow）
//
// UI：参数条（单据类型 ChoiceChip + 起止日期 + 查询）→ 明细/汇总切换（Tab）→ 列表展示。
// RETURN（退货）的月度 qty/amt 在库为正数，前端按 docType=RETURN 取负展示。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_client.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/theme/uten_tokens.dart';
import '../config/sales_doc_config.dart';
import '../providers/master_name_provider.dart';

class _DetailRow {
  const _DetailRow(
      {this.billNo,
      this.billDate,
      this.clientId,
      this.goodsId,
      this.colorId,
      this.unitId,
      this.qty,
      this.price,
      this.amountLocal,
      this.remark});
  final String? billNo;
  final String? billDate;
  final String? clientId;
  final String? goodsId;
  final String? colorId;
  final String? unitId;
  final double? qty;
  final double? price;
  final double? amountLocal;
  final String? remark;
}

class _Monthly {
  const _Monthly(this.docType, this.ym, this.goodsId, this.clientId, this.qty,
      this.amt);
  final String docType;
  final String ym;
  final String? goodsId;
  final String? clientId;
  final double qty;
  final double amt;
}

class _Pending {
  const _Pending(this.goodsId, this.colorId, this.clientId, this.qty, this.amt);
  final String? goodsId;
  final String? colorId;
  final String? clientId;
  final double qty;
  final double amt;
}

class SalesReportPage extends ConsumerStatefulWidget {
  const SalesReportPage({super.key});

  @override
  ConsumerState<SalesReportPage> createState() => _SalesReportPageState();
}

class _SalesReportPageState extends ConsumerState<SalesReportPage> {
  /// 当前选中 docType（用于明细 + 月度过滤）。null = 全部（仅月度支持）。
  String? _docType = 'ORDER';
  DateTime _from = DateTime(DateTime.now().year, 1, 1);
  DateTime _to = DateTime.now();

  List<_DetailRow> _detail = const [];
  int _detailTotal = 0;
  final int _detailPage = 1;

  List<_Monthly> _monthly = const [];
  List<_Pending> _pending = const [];

  bool _loading = false;
  // 0=明细 1=汇总 2=待交货
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(salesMasterNameServiceProvider).ensureLoaded().then((_) => _load());
    });
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final api = ref.read(apiClientProvider);
    try {
      final goodsIds = <String>{};
      // 明细（仅当指定了 docType）
      if (_docType != null) {
        final dJson = await api.get(
            '/sales/reports/$_docType/detail',
            query: {
              'dateFrom': _fmt(_from),
              'dateTo': _fmt(_to),
              'page': _detailPage,
              'size': 50,
            });
        final items = dJson['items'];
        if (items is List) {
          final typed = items.cast<Map<String, dynamic>>();
          _detail = typed
              .map((e) => _DetailRow(
                    billNo: e['billNo'] as String?,
                    billDate: e['billDate'] as String?,
                    clientId: e['clientId'] as String?,
                    goodsId: e['goodsId'] as String?,
                    colorId: e['colorId'] as String?,
                    unitId: e['unitId'] as String?,
                    qty: (e['qty'] as num?)?.toDouble(),
                    price: (e['price'] as num?)?.toDouble(),
                    amountLocal: (e['amountLocal'] as num?)?.toDouble(),
                    remark: e['remark'] as String?,
                  ))
              .toList();
          for (final r in _detail) {
            if (r.goodsId != null) goodsIds.add(r.goodsId!);
          }
          _detailTotal = (dJson['total'] as num?)?.toInt() ?? _detail.length;
        } else {
          _detail = const [];
          _detailTotal = 0;
        }
      } else {
        _detail = const [];
        _detailTotal = 0;
      }

      // 月度（docType 取选中或全部）
      final mList = await api.getList('/sales/reports/monthly', query: {
        if (_docType != null) 'docType': _docType,
        'dateFrom': _fmt(_from),
        'dateTo': _fmt(_to),
        'limit': 200,
      });
      _monthly = mList
          .map((e) => _Monthly(
                (e['docType'] ?? '') as String,
                (e['ym'] ?? '') as String,
                e['goodsId'] as String?,
                e['clientId'] as String?,
                ((e['qty'] as num?)?.toDouble() ?? 0) *
                    ((e['docType'] == 'RETURN') ? -1 : 1),
                ((e['amt'] as num?)?.toDouble() ?? 0) *
                    ((e['docType'] == 'RETURN') ? -1 : 1),
              ))
          .toList();
      for (final m in _monthly) {
        if (m.goodsId != null) goodsIds.add(m.goodsId!);
      }

      // 待交货（订货未发，与 docType 无关）
      final pList = await api.getList('/sales/reports/pending', query: {
        'limit': 200,
      });
      _pending = pList
          .map((e) => _Pending(
                e['goodsId'] as String?,
                e['colorId'] as String?,
                e['clientId'] as String?,
                (e['pendingQty'] as num?)?.toDouble() ?? 0,
                (e['pendingAmt'] as num?)?.toDouble() ?? 0,
              ))
          .toList();
      for (final p in _pending) {
        if (p.goodsId != null) goodsIds.add(p.goodsId!);
      }

      await ref.read(salesMasterNameServiceProvider).loadGoodsNames(goodsIds);
      if (!mounted) return;
      setState(() => _loading = false);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('加载报表失败')));
      setState(() => _loading = false);
    }
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  String _docLabel(String? t) => {
        'QUOTE': '报价',
        'ORDER': '订货',
        'SHIPMENT': '出货',
        'OTHER_SHIPMENT': '其它出货',
        'RETURN': '退货',
      }[t] ??
      '全部';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(salesMasterNameServiceProvider);
    return Scaffold(
      appBar: UtenAppBar(
        title: '销售报表',
        leading: UtenBackButton(
            onPressed: () => backTo(context, defaultPath: SalesRoutePath.hub)),
      ),
      body: SafeArea(
        child: UtenContentContainer(
          child: _loading
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
              : ListView(
                  padding: const EdgeInsets.all(UtenSpacing.s12),
                  children: [
                    // 筛选条：单据类型 + 起止日期 + 查询
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        for (final t in const [
                          null,
                          'QUOTE',
                          'ORDER',
                          'SHIPMENT',
                          'OTHER_SHIPMENT',
                          'RETURN'
                        ])
                          ChoiceChip(
                            label: Text(_docLabel(t)),
                            selected: _docType == t,
                            onSelected: (_) =>
                                setState(() => _docType = t),
                          ),
                      ],
                    ),
                    const SizedBox(height: UtenSpacing.s8),
                    Wrap(
                      spacing: 12,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
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
                    // Tab：明细 / 汇总 / 待交货
                    SegmentedButton<int>(
                      segments: const [
                        ButtonSegment(
                            value: 0, label: Text('明细'),
                            icon: Icon(Icons.list_alt_outlined, size: 18)),
                        ButtonSegment(
                            value: 1, label: Text('汇总'),
                            icon: Icon(Icons.bar_chart_outlined, size: 18)),
                        ButtonSegment(
                            value: 2, label: Text('待交货'),
                            icon: Icon(Icons.local_shipping_outlined, size: 18)),
                      ],
                      selected: {_tab},
                      onSelectionChanged: (s) =>
                          setState(() => _tab = s.first),
                    ),
                    const SizedBox(height: UtenSpacing.s12),
                    if (_tab == 0)
                      _detailCard(theme, names)
                    else if (_tab == 1)
                      _monthlyCard(theme, names)
                    else
                      _pendingCard(theme, names),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _detailCard(ThemeData theme, SalesMasterNameService names) {
    if (_docType == null) {
      return _hint(theme, '请在上方选择具体单据类型后再查明细（明细按类型分表，不支持全部）。');
    }
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(UtenSpacing.s12),
            child: Text(
                '明细（${_docLabel(_docType)}）· 共 $_detailTotal 行',
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w600)),
          ),
          const Divider(height: 1),
          if (_detail.isEmpty)
            _empty(theme)
          else
            for (final r in _detail) ...[
              ListTile(
                dense: true,
                title: Text(names.goods(r.goodsId)),
                subtitle: Text(
                  [
                    (r.billDate ?? '').substring(0, 10),
                    r.billNo ?? '',
                    names.client(r.clientId),
                    names.color(r.colorId),
                  ].join('  ·  '),
                  style: const TextStyle(fontSize: 11),
                ),
                trailing: Text(
                    '¥${r.amountLocal?.toStringAsFixed(0) ?? '—'} · ${r.qty?.toStringAsFixed(1) ?? '—'}'),
              ),
              const Divider(height: 1),
            ],
        ],
      ),
    );
  }

  Widget _monthlyCard(ThemeData theme, SalesMasterNameService names) {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(UtenSpacing.s12),
            child: Text(
                '月度汇总（${_docLabel(_docType)}）',
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w600)),
          ),
          const Divider(height: 1),
          if (_monthly.isEmpty)
            _empty(theme)
          else
            for (final r in _monthly) ...[
              ListTile(
                dense: true,
                title: Text(names.goods(r.goodsId)),
                subtitle: Text(
                  '${r.ym.substring(0, 10)}  ·  ${names.client(r.clientId)}  ·  ${r.docType}',
                  style: const TextStyle(fontSize: 11),
                ),
                trailing: Text(
                    '${r.qty >= 0 ? '' : ''}¥${r.amt.toStringAsFixed(0)} · ${r.qty.toStringAsFixed(1)}'),
              ),
              const Divider(height: 1),
            ],
        ],
      ),
    );
  }

  Widget _pendingCard(ThemeData theme, SalesMasterNameService names) {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(UtenSpacing.s12),
            child: Text('待交货订货汇总',
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w600)),
          ),
          const Divider(height: 1),
          if (_pending.isEmpty)
            _empty(theme)
          else
            for (final r in _pending) ...[
              ListTile(
                dense: true,
                title: Text(names.goods(r.goodsId)),
                subtitle: Text(
                  [
                    names.color(r.colorId),
                    names.client(r.clientId),
                  ].join('  ·  '),
                  style: const TextStyle(fontSize: 11),
                ),
                trailing: Text('待 ${r.qty.toStringAsFixed(1)}'),
              ),
              const Divider(height: 1),
            ],
        ],
      ),
    );
  }

  Widget _empty(ThemeData theme) => Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Text('暂无数据',
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
      );

  Widget _hint(ThemeData theme, String text) => Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Row(
          children: [
            Icon(Icons.info_outline,
                size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: Text(text,
                  style: TextStyle(
                      color: theme.colorScheme.onSurfaceVariant)),
            ),
          ],
        ),
      );
}
