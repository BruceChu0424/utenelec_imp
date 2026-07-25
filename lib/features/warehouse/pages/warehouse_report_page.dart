// 仓库报表页（仓库管理，stock:view）：参数化查询出入库流水（stock_movements 统一账本，
// 567k 行，迁移已填充）。复用现有 GET /api/stock/movements 端点（stockQueryRepository）。
//
// 与 basic_data/pages/color_page.dart 同款布局：UtenAppBar + UtenContentContainer +
// 标题行(Icon+label+(N)) + 筛选行(仓库/类型/日期范围/查询/清除) + Expanded(MasterDataTableView)。
// 流水无 facet → 表头渲染纯标签。货品名按当页 id 批量 lookup 后解析。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../purchase/providers/master_name_provider.dart';
import '../../stock/models/stock_query.dart';
import '../../stock/repositories/stock_query_repository.dart';

class WarehouseReportPage extends ConsumerStatefulWidget {
  const WarehouseReportPage({super.key});

  @override
  ConsumerState<WarehouseReportPage> createState() =>
      _WarehouseReportPageState();
}

class _WarehouseReportPageState extends ConsumerState<WarehouseReportPage> {
  PagedResult<MovementRow>? _page;
  int _pageNum = 1;
  bool _loading = false;
  String? _error;

  // 筛选条件（_filterEpoch 用于强制 DropdownButtonFormField 在「清除」后重挂载，
  // 让 initialValue 重新生效；与 master_edit_dialog 同款 initialValue 模式）
  String? _warehouseId;
  int? _movementType;
  DateTime? _dateFrom;
  DateTime? _dateTo;
  int _filterEpoch = 0;

