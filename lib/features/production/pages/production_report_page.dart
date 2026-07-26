// 生产报表页（生产管理 · production_report:view）：4 报表参数化（reportType 入参）。
//
// 4 报表（hub 第二组 4 入口）：
//   - planDetail   计划明细：日期/货品/状态/单号 过滤 + 分页（production_plan_items 实时）
//   - planSummary  计划汇总：月份上卷（production_monthly_mv WHERE doc_type='PLAN'）
//   - dailyDetail  日报明细：同形（0 行，结构留位）
//   - dailySummary 日报汇总：同形（0 行）
//
// 后端明细端点返回裸数组（非 PageResponse）但支持 page/size 分页；
// 本页用"返回行数 < size 即末页"启发式判定总页数。
// 汇总端点走物化视图，仅日期过滤 + limit。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../purchase/providers/master_name_provider.dart';
import '../../purchase/widgets/goods_picker_dialog.dart';
import '../models/production_plan.dart' show productionStatusLabel;
import '../models/production_report.dart';
import '../repositories/production_repository.dart';

class ProductionReportPage extends ConsumerStatefulWidget {
  const ProductionReportPage({super.key, required this.reportType});
  final ProductionReportType reportType;

  @override
  ConsumerState<ProductionReportPage> createState() =>
      _ProductionReportPageState();
}

class _ProductionReportPageState extends ConsumerState<ProductionReportPage> {
  static const int _pageSize = 50;

  // 明细状态
  List<ProductionPlanDetailReportRow> _planDetailRows = const [];
  List<ProductionDailyDetailReportRow> _dailyDetailRows = const [];
  int _page = 1;
  int _totalPages = 1;

  // 汇总状态
  List<ProductionMonthlySummaryRow> _summaryRows = const [];

  bool _loading = false;
  String? _error;

  // 过滤
  DateTime _from = DateTime(DateTime.now().year, 1, 1);
  DateTime _to = DateTime.now();
  GoodsOption? _goods; // 货品过滤（明细用）
  String _keyword = ''; // 单号精确匹配（明细用）
  int? _statusFilter; // 父计划状态（planDetail 用）

