// 盘点模式独立页（/stock/count-session，2026-10-08）。
//
// 从即时库存「盘点模式」直达（带当前已选的具体仓库，不再弹选仓窗），本页自成会话：
// - 只针对一个具体仓库；顶部「仓库」字段随时切换去盘其他仓，各仓未送审的实盘
//   输入分别保留（内存内即保留，整页随本机草稿落盘）；
// - 默认「有库存」段=只列本仓有账面数量的行；「全部物料」含零库存（盘盈场景），
//   也可用「添加物料」把零库存物料加进来；
// - 分类不再占左侧树，收敛为工具条「分类」滑窗筛选（候选树本身就是按仓裁剪的）；
// - 草稿走平台统一的本机表单草稿(FormDraftMixin)：输入自动保存、退出三选弹窗、
//   /form-drafts 可恢复，无显式「存草稿」按钮；
// - 「保存并送审」生成待审申请(stock_count_requests)，审核通过才改正式库存。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../components/buttons/uten_back_button.dart';
import '../../../../components/buttons/uten_button.dart';
import '../../../../components/inputs/uten_filter_picker_field.dart';
import '../../../../components/layout/uten_app_bar.dart';
import '../../../../components/layout/uten_content_container.dart';
import '../../../../components/layout/uten_filter_toolbar.dart';
import '../../../../components/layout/uten_floating_action_group.dart';
import '../../../../core/network/api_exception.dart';
import '../../../../core/router/nav_helpers.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/uten_tokens.dart';
import '../../../../core/ui/app_notification.dart';
import '../../../../shared/badges/badge_registry.dart';
import '../../../../shared/drafts/form_draft_catalog.dart';
import '../../../../shared/drafts/form_draft_mixin.dart';
import '../../../../shared/formatters/exact_decimal.dart';
import '../../../../shared/models/paged_result.dart';
import '../../../basic_data/models/product_category_node.dart';
import '../../../basic_data/widgets/master_data_table_view.dart';
import '../../../basic_data/widgets/product_category_picker_panel.dart';
import '../models/stock_count_request.dart';
import '../repositories/stock_count_request_repository.dart';
import '../widgets/stock_count_candidate_picker.dart';
import '../widgets/stock_count_inline_editor.dart';

/// 一个仓库的未送审输入快照（切换仓库时暂存；随草稿落盘）。
class _WarehouseStash {
  _WarehouseStash(this.reason, this.inputs, this.addedKeys);
  final String reason;
  final Map<String, ({String q, String w})> inputs;
  final Set<String> addedKeys;
}

class StockCountSessionPage extends ConsumerStatefulWidget {
  const StockCountSessionPage({super.key, this.warehouseId});
  final String? warehouseId;
  @override
  ConsumerState<StockCountSessionPage> createState() =>
      _StockCountSessionPageState();
}

