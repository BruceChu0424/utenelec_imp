// 生产调度与进度（合一页面，三 Tab）。
//
//  Tab1 待排产：已审订单行缺口列表（交货升序 ≤3天标红）→ 勾选/全选 → 合并排产（原调度页能力）。
//  Tab2 进行中：已审未结案计划卡片（父计划圆形总进度，点开展子计划小圆环），搜索 + 车间筛选 + 显示设置。
//  Tab3 已完成：已结案计划卡片（绿色完成标志）。
//
// 进度 = 完工入库量 ÷ 排产量（成品入库审核后即时反映）。
// 路由：/production/schedule → Tab0；/production/progress → Tab1（旧两页合并，Hub 两卡片进不同 Tab）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/models/progress_ratio.dart';
import '../../rd_task/providers/rd_task_count_provider.dart';
import '../models/production_material_analysis.dart';
import '../providers/production_board_sort_provider.dart';
import '../providers/production_pending_provider.dart';
import '../repositories/production_repository.dart';
import '../widgets/progress_ring.dart';

class ProductionBoardPage extends ConsumerStatefulWidget {
  const ProductionBoardPage({super.key, this.initialTab = 0});

  final int initialTab;

  @override
  ConsumerState<ProductionBoardPage> createState() =>
      _ProductionBoardPageState();
}

class _ProductionBoardPageState extends ConsumerState<ProductionBoardPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  late int _activeTab;

  @override
  void initState() {
    super.initState();
    _activeTab = widget.initialTab.clamp(0, 2);
    _tabController = TabController(
      length: 3,
      initialIndex: _activeTab,
      vsync: this,
    )..addListener(_handleTabChange);
  }

  void _handleTabChange() {
    final next = _tabController.index;
    if (next != _activeTab && mounted) {
      setState(() => _activeTab = next);
    }
  }

  @override
  void dispose() {
    _tabController
      ..removeListener(_handleTabChange)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: UtenAppBar(
        title: '生产调度与进度',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.production),
        ),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: '待排产'),
            Tab(text: '进行中'),
            Tab(text: '已完成'),
          ],
        ),
      ),
      body: SafeArea(
        child: TabBarView(
          controller: _tabController,
          children: [
            _PendingPanel(active: _activeTab == 0),
            _PlanPanel(closed: false, active: _activeTab == 1),
            _PlanPanel(closed: true, active: _activeTab == 2),
          ],
        ),
      ),
    );
  }
}

// ═════════════════════════ Tab1 待排产（原调度页） ═════════════════════════

class _PendingPanel extends ConsumerStatefulWidget {
  const _PendingPanel({required this.active});

  final bool active;

  @override
  ConsumerState<_PendingPanel> createState() => _PendingPanelState();
}

class _PendingPanelState extends ConsumerState<_PendingPanel> {
  static const int _maxAnalysisItems = 500;
  PagedResult<SchedulePendingRow>? _page;
  bool _loading = false;
  String? _error;
  bool _submitting = false;

  int _pageNo = 1;
  // 服务端单页上限 100；调度岗位经常一次处理大量销售订单，默认直接取满一页，
  // 表格按需构建且选择可跨页保留，最多 5 页即可组成后端允许的 500 项生成批次。
  final int _pageSize = 100;

  /// 勾选状态：orderItemId → 本次排产量（跨页保留，勾选时默认=缺口，可改）。
  final Map<String, double> _selected = {};
  final Map<String, SchedulePendingRow> _selectedRows = {};

  DateTime? _beginDate;
  DateTime? _endDate;
  DateTime? _deliverFrom; // 交货日期范围筛选（从）
  DateTime? _deliverTo; // 交货日期范围筛选（至）
  final _searchCtrl = TextEditingController();
  String _keyword = '';
  Timer? _debounce;
  bool _hasLoaded = false;

  /// 表头值筛选（当前仅 status：BOM缺失/紧急/正常）。
  Map<String, String?> _filters = {};

  /// 表头值筛选 facets（status 三桶 + 计数）。
  SchedulePendingFacets? _facets;

  /// 表头排序：列 key（deliverDate/qty/needQty/orderBillNo），null=后端默认（交货升序）。
  String? _sortKey = 'deliverDate';
  bool _sortAsc = true;

  List<SchedulePendingRow> get _rows => _page?.items ?? const [];

  @override
  void initState() {
    super.initState();
    _loadWhenActive();
  }