  ProductionReportType get _type => widget.reportType;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(masterNameServiceProvider).ensureLoaded().then((_) => _load());
    });
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  ProductionReportFilter get _filter => ProductionReportFilter(
        dateFrom: _fmt(_from),
        dateTo: _fmt(_to),
        goodsId: _goods?.id,
        status: _statusFilter,
        billNo: _keyword.trim().isEmpty ? null : _keyword.trim(),
        page: _page,
        size: _pageSize,
        limit: 200,
      );

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = ref.read(productionReportRepositoryProvider);
      if (_type.isDetail) {
        if (_type == ProductionReportType.planDetail) {
          final rows = await repo.planDetail(filter: _filter);
          final goodsIds =
              rows.map((e) => e.goodsId).whereType<String>().toSet();
          if (goodsIds.isNotEmpty) {
            await ref.read(masterNameServiceProvider).loadGoodsNames(goodsIds);
          }
          if (!mounted) return;
          setState(() {
            _planDetailRows = rows;
            // 启发式：满页则假定还有下一页（保守，便于翻页；末页自然停）。
            _totalPages = rows.length >= _pageSize ? _page + 1 : _page;
            _loading = false;
          });
        } else {
          final rows = await repo.dailyDetail(filter: _filter);
          final goodsIds =
              rows.map((e) => e.goodsId).whereType<String>().toSet();
          if (goodsIds.isNotEmpty) {
            await ref.read(masterNameServiceProvider).loadGoodsNames(goodsIds);
          }
          if (!mounted) return;
          setState(() {
            _dailyDetailRows = rows;
            _totalPages = rows.length >= _pageSize ? _page + 1 : _page;
            _loading = false;
          });
        }
      } else {
        final rows = _type == ProductionReportType.planSummary
            ? await repo.planSummary(filter: _filter)
            : await repo.dailySummary(filter: _filter);
        final goodsIds = rows.map((e) => e.goodsId).whereType<String>().toSet();
        if (goodsIds.isNotEmpty) {
          await ref.read(masterNameServiceProvider).loadGoodsNames(goodsIds);
        }
        if (!mounted) return;
        setState(() {
          _summaryRows = rows;
          _loading = false;
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '加载报表失败';
        _loading = false;
      });
    }
  }

  void _resetPageAndLoad() {
    _page = 1;
    _load();
  }

  Future<void> _pickGoods() async {
    final g = await showGoodsPickerDialog(context, ref);
    if (g != null) {
      setState(() => _goods = g);
      _resetPageAndLoad();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(masterNameServiceProvider);
    return Scaffold(
      appBar: UtenAppBar(
        title: '${_type.label}报表',
        leading: UtenBackButton(
            onPressed: () => backTo(context, defaultPath: RouteName.production)),
      ),
      body: SafeArea(
        child: UtenContentContainer(
          child: Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            child: Column(
              children: [
                _filterStrip(theme),
                Expanded(
                  child: _loading && _type.isDetail && _planDetailRows.isEmpty && _dailyDetailRows.isEmpty
                      ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
                      : _loading && !_type.isDetail && _summaryRows.isEmpty
                          ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
                          : _error != null
                              ? Center(child: Text(_error!))
                              : _type.isDetail
                                  ? _detailTable(theme, names)
                                  : _summaryList(theme, names),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ────────── 过滤条 ──────────

  Widget _filterStrip(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(
          bottom: UtenSpacing.s8,
          left: UtenSpacing.s4,
          right: UtenSpacing.s4),
      child: Wrap(
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
              if (p != null) {
                setState(() => _from = p);
                _resetPageAndLoad();
              }
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
              if (p != null) {
                setState(() => _to = p);
                _resetPageAndLoad();
              }
            },
            icon: const Icon(Icons.event_outlined, size: 18),
            label: Text('止 ${_fmt(_to)}'),
          ),
          if (_type.isDetail)
            UtenButton(
              type: UtenButtonType.tonal,
              icon: Icons.inventory_2_outlined,
              onPressed: _pickGoods,
              child: Text(_goods == null
                  ? '货品过滤'
                  : '货品: ${_goods!.name ?? _goods!.id.substring(0, 8)}'),
            ),
          if (_type == ProductionReportType.planDetail) ...[
            for (final s in const [
              ['全部', null],
              ['草稿', 0],
              ['已审', 1],
              ['红冲', -1]
            ])
              ChoiceChip(
                label: Text(s[0] as String),
                selected: _statusFilter == s[1],
                onSelected: (_) {
                  setState(() => _statusFilter = s[1] as int?);
                  _resetPageAndLoad();
                },
              ),
          ],
          if (_type.isDetail)
            SizedBox(
              width: 180,
              child: UtenSearchBar(
                hint: '精确单号',
                initialValue: _keyword,
                onChanged: (v) {
                  setState(() => _keyword = v);
                  _resetPageAndLoad();
                },
              ),
            ),
        ],
      ),
    );
  }

  // ────────── 明细表 ──────────

  Widget _detailTable(ThemeData theme, MasterNameService names) {
    if (_type == ProductionReportType.planDetail) {
      return MasterDataTableView<ProductionPlanDetailReportRow>(
        columns: _planDetailColumns(names),
        items: _planDetailRows,
        facets: const {},
        nullCounts: const {},
        filters: const {},
        onFilterChanged: (_, _) {},
        onRowTap: (_) {},
        isLoading: _loading && _planDetailRows.isEmpty,
        loadingMore: _loading && _planDetailRows.isNotEmpty,
        error: _error,
        onRetry: _load,
        emptyMessage: '暂无计划明细数据',
        currentPage: _page,
        totalPages: _totalPages,
        onPageChange: (p) {
          setState(() => _page = p);
          _load();
        },
      );
    }
    return MasterDataTableView<ProductionDailyDetailReportRow>(
      columns: _dailyDetailColumns(names),
      items: _dailyDetailRows,
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      onRowTap: (_) {},
      isLoading: _loading && _dailyDetailRows.isEmpty,
      loadingMore: _loading && _dailyDetailRows.isNotEmpty,
      error: _error,
      onRetry: _load,
      emptyMessage: '暂无日报明细数据（结构留位）',
      currentPage: _page,
      totalPages: _totalPages,
      onPageChange: (p) {
        setState(() => _page = p);
        _load();
      },
    );
  }

  List<MasterColumnDef<ProductionPlanDetailReportRow>> _planDetailColumns(
          MasterNameService names) =>
      <MasterColumnDef<ProductionPlanDetailReportRow>>[
        MasterColumnDef(
            key: 'billNo', label: '单据号', width: 140, value: (it) => it.billNo),
        MasterColumnDef(
            key: 'billDate',
            label: '日期',
            width: 110,
            value: (it) => (it.billDate ?? '').substring(0, 10)),
        MasterColumnDef(
            key: 'goods',
            label: '货品',
            width: 200,
            value: (it) => names.goods(it.goodsId)),
        MasterColumnDef(
            key: 'qty',
            label: '排产量',
            width: 100,
            value: (it) => it.qty?.toStringAsFixed(2)),
        MasterColumnDef(
            key: 'oqty',
            label: '订货量',
            width: 100,
            value: (it) => it.oqty?.toStringAsFixed(2)),
        MasterColumnDef(
            key: 'iqty',
            label: '完工量',
            width: 100,
            value: (it) => it.iqty?.toStringAsFixed(2)),
        MasterColumnDef(
            key: 'planStatus',
            label: '计划状态',
            width: 90,
            value: (it) => productionStatusLabel(it.planStatus)),
      ];

  List<MasterColumnDef<ProductionDailyDetailReportRow>> _dailyDetailColumns(
          MasterNameService names) =>
      <MasterColumnDef<ProductionDailyDetailReportRow>>[
        MasterColumnDef(
            key: 'billNo', label: '单据号', width: 140, value: (it) => it.billNo),
        MasterColumnDef(
            key: 'billDate',
            label: '日期',
            width: 110,
            value: (it) => (it.billDate ?? '').substring(0, 10)),
        MasterColumnDef(
            key: 'goods',
            label: '货品',
            width: 200,
            value: (it) => names.goods(it.goodsId)),
        MasterColumnDef(
            key: 'qty',
            label: '完工量',
            width: 100,
            value: (it) => it.qty?.toStringAsFixed(2)),
        MasterColumnDef(
            key: 'total',
            label: '金额',
            width: 110,
            value: (it) => it.total?.toStringAsFixed(2)),
        MasterColumnDef(
            key: 'status',
            label: '状态',
            width: 90,
            value: (it) => productionStatusLabel(it.status)),
      ];

  // ────────── 汇总列表（MV 上卷） ──────────

  Widget _summaryList(ThemeData theme, MasterNameService names) {
    if (_summaryRows.isEmpty) {
      return Center(
        child: Text(
          _type == ProductionReportType.dailySummary
              ? '暂无日报汇总数据（结构留位）'
              : '暂无汇总数据',
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s4),
      itemCount: _summaryRows.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (ctx, i) {
        final r = _summaryRows[i];
        final ym = (r.ym ?? '').substring(0, 10);
        return ListTile(
          dense: true,
          title: Text(names.goods(r.goodsId)),
          subtitle: Text(ym, style: const TextStyle(fontSize: 11)),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_type == ProductionReportType.planSummary) ...[
                _metric('排产', r.planQtySum, theme),
                _metric('订货', r.orderQtySum, theme),
                _metric('完工', r.finishedQtySum, theme),
              ] else ...[
                _metric('完工', r.finishedQtySum, theme),
                _metric('入库', r.inboundQtySum, theme),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _metric(String label, double? v, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(left: UtenSpacing.s12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          Text((v ?? 0).toStringAsFixed(0),
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
