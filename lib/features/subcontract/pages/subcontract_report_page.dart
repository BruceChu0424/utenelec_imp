// 委外报表页（委外管理，subcontract_report:view）。
//
// 三块（对应老库 17 张报表的归并）：
//  ① 月度汇总（MV 上卷，货品×委外商×类型；docType 切换覆盖 8 张汇总报表）
//     - 明细报表 ×8 复用各单据列表页（带日期/委外商/状态过滤），不在本页重复。
//  ② 委外出入状况表（综合 O：发料/材料退/收回成品/成品退/损耗 × 委外商×货品）
//
// docType 取值与后端 SubcontractReportService 对齐：INQUIRY/APPLICATION/ORDER/RECEIPT/
// RETURN/MATERIAL_ISSUE/MATERIAL_RETURN/WASTE。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/theme/uten_tokens.dart';
import '../config/subcontract_doc_config.dart';
import '../repositories/subcontract_repository.dart';
import '../../../features/purchase/providers/master_name_provider.dart'
    as mn;

class _Monthly {
  const _Monthly(this.docType, this.ym, this.goodsId, this.supplierId, this.qty,
      this.amt);
  final String docType;
  final String ym;
  final String? goodsId;
  final String? supplierId;
  final double qty;
  final double amt;
}

class _InOut {
  const _InOut(this.supplierId, this.goodsId, this.issueQty, this.mReturnQty,
      this.receiptQty, this.returnQty, this.wasteQty);
  final String? supplierId;
  final String? goodsId;
  final double issueQty; // 发料(出，负)
  final double mReturnQty; // 材料退(入，正)
  final double receiptQty; // 收回成品(入，正)
  final double returnQty; // 成品退(出，负)
  final double wasteQty; // 损耗(出，负)
}

class SubcontractReportPage extends ConsumerStatefulWidget {
  const SubcontractReportPage({super.key});

  @override
  ConsumerState<SubcontractReportPage> createState() =>
      _SubcontractReportPageState();
}