  @override
  void didUpdateWidget(covariant _PendingPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) _loadWhenActive();
  }

  void _loadWhenActive() {
    if (!widget.active || _hasLoaded) return;
    _hasLoaded = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  bool get _canEdit {
    final permissions = ref.read(currentPermissionsProvider);
    return permissions.contains(Perm.productionMaterialAnalysisManage);
  }

  bool get _canForward =>
      ref
          .read(currentPermissionsProvider)
          .contains(Perm.productionPlanForwardRd) ||
      ref.read(isSuperAdminProvider);

  bool _batchForwarding = false;

  /// 一键批量转发当前页所有 BOM 缺失且我未登记的行（成品，按货品去重，研发每件只收一条）。
  Future<void> _forwardAllBomGaps(List<SchedulePendingRow> rows) async {
    if (_batchForwarding) return;
    setState(() => _batchForwarding = true);
    try {
      final items = <({String goodsId, String? orderItemId})>[
        for (final r in rows)
          if (r.goodsId != null)
            (goodsId: r.goodsId!, orderItemId: r.orderItemId),
      ];
      final result = await ref
          .read(productionPlanRepositoryProvider)
          .forwardToRdBatch(items);
      final created = (result['created'] as num?)?.toInt() ?? 0;
      final reused = (result['reused'] as num?)?.toInt() ?? 0;
      if (!mounted) return;
      context.appSuccess(
        '已登记 ${items.length} 行等待研发维护'
        '${created > 0 ? '（新建 $created）' : ''}'
        '${reused > 0 ? '（复用 $reused）' : ''}',
      );
      ref.read(productionPendingCountProvider.notifier).refresh();
      ref.read(rdTaskCountProvider.notifier).refresh();
      await _load();
    } catch (_) {
      if (mounted) context.appWarning('批量转发失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _batchForwarding = false);
    }
  }

  String _fmtDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// 筛选/每页条数变化：回到第一页重新加载。
  void _reload() {
    _pageNo = 1;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final repo = ref.read(productionPlanRepositoryProvider);
    final kw = _keyword;
    final dateFrom = _deliverFrom == null ? null : _fmtDate(_deliverFrom!);
    final dateTo = _deliverTo == null ? null : _fmtDate(_deliverTo!);
    try {
      // 并行：列表（带排序/状态筛选）+ facets（仅随 keyword/日期变；服务端忽略 status/sort）
      final results = await Future.wait<dynamic>([
        repo.schedulePending(
          page: _pageNo,
          size: _pageSize,
          keyword: kw,
          dateFrom: dateFrom,
          dateTo: dateTo,
          sort: _sortKey,
          order: _sortKey == null ? null : (_sortAsc ? 'asc' : 'desc'),
          status: _filters['status'],
        ),
        repo.schedulePendingFacets(
          keyword: kw,
          dateFrom: dateFrom,
          dateTo: dateTo,
        ),
      ]);
      if (!mounted) return;
      final page = results[0] as PagedResult<SchedulePendingRow>;
      // 服务端已把越界页码回退到最后一页；与本地页码对齐
      if (page.page != _pageNo) _pageNo = page.page;
      setState(() {
        _page = page;
        _facets = results[1] as SchedulePendingFacets;
        for (final row in page.items) {
          if (_selected.containsKey(row.orderItemId)) {
            _selectedRows[row.orderItemId] = row;
          }
        }
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = productionErrorMessage(e, fallback: '加载待排产列表失败');
        _loading = false;
      });
    }
  }

  /// 表头值筛选变化（拷贝 map → set/remove key → 回第 1 页重载）。
  void _onFilterChanged(String key, String? value) {
    setState(() {
      final next = Map<String, String?>.from(_filters);
      if (value == null) {
        next.remove(key);
      } else {
        next[key] = value;
      }
      _filters = next;
    });
    _reload();
  }

  /// 表头排序变化（set sortKey/方向 → 回第 1 页重载）。
  void _onSortChange(String? column, bool ascending) {
    setState(() {
      _sortKey = column;
      _sortAsc = ascending;
    });
    _reload();
  }

  Future<void> _pickDate(bool begin) async {
    final now = ChinaDateTime.today();
    final d = await showDatePicker(
      context: context,
      initialDate: begin ? (_beginDate ?? now) : (_endDate ?? now),
      firstDate: now.subtract(const Duration(days: 30)),
      lastDate: now.add(const Duration(days: 365)),
    );
    if (d != null) setState(() => begin ? _beginDate = d : _endDate = d);
  }

  /// 交货日期范围筛选（从/至；互相纠偏）。
  Future<void> _pickDeliverDate(bool begin) async {
    final now = ChinaDateTime.today();
    final d = await showDatePicker(
      context: context,
      initialDate: begin ? (_deliverFrom ?? now) : (_deliverTo ?? now),
      firstDate: DateTime(2000),
      lastDate: now.add(const Duration(days: 365)),
    );
    if (d == null) return;
    if (begin) {
      _deliverFrom = d;
      if (_deliverTo != null && _deliverTo!.isBefore(d)) _deliverTo = null;
    } else {
      _deliverTo = d;
      if (_deliverFrom != null && _deliverFrom!.isAfter(d)) _deliverFrom = null;
    }
    _reload();
  }

  /// 建议计划：选中本页全部行后进入联合物料分析。
  Future<void> _suggestAllAndSubmit() async {
    final rows = _rows;
    if (rows.isEmpty || _submitting) return;
    final eligible = rows
        .where((row) => row.materialAnalysisId == null)
        .toList(growable: false);
    if (eligible.isEmpty) {
      context.appInfo('当前页产品都已有物料分析，请单独勾选一项继续分析');
      return;
    }
    setState(() {
      for (final r in eligible) {
        if (_selected.length >= _maxAnalysisItems &&
            !_selected.containsKey(r.orderItemId)) {
          break;
        }
        final quantity = r.needQty ?? 0;
        if (quantity > 0) {
          _selected[r.orderItemId] = quantity;
          _selectedRows[r.orderItemId] = r;
        }
      }
    });
    final skipped = rows.length - eligible.length;
    if (skipped > 0) {
      context.appInfo('已跳过 $skipped 项进行中的物料分析；它们需单独继续');
    }
    if (_selected.length >= _maxAnalysisItems &&
        eligible.any((row) => !_selected.containsKey(row.orderItemId))) {
      context.appWarning('单次联合分析最多 500 个产品，已保留前 500 项；其余请另开一个批次');
    }
    await _openMaterialAnalysis();
  }

  Future<void> _suggestFinish() async {
    final byGoods = <String, double>{};
    for (final entry in _selectedRows.entries) {
      final r = entry.value;
      final v = _selected[entry.key];
      if (v != null && r.goodsId != null) {
        byGoods[r.goodsId!] = (byGoods[r.goodsId!] ?? 0) + v;
      }
    }
    if (byGoods.isEmpty) return;
    final res = await context.guardAction(
      () => ref.read(productionPlanRepositoryProvider).suggestFinish({
        'items': [
          for (final e in byGoods.entries) {'goodsId': e.key, 'qty': e.value},
        ],
        if (_beginDate != null) 'startDate': _fmtDate(_beginDate!),
      }),
      errorFallback: '推算失败，请稍后重试',
    );
    if (!mounted || res == null) return;
    final s = res['suggestedDate']?.toString();
    if (s == null) {
      context.appWarning(res['note']?.toString() ?? '无历史工时，无法推算');
      return;
    }
    setState(() => _endDate = DateTime.tryParse(s));
    context.appInfo(
      '建议完工 $s（${res['planDays']} 天，含 BOM 缓冲 ${res['bomBufferDays']} 天）',
    );
  }

  Future<void> _openMaterialAnalysis({bool allowEmpty = false}) async {
    if (_submitting) return;
    if (_selected.isEmpty) {
      if (allowEmpty) {
        await context.push(RouteName.productionMaterialAnalysis);
        if (mounted) await _load();
      }
      return;
    }
    for (final entry in _selected.entries) {
      final r = _selectedRows[entry.key];
      final v = entry.value;
      if (r == null) {
        context.appWarning('所选行数据已变化，请刷新后重新选择');
        return;
      }
      if (v <= 0 || v > (r.needQty ?? 0) + 1e-6) {
        context.appWarning(
          '订单 ${r.orderBillNo} 排产量需在 0 ~ 缺口 '
          '${(r.needQty ?? 0).toStringAsFixed(2)} 之间',
        );
        return;
      }
    }
    setState(() => _submitting = true);
    try {
      final selectedRows = [
        for (final id in _selected.keys) _selectedRows[id]!,
      ];
      final analysisIds = selectedRows
          .map((row) => row.materialAnalysisId)
          .whereType<String>()
          .toSet();
      final canResumeSingle =
          selectedRows.length == 1 && analysisIds.length == 1;
      if (analysisIds.isNotEmpty && !canResumeSingle) {
        context.appWarning('已有物料分析的产品只能单独“继续分析”；联合分析请只选择全部未分析的产品。');
        return;
      }
      await context.push(
        RouteName.productionMaterialAnalysis,
        extra: ProductionMaterialAnalysisSeed(
          analysisId: canResumeSingle ? analysisIds.single : null,
          analysisVersion: canResumeSingle
              ? selectedRows.single.materialAnalysisVersion
              : null,
          billDate: _fmtDate(ChinaDateTime.today()),
          deliveryDate: _endDate == null ? null : _fmtDate(_endDate!),
          sources: canResumeSingle
              ? const []
              : [
                  for (final row in selectedRows)
                    MaterialAnalysisSourceInput(
                      salesOrderItemId: row.orderItemId,
                      requestedQty: _selected[row.orderItemId]!,
                      deliveryDate: row.deliverDate,
                    ),
                ],
        ),
      );
      if (!mounted) return;
      setState(() {
        _selected.clear();
        _selectedRows.clear();
      });
      await _load();
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _toggle(SchedulePendingRow r, bool on) {
    if (on &&
        !_selected.containsKey(r.orderItemId) &&
        _selected.length >= _maxAnalysisItems) {
      context.appWarning('单次联合分析最多 500 个产品；请先生成当前批次，或清空后重新选择');
      return;
    }
    setState(() {
      if (on) {
        _selected[r.orderItemId] = r.needQty ?? 0;
        _selectedRows[r.orderItemId] = r;
      } else {
        _selected.remove(r.orderItemId);
        _selectedRows.remove(r.orderItemId);
      }
    });
  }

  /// 同步桌面表格的受控多选集合。MasterDataTableView 会把跨页已选 id
  /// 一并回传；这里只为当前页新选行补齐数量/行快照，取消项则从两张表同时移除。
  void _replaceSelectedIds(Set<String> nextIds) {
    final currentRows = {for (final row in _rows) row.orderItemId: row};
    final acceptedIds = <String>{};
    for (final id in _selected.keys) {
      if (nextIds.contains(id) && acceptedIds.length < _maxAnalysisItems) {
        acceptedIds.add(id);
      }
    }
    for (final id in nextIds) {
      if (acceptedIds.length >= _maxAnalysisItems) break;
      acceptedIds.add(id);
    }
    final capped = acceptedIds.length < nextIds.length;
    setState(() {
      final removed = _selected.keys
          .where((id) => !acceptedIds.contains(id))
          .toList(growable: false);
      for (final id in removed) {
        _selected.remove(id);
        _selectedRows.remove(id);
      }
      for (final id in acceptedIds) {
        if (_selected.containsKey(id)) continue;
        final row = currentRows[id];
        final quantity = row?.needQty ?? 0;
        if (row == null || quantity <= 0) continue;
        _selected[id] = quantity;
        _selectedRows[id] = row;
      }
    });
    if (capped) {
      context.appWarning('单次联合分析最多 500 个产品，已保留前 500 项；其余请另开一个批次');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return UtenContentContainer.wide(
      child: Column(
        children: [
          // 工具行：搜索 + 交货日期范围 + 建议计划 + 刷新
          Padding(
            padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
            child: Wrap(
              spacing: UtenSpacing.s8,
              runSpacing: UtenSpacing.s8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 240,
                  child: TextField(
                    controller: _searchCtrl,
                    decoration: InputDecoration(
                      isDense: true,
                      prefixIcon: const Icon(Icons.search_rounded, size: 20),
                      hintText: '搜索订单号 / 客户 / 货品',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onChanged: (v) {
                      // 服务端筛选：400ms 防抖，避免逐字打请求
                      _debounce?.cancel();
                      _debounce = Timer(const Duration(milliseconds: 400), () {
                        _keyword = v;
                        _reload();
                      });
                    },
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: () => _pickDeliverDate(true),
                  icon: const Icon(Icons.date_range_rounded, size: 16),
                  label: Text(
                    _deliverFrom == null ? '交货从' : _fmtDate(_deliverFrom!),
                  ),
                  style: _deliverFrom != null
                      ? OutlinedButton.styleFrom(
                          foregroundColor: theme.colorScheme.primary,
                        )
                      : null,
                ),
                OutlinedButton.icon(
                  onPressed: () => _pickDeliverDate(false),
                  icon: const Icon(Icons.event_rounded, size: 16),
                  label: Text(
                    _deliverTo == null ? '交货至' : _fmtDate(_deliverTo!),
                  ),
                  style: _deliverTo != null
                      ? OutlinedButton.styleFrom(
                          foregroundColor: theme.colorScheme.primary,
                        )
                      : null,
                ),
                if (_deliverFrom != null || _deliverTo != null)
                  IconButton(
                    icon: const Icon(Icons.clear_rounded, size: 18),
                    tooltip: '清除时间筛选',
                    onPressed: () {
                      _deliverFrom = null;
                      _deliverTo = null;
                      _reload();
                    },
                  ),
                if (_canEdit)
                  TextButton.icon(
                    icon: const Icon(Icons.auto_awesome_rounded, size: 18),
                    label: Text('建议联合分析（本页 ${_rows.length} 行）'),
                    onPressed: _rows.isEmpty || _submitting
                        ? null
                        : _suggestAllAndSubmit,
                  ),
                IconButton(
                  icon: const Icon(Icons.refresh_rounded),
                  tooltip: '刷新',
                  onPressed: _load,
                ),
              ],
            ),
          ),
          Expanded(child: _list(theme)),
          if (_canEdit) _footer(theme),
        ],
      ),
    );
  }

  /// 分页条已改用 MasterDataTableView 内置分页（见 _list）。

  Widget _list(ThemeData theme) {
    final rows = _rows;
    final forwardable = _canForward
        ? rows
              .where((r) => !r.bomReady && !r.myForward && r.goodsId != null)
              .toList()
        : const <SchedulePendingRow>[];
    // 空态/错误/加载三态交给 MasterDataTableView 渲染。
    return Column(
      children: [
        if (forwardable.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
            child: Row(
              children: [
                Icon(
                  Icons.forward_to_inbox_outlined,
                  size: 16,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '当前页 ${forwardable.length} 行 BOM 缺失，一键转发工程研发部维护',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                UtenButton(
                  type: UtenButtonType.tonal,
                  size: UtenButtonSize.small,
                  onPressed: _batchForwarding
                      ? null
                      : () => _forwardAllBomGaps(forwardable),
                  child: Text(_batchForwarding ? '转发中…' : '一键转发研发'),
                ),
              ],
            ),
          ),
        Expanded(
          child: context.breakpoint.isCompact
              ? _pendingMobileList(theme, rows)
              : MasterDataTableView<SchedulePendingRow>(
                  columns: _pendingColumns,
                  items: rows,
                  selectable: _canEdit,
                  idOf: (row) =>
                      (row.needQty ?? 0) > 0 ? row.orderItemId : null,
                  selectedIds: _selected.keys.toSet(),
                  onSelectedIdsChanged: _replaceSelectedIds,
                  facets: _facets?.fields ?? const {},
                  nullCounts: const {},
                  filters: _filters,
                  onFilterChanged: _onFilterChanged,
                  rowColor: (r) {
                    if (!r.bomReady) {
                      return theme.colorScheme.errorContainer.withValues(
                        alpha: 0.45,
                      );
                    }
                    if (r.materialAnalysisId != null &&
                        (r.readyNowQty ?? 0) <= 0) {
                      return theme.colorScheme.errorContainer.withValues(
                        alpha: 0.32,
                      );
                    }
                    if (r.urgent) {
                      return theme.colorScheme.error.withValues(alpha: 0.06);
                    }
                    return null;
                  },
                  sortColumn: _sortKey,
                  sortAscending: _sortAsc,
                  onSortChange: _onSortChange,
                  isLoading: _loading,
                  error: (_error != null && rows.isEmpty) ? _error : null,
                  onRetry: _load,
                  emptyMessage:
                      _keyword.isEmpty &&
                          _deliverFrom == null &&
                          _deliverTo == null &&
                          _filters.isEmpty
                      ? '暂无待排产的订单行'
                      : '没有匹配的待排产行',
                  currentPage: _page?.page ?? _pageNo,
                  totalPages: _page?.totalPages ?? 1,
                  onPageChange: (p) {
                    _pageNo = p;
                    _load();
                  },
                ),
        ),
      ],
    );
  }

  Widget _pendingMobileList(ThemeData theme, List<SchedulePendingRow> rows) {
    if (_loading && rows.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && rows.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, color: theme.colorScheme.error),
              const SizedBox(height: UtenSpacing.s8),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: UtenSpacing.s8),
              UtenButton(
                type: UtenButtonType.tonal,
                onPressed: _load,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (rows.isEmpty) {
      return const Center(child: Text('暂无待排产的订单行'));
    }
    return ListView.separated(
      key: const Key('production-pending-mobile-list'),
      itemCount: rows.length,
      separatorBuilder: (_, _) => const SizedBox(height: UtenSpacing.s8),
      itemBuilder: (_, index) {
        final row = rows[index];
        final selected = _selected.containsKey(row.orderItemId);
        final canSelect = _canEdit && (row.needQty ?? 0) > 0;
        final analyzed =
            row.materialAnalysisId != null || row.readyNowQty != null;
        final ready = row.readyNowQty ?? 0;
        final awaitingApproval =
            (row.submittedPlanQty ?? 0) > (row.approvedPlannedQty ?? 0);
        final statusColor = !row.bomReady || (analyzed && ready <= 0)
            ? theme.colorScheme.error
            : awaitingApproval
            ? theme.colorScheme.tertiary
            : analyzed
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurfaceVariant;
        return Card(
          margin: EdgeInsets.zero,
          elevation: 0,
          color: !row.bomReady || (analyzed && ready <= 0)
              ? theme.colorScheme.errorContainer.withValues(alpha: 0.32)
              : null,
          shape: RoundedRectangleBorder(
            borderRadius: UtenRadius.mdAll,
            side: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
          child: InkWell(
            onTap: canSelect ? () => _toggle(row, !selected) : null,
            borderRadius: UtenRadius.mdAll,
            child: Padding(
              padding: const EdgeInsets.all(UtenSpacing.s12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 48,
                        height: 48,
                        child: Checkbox(
                          value: selected,
                          onChanged: !canSelect
                              ? null
                              : (value) => _toggle(row, value ?? false),
                        ),
                      ),
                      const SizedBox(width: UtenSpacing.s8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              row.goodsName ?? row.goodsCode ?? '未命名产品',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            Text(
                              [
                                row.orderBillNo,
                                row.goodsCode,
                                row.spec,
                              ].whereType<String>().join(' · '),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: UtenSpacing.s8),
                  Wrap(
                    spacing: UtenSpacing.s12,
                    runSpacing: UtenSpacing.s4,
                    children: [
                      Text('订货 ${_qtyText(row.qty)}'),
                      Text('待排 ${_qtyText(row.needQty)}'),
                      Text('交货 ${_shortDate(row.deliverDate)}'),
                    ],
                  ),
                  const SizedBox(height: UtenSpacing.s8),
                  Row(
                    children: [
                      Icon(
                        analyzed
                            ? ready > 0
                                  ? Icons.check_circle_outline
                                  : Icons.error_outline
                            : Icons.help_outline,
                        size: 18,
                        color: statusColor,
                      ),
                      const SizedBox(width: UtenSpacing.s4),
                      Expanded(
                        child: Text(
                          analyzed
                              ? '可立即生产 ${_qtyText(row.readyNowQty)} · '
                                    '预计 ${_qtyText(row.readyByDateQty)} · '
                                    '齐套 ${_ratioText(row.readinessRatio)}'
                              : '未分析 · 进入物料分析获取可生产数量',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: statusColor,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (row.materialAnalyzedAt != null)
                    Text(
                      '最后分析 ${_shortDateTime(row.materialAnalyzedAt)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  if (awaitingApproval)
                    Text(
                      '已提交 ${_qtyText(row.submittedPlanQty)} · '
                      '已批准 ${_qtyText(row.approvedPlannedQty)} · 待审批',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.tertiary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  if (selected) ...[
                    const SizedBox(height: UtenSpacing.s8),
                    _selectedQtyField(row),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 待排产表格列（**无客户列**——生产只看生产相关信息）。
  /// status 列 key 与后端 /pending?status= 及 /pending/facets 三桶对齐（值即桶 value）。
  List<MasterColumnDef<SchedulePendingRow>> get _pendingColumns => [
    MasterColumnDef(
      key: 'orderBillNo',
      label: '销售单号',
      width: 140,
      sortable: true,
      value: (r) => r.orderBillNo,
    ),
    MasterColumnDef(
      key: 'goodsName',
      label: '货品名称',
      width: 200,
      value: (r) {
        final name = r.goodsName ?? r.goodsCode ?? '—';
        return (r.spec != null && r.spec!.isNotEmpty)
            ? '$name · ${r.spec}'
            : name;
      },
    ),
    MasterColumnDef(
      key: 'qty',
      label: '订货量',
      width: 100,
      type: 'number',
      sortable: true,
      value: (r) => r.qty?.toStringAsFixed(2) ?? '—',
    ),
    MasterColumnDef(
      key: 'needQty',
      label: '缺口',
      width: 100,
      type: 'number',
      sortable: true,
      value: (r) => r.needQty?.toStringAsFixed(2) ?? '—',
    ),
    MasterColumnDef(
      key: 'readyNowQty',
      label: '可生产几个',
      width: 150,
      type: 'number',
      value: (r) => r.readyNowQty == null && r.materialAnalysisId == null
          ? '未分析'
          : '${_qtyText(r.readyNowQty)}（${_ratioText(r.readinessRatio)}）',
    ),
    MasterColumnDef(
      key: 'readyByDateQty',
      label: '预计可生产',
      width: 130,
      type: 'number',
      value: (r) => r.readyByDateQty == null ? '—' : _qtyText(r.readyByDateQty),
    ),
    MasterColumnDef(
      key: 'deliverDate',
      label: '交货日期',
      width: 120,
      type: 'date',
      sortable: true,
      value: (r) =>
          r.deliverDate == null ? '—' : r.deliverDate!.substring(0, 10),
    ),
    MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 110,
      value: (r) {
        if (!r.bomReady) return 'BOM资料异常';
        if ((r.submittedPlanQty ?? 0) > (r.approvedPlannedQty ?? 0)) {
          return '已提交·待审批';
        }
        if (r.readyNowQty == null && r.materialAnalysisId == null) {
          return '未分析';
        }
        if ((r.readyNowQty ?? 0) <= 0) return '已分析·暂不可生产';
        if (r.urgent) return '紧急';
        return '已分析';
      },
    ),
  ];

  Widget _selectedQtyField(SchedulePendingRow row) => TextFormField(
    key: ValueKey('pending-qty-${row.orderItemId}'),
    initialValue: _selected[row.orderItemId]?.toString(),
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    decoration: InputDecoration(
      labelText: '本次联合分析数量',
      helperText: '待排上限 ${_qtyText(row.needQty)}；最终可生产量由服务端预览确认',
    ),
    onChanged: (value) {
      final parsed = double.tryParse(value.trim());
      if (parsed != null) _selected[row.orderItemId] = parsed;
    },
  );

  String _qtyText(double? value) {
    if (value == null) return '—';
    if (value == value.roundToDouble()) return value.toStringAsFixed(0);
    return value
        .toStringAsFixed(4)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }

  String _ratioText(double? value) {
    if (value == null) return '—';
    final ratio = normalizeProgressRatio(value);
    return '${(ratio.clamp(0, 1) * 100).toStringAsFixed(0)}%';
  }

  String _shortDate(String? value) {
    if (value == null || value.isEmpty) return '—';
    return value.length >= 10 ? value.substring(0, 10) : value;
  }

  String _shortDateTime(String? value) {
    if (value == null || value.isEmpty) return '—';
    return value.replaceFirst('T', ' ').split('.').first;
  }

  // 旧的待排产卡片行（_pendingRow/_num，含勾选框+手填排产量）已由 MasterDataTableView 取代（见 _list）。

  Widget _footer(ThemeData theme) {
    final compact = context.breakpoint.isCompact;
    // 唯一主入口：此处只进入/恢复物料分析，正式写单仍在分析页经过
    // 路线确认、齐套预览和计划单向导，文案不能提前承诺“已生成计划”。
    final generateButton = UtenButton(
      key: const Key('pending-enter-analysis-to-generate'),
      size: UtenButtonSize.large,
      icon: _selected.isEmpty
          ? Icons.insights_rounded
          : Icons.playlist_add_check_rounded,
      isLoading: _submitting,
      onPressed: _submitting
          ? null
          : () => _openMaterialAnalysis(allowEmpty: true),
      child: Text(
        _selected.isEmpty ? '新建物料分析' : '联合分析所选 ${_selected.length} 项',
      ),
    );
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_selected.isNotEmpty)
            Row(
              children: [
                Expanded(
                  child: Text(
                    '已选 ${_selected.length} 项（最多 500 项，可跨页选择）',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                TextButton.icon(
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: _submitting
                      ? null
                      : () => setState(() {
                          _selected.clear();
                          _selectedRows.clear();
                        }),
                  icon: const Icon(Icons.clear_all_rounded),
                  label: const Text('清空已选'),
                ),
              ],
            ),
          if (!compact && _selected.isNotEmpty) ...[
            SizedBox(
              height: 86,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _selectedRows.length,
                separatorBuilder: (_, _) =>
                    const SizedBox(width: UtenSpacing.s8),
                itemBuilder: (_, index) {
                  final row = _selectedRows.values.elementAt(index);
                  return SizedBox(width: 310, child: _selectedQtyField(row));
                },
              ),
            ),
            const SizedBox(height: UtenSpacing.s8),
          ],
          if (compact) ...[
            SizedBox(width: double.infinity, child: generateButton),
          ] else
            Row(
              children: [
                Expanded(
                  child: Wrap(
                    spacing: UtenSpacing.s8,
                    runSpacing: UtenSpacing.s4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _dateBtn('开工', _beginDate, () => _pickDate(true)),
                      _dateBtn('完工', _endDate, () => _pickDate(false)),
                      IconButton(
                        constraints: const BoxConstraints(
                          minWidth: 48,
                          minHeight: 48,
                        ),
                        icon: const Icon(Icons.auto_awesome_rounded, size: 18),
                        tooltip: '建议完工日期',
                        onPressed: _selected.isEmpty ? null : _suggestFinish,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: UtenSpacing.s8),
                generateButton,
              ],
            ),
        ],
      ),
    );
  }

  Widget _dateBtn(String label, DateTime? d, VoidCallback onTap) {
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
      onPressed: onTap,
      icon: const Icon(Icons.date_range_rounded, size: 16),
      label: Text(
        d == null
            ? label
            : '$label ${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}',
      ),
    );
  }
}

// ═════════════════════ Tab2/3 进行中 / 已完成（进度卡片） ═════════════════════

/// 进行中/已完成列表排序方式（置顶的计划始终排最前）。
/// billDate=开单远→近（先开单的在前，默认）；billDateDesc=开单近→远（最新开的在前）。
enum _PlanSort { billDate, billDateDesc, deliveryDate, progress }

class _PlanPanel extends ConsumerStatefulWidget {
  const _PlanPanel({required this.closed, required this.active});

  final bool closed;
  final bool active;

  @override
  ConsumerState<_PlanPanel> createState() => _PlanPanelState();
}

class _PlanPanelState extends ConsumerState<_PlanPanel> {
  PagedResult<PlanProgressRow>? _page;
  Map<String, dynamic>? _summary;
  List<String> _workshops = const [];
  bool _loading = false;
  String? _error;

  int _pageNo = 1;
  int _pageSize = 20;

  final _searchCtrl = TextEditingController();
  String _keyword = '';
  String? _workshop; // null=全部车间
  DateTime? _from; // 开单日期范围（从）
  DateTime? _to; // 开单日期范围（至）
  Timer? _debounce;
  final Set<String> _expanded = {};
  bool _hasLoaded = false;

  /// 显示设置（Excel 列显隐思路）：卡片上哪些信息块可见。
  bool _showWorkshop = true;
  bool _showWindow = true;
  bool _showDates = true;
  bool _showQty = true;

  bool get _canEdit =>
      ref.read(currentPermissionsProvider).contains(Perm.productionPlanEdit);

  List<PlanProgressRow> get _rows => _page?.items ?? const [];

  /// 排序方式（按账号持久化偏好：默认开单远→近；置顶始终最前）。仅 build 路径可用（watch）。
  _PlanSort get _sort =>
      _PlanSort.values.asNameMap()[ref.watch(productionBoardSortProvider)] ??
      _PlanSort.billDate;

  void _setSort(_PlanSort v) {
    ref.read(productionBoardSortProvider.notifier).update(v.name);
    _reload();
  }

  @override
  void initState() {
    super.initState();
    _loadWhenActive();
  }

  @override
  void didUpdateWidget(covariant _PlanPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) _loadWhenActive();
  }

  void _loadWhenActive() {
    if (!widget.active || _hasLoaded) return;
    _hasLoaded = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  String _fmtDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// 筛选/排序/每页条数变化：回到第一页重新加载。
  void _reload() {
    _pageNo = 1;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final repo = ref.read(productionPlanRepositoryProvider);
    final sort = ref.read(productionBoardSortProvider);
    final kw = _keyword;
    final ws = _workshop ?? '';
    final from = _from == null ? null : _fmtDate(_from!);
    final to = _to == null ? null : _fmtDate(_to!);
    try {
      final results = await Future.wait([
        repo.planProgress(
          closed: widget.closed,
          sort: sort,
          page: _pageNo,
          size: _pageSize,
          keyword: kw,
          workshop: ws,
          dateFrom: from,
          dateTo: to,
        ),
        repo.planProgressSummary(
          closed: widget.closed,
          keyword: kw,
          workshop: ws,
          dateFrom: from,
          dateTo: to,
        ),
        repo.planProgressWorkshops(closed: widget.closed),
      ]);
      if (!mounted) return;
      final page = results[0] as PagedResult<PlanProgressRow>;
      // 服务端已把越界页码回退到最后一页；与本地页码不一致时对齐（如过滤后总数变少）
      if (page.page != _pageNo) {
        _pageNo = page.page;
      }
      setState(() {
        _page = page;
        _summary = results[1] as Map<String, dynamic>;
        _workshops = results[2] as List<String>;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = productionErrorMessage(e, fallback: '加载生产进度失败');
        _loading = false;
      });
    }
  }

  /// 置顶 / 重要标注：成功后重新加载（置顶影响服务端排序与分页位置）。
  Future<void> _toggleFlag(
    PlanProgressRow r, {
    bool? pinned,
    bool? important,
  }) async {
    final ok = await context.guardRun(
      () => ref
          .read(productionPlanRepositoryProvider)
          .updatePlanFlags(r.planId, pinned: pinned, important: important),
      success: pinned != null
          ? (pinned ? '已置顶' : '已取消置顶')
          : (important! ? '已标注重要' : '已取消重要标注'),
      errorFallback: '标记失败，请稍后重试',
    );
    if (ok && mounted) _load();
  }

  Future<void> _pickDate(bool begin) async {
    final now = ChinaDateTime.today();
    final d = await showDatePicker(
      context: context,
      initialDate: begin ? (_from ?? now) : (_to ?? now),
      firstDate: DateTime(2000),
      lastDate: now.add(const Duration(days: 365)),
    );
    if (d == null) return;
    if (begin) {
      _from = d;
      if (_to != null && _to!.isBefore(d)) _to = null;
    } else {
      _to = d;
      if (_from != null && _from!.isAfter(d)) _from = null;
    }
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return UtenContentContainer.wide(
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 大屏幕：左右布局（左筛选面板 / 右卡片列表）；窄屏：顶部筛选 + 下列表
          final wide = constraints.maxWidth >= 1080;
          if (wide) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 264,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(
                      vertical: UtenSpacing.s8,
                    ),
                    child: _controls(theme, vertical: true),
                  ),
                ),
                const VerticalDivider(width: 1),
                const SizedBox(width: UtenSpacing.s12),
                Expanded(child: _listPane(theme)),
              ],
            );
          }
          return Column(
            children: [
              _controls(theme, vertical: false),
              Expanded(child: _listPane(theme)),
            ],
          );
        },
      ),
    );
  }

  /// 筛选面板：搜索 / 车间 / 排序 / 开单日期范围 / 显示设置 / 刷新。
  /// vertical=true 宽屏左栏竖排；false 窄屏顶部 Wrap 横排。
  Widget _controls(ThemeData theme, {required bool vertical}) {
    if (vertical) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '筛选与排序',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: UtenSpacing.s8),
          _searchField(),
          const SizedBox(height: UtenSpacing.s8),
          _workshopDropdown(),
          const SizedBox(height: UtenSpacing.s8),
          _sortDropdown(),
          const SizedBox(height: UtenSpacing.s8),
          Align(alignment: Alignment.centerLeft, child: _dateRange()),
          const SizedBox(height: UtenSpacing.s4),
          Row(children: [_settingsMenu(), const Spacer(), _refreshBtn()]),
        ],
      );
    }
    return LayoutBuilder(
      builder: (_, constraints) {
        final compact = constraints.maxWidth < 600;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
          child: compact
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _searchField(),
                    const SizedBox(height: UtenSpacing.s8),
                    _workshopDropdown(),
                    const SizedBox(height: UtenSpacing.s8),
                    _sortDropdown(),
                    const SizedBox(height: UtenSpacing.s8),
                    _dateRange(),
                    Row(
                      children: [
                        _settingsMenu(),
                        const Spacer(),
                        _refreshBtn(),
                      ],
                    ),
                  ],
                )
              : Wrap(
                  spacing: UtenSpacing.s8,
                  runSpacing: UtenSpacing.s8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(width: 240, child: _searchField()),
                    SizedBox(width: 160, child: _workshopDropdown()),
                    SizedBox(width: 160, child: _sortDropdown()),
                    _dateRange(),
                    _settingsMenu(),
                    _refreshBtn(),
                  ],
                ),
        );
      },
    );
  }

  Widget _searchField() {
    return TextField(
      controller: _searchCtrl,
      decoration: InputDecoration(
        isDense: true,
        prefixIcon: const Icon(Icons.search_rounded, size: 20),
        hintText: '搜索计划单号 / 车间',
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      ),
      onChanged: (v) {
        // 服务端筛选：400ms 防抖，避免逐字打请求
        _debounce?.cancel();
        _debounce = Timer(const Duration(milliseconds: 400), () {
          _keyword = v;
          _reload();
        });
      },
    );
  }

  Widget _workshopDropdown() {
    // 防御：已选车间已不在最新选项里（计划结案后车间消失）时回退「全部」，避免断言
    final value = (_workshop != null && _workshops.contains(_workshop))
        ? _workshop!
        : '';
    return DropdownButtonFormField<String>(
      initialValue: value,
      decoration: const InputDecoration(
        isDense: true,
        labelText: '车间',
        border: OutlineInputBorder(),
      ),
      items: [
        const DropdownMenuItem(value: '', child: Text('全部车间')),
        for (final w in _workshops) DropdownMenuItem(value: w, child: Text(w)),
      ],
      onChanged: (v) {
        _workshop = (v == null || v.isEmpty) ? null : v;
        _reload();
      },
    );
  }

  Widget _sortDropdown() {
    return DropdownButtonFormField<_PlanSort>(
      initialValue: _sort,
      decoration: const InputDecoration(
        isDense: true,
        labelText: '排序',
        border: OutlineInputBorder(),
      ),
      items: const [
        DropdownMenuItem(value: _PlanSort.billDate, child: Text('开单远→近')),
        DropdownMenuItem(value: _PlanSort.billDateDesc, child: Text('开单近→远')),
        DropdownMenuItem(value: _PlanSort.deliveryDate, child: Text('交货日期')),
        DropdownMenuItem(value: _PlanSort.progress, child: Text('完工进度')),
      ],
      onChanged: (v) => _setSort(v ?? _PlanSort.billDate),
    );
  }

  /// 时间范围筛选（开单日期 从/至 + 清除）。
  Widget _dateRange() {
    return Wrap(
      spacing: 4,
      children: [
        OutlinedButton.icon(
          onPressed: () => _pickDate(true),
          icon: const Icon(Icons.date_range_rounded, size: 16),
          label: Text(_from == null ? '开单从' : _fmtDate(_from!)),
          style: _from != null
              ? OutlinedButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.primary,
                )
              : null,
        ),
        OutlinedButton.icon(
          onPressed: () => _pickDate(false),
          icon: const Icon(Icons.event_rounded, size: 16),
          label: Text(_to == null ? '开单至' : _fmtDate(_to!)),
          style: _to != null
              ? OutlinedButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.primary,
                )
              : null,
        ),
        if (_from != null || _to != null)
          IconButton(
            icon: const Icon(Icons.clear_rounded, size: 18),
            tooltip: '清除时间筛选',
            onPressed: () {
              _from = null;
              _to = null;
              _reload();
            },
          ),
      ],
    );
  }

  Widget _settingsMenu() {
    return PopupMenuButton<void>(
      icon: const Icon(Icons.view_column_outlined),
      tooltip: '显示设置',
      itemBuilder: (_) => [
        _checkItem(
          '车间标签',
          _showWorkshop,
          (v) => setState(() => _showWorkshop = v),
        ),
        _checkItem('工期窗口', _showWindow, (v) => setState(() => _showWindow = v)),
        _checkItem(
          '单据/交货日期',
          _showDates,
          (v) => setState(() => _showDates = v),
        ),
        _checkItem('数量明细', _showQty, (v) => setState(() => _showQty = v)),
      ],
    );
  }

  Widget _refreshBtn() {
    return IconButton(
      icon: const Icon(Icons.refresh_rounded),
      tooltip: '刷新',
      onPressed: _load,
    );
  }

  PopupMenuItem<void> _checkItem(
    String label,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return PopupMenuItem(
      child: StatefulBuilder(
        builder: (_, setM) => CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(label, style: Theme.of(context).textTheme.bodySmall),
          value: value,
          onChanged: (v) {
            setM(() {});
            onChanged(v ?? false);
            Navigator.pop(context);
          },
        ),
      ),
    );
  }

  /// 右栏：总览条 + 卡片列表 + 底部分页条。
  Widget _listPane(ThemeData theme) {
    return Column(
      children: [
        _summaryCard(theme),
        Expanded(child: _list(theme)),
        _pager(theme),
      ],
    );
  }

  /// 总览条（跨全部页的汇总，来自 /progress/summary）。
  Widget _summaryCard(ThemeData theme) {
    final count = (_summary?['count'] as num?)?.toInt() ?? _page?.total ?? 0;
    final sumQty = (_summary?['sumQty'] as num?)?.toDouble() ?? 0;
    final sumReported = (_summary?['sumReported'] as num?)?.toDouble() ?? 0;
    final sumIn = (_summary?['sumInbound'] as num?)?.toDouble() ?? 0;
    final overall = sumQty > 0 ? (sumIn / sumQty).clamp(0.0, 1.0) : 0.0;
    return Card(
      margin: const EdgeInsets.only(top: UtenSpacing.s8),
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Row(
          children: [
            ProgressRing(value: overall, size: 44),
            const SizedBox(width: UtenSpacing.s12),
            Expanded(
              child: Text(
                '${widget.closed ? '已完成' : '在产'} $count 张计划 · '
                '排产 ${_fmt(sumQty)} · 已报工 ${_fmt(sumReported)} · '
                '已入库 ${_fmt(sumIn)}',
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 底部分页条：总数 + 每页条数 + 翻页。
  Widget _pager(ThemeData theme) {
    final p = _page;
    final total = p?.total ?? 0;
    final pages = p?.totalPages ?? 0;
    final pageSize = DropdownButton<int>(
      value: _pageSize,
      underline: const SizedBox.shrink(),
      items: const [
        DropdownMenuItem(value: 20, child: Text('20 条/页')),
        DropdownMenuItem(value: 50, child: Text('50 条/页')),
        DropdownMenuItem(value: 100, child: Text('100 条/页')),
      ],
      onChanged: (v) {
        if (v == null || v == _pageSize) return;
        _pageSize = v;
        _reload();
      },
    );
    final pageControls = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: const Icon(Icons.chevron_left_rounded),
          tooltip: '上一页',
          onPressed: _pageNo > 1 && !_loading
              ? () {
                  _pageNo--;
                  _load();
                }
              : null,
        ),
        Text(
          pages == 0 ? '0 / 0' : '$_pageNo / $pages',
          style: theme.textTheme.bodyMedium,
        ),
        IconButton(
          icon: const Icon(Icons.chevron_right_rounded),
          tooltip: '下一页',
          onPressed: _pageNo < pages && !_loading
              ? () {
                  _pageNo++;
                  _load();
                }
              : null,
        ),
      ],
    );
    return LayoutBuilder(
      builder: (_, constraints) => Padding(
        padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s4),
        child: constraints.maxWidth < 600
            ? Column(
                children: [
                  Row(
                    children: [
                      Text(
                        '共 $total 张',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const Spacer(),
                      pageSize,
                    ],
                  ),
                  pageControls,
                ],
              )
            : Row(
                children: [
                  Text(
                    '共 $total 张',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  pageSize,
                  pageControls,
                ],
              ),
      ),
    );
  }

  Widget _list(ThemeData theme) {
    if (_loading && _page == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    if (_error != null && _page == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            const SizedBox(height: UtenSpacing.s8),
            UtenButton(
              type: UtenButtonType.tonal,
              onPressed: _load,
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    final rows = _rows;
    if (rows.isEmpty) {
      return Center(
        child: Text(
          widget.closed
              ? '暂无已完成计划'
              : (_keyword.isEmpty &&
                        _workshop == null &&
                        _from == null &&
                        _to == null
                    ? '暂无在产计划（已审未结案的计划会出现在这里）'
                    : '没有匹配的计划'),
        ),
      );
    }
    return Stack(
      children: [
        ListView(
          padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
          children: [for (final r in rows) _planCard(theme, r)],
        ),
        if (_loading)
          const Align(
            alignment: Alignment.topCenter,
            child: LinearProgressIndicator(minHeight: 2),
          ),
      ],
    );
  }

  Widget _planCard(ThemeData theme, PlanProgressRow r) {
    final pct = r.percent.clamp(0.0, 1.0);
    final done = widget.closed || pct >= 1.0;
    final overdue = r.overdue && !done; // 已过交货日：整卡红色标注
    final urgent = r.urgent && !done && !overdue; // 交货 ≤3 天未逾期：浅色提醒
    final expanded = _expanded.contains(r.planId);
    final deliver = r.deliveryDate == null
        ? '交货未定'
        : '交货 ${r.deliveryDate!.substring(0, 10)}';
    final window = (r.planBeginDate == null && r.planEndDate == null)
        ? null
        : '${r.planBeginDate?.substring(0, 10) ?? '？'} ~ ${r.planEndDate?.substring(0, 10) ?? '？'}';
    return Card(
      margin: const EdgeInsets.only(top: UtenSpacing.s8),
      color: overdue
          ? theme.colorScheme.error.withValues(alpha: 0.10)
          : urgent
          ? theme.colorScheme.error.withValues(alpha: 0.04)
          : null,
      shape: overdue
          ? RoundedRectangleBorder(
              side: BorderSide(color: theme.colorScheme.error, width: 1.2),
              borderRadius: UtenRadius.lgAll,
            )
          : null,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          children: [
            InkWell(
              borderRadius: UtenRadius.mdAll,
              onTap: () => _openPlanDetail(r.planId),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ProgressRing(value: pct, done: done),
                  const SizedBox(width: UtenSpacing.s12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            if (r.pinned)
                              Padding(
                                padding: const EdgeInsets.only(right: 4),
                                child: Icon(
                                  Icons.push_pin_rounded,
                                  size: 14,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            if (r.important)
                              const Padding(
                                padding: EdgeInsets.only(right: 4),
                                child: Icon(
                                  Icons.star_rounded,
                                  size: 16,
                                  color: Colors.amber,
                                ),
                              ),
                            Flexible(
                              child: Text(
                                r.billNo ?? '—',
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                            ),
                            const SizedBox(width: UtenSpacing.s8),
                            _statusChip(theme, r, done, overdue: overdue),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: UtenSpacing.s12,
                          runSpacing: 2,
                          children: [
                            if (_showWorkshop &&
                                r.workshopName != null &&
                                r.workshopName!.isNotEmpty)
                              _meta(
                                theme,
                                Icons.factory_outlined,
                                r.workshopName!,
                              ),
                            if (_showDates)
                              _meta(
                                theme,
                                Icons.event_outlined,
                                deliver,
                                color: r.urgent && !done
                                    ? theme.colorScheme.error
                                    : null,
                                bold: overdue,
                              ),
                            if (_showDates && r.billDate != null)
                              _meta(
                                theme,
                                Icons.edit_calendar_outlined,
                                '开单 ${r.billDate!.substring(0, 10)}',
                              ),
                            if (_showWindow && window != null)
                              _meta(
                                theme,
                                Icons.date_range_rounded,
                                '工期 $window',
                              ),
                            _meta(
                              theme,
                              Icons.list_alt_outlined,
                              '${r.lineCount} 行',
                            ),
                            if (r.materialState != null)
                              _materialMeta(
                                theme,
                                state: r.materialState!,
                                readyQty: r.materialReadyQty,
                                totalQty: r.materialTotalQty,
                                readySegments: r.materialReadySegmentCount,
                                totalSegments: r.materialSegmentCount,
                                canStartNow: r.canStartNow,
                              ),
                            if ((r.todayQty ?? 0) > 0)
                              _meta(
                                theme,
                                Icons.today_rounded,
                                '今日入库 +${_fmt(r.todayQty)}',
                                color: Colors.green.shade700,
                                bold: true,
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (_showQty)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '已入库 ${_fmt(r.inboundQty)}',
                          style: theme.textTheme.bodyMedium,
                        ),
                        Text(
                          '已报工 ${_fmt(r.reportedQty)}',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        Text(
                          '排产 ${_fmt(r.totalQty)}',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  if (_canEdit)
                    PopupMenuButton<String>(
                      icon: const Icon(Icons.more_vert_rounded, size: 18),
                      tooltip: '标记',
                      onSelected: (v) {
                        if (v == 'pin') {
                          _toggleFlag(r, pinned: !r.pinned);
                        } else if (v == 'important') {
                          _toggleFlag(r, important: !r.important);
                        }
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'pin',
                          child: ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(
                              Icons.push_pin_outlined,
                              size: 18,
                            ),
                            title: Text(r.pinned ? '取消置顶' : '置顶'),
                          ),
                        ),
                        PopupMenuItem(
                          value: 'important',
                          child: ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(
                              Icons.star_outline_rounded,
                              size: 18,
                            ),
                            title: Text(r.important ? '取消重要标注' : '标注重要'),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
            if (r.subplans.isNotEmpty) ...[
              const Divider(height: UtenSpacing.s16),
              InkWell(
                borderRadius: UtenRadius.mdAll,
                onTap: () => setState(
                  () => expanded
                      ? _expanded.remove(r.planId)
                      : _expanded.add(r.planId),
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Row(
                    children: [
                      Icon(
                        expanded
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                        size: 18,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '子计划 ${r.subplans.length} 张（点开展示进度）',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (expanded)
                for (final s in r.subplans) _subplanRow(theme, s),
            ],
          ],
        ),
      ),
    );
  }

  Widget _subplanRow(ThemeData theme, SubPlanProgress s) {
    final pct = s.percent.clamp(0.0, 1.0);
    final done = s.closed || pct >= 1.0;
    final identity = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          s.billNo ?? '—',
          style: theme.textTheme.bodyLarge?.copyWith(
            fontWeight: FontWeight.w700,
            color: theme.colorScheme.primary,
            decoration: s.status == -1 ? TextDecoration.lineThrough : null,
          ),
        ),
        if (s.workshopName != null && s.workshopName!.isNotEmpty)
          Text(
            s.workshopName!,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
    final quantities = Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          '已报工 ${_fmt(s.reportedQty)}',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Text(
          '已入库 ${_fmt(s.inboundQty)} / 排产 ${_fmt(s.totalQty)}',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
    final material = s.materialState == null
        ? null
        : _materialMeta(
            theme,
            state: s.materialState!,
            readyQty: s.materialReadyQty,
            totalQty: s.materialTotalQty,
            readySegments: s.materialReadySegmentCount,
            totalSegments: s.materialSegmentCount,
            canStartNow: s.canStartNow,
          );
    return InkWell(
      borderRadius: UtenRadius.mdAll,
      onTap: () => _openPlanDetail(s.planId),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            vertical: UtenSpacing.s4,
            horizontal: UtenSpacing.s8,
          ),
          child: LayoutBuilder(
            builder: (_, constraints) {
              final compact = constraints.maxWidth < 600;
              final chevron = Icon(
                Icons.chevron_right_rounded,
                size: 24,
                color: theme.colorScheme.onSurfaceVariant,
              );
              if (compact) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        ProgressRing(
                          value: pct,
                          size: 42,
                          fontSize: 11,
                          done: done,
                        ),
                        const SizedBox(width: UtenSpacing.s8),
                        Expanded(child: identity),
                        _miniStatus(theme, s, done),
                        const SizedBox(width: UtenSpacing.s4),
                        chevron,
                      ],
                    ),
                    const SizedBox(height: UtenSpacing.s8),
                    Wrap(
                      spacing: UtenSpacing.s12,
                      runSpacing: UtenSpacing.s8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          '已报工 ${_fmt(s.reportedQty)}',
                          style: theme.textTheme.bodyMedium,
                        ),
                        Text(
                          '已入库 ${_fmt(s.inboundQty)} / 排产 ${_fmt(s.totalQty)}',
                          style: theme.textTheme.bodyMedium,
                        ),
                        ?material,
                      ],
                    ),
                  ],
                );
              }
              return Row(
                children: [
                  ProgressRing(value: pct, size: 40, fontSize: 11, done: done),
                  const SizedBox(width: UtenSpacing.s8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [identity, ?material],
                    ),
                  ),
                  quantities,
                  const SizedBox(width: UtenSpacing.s8),
                  _miniStatus(theme, s, done),
                  const SizedBox(width: UtenSpacing.s4),
                  chevron,
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Future<void> _openPlanDetail(String rawPlanId) async {
    final planId = rawPlanId.trim();
    if (planId.isEmpty) {
      context.appError('生产计划链接异常，请刷新后重试', force: true);
      return;
    }
    try {
      await context.push(RoutePath.productionPlanDetail(planId));
    } catch (_) {
      if (mounted) context.appError('无法打开生产计划，请刷新后重试', force: true);
    }
  }

  Widget _statusChip(
    ThemeData theme,
    PlanProgressRow r,
    bool done, {
    bool overdue = false,
  }) {
    final (label, color) = done
        ? ('已完成 ✓', Colors.green)
        : overdue
        ? ('已逾期', theme.colorScheme.error)
        : r.urgent
        ? ('紧急', theme.colorScheme.error)
        : ('进行中', Colors.orange);
    return _chip(theme, label, color);
  }

  Widget _miniStatus(ThemeData theme, SubPlanProgress s, bool done) {
    final (label, color) = s.status == -1
        ? ('红冲', theme.colorScheme.onSurfaceVariant)
        : s.status == 0
        ? ('草稿', Colors.orange)
        : done
        ? ('已完成 ✓', Colors.green)
        : ('进行中', Colors.orange);
    return _chip(theme, label, color);
  }

  Widget _chip(ThemeData theme, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: theme.textTheme.titleSmall?.copyWith(color: color),
      ),
    );
  }

  Widget _meta(
    ThemeData theme,
    IconData icon,
    String text, {
    Color? color,
    bool bold = false,
  }) {
    final c = color ?? theme.colorScheme.onSurfaceVariant;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 24),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: c),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              text,
              softWrap: true,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: c,
                fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _materialMeta(
    ThemeData theme, {
    required String state,
    required double? readyQty,
    required double? totalQty,
    required int readySegments,
    required int totalSegments,
    required bool canStartNow,
  }) {
    final String text;
    final Color color;
    final IconData icon;
    switch (state) {
      case 'READY':
        text = canStartNow ? '物料已齐套 · 可开工' : '物料已齐套';
        color = Colors.green.shade700;
        icon = Icons.check_circle_outline_rounded;
        break;
      case 'PARTIAL':
        text =
            '物料已齐 ${_fmt(readyQty)} / ${_fmt(totalQty)}'
            '（$readySegments/$totalSegments 段）'
            '${canStartNow ? ' · 可开工' : ''}';
        color = Colors.orange.shade800;
        icon = Icons.inventory_2_outlined;
        break;
      case 'WAITING':
        text = '物料待齐套（0/$totalSegments 段）';
        color = Colors.orange.shade800;
        icon = Icons.hourglass_bottom_rounded;
        break;
      case 'LEGACY_UNSUPPORTED':
        text = '旧计划未计算物料齐套';
        color = theme.colorScheme.onSurfaceVariant;
        icon = Icons.history_rounded;
        break;
      case 'DATA_ERROR':
        text = '物料齐套数据异常，请检查';
        color = theme.colorScheme.error;
        icon = Icons.error_outline_rounded;
        break;
      default:
        text = '尚未生成正式执行计划';
        color = theme.colorScheme.onSurfaceVariant;
        icon = Icons.pending_actions_outlined;
        break;
    }
    return _meta(theme, icon, text, color: color, bold: canStartNow);
  }

  String _fmt(double? v) => v == null
      ? '—'
      : (v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2));
}