  /// movementType 下拉选项 (label, value)，对应 movementTypeLabel 的全部类型。
  static const _movementOptions = <(String, int)>[
    ('采购入库', 1),
    ('采购退货', 2),
    ('销售出库', 3),
    ('销售退货', 4),
    ('生产领料', 5),
    ('生产退料', 6),
    ('调拨入', 7),
    ('调拨出', 8),
    ('盘盈入', 9),
    ('盘亏出', 10),
    ('其它入', 11),
    ('其它出', 12),
    ('产成品进仓', 13),
    ('产成品出仓', 14),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 先把仓库/供应商/货品字典预加载完再拉首页数据，避免首屏名称全部是 '—'
      ref.read(masterNameServiceProvider).ensureLoaded().then((_) => _load(1));
    });
  }

  Future<void> _load(int page) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
      _pageNum = page;
    });
    try {
      final r = await ref.read(stockQueryRepositoryProvider).movements(
            page: page,
            warehouseId: _warehouseId,
            movementType: _movementType,
            dateFrom: _dateFrom == null ? null : _fmt(_dateFrom!),
            dateTo: _dateTo == null ? null : _fmt(_dateTo!),
          );
      // 货品名称按当页 id 批量解析（本地缓存，重复命中不重复请求）
      final goodsIds = r.items
          .map((m) => m.goodsId)
          .whereType<String>()
          .where((id) => id.isNotEmpty)
          .toSet();
      if (goodsIds.isNotEmpty) {
        await ref.read(masterNameServiceProvider).loadGoodsNames(goodsIds);
      }
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
        _error = '加载报表失败'; // TODO(l10n): 补 arb
        _loading = false;
      });
    }
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _pickDate(bool isFrom) async {
    final initial =
        isFrom ? (_dateFrom ?? DateTime.now()) : (_dateTo ?? DateTime.now());
    final p = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2010),
      lastDate: DateTime(2100),
    );
    if (!mounted) return;
    if (p == null) return;
    setState(() {
      if (isFrom) {
        _dateFrom = p;
      } else {
        _dateTo = p;
      }
    });
  }

  void _clearFilters() {
    setState(() {
      _warehouseId = null;
      _movementType = null;
      _dateFrom = null;
      _dateTo = null;
      _filterEpoch++;
    });
  }

  // ---- 列定义 -----------------------------------------------------------

  List<MasterColumnDef<MovementRow>> get _columns => <MasterColumnDef<MovementRow>>[
        MasterColumnDef(
            key: 'date',
            label: '日期',
            width: 120,
            value: (m) => m.transactionDate == null
                ? null
                : (m.transactionDate!.length >= 10
                    ? m.transactionDate!.substring(0, 10)
                    : m.transactionDate)),
        MasterColumnDef(
            key: 'type',
            label: '类型',
            width: 120,
            value: (m) => movementTypeLabel(m.movementType)),
        MasterColumnDef(
            key: 'goods',
            label: '货品',
            width: 220,
            value: (m) => ref.read(masterNameServiceProvider).goods(m.goodsId)),
        MasterColumnDef(
            key: 'warehouse',
            label: '仓库',
            width: 160,
            value: (m) =>
                ref.read(masterNameServiceProvider).warehouse(m.warehouseId)),
        MasterColumnDef(
            key: 'qty',
            label: '数量',
            width: 120,
            value: (m) {
              if (m.qty == null) return null;
              final sign = m.direction == 1 ? '+' : '-';
              return '$sign${m.qty!.toStringAsFixed(2)}';
            }),
        MasterColumnDef(
            key: 'amount',
            label: '金额',
            width: 140,
            value: (m) => m.amountLocal?.toStringAsFixed(2)),
      ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(masterNameServiceProvider);
    final total = _page?.total ?? 0;
    return Scaffold(
      appBar: UtenAppBar(
        title: '仓库报表', // TODO(l10n): 补 arb
        leading: UtenBackButton(
            onPressed: () => context.go(RouteName.warehouse)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新', // TODO(l10n): 补 arb
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
                // 标题行
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
                      Text('仓库报表 ($total)',
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
                // 筛选行
                Padding(
                  padding: const EdgeInsets.only(
                      bottom: UtenSpacing.s8,
                      left: UtenSpacing.s4,
                      right: UtenSpacing.s4),
                  child: Wrap(
                    spacing: UtenSpacing.s12,
                    runSpacing: UtenSpacing.s8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      // 仓库下拉
                      SizedBox(
                        width: 180,
                        child: DropdownButtonFormField<String?>(
                          key: ValueKey('wh-$_filterEpoch'),
                          initialValue: _warehouseId,
                          decoration: const InputDecoration(
                            labelText: '仓库', // TODO(l10n): 补 arb
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(
                                horizontal: 12, vertical: 10),
                          ),
                          items: <DropdownMenuItem<String?>>[
                            const DropdownMenuItem<String?>(
                                child: Text('全部仓库')), // TODO(l10n): 补 arb
                            for (final e in names.warehouseEntries.entries)
                              DropdownMenuItem<String?>(
                                  value: e.key, child: Text(e.value)),
                          ],
                          onChanged: (v) => setState(() => _warehouseId = v),
                        ),
                      ),
                      // 类型下拉
                      SizedBox(
                        width: 160,
                        child: DropdownButtonFormField<int?>(
                          key: ValueKey('mt-$_filterEpoch'),
                          initialValue: _movementType,
                          decoration: const InputDecoration(
                            labelText: '类型', // TODO(l10n): 补 arb
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(
                                horizontal: 12, vertical: 10),
                          ),
                          items: <DropdownMenuItem<int?>>[
                            const DropdownMenuItem<int?>(
                                child: Text('全部类型')), // TODO(l10n): 补 arb
                            for (final opt in _movementOptions)
                              DropdownMenuItem<int?>(
                                  value: opt.$2, child: Text(opt.$1)),
                          ],
                          onChanged: (v) => setState(() => _movementType = v),
                        ),
                      ),
                      // 起始日期
                      TextButton.icon(
                        onPressed: () => _pickDate(true),
                        icon: const Icon(Icons.event_outlined, size: 18),
                        label: Text(_dateFrom == null
                            ? '起始日期' // TODO(l10n): 补 arb
                            : '起 ${_fmt(_dateFrom!)}'),
                      ),
                      // 结束日期
                      TextButton.icon(
                        onPressed: () => _pickDate(false),
                        icon: const Icon(Icons.event_outlined, size: 18),
                        label: Text(_dateTo == null
                            ? '结束日期' // TODO(l10n): 补 arb
                            : '止 ${_fmt(_dateTo!)}'),
                      ),
                      // 清除
                      TextButton(
                        onPressed: _clearFilters,
                        child: const Text('清除'), // TODO(l10n): 补 arb
                      ),
                      // 查询
                      FilledButton.tonalIcon(
                        onPressed: () => _load(1),
                        icon: const Icon(Icons.search_rounded, size: 18),
                        label: const Text('查询'), // TODO(l10n): 补 arb
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: MasterDataTableView<MovementRow>(
                    columns: _columns,
                    items: _page?.items ?? const [],
                    facets: const {},
                    nullCounts: const {},
                    filters: const {},
                    onFilterChanged: (_, _) {},
                    onRowTap: (_) {},
                    isLoading: _loading && _page == null,
                    loadingMore: _loading && _page != null,
                    error: _error,
                    onRetry: () => _load(_pageNum),
                    emptyMessage: '暂无流水记录', // TODO(l10n): 补 arb
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