class _StockCountSessionPageState extends ConsumerState<StockCountSessionPage>
    with FormDraftMixin<StockCountSessionPage> {
  late final StockCountInlineController _count;
  final _search = TextEditingController();

  StockCountScope? _scope;
  StockCountWarehouse? _warehouse;
  List<ProductCategoryNode> _categoryTree = const [];
  String? _categoryId;

  /// 2026-10-08 用户口径：盘点要盘全部——账面为 0 的行也要显示并录入实盘数；
  /// 「有库存」只是可选筛段（只看账上有数的）。
  bool _stockedOnly = false;
  String _keyword = '';
  PagedResult<CountStockRow>? _page;
  int _pageNum = 1;
  bool _loading = false;
  String? _error;
  bool _submitting = false;
  bool _starting = false;

  /// 当前仓不在页内的行（添加的零库存物料 / 草稿恢复的行）。
  final _extraRows = <String, CountStockRow>{};
  final _stashByWarehouse = <String, _WarehouseStash>{};

  /// 草稿恢复的仓库与暂存（scope 到位后套用）。
  String? _pendingStashWarehouseId;

  @override
  bool get formDraftBusy => _submitting || _count.busy || _starting;
  @override
  FormDraftSpec get formDraftSpec =>
      FormDraftCatalog.stockCount.spec(title: '盘点模式');
  @override
  Iterable<Listenable> get formDraftListenables => [_count, _count.reason];

  @override
  Map<String, dynamic> captureFormDraft() {
    _stashCurrentWarehouse();
    return {
      'warehouseId': _warehouse?.id,
      'stashes': {
        for (final entry in _stashByWarehouse.entries)
          entry.key: {
            'reason': entry.value.reason,
            'added': entry.value.addedKeys.toList(),
            'inputs': {
              for (final input in entry.value.inputs.entries)
                input.key: {'q': input.value.q, 'w': input.value.w},
            },
          },
      },
    };
  }

  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    final stashes = <String, _WarehouseStash>{};
    final raw = data['stashes'];
    if (raw is Map<String, dynamic>) {
      for (final entry in raw.entries) {
        final value = entry.value;
        if (value is! Map<String, dynamic>) continue;
        final inputs = <String, ({String q, String w})>{};
        final rawInputs = value['inputs'];
        if (rawInputs is Map<String, dynamic>) {
          for (final input in rawInputs.entries) {
            final fields = input.value;
            if (fields is Map<String, dynamic>) {
              inputs[input.key] = (
                q: fields['q'] as String? ?? '',
                w: fields['w'] as String? ?? '',
              );
            }
          }
        }
        stashes[entry.key] = _WarehouseStash(
          value['reason'] as String? ?? '',
          inputs,
          {
            for (final key in value['added'] as List? ?? const [])
              if (key is String) key,
          },
        );
      }
    }
    _stashByWarehouse
      ..clear()
      ..addAll(stashes);
    final warehouseId = data['warehouseId'] as String?;
    if (_warehouse != null && warehouseId != _warehouse!.id) {
      final target = _scope?.warehouses
          .where((w) => w.id == warehouseId)
          .firstOrNull;
      if (target != null) {
        await _switchWarehouse(target);
        return;
      }
    }
    _pendingStashWarehouseId ??= warehouseId;
    // scope 尚未到位（或草稿仓库已不在可盘范围）时，等 _start 选仓后套用暂存。
    _applyStashToCurrentWarehouse();
  }

  @override
  void initState() {
    super.initState();
    _count = StockCountInlineController(
      ref.read(stockCountRequestRepositoryProvider),
    )..addListener(_onCountChanged);
    startFormDraftIdentityGuard();
    _start();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (mounted) await initializeFormDraft();
    });
  }

  @override
  void dispose() {
    _count.removeListener(_onCountChanged);
    _search.dispose();
    _count.dispose();
    super.dispose();
  }

  void _onCountChanged() {
    if (mounted) setState(() {});
  }

  StockCountRequestRepository get _repo =>
      ref.read(stockCountRequestRepositoryProvider);

  Future<void> _start() async {
    if (_starting) return;
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      final scope = await _repo.scope();
      if (!mounted) return;
      if (!scope.canSubmit) {
        setState(() => _error = '当前没有提交盘点的权限');
        return;
      }
      StockCountWarehouse? selected;
      final preferred = _pendingStashWarehouseId ?? widget.warehouseId;
      for (final warehouse in scope.warehouses) {
        if (warehouse.id == preferred) selected = warehouse;
      }
      selected ??= scope.warehouses.firstOrNull;
      setState(() => _scope = scope);
      if (selected == null) {
        setState(() => _error = '当前没有可盘点的仓库');
        return;
      }
      await _switchWarehouse(selected, initial: true);
    } catch (error) {
      if (mounted) {
        setState(() => _error = error is ApiException ? error.message : '盘点模式未能开启，请重试');
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  /// 暂存当前仓的未送审输入（切仓/落草稿前调用）。
  void _stashCurrentWarehouse() {
    final warehouse = _warehouse;
    if (warehouse == null) return;
    final inputs = <String, ({String q, String w})>{};
    _count.rows.forEach((key, row) {
      if (row.qty.text.trim().isNotEmpty || row.weight.text.trim().isNotEmpty) {
        inputs[key] = (q: row.qty.text, w: row.weight.text);
      }
    });
    _stashByWarehouse[warehouse.id] = _WarehouseStash(
      _count.reason.text,
      inputs,
      {..._extraRows.keys},
    );
  }

  Future<void> _switchWarehouse(
    StockCountWarehouse next, {
    bool initial = false,
  }) async {
    if (!initial && _warehouse?.id == next.id) return;
    _stashCurrentWarehouse();
    _count.begin(next);
    _extraRows.clear();
    setState(() {
      _warehouse = next;
      _page = null;
      _categoryId = null;
      _categoryTree = const [];
      _error = null;
    });
    await _load(1);
    await _loadCategoryTree();
    _applyStashToCurrentWarehouse();
    markFormDraftChanged();
  }

  Future<void> _loadCategoryTree() async {
    final warehouse = _warehouse;
    if (warehouse == null) return;
    try {
      final tree = await _repo.candidateCategories(warehouse.id);
      if (!mounted || _warehouse?.id != warehouse.id) return;
      setState(() => _categoryTree = tree);
    } on ApiException catch (error) {
      if (mounted) context.appWarning('分类筛选加载失败：${error.message}');
    }
  }

  Future<void> _pickCategory() async {
    final result = await showUtenProductCategoryPickerPanel(
      context,
      tree: _categoryTree,
      selectedId: _categoryId,
    );
    if (!mounted || result == null) return;
    setState(() => _categoryId = result.isAll ? null : result.id);
    await _load(1);
  }

  Future<void> _pickWarehouse() async {
    final scope = _scope;
    if (scope == null || _count.busy) return;
    final selected = await showDialog<StockCountWarehouse>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('盘点仓库'),
        children: [
          for (final warehouse in scope.warehouses)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, warehouse),
              child: Text('${warehouse.name} · ${warehouse.reviewerLabel}审核'),
            ),
        ],
      ),
    );
    if (!mounted || selected == null) return;
    await _switchWarehouse(selected);
  }

  Future<void> _load(int page) async {
    final warehouse = _warehouse;
    if (warehouse == null) return;
    setState(() {
      _loading = true;
      _error = null;
      _pageNum = page;
    });
    try {
      final result = await _repo.candidates(
        warehouseId: warehouse.id,
        keyword: _keyword.isEmpty ? null : _keyword,
        categoryId: _categoryId,
        stockedOnly: _stockedOnly,
        page: page,
      );
      if (!mounted || _warehouse?.id != warehouse.id) return;
      // 行集与页集同键；编辑缓冲 putIfAbsent 保留已填值。
      _count.addAll(result.items);
      for (final row in result.items) {
        _extraRows.remove(row.key);
      }
      setState(() => _page = result);
    } catch (error) {
      if (mounted && _warehouse?.id == warehouse.id) {
        setState(() => _error = error is ApiException ? error.message : '盘点数据没有读到，请重试');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 把当前仓的暂存套回去：按 goodsId 重拉快照重建行，再回填输入文本。
  Future<void> _applyStashToCurrentWarehouse() async {
    final warehouse = _warehouse;
    if (warehouse == null) return;
    final stash = _stashByWarehouse[warehouse.id];
    if (stash == null) return;
    _count.reason.text = stash.reason;
    final goodsIds = <String>{};
    for (final key in {...stash.inputs.keys, ...stash.addedKeys}) {
      final goodsId = key.split('|').first;
      if (goodsId.isNotEmpty) goodsIds.add(goodsId);
    }
    if (goodsIds.isEmpty) return;
    try {
      final rows = await _fetchByGoods(warehouse.id, goodsIds);
      if (!mounted || _warehouse?.id != warehouse.id) return;
      _count.addAll(rows);
      final pageKeys =
          (_page?.items ?? const <CountStockRow>[]).map((r) => r.key).toSet();
      for (final row in rows) {
        if (!pageKeys.contains(row.key)) {
          _extraRows.putIfAbsent(row.key, () => row);
        }
      }
      for (final entry in stash.inputs.entries) {
        final row = _count.rows[entry.key];
        if (row == null) continue; // 行已失效(删除/占位)：放弃这笔记入
        row.qty.text = entry.value.q;
        row.weight.text = entry.value.w;
      }
      if (mounted) setState(() {});
    } on ApiException catch (error) {
      if (mounted) context.appWarning('部分盘点的输入没能恢复：${error.message}');
    }
  }

  Future<List<CountStockRow>> _fetchByGoods(
    String warehouseId,
    Set<String> goodsIds,
  ) async {
    final rows = <CountStockRow>[];
    final ids = goodsIds.toList();
    for (var offset = 0; offset < ids.length; offset += 50) {
      final chunk = ids.sublist(
        offset,
        (offset + 50).clamp(0, ids.length),
      );
      var page = 1;
      while (true) {
        final result = await _repo.candidates(
          warehouseId: warehouseId,
          goodsIds: chunk,
          page: page,
          size: 100,
        );
        rows.addAll(result.items);
        if (page >= result.totalPages) break;
        page++;
      }
    }
    return rows;
  }

  Future<void> _addMaterials() async {
    final warehouse = _warehouse;
    if (warehouse == null || _count.busy) return;
    final session = _count.session;
    final rows = await showStockCountCandidatePicker(
      context,
      ref,
      warehouse: warehouse,
    );
    if (!mounted ||
        rows.isEmpty ||
        !_count.active ||
        _count.session != session) {
      return;
    }
    _count.addAll(rows, expectedSession: session);
    final pageKeys =
        (_page?.items ?? const <CountStockRow>[]).map((r) => r.key).toSet();
    for (final row in rows) {
      if (!pageKeys.contains(row.key)) {
        _extraRows.putIfAbsent(row.key, () => row);
      }
    }
    setState(() {});
    markFormDraftChanged();
  }

  Future<void> _save() async {
    final warehouse = _warehouse;
    if (warehouse == null || _submitting || _count.busy) return;
    for (final row in _count.rows.values.where((row) => row.changed)) {
      if (row.validation != null) {
        context.appError('${row.snapshot.goodsName}：${row.validation}');
        return;
      }
    }
    setState(() => _submitting = true);
    try {
      await saveFormDraftNow();
      final request = await runFormDraftSubmission(() => _count.submit());
      await completeFormDraft();
      _count.clear();
      _stashByWarehouse.remove(warehouse.id);
      if (!mounted) return;
      refreshBadgesIn(ProviderScope.containerOf(context));
      context.appSuccess(
        '盘点 ${request.requestNo} 已送${warehouse.reviewerLabel}审核，正式库存尚未改变',
      );
      backTo(context, defaultPath: RouteName.stockInstantInventory);
    } catch (error) {
      if (mounted) {
        context.appError(
          error is ApiException
              ? error.message
              : error is FormatException
              ? error.message
              : '送审结果未确认，输入已保留，可原样重试',
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  // ---- 表格 ----

  List<CountStockRow> get _items {
    final rows = [...?_page?.items];
    final pageKeys = rows.map((row) => row.key).toSet();
    rows.addAll(_extraRows.values.where((row) => !pageKeys.contains(row.key)));
    return rows;
  }

  /// 账面重量展示：估算带 ≈ 前缀；有数量没称过 =「未称」，无数量 =「—」。
  String _weightText(CountStockRow row) {
    final weight = financeExactTrimmed(row.weightKg);
    if (weight == null) {
      return (double.tryParse(row.qty) ?? 0) != 0 ? '未称' : '—';
    }
    return row.weightEstimated ? '≈$weight' : weight;
  }

  /// 数量差额（实盘-账面，只对已改行显示）；精确十进制，最多 4 位小数。
  String? _deltaText(CountStockRow row) {
    final edit = _count.rows[row.key];
    if (edit == null || !edit.qtyChanged) return null;
    final left = _parseExact(edit.targetQty);
    final right = _parseExact(edit.snapshot.qty);
    if (left == null || right == null) return null;
    var (units, scale) = left;
    var (otherUnits, otherScale) = right;
    if (scale < otherScale) {
      units *= BigInt.from(10).pow(otherScale - scale);
      scale = otherScale;
    } else if (otherScale < scale) {
      otherUnits *= BigInt.from(10).pow(scale - otherScale);
    }
    final delta = units - otherUnits;
    final negative = delta.isNegative;
    final text = financeExactDecimalFromUnits(delta.abs(), scale: scale);
    return (negative ? '-' : '') + (financeExactTrimmed(text) ?? '0');
  }

  static (BigInt, int)? _parseExact(String text) {
    final value = text.trim();
    if (!RegExp(r'^\d{1,14}(\.\d{1,4})?$').hasMatch(value)) return null;
    final parts = value.split('.');
    final fraction = parts.length > 1 ? parts[1] : '';
    return (BigInt.parse(parts[0] + fraction), fraction.length);
  }

  List<MasterColumnDef<CountStockRow>> _columns() => [
    // 2026-09-14 全站表格统一：名称 → 编号 → 颜色 三列在最前。
    MasterColumnDef<CountStockRow>(
      key: 'name',
      label: '货品名称',
      width: 220,
      value: (row) => row.goodsName,
    ),
    MasterColumnDef<CountStockRow>(
      key: 'goodsCode',
      label: '编号',
      width: 130,
      value: (row) => row.goodsCode,
    ),
    MasterColumnDef<CountStockRow>(
      key: 'color',
      label: '颜色',
      width: 90,
      value: (row) => row.colorName ?? '',
    ),
    MasterColumnDef<CountStockRow>(
      key: 'model',
      label: '型号',
      width: 110,
      value: (row) => row.model ?? '',
    ),
    MasterColumnDef<CountStockRow>(
      key: 'spec',
      label: '规格',
      width: 120,
      value: (row) => row.spec ?? '',
    ),
    MasterColumnDef<CountStockRow>(
      key: 'stockPlace',
      label: '库位号',
      width: 90,
      value: (row) => row.stockPlace ?? '',
    ),
    MasterColumnDef<CountStockRow>(
      key: 'category',
      label: '所属类型',
      width: 120,
      value: (row) => row.categoryName ?? '—',
    ),
    MasterColumnDef<CountStockRow>(
      key: 'unit',
      label: '单位',
      width: 70,
      value: (row) => row.unitName,
    ),
    MasterColumnDef<CountStockRow>(
      key: 'qty',
      label: '账面数量',
      width: 110,
      type: 'number',
      value: (row) => row.qty,
    ),
    MasterColumnDef<CountStockRow>(
      key: 'weight',
      label: '账面重量 (kg)',
      width: 110,
      value: (row) => _weightText(row),
    ),
    ..._count.columns<CountStockRow>((row) => row.key),
    MasterColumnDef<CountStockRow>(
      key: 'delta',
      label: '数量差额',
      width: 100,
      type: 'number',
      value: (row) => _deltaText(row) ?? '',
    ),
  ];

  // ---- 布局 ----

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: UtenAppBar(
        title: '盘点模式', // TODO(l10n): 补 arb
        leading: UtenBackButton(
          onPressed: () =>
              backTo(context, defaultPath: RouteName.stockInstantInventory),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新', // TODO(l10n): 补 arb
            onPressed: _starting ? null : () => _load(_pageNum),
          ),
        ],
      ),
      body: withFormDraft(
        UtenContentContainer.wide(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              UtenFilterToolbar<String>(
                segmentsKey: const Key('stock-count-scope-segments'),
                selected: {_stockedOnly ? 'stocked' : 'all'},
                enabled: !_starting,
                segments: const [
                  UtenFilterSegment(value: 'all', label: '全部物料'),
                  UtenFilterSegment(value: 'stocked', label: '有库存'),
                ],
                onSelectionChanged: (value) {
                  setState(() => _stockedOnly = value == 'stocked');
                  _load(1);
                },
                searchController: _search,
                searchHint: '搜索货品名称 / 编号 / 颜色',
                onSearchChanged: (keyword) {
                  _keyword = keyword.trim();
                  _load(1);
                },
                trailing: Wrap(
                  spacing: UtenSpacing.s12,
                  runSpacing: UtenSpacing.s8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    UtenFilterPickerField(
                      key: const Key('stock-count-warehouse'),
                      label: '仓库',
                      icon: Icons.warehouse_outlined,
                      width: 220,
                      value: _warehouse?.name,
                      enabled: !_starting,
                      onTap: _pickWarehouse,
                    ),
                    UtenFilterPickerField(
                      key: const Key('stock-count-category'),
                      label: '分类',
                      icon: Icons.category_outlined,
                      width: 180,
                      value: findCategoryName(_categoryTree, _categoryId),
                      enabled: _categoryTree.isNotEmpty,
                      onTap: _pickCategory,
                    ),
                    Text(
                      '共 ${_page?.total ?? 0} 项',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(child: _buildTable()),
            ],
          ),
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
      floatingActionButton: (_scope == null || _warehouse == null)
          ? null
          : UtenFloatingActionGroup(
              children: [
                UtenButton(
                  key: const Key('stock-count-add'),
                  size: UtenButtonSize.large,
                  type: UtenButtonType.secondary,
                  onPressed: _count.busy ? null : _addMaterials,
                  child: const Text('添加物料'),
                ),
                UtenButton(
                  key: const Key('stock-count-exit'),
                  size: UtenButtonSize.large,
                  type: UtenButtonType.secondary,
                  onPressed: _count.busy
                      ? null
                      : () => backTo(
                          context,
                          defaultPath: RouteName.stockInstantInventory,
                        ),
                  child: const Text('退出盘点'),
                ),
                UtenButton(
                  key: const Key('stock-count-save'),
                  size: UtenButtonSize.large,
                  onPressed:
                      _submitting || _count.busy || _count.changedCount == 0
                      ? null
                      : _save,
                  child: const Text('保存并送审'),
                ),
              ],
            ),
    );
  }

  Widget _buildTable() {
    final warehouse = _warehouse;
    if (_scope == null || warehouse == null) {
      if (_error != null) {
        return _messagePane(_error!, retry: _start);
      }
      return const Center(child: CircularProgressIndicator());
    }
    return MasterDataTableView<CountStockRow>(
      tableKey:
          'features.stock.counts.pages.stock_count_session_page.StockCountSessionPageState',
      columns: _columns(),
      items: _items,
      rowKeyOf: (row) => row.key,
      toolbarActions: [
        // 盘点说明选填(V795)；无改动时说明也随草稿保留。
        StockCountReasonField(controller: _count, maxWidth: 240),
      ],
      // 本页筛选在工具条（仓库/分类/分段/搜索），表头不带筛选列。
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      isLoading: _loading && _page == null,
      loadingMore: _loading && _page != null,
      error: _error,
      onRetry: () => _load(_pageNum),
      emptyMessage: _stockedOnly
          ? '本仓暂无有库存的物料；可切回「全部物料」或用「添加物料」录入盘盈'
          : '没有符合条件的物料',
      currentPage: _page?.page ?? 1,
      totalPages: _page?.totalPages ?? 1,
      paginationScope: (warehouse.id, _stockedOnly, _categoryId, _keyword),
      onPageChange: (page) => _load(page),
      bottomContentPadding: UtenFloatingActionGroup.scrollClearance,
    );
  }

  Widget _messagePane(String message, {required VoidCallback retry}) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(message, textAlign: TextAlign.center),
        const SizedBox(height: UtenSpacing.s8),
        TextButton(onPressed: retry, child: const Text('重试')),
      ],
    ),
  );
}
