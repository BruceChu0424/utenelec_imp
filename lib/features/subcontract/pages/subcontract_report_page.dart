// 委外报表页（委外管理，subcontract_report:view）。
//
// 三块（对应老库 17 张报表的归并）：
//  ① 月度汇总（MV 上卷，货品×委外商×类型；docType 切换覆盖 8 张汇总报表）
//     - 明细报表 ×8 复用各单据列表页（带日期/委外商/状态过滤），不在本页重复。
//  ② 委外出入状况表（综合 O：发料/材料退/收回成品/成品退/损耗 × 委外商×货品）
//
// docType 取值与后端 SubcontractReportService 对齐：INQUIRY/APPLICATION/ORDER/RECEIPT/
// RETURN/MATERIAL_ISSUE/MATERIAL_RETURN/WASTE。
//
// 布局：桌面分栏（左筛选 / 右表格）+ SegmentedButton 切换月度汇总/出入状况表。
// 数据渲染为 MasterDataTableView（Excel 风格横排列头），不再用 ListTile/Cards。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_list_two_pane.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
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
  int _view = 0; // 0=月度汇总，1=出入状况

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
    } catch (e) {
      if (!mounted) return;
      debugPrint('subcontract report load failed: $e');
      // 原先 catch(_) 吞异常只弹通用文案，无法定位 403/500/解析错。
      // 现把真实 code + message 透出（ApiException.code=FORBIDDEN/INTERNAL/NETWORK/...）。
      final msg = e is ApiException
          ? '${e.code} · ${e.message}'
          : '加载报表失败：$e';
      context.appError(msg);
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
                      Text('委外报表',
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
                // 桌面：左筛选（单据类型/日期/委外商/查询）+ 右报表内容；手机：垂直堆叠
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
                                icon: const Icon(Icons.event_outlined,
                                    size: 18),
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
                                icon: const Icon(Icons.event_outlined,
                                    size: 18),
                                label: Text('止 ${_fmt(_to)}'),
                              ),
                            ],
                          ),
                          const SizedBox(height: UtenSpacing.s12),
                          _filterLabel('委外商'),
                          SizedBox(
                            width: double.infinity,
                            child: DropdownButtonFormField<String?>(
                              initialValue: _supplierId,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                isDense: true,
                                labelText: '委外商',
                              ),
                              items: [
                                const DropdownMenuItem<String?>(
                                    child: Text('全部委外商')),
                                ...names.supplierEntries.entries.map(
                                    (e) => DropdownMenuItem<String?>(
                                          value: e.key,
                                          child: Text(e.value,
                                              maxLines: 1,
                                              overflow:
                                                  TextOverflow.ellipsis),
                                        )),
                              ],
                              onChanged: (v) =>
                                  setState(() => _supplierId = v),
                            ),
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
                    tablePane: _buildReportArea(theme, names),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 报表内容区：加载中居中转圈，否则 SegmentedButton 切换 + Expanded(表格)。
  Widget _buildReportArea(ThemeData theme, mn.MasterNameService names) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              UtenSpacing.s12, UtenSpacing.s8, UtenSpacing.s12, UtenSpacing.s4),
          child: SizedBox(
            width: double.infinity,
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(
                  value: 0,
                  icon: Icon(Icons.bar_chart_outlined),
                  label: Text('月度汇总'),
                ),
                ButtonSegment(
                  value: 1,
                  icon: Icon(Icons.swap_vert_outlined),
                  label: Text('出入状况'),
                ),
              ],
              selected: {_view},
              onSelectionChanged: (s) => setState(() => _view = s.first),
            ),
          ),
        ),
        Expanded(
          child: _view == 0 ? _monthlyTable(names) : _inOutTable(names),
        ),
      ],
    );
  }

  Widget _monthlyTable(mn.MasterNameService names) {
    return MasterDataTableView<_Monthly>(
      columns: [
        MasterColumnDef<_Monthly>(
          key: 'ym',
          label: '月份',
          width: 110,
          value: (r) =>
              r.ym.substring(0, r.ym.length >= 10 ? 10 : r.ym.length),
        ),
        MasterColumnDef<_Monthly>(
          key: 'goods',
          label: '货品',
          width: 200,
          value: (r) => names.goods(r.goodsId),
        ),
        MasterColumnDef<_Monthly>(
          key: 'supplier',
          label: '委外商',
          width: 160,
          value: (r) => names.supplier(r.supplierId),
        ),
        MasterColumnDef<_Monthly>(
          key: 'docType',
          label: '类型',
          width: 90,
          value: (r) => r.docType,
        ),
        MasterColumnDef<_Monthly>(
          key: 'qty',
          label: '数量',
          width: 100,
          value: (r) => r.qty.toStringAsFixed(2),
        ),
        MasterColumnDef<_Monthly>(
          key: 'amt',
          label: '金额',
          width: 120,
          value: (r) => r.amt.toStringAsFixed(2),
        ),
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

  Widget _inOutTable(mn.MasterNameService names) {
    return MasterDataTableView<_InOut>(
      columns: [
        MasterColumnDef<_InOut>(
          key: 'goods',
          label: '货品',
          width: 200,
          value: (r) => names.goods(r.goodsId),
        ),
        MasterColumnDef<_InOut>(
          key: 'supplier',
          label: '委外商',
          width: 160,
          value: (r) => names.supplier(r.supplierId),
        ),
        MasterColumnDef<_InOut>(
          key: 'issueQty',
          label: '发料',
          width: 90,
          value: (r) => _fmt2(r.issueQty),
        ),
        MasterColumnDef<_InOut>(
          key: 'mReturnQty',
          label: '材料退',
          width: 90,
          value: (r) => _fmt2(r.mReturnQty),
        ),
        MasterColumnDef<_InOut>(
          key: 'receiptQty',
          label: '收回成品',
          width: 100,
          value: (r) => _fmt2(r.receiptQty),
        ),
        MasterColumnDef<_InOut>(
          key: 'returnQty',
          label: '成品退',
          width: 90,
          value: (r) => _fmt2(r.returnQty),
        ),
        MasterColumnDef<_InOut>(
          key: 'wasteQty',
          label: '损耗',
          width: 90,
          value: (r) => _fmt2(r.wasteQty),
        ),
      ],
      items: _inOut,
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      onRowTap: (_) {},
    );
  }

  String _fmt2(double v) => v.toStringAsFixed(1);
}
