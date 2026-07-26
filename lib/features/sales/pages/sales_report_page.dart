// 销售报表页（销售管理，sales_report:view）：
//
// 后端三接口（GET /api/sales/reports/*）：
//  - /{docType}/detail?dateFrom=&dateTo=&clientId=&goodsId=&billNo=&status=&page=&size=
//    （明细行 SalesDetailRow；docType ∈ QUOTE|ORDER|SHIPMENT|OTHER_SHIPMENT|RETURN）
//  - /monthly?docType=&dateFrom=&dateTo=&clientId=&goodsId=&limit=
//    （月度汇总 MonthlySummaryRow；MV 上卷：货品 × 客户 × 类型 × 月）
//  - /pending?clientId=&limit= （待交货订货汇总 PendingRow）
//
// UI：左筛选侧栏（单据类型 + 日期 + 查询）+ 右 Excel 风格表格（明细/汇总/待交货 切换）。
// RETURN（退货）的月度 qty/amt 在库为正数，前端按 docType=RETURN 取负展示。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_list_two_pane.dart';
import '../../../core/network/api_client.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
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
  DateTime _from = DateTime(DateTime.now().year);
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
      context.appError('加载报表失败'); // TODO(l10n): 补 arb
      setState(() => _loading = false);
    }
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  String _ym10(String s) =>
      s.isEmpty ? '' : (s.length >= 10 ? s.substring(0, 10) : s);

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
    return Scaffold(
      appBar: UtenAppBar(
        title: '销售报表',
        leading: UtenBackButton(
            onPressed: () => backTo(context, defaultPath: SalesRoutePath.hub)),
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            child: Column(
              children: [
                // 页面头：Icon + 标题
                Padding(
                  padding: const EdgeInsets.only(
                      bottom: UtenSpacing.s8,
                      left: UtenSpacing.s4,
                      right: UtenSpacing.s4),
                  child: Row(
                    children: [
                      Icon(Icons.assessment_outlined,
                          size: 18, color: theme.colorScheme.primary),
                      const SizedBox(width: UtenSpacing.s8),
                      Text('销售报表',
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
                // 桌面：左筛选侧栏（单据类型 + 日期 + 查询）+ 右 Excel 表格（明细/汇总/待交货）；手机：垂直堆叠
                Expanded(
                  child: UtenListTwoPane(
                    filterPane: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: UtenSpacing.s4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _filterLabel('单据类型'),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
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
                          const SizedBox(height: UtenSpacing.s12),
                          _filterLabel('日期范围'),
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
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
                            ],
                          ),
                          const SizedBox(height: UtenSpacing.s8),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.tonalIcon(
                              onPressed: _load,
                              icon: const Icon(Icons.search_rounded, size: 18),
                              label: const Text('查询'),
                            ),
                          ),
                        ],
                      ),
                    ),
                    tablePane: _buildReportArea(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 报表内容区：加载中居中转圈；否则 SegmentedButton(明细/汇总/待交货) + Expanded(当前 Excel 表)。
  /// MasterDataTableView 内部含 Expanded，必须放进有界高度的 Expanded 父级。
  Widget _buildReportArea() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    final Widget active = switch (_tab) {
      0 => _detailTable(),
      1 => _monthlyTable(),
      _ => _pendingTable(),
    };
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              UtenSpacing.s12, UtenSpacing.s4, UtenSpacing.s12, UtenSpacing.s4),
          child: SegmentedButton<int>(
            segments: const [
              ButtonSegment(
                  value: 0,
                  label: Text('明细'),
                  icon: Icon(Icons.list_alt_outlined, size: 18)),
              ButtonSegment(
                  value: 1,
                  label: Text('汇总'),
                  icon: Icon(Icons.bar_chart_outlined, size: 18)),
              ButtonSegment(
                  value: 2,
                  label: Text('待交货'),
                  icon: Icon(Icons.local_shipping_outlined, size: 18)),
            ],
            selected: {_tab},
            onSelectionChanged: (s) => setState(() => _tab = s.first),
          ),
        ),
        Expanded(child: active),
      ],
    );
  }

  Widget _filterLabel(String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s4),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
      ),
    );
  }

  /// 明细表（需选定具体单据类型；全部类型时不支持明细）。
  Widget _detailTable() {
    final names = ref.watch(salesMasterNameServiceProvider);
    if (_docType == null) {
      return _hint('请先在左侧选择具体单据类型后再查明细（明细按类型分表，不支持全部）。');
    }
    return MasterDataTableView<_DetailRow>(
      columns: <MasterColumnDef<_DetailRow>>[
        MasterColumnDef(
            key: 'date', label: '日期', width: 110, value: (r) => _ym10(r.billDate ?? '')),
        MasterColumnDef(
            key: 'billNo', label: '单据号', width: 140, value: (r) => r.billNo),
        MasterColumnDef(
            key: 'client',
            label: '客户',
            width: 160,
            value: (r) => names.client(r.clientId)),
        MasterColumnDef(
            key: 'goods',
            label: '货品',
            width: 200,
            value: (r) => names.goods(r.goodsId)),
        MasterColumnDef(
            key: 'color',
            label: '颜色',
            width: 90,
            value: (r) => names.color(r.colorId)),
        MasterColumnDef(
            key: 'qty',
            label: '数量',
            width: 90,
            value: (r) => r.qty?.toStringAsFixed(2)),
        MasterColumnDef(
            key: 'price',
            label: '单价',
            width: 90,
            value: (r) => r.price?.toStringAsFixed(2)),
        MasterColumnDef(
            key: 'amount',
            label: '金额',
            width: 120,
            value: (r) => r.amountLocal?.toStringAsFixed(2)),
      ],
      items: _detail,
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      onRowTap: (_) {},
      emptyMessage: '暂无明细数据（共 $_detailTotal 行，仅展示前 50 行）',
    );
  }

  /// 月度汇总表。
  Widget _monthlyTable() {
    final names = ref.watch(salesMasterNameServiceProvider);
    return MasterDataTableView<_Monthly>(
      columns: <MasterColumnDef<_Monthly>>[
        MasterColumnDef(
            key: 'ym', label: '月份', width: 110, value: (r) => _ym10(r.ym)),
        MasterColumnDef(
            key: 'goods',
            label: '货品',
            width: 200,
            value: (r) => names.goods(r.goodsId)),
        MasterColumnDef(
            key: 'client',
            label: '客户',
            width: 160,
            value: (r) => names.client(r.clientId)),
        MasterColumnDef(
            key: 'type', label: '类型', width: 90, value: (r) => r.docType),
        MasterColumnDef(
            key: 'qty',
            label: '数量',
            width: 100,
            value: (r) => r.qty.toStringAsFixed(2)),
        MasterColumnDef(
            key: 'amt',
            label: '金额',
            width: 120,
            value: (r) => r.amt.toStringAsFixed(2)),
      ],
      items: _monthly,
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      onRowTap: (_) {},
      emptyMessage: '暂无汇总数据',
    );
  }

  /// 待交货汇总表。
  Widget _pendingTable() {
    final names = ref.watch(salesMasterNameServiceProvider);
    return MasterDataTableView<_Pending>(
      columns: <MasterColumnDef<_Pending>>[
        MasterColumnDef(
            key: 'goods',
            label: '货品',
            width: 200,
            value: (r) => names.goods(r.goodsId)),
        MasterColumnDef(
            key: 'color',
            label: '颜色',
            width: 100,
            value: (r) => names.color(r.colorId)),
        MasterColumnDef(
            key: 'client',
            label: '客户',
            width: 160,
            value: (r) => names.client(r.clientId)),
        MasterColumnDef(
            key: 'qty',
            label: '待交数',
            width: 110,
            value: (r) => r.qty.toStringAsFixed(2)),
        MasterColumnDef(
            key: 'amt',
            label: '待交额',
            width: 120,
            value: (r) => r.amt.toStringAsFixed(2)),
      ],
      items: _pending,
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      onRowTap: (_) {},
      emptyMessage: '暂无待交货数据',
    );
  }

  Widget _hint(String text) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.info_outline,
                size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: UtenSpacing.s8),
            Flexible(
              child: Text(text,
                  style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
            ),
          ],
        ),
      ),
    );
  }
}
