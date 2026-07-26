// 生产计划成本 / BOM 展开查询页（生产管理 · production_plan_cost:view · 严格只读）。
//
// ⚠ 本期严格只读：F_PlanCostItem 136 万行是"读多写少 + 重算昂贵"的快照表。
//   不做 BOM 展开 / 数量级联重算 / MRP 需购量（归未来成本/MRP 模块，见 docs/数据迁移/24 §四）。
//   UI 顶部标注"只读历史数据"，无新建/编辑/审核入口。
//
// 过滤驱动后端 SQL（分区裁剪 + 索引）：
//   - masterGoodsId 顶层成品（idx_ppc_mgoods，最常用）
//   - goodsId 节点物料（idx_ppc_goods）
//   - dateFrom/dateTo 分区裁剪（bill_date，按年 RANGE 分区）
//   - planItemId 经 BillID 陷阱（idx_ppc_billitem；本期 UI 不暴露，留 repository 备未来深链）
// 表格列：单据号/日期/层级/类型/货品/总需量/单套用量/单价/金额/供应。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../purchase/providers/master_name_provider.dart';
import '../../purchase/widgets/goods_picker_dialog.dart';
import '../models/production_plan_cost.dart';
import '../repositories/production_repository.dart';

class ProductionPlanCostPage extends ConsumerStatefulWidget {
  const ProductionPlanCostPage({super.key});

  @override
  ConsumerState<ProductionPlanCostPage> createState() =>
      _ProductionPlanCostPageState();
}