class _SubcontractReportPageState
    extends ConsumerState<SubcontractReportPage> {
  String _docType = 'RECEIPT'; // 默认进仓（收回成品，业务重点）
  DateTime _from = DateTime(DateTime.now().year);
  DateTime _to = DateTime.now();
  String? _supplierId; // 出入状况表的委外商过滤

  List<_Monthly> _monthly = const [];
  List<_InOut> _inOut = const [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(mn.masterNameServiceProvider).ensureLoaded().then((_) => _load());
    });
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final repo = ref.read(subcontractReportRepositoryProvider);
    try {
      final m = await repo.monthly(
        docType: _docType,
        dateFrom: _fmt(_from),
        dateTo: _fmt(_to),
      );
      final io = await repo.inOutStatus(
        supplierId: _supplierId,
        dateFrom: _fmt(_from),
        dateTo: _fmt(_to),
      );
      final goodsIds = <String?>[
        ...m.map((e) => e['goodsId'] as String?),
        ...io.map((e) => e['goodsId'] as String?),
      ].where((s) => s != null && s.isNotEmpty).map((s) => s!).toSet();
      await ref.read(mn.masterNameServiceProvider).loadGoodsNames(goodsIds);
      if (!mounted) return;
      setState(() {
        _monthly = m
            .map((e) => _Monthly(
                  (e['docType'] ?? '') as String,
                  ((e['ym'] ?? '')).toString(),
                  e['goodsId'] as String?,
                  e['supplierId'] as String?,
                  (e['qty'] as num?)?.toDouble() ?? 0,
                  (e['amt'] as num?)?.toDouble() ?? 0,
                ))
            .toList();
        _inOut = io
            .map((e) => _InOut(
                  e['supplierId'] as String?,
                  e['goodsId'] as String?,
                  (e['issueQty'] as num?)?.toDouble() ?? 0,
                  (e['mReturnQty'] as num?)?.toDouble() ?? 0,
                  (e['receiptQty'] as num?)?.toDouble() ?? 0,
                  (e['returnQty'] as num?)?.toDouble() ?? 0,
                  (e['wasteQty'] as num?)?.toDouble() ?? 0,
                ))
            .toList();
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('加载报表失败')));
      setState(() => _loading = false);
    }
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  String _docLabel(String t) => const {
        'INQUIRY': '询价',
        'APPLICATION': '申请',
        'ORDER': '订货',
        'RECEIPT': '进仓',
        'RETURN': '退货',
        'MATERIAL_ISSUE': '发料',
        'MATERIAL_RETURN': '材料退',
        'WASTE': '损耗',
      }[t] ??
      t;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(mn.masterNameServiceProvider);
    return Scaffold(
      appBar: UtenAppBar(
        title: '委外报表',
        leading:
            UtenBackButton(
                onPressed: () =>
                    backTo(context, defaultPath: SubcontractRoute.hub)),
      ),
      body: SafeArea(
        child: UtenContentContainer(
          child: _loading
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
              : ListView(
                  padding: const EdgeInsets.all(UtenSpacing.s12),
                  children: [
                    // 筛选条：单据类型 + 日期范围 + 查询
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        for (final t in [
                          'INQUIRY',
                          'APPLICATION',
                          'ORDER',
                          'RECEIPT',
                          'RETURN',
                          'MATERIAL_ISSUE',
                          'MATERIAL_RETURN',
                          'WASTE'
                        ])
                          ChoiceChip(
                            label: Text(_docLabel(t)),
                            selected: _docType == t,
                            onSelected: (_) => setState(() => _docType = t),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
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
                        // 出入状况表：委外商过滤
                        _supplierDropdown(names),
                        FilledButton.tonalIcon(
                          onPressed: _load,
                          icon: const Icon(Icons.search_rounded, size: 18),
                          label: const Text('查询'),
                        ),
                      ],
                    ),
                    const SizedBox(height: UtenSpacing.s12),
                    Text('月度汇总（${_docLabel(_docType)}）',
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    Card(
                      child: _monthly.isEmpty
                          ? const Padding(
                              padding: EdgeInsets.all(16),
                              child: Text('暂无数据'),
                            )
                          : ListView.separated(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              itemCount: _monthly.length,
                              separatorBuilder: (_, _) =>
                                  const Divider(height: 1),
                              itemBuilder: (ctx, i) {
                                final r = _monthly[i];
                                return ListTile(
                                  dense: true,
                                  title: Text(names.goods(r.goodsId)),
                                  subtitle: Text(
                                    '${r.ym.substring(0, r.ym.length >= 10 ? 10 : r.ym.length)}  ·  ${names.supplier(r.supplierId)}',
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                  trailing: Text(
                                      '¥${r.amt.toStringAsFixed(0)} · ${r.qty.toStringAsFixed(1)}'),
                                );
                              },
                            ),
                    ),
                    const SizedBox(height: UtenSpacing.s12),
                    Text('委外出入状况表（综合 O）',
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    Card(
                      child: _inOut.isEmpty
                          ? const Padding(
                              padding: EdgeInsets.all(16),
                              child: Text('暂无数据'),
                            )
                          : ListView.separated(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              itemCount: _inOut.length,
                              separatorBuilder: (_, _) =>
                                  const Divider(height: 1),
                              itemBuilder: (ctx, i) {
                                final r = _inOut[i];
                                return ListTile(
                                  dense: true,
                                  title: Text(names.goods(r.goodsId)),
                                  subtitle: Text(names.supplier(r.supplierId),
                                      style: const TextStyle(fontSize: 11)),
                                  trailing: SizedBox(
                                    width: 220,
                                    child: Text(
                                      [
                                        '发${_fmt2(r.issueQty)}',
                                        '退${_fmt2(r.mReturnQty)}',
                                        '收${_fmt2(r.receiptQty)}',
                                        '成退${_fmt2(r.returnQty)}',
                                        '损${_fmt2(r.wasteQty)}',
                                      ].join(' '),
                                      textAlign: TextAlign.right,
                                      style: const TextStyle(fontSize: 11),
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  /// 委外商下拉过滤（出入状况表用）。从 MasterNameService 缓存取 entries。
  Widget _supplierDropdown(mn.MasterNameService names) {
    return SizedBox(
      width: 200,
      child: DropdownButtonFormField<String?>(
        initialValue: _supplierId,
        decoration: const InputDecoration(
            isDense: true,
            labelText: '委外商',
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8)),
        items: [
          const DropdownMenuItem<String?>(child: Text('全部委外商')),
          ...names.supplierEntries.entries.map((e) => DropdownMenuItem<String?>(
                value: e.key,
                child: Text(e.value,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              )),
        ],
        onChanged: (v) => setState(() => _supplierId = v),
      ),
    );
  }

  String _fmt2(double v) => v.toStringAsFixed(1);
}