class _ProductionPlanCostPageState
    extends ConsumerState<ProductionPlanCostPage> {
  PagedResult<ProductionPlanCostRow>? _page;
  int _pageNum = 1;
  bool _loading = false;
  String? _error;

  // 过滤状态
  GoodsOption? _masterGoods; // 顶层成品
  GoodsOption? _nodeGoods; // 节点物料
  DateTime? _dateFrom;
  DateTime? _dateTo;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(masterNameServiceProvider).ensureLoaded();
      _load(1);
    });
  }

  String _fmt(DateTime? d) => d == null
      ? ''
      : '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  ProductionPlanCostFilter get _filter => ProductionPlanCostFilter(
        masterGoodsId: _masterGoods?.id,
        goodsId: _nodeGoods?.id,
        dateFrom: _fmt(_dateFrom),
        dateTo: _fmt(_dateTo),
      );

  Future<void> _load(int page) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
      _pageNum = page;
    });
    try {
      final r = await ref
          .read(productionPlanCostRepositoryProvider)
          .list(page: page, size: 50, filter: _filter);
      // 解析本页涉及的货品名（详情列展示用）；供应名走 dict，ensureLoaded 已缓存全量。
      final goodsIds = <String>{
        ...r.items.map((e) => e.goodsId).whereType<String>(),
        ...r.items.map((e) => e.masterGoodsId).whereType<String>(),
      };
      if (goodsIds.isNotEmpty) {
        await ref.read(masterNameServiceProvider).loadGoodsNames(goodsIds);
      }
      // 确保主档 dict（含供应商）已就绪，supplier(id) 即可解析。
      await ref.read(masterNameServiceProvider).ensureLoaded();
      if (!mounted) return;
      setState(() {
        _page = r;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '加载 BOM 成本失败';
        _loading = false;
      });
    }
  }

  Future<void> _pickMaster() async {
    final g = await showGoodsPickerDialog(context, ref);
    if (g != null) {
      setState(() => _masterGoods = g);
      _load(1);
    }
  }

  Future<void> _pickNode() async {
    final g = await showGoodsPickerDialog(context, ref);
    if (g != null) {
      setState(() => _nodeGoods = g);
      _load(1);
    }
  }

  void _clearFilters() {
    setState(() {
      _masterGoods = null;
      _nodeGoods = null;
      _dateFrom = null;
      _dateTo = null;
    });
    _load(1);
  }

  List<MasterColumnDef<ProductionPlanCostRow>> _columns(MasterNameService names) =>
      <MasterColumnDef<ProductionPlanCostRow>>[
        MasterColumnDef(
            key: 'billNo', label: '单据号', width: 140, value: (it) => it.billNo),
        MasterColumnDef(
            key: 'billDate',
            label: '日期',
            width: 110,
            value: (it) => (it.billDate ?? '').substring(0, 10)),
        MasterColumnDef(
            key: 'level',
            label: '层级',
            width: 60,
            value: (it) => it.level?.toString()),
        MasterColumnDef(
            key: 'nodeClass',
            label: '类型',
            width: 90,
            value: (it) => it.nodeClassLabel),
        MasterColumnDef(
            key: 'goods',
            label: '货品',
            width: 200,
            value: (it) => names.goods(it.goodsId)),
        MasterColumnDef(
            key: 'qty',
            label: '总需量',
            width: 100,
            value: (it) => it.qty?.toStringAsFixed(2)),
        MasterColumnDef(
            key: 'dqty',
            label: '单套用量',
            width: 100,
            value: (it) => it.dqty?.toStringAsFixed(4)),
        MasterColumnDef(
            key: 'price',
            label: '单价',
            width: 90,
            value: (it) => it.price?.toStringAsFixed(4)),
        MasterColumnDef(
            key: 'total',
            label: '金额',
            width: 110,
            value: (it) => it.total?.toStringAsFixed(2)),
        MasterColumnDef(
            key: 'supplier',
            label: '建议供应',
            width: 160,
            value: (it) => names.supplier(it.supplierId)),
      ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(masterNameServiceProvider);
    final total = _page?.total ?? 0;
    final hasFilter =
        _masterGoods != null || _nodeGoods != null || _dateFrom != null || _dateTo != null;
    return Scaffold(
      appBar: UtenAppBar(
        title: 'BOM 成本展开',
        leading: UtenBackButton(
            onPressed: () => backTo(context, defaultPath: RouteName.production)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新',
            onPressed: () => _load(_pageNum),
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer(
          child: Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            child: Column(
              children: [
                // 只读告示
                Container(
                  margin: const EdgeInsets.only(
                      left: UtenSpacing.s4,
                      right: UtenSpacing.s4,
                      bottom: UtenSpacing.s8),
                  padding: const EdgeInsets.symmetric(
                      horizontal: UtenSpacing.s12, vertical: UtenSpacing.s8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.tertiaryContainer
                        .withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: theme.colorScheme.outlineVariant),
                  ),
                  child: Row(children: [
                    Icon(Icons.history_rounded,
                        size: 18, color: theme.colorScheme.onTertiaryContainer),
                    const SizedBox(width: UtenSpacing.s8),
                    Expanded(
                      child: Text('只读历史数据 · 本期不做 BOM 展开/成本重算',
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onTertiaryContainer)),
                    ),
                  ]),
                ),
                // 过滤条
                Padding(
                  padding: const EdgeInsets.only(
                      bottom: UtenSpacing.s8,
                      left: UtenSpacing.s4,
                      right: UtenSpacing.s4),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      UtenButton(
                        type: UtenButtonType.tonal,
                        icon: Icons.inventory_2_outlined,
                        onPressed: _pickMaster,
                        child: Text(_masterGoods == null
                            ? '顶层成品'
                            : '成品: ${_masterGoods!.name ?? _masterGoods!.id.substring(0, 8)}'),
                      ),
                      UtenButton(
                        type: UtenButtonType.tonal,
                        icon: Icons.widgets_outlined,
                        onPressed: _pickNode,
                        child: Text(_nodeGoods == null
                            ? '节点物料'
                            : '物料: ${_nodeGoods!.name ?? _nodeGoods!.id.substring(0, 8)}'),
                      ),
                      TextButton.icon(
                        onPressed: () async {
                          final p = await showDatePicker(
                            context: context,
                            initialDate: _dateFrom ?? DateTime(2022),
                            firstDate: DateTime(2010),
                            lastDate: DateTime(2100),
                          );
                          if (p != null) {
                            setState(() => _dateFrom = p);
                            _load(1);
                          }
                        },
                        icon: const Icon(Icons.event_outlined, size: 18),
                        label: Text(_dateFrom == null
                            ? '起日期'
                            : '起 ${_fmt(_dateFrom)}'),
                      ),
                      TextButton.icon(
                        onPressed: () async {
                          final p = await showDatePicker(
                            context: context,
                            initialDate: _dateTo ?? DateTime.now(),
                            firstDate: DateTime(2010),
                            lastDate: DateTime(2100),
                          );
                          if (p != null) {
                            setState(() => _dateTo = p);
                            _load(1);
                          }
                        },
                        icon: const Icon(Icons.event_outlined, size: 18),
                        label: Text(_dateTo == null ? '止日期' : '止 ${_fmt(_dateTo)}'),
                      ),
                      if (hasFilter)
                        TextButton.icon(
                          onPressed: _clearFilters,
                          icon: const Icon(Icons.clear_all_rounded, size: 18),
                          label: const Text('清除'),
                        ),
                    ],
                  ),
                ),
                // 标题行
                Padding(
                  padding: const EdgeInsets.only(
                      bottom: UtenSpacing.s4,
                      left: UtenSpacing.s4,
                      right: UtenSpacing.s4),
                  child: Row(children: [
                    Icon(Icons.account_tree_outlined,
                        size: 18, color: theme.colorScheme.primary),
                    const SizedBox(width: UtenSpacing.s8),
                    Text('BOM 行 ($total)',
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600)),
                  ]),
                ),
                Expanded(
                  child: MasterDataTableView<ProductionPlanCostRow>(
                    columns: _columns(names),
                    items: _page?.items ?? const [],
                    facets: const {},
                    nullCounts: const {},
                    filters: const {},
                    onFilterChanged: (_, _) {},
                    onRowTap: (_) {
                      // 只读：tap 仅展示提示，不跳详情（详情页本期不做编辑，单行查询收益低）。
                      context.appSuccess('BOM 行只读');
                    },
                    isLoading: _loading && _page == null,
                    loadingMore: _loading && _page != null,
                    error: _error,
                    onRetry: () => _load(_pageNum),
                    emptyMessage: '暂无 BOM 成本数据',
                    currentPage: _page?.page ?? 1,
                    totalPages: _page?.totalPages ?? 1,
                    onPageChange: (p) => _load(p),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
