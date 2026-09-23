// 分类主档页的右侧明细区(客户/供应商/模具/货品四页共用，ADR-111)。
//
// 四页原先各写一遍整段 _DetailPane(加载/分页/筛选/排序/打印导出/启停/删除/批量)，
// 方法同名同构、差异只在实体名与文案；批量启停/删除还在前端逐条循环调单条接口
// (选 100 条就是 200 次串行请求，失败 catch 吞掉只报「N 个跳过」)。
//
// 现在明细区只有这一份：
// - 分类信息卡 + 标题/搜索/添加 + MasterDataTableView(表头筛选/排序/分页/多选)；
// - 行启停走单条窄命令(PATCH /status，带列表行版本，不再先拉详情)；
// - 行删除、批量启停、批量删除走服务端批量命令(一次请求、一个事务、逐条原因)，
//   结果经 showMasterBatchOutcome 逐条展示；
// - 各页只给 [MasterEntityPaneConfig]：列、仓储闭包、文案、权限，以及特有动作
//   (客户负责人/可见人、货品复制粘贴与组件信息、模具详情弹层)。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_export_button.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/print/uten_print_preview.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/widgets/master_detail_card.dart';
import '../models/master_batch.dart';
import '../models/master_facet.dart';
import '../models/product_category_node.dart';
import '../repositories/master_batch_repository.dart';
import '../repositories/master_status_repository.dart';
import 'master_batch_feedback.dart';
import 'master_data_table_view.dart';
import 'system_master_category_guard.dart';

/// 明细列表的一次查询条件。[forPrint] 为打印预览全量拉取(货品页据此保持禁用品口径)。
class MasterPaneQuery {
  const MasterPaneQuery({
    required this.categoryId,
    this.page = 1,
    this.size,
    this.keyword,
    this.filters = const {},
    this.sort,
    this.order,
    this.forPrint = false,
  });

  final String categoryId;
  final int page;
  final int? size;
  final String? keyword;
  final Map<String, String?> filters;
  final String? sort;
  final String? order;
  final bool forPrint;

  bool get hasKeyword => keyword != null && keyword!.trim().isNotEmpty;
}

/// 表头筛选桶 + 空值计数(各主档 facets 同形)。
class MasterPaneFacets {
  const MasterPaneFacets({required this.fields, required this.nullCounts});

  final Map<String, List<MasterFacetBucket>> fields;
  final Map<String, int> nullCounts;
}

/// 打印/导出按钮配置；[inCard]=true 放分类信息卡(货品页)，否则放表格工具条。
class MasterPaneExport {
  const MasterPaneExport({
    required this.title,
    required this.endpoint,
    required this.permission,
    required this.label,
    this.extraQuery = const {},
    this.inCard = false,
  });

  final String title;
  final String endpoint;
  final String permission;
  final String label;
  final Map<String, dynamic> extraQuery;
  final bool inCard;
}

/// 明细区对页面暴露的操作面(页面的特有动作经它刷新列表、读选中、跑批量命令)。
abstract interface class MasterEntityPaneController<TItem, TDetail> {
  String get categoryId;
  ProductCategoryDetail? get category;
  PagedResult<TItem>? get page;
  int get pageNum;
  Set<String> get selectedIds;
  bool get busy;

  /// 重拉当前页(以及前导分组)；[page] 为空时留在当前页。
  Future<void> reload({int? page});
  void clearSelection();

  /// 行操作互斥(防连点)：已有操作在跑时直接返回 null。
  Future<T?> runExclusive<T>(Future<T> Function() action);

  /// 拉详情后执行(编辑等)；对象只读时提示原因不执行。
  Future<void> withDetail(
    String id,
    Future<void> Function(TDetail detail) action,
  );

  Future<void> toggleStatus(TItem row);
  Future<void> batchSetStatus(Set<String> ids, String status);
  Future<void> batchDelete(Set<String> ids);
}

/// 一张分类主档页右侧明细区的全部差异点。
class MasterEntityPaneConfig<TItem, TDetail> {
  const MasterEntityPaneConfig({
    required this.noun,
    required this.icon,
    required this.defaultCodePrefix,
    required this.keyPrefix,
    required this.searchHint,
    required this.columns,
    required this.idOf,
    required this.statusOf,
    required this.labelOf,
    required this.loadCategory,
    required this.loadPage,
    required this.loadFacets,
    required this.batchEntityPath,
    required this.statusResourceOf,
    required this.canCreate,
    required this.canEdit,
    required this.canDelete,
    required this.canStatus,
    this.versionOf,
    this.writableOf,
    this.readOnlyRowHint,
    this.readOnlyBatchHint,
    this.defaultSortKey,
    this.columnOfFacetField = const {},
    this.filterParamOfColumn = const {},
    this.export,
    this.onCreate,
    this.onOpen,
    this.loadDetail,
    this.onEdit,
    this.detailReadOnlyHint,
    this.extraMenuItems,
    this.rowMenuOverride,
    this.extraBatchActions,
    this.batchActionsOverride,
    this.cardActions,
    this.loadLeadingGroups,
  });

  /// 面向人的实体名(客户/供应商/模具/货品)。
  final String noun;
  final IconData icon;
  final String defaultCodePrefix;

  /// 搜索框 key 前缀(切分类/树搜索时按 key 重建搜索框)。
  final String keyPrefix;
  final String searchHint;
  final List<MasterColumnDef<TItem>> columns;
  final String Function(TItem row) idOf;
  final String? Function(TItem row) statusOf;
  final String Function(TItem row) labelOf;
  final int? Function(TItem row)? versionOf;

  /// 对象级写权限(客户)；为空表示行都可写。
  final bool Function(TItem row)? writableOf;
  final String Function(TItem row)? readOnlyRowHint;
  final String? readOnlyBatchHint;

  final Future<ProductCategoryDetail> Function(String categoryId) loadCategory;
  final Future<PagedResult<TItem>> Function(MasterPaneQuery query) loadPage;
  final Future<MasterPaneFacets> Function(String categoryId) loadFacets;

  /// 主档集合路径(ApiEndpoints.clients 等)，批量命令拼 /batch-status、/batch-delete。
  final String batchEntityPath;

  /// 单条资源路径(ApiEndpoints.client(id) 等)，行启停拼 /status。
  final String Function(String id) statusResourceOf;

  final bool canCreate;
  final bool canEdit;
  final bool canDelete;
  final bool canStatus;
  final String? defaultSortKey;

  /// 服务端 facet 字段 → 表格列 key(如 empId → ownerEmployeeName)。
  final Map<String, String> columnOfFacetField;

  /// 表格列 key → 服务端筛选参数名(如 ownerEmployeeName → ownerEmployeeId)。
  final Map<String, String> filterParamOfColumn;
  final MasterPaneExport? export;

  final Future<void> Function(MasterEntityPaneController<TItem, TDetail> pane)?
  onCreate;
  final Future<void> Function(
    MasterEntityPaneController<TItem, TDetail> pane,
    TItem row,
  )?
  onOpen;
  final Future<TDetail> Function(String id)? loadDetail;
  final Future<void> Function(
    MasterEntityPaneController<TItem, TDetail> pane,
    TDetail detail,
  )?
  onEdit;
  final String? Function(TDetail detail)? detailReadOnlyHint;

  /// 默认行菜单里插在「编辑」与「删除」之间的特有动作。
  final List<UtenContextMenuEntry> Function(
    MasterEntityPaneController<TItem, TDetail> pane,
    TItem row,
  )?
  extraMenuItems;

  /// 整个行菜单由页面接管(货品页：复制/粘贴/组件信息与多选菜单)。
  final List<UtenContextMenuEntry> Function(
    MasterEntityPaneController<TItem, TDetail> pane,
    TItem row,
  )?
  rowMenuOverride;
  final List<Widget> Function(
    MasterEntityPaneController<TItem, TDetail> pane,
    Set<String> ids,
  )?
  extraBatchActions;
  final List<Widget> Function(
    MasterEntityPaneController<TItem, TDetail> pane,
    Set<String> ids,
  )?
  batchActionsOverride;

  /// 分类信息卡上的额外按钮(货品页：导入货品)。
  final List<Widget> Function(MasterEntityPaneController<TItem, TDetail> pane)?
  cardActions;

  /// 表头下前导分组(货品页：禁用货品 / 不明货品)，随列表一起重拉。
  final Future<List<MasterDataGroup<TItem>>> Function(
    MasterPaneQuery query,
    ProductCategoryDetail category,
  )?
  loadLeadingGroups;
}

class MasterEntityDetailPane<TItem, TDetail> extends ConsumerStatefulWidget {
  const MasterEntityDetailPane({
    super.key,
    required this.config,
    required this.categoryId,
    required this.canEditCategory,
    required this.canAddCategory,
    required this.canDeleteCategory,
    required this.externalKeyword,
    required this.onAddChild,
    required this.onEditCategory,
    required this.onDeleteCategory,
  });

  final MasterEntityPaneConfig<TItem, TDetail> config;
  final String categoryId;
  final bool canEditCategory;
  final bool canAddCategory;
  final bool canDeleteCategory;

  /// 顶部树搜索命中内容时传入的过滤词：采纳为本地列表搜索词，右侧只显示搜索结果。
  final String? externalKeyword;
  final VoidCallback onAddChild;
  final void Function(ProductCategoryDetail detail) onEditCategory;
  final VoidCallback onDeleteCategory;

  @override
  ConsumerState<MasterEntityDetailPane<TItem, TDetail>> createState() =>
      _MasterEntityDetailPaneState<TItem, TDetail>();
}

class _MasterEntityDetailPaneState<TItem, TDetail>
    extends ConsumerState<MasterEntityDetailPane<TItem, TDetail>>
    implements MasterEntityPaneController<TItem, TDetail> {
  final _categoryRequests = LatestRequestGuard();
  final _listRequests = LatestRequestGuard();
  final _groupRequests = LatestRequestGuard();

  ProductCategoryDetail? _category;
  bool _loading = true;
  String? _error;

  PagedResult<TItem>? _page;
  int _pageNum = 1;
  bool _listLoading = false;
  String? _listError;
  List<MasterDataGroup<TItem>> _groups = const [];

  Map<String, String?> _filters = {};
  String _keyword = '';
  MasterPaneFacets? _facets;
  int _kwSeed = 0;
  String? _sortKey;
  bool _sortAsc = true;
  Set<String> _selectedIds = {};
  bool _busy = false;

  MasterEntityPaneConfig<TItem, TDetail> get _c => widget.config;

  @override
  void initState() {
    super.initState();
    _sortKey = _c.defaultSortKey;
    _load();
  }

  @override
  void didUpdateWidget(MasterEntityDetailPane<TItem, TDetail> old) {
    super.didUpdateWidget(old);
    if (old.categoryId != widget.categoryId) {
      _load();
      return;
    }
    if (old.externalKeyword != widget.externalKeyword) {
      setState(() {
        _kwSeed++;
        _keyword = widget.externalKeyword ?? '';
      });
      reload(page: 1);
    }
  }

  // ---- MasterEntityPaneController ----------------------------------------

  @override
  String get categoryId => widget.categoryId;

  @override
  ProductCategoryDetail? get category => _category;

  @override
  PagedResult<TItem>? get page => _page;

  @override
  int get pageNum => _pageNum;

  @override
  Set<String> get selectedIds => _selectedIds;

  @override
  bool get busy => _busy;

  @override
  void clearSelection() => setState(() => _selectedIds = {});

  @override
  Future<void> reload({int? page}) async {
    await Future.wait([_loadList(page ?? _pageNum), _loadGroups()]);
    // 删空当前页时回退上一页，避免列表空白。
    final current = _page;
    if (mounted &&
        current != null &&
        current.items.isEmpty &&
        current.page > 1) {
      await _loadList(current.page - 1);
    }
  }

  @override
  Future<T?> runExclusive<T>(Future<T> Function() action) async {
    if (_busy) return null;
    setState(() => _busy = true);
    try {
      return await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Future<void> withDetail(
    String id,
    Future<void> Function(TDetail detail) action,
  ) async {
    final loader = _c.loadDetail;
    if (loader == null) return;
    final detail = await runExclusive(
      () => context.guardLoad(
        () => loader(id),
        errorFallback: '加载${_c.noun}详情失败', // TODO(l10n): 补 arb
      ),
    );
    if (detail == null || !mounted) return;
    final hint = _c.detailReadOnlyHint?.call(detail);
    if (hint != null) {
      context.appInfo(hint);
      return;
    }
    await action(detail);
  }

  @override
  Future<void> toggleStatus(TItem row) async {
    if (!_rowWritable(row)) {
      context.appInfo(_c.readOnlyRowHint?.call(row) ?? '该${_c.noun}为只读');
      return;
    }
    final next = _c.statusOf(row) == '使用' ? '禁用' : '使用';
    final ok = await runExclusive(
      () => context.guardRun(
        () => ref
            .read(masterStatusRepositoryProvider)
            .change(
              resourcePath: _c.statusResourceOf(_c.idOf(row)),
              status: next,
              version: _c.versionOf?.call(row),
            ),
        success: next == '禁用'
            ? '${_c.noun}已禁用'
            : '${_c.noun}已启用', // TODO(l10n): 补 arb
      ),
    );
    if (ok == true && mounted) await reload();
  }

  @override
  Future<void> batchSetStatus(Set<String> ids, String status) async {
    if (ids.isEmpty) return;
    final result = await runExclusive(
      () => context.guardAction(
        () => ref
            .read(masterBatchRepositoryProvider)
            .changeStatus(
              entityPath: _c.batchEntityPath,
              status: status,
              items: _batchItems(ids),
            ),
        errorFallback: '批量操作失败，请稍后重试', // TODO(l10n): 补 arb
      ),
    );
    if (result == null || !mounted) return;
    await _afterBatch(result, status == '禁用' ? '禁用' : '启用');
  }

  @override
  Future<void> batchDelete(Set<String> ids) async {
    if (ids.isEmpty || _busy) return;
    final single = ids.length == 1 ? _labelOf(ids.first) : null;
    final ok = await UtenDialog.show(
      context,
      title: single != null
          ? '删除${_c.noun}'
          : '批量删除${_c.noun}', // TODO(l10n): 补 arb
      content: Text(
        single != null
            ? '确定删除「$single」吗？'
            : '确定删除选中的 ${ids.length} 个${_c.noun}吗？还在被单据、库存或其它资料使用的会逐条说明原因并保留。', // TODO(l10n): 补 arb
      ),
      confirmLabel: '删除', // TODO(l10n): 补 arb
      danger: true,
    );
    if (ok != true || !mounted) return;
    final result = await runExclusive(
      () => context.guardAction(
        () => ref
            .read(masterBatchRepositoryProvider)
            .delete(entityPath: _c.batchEntityPath, items: _batchItems(ids)),
        errorFallback: '删除失败，请稍后重试', // TODO(l10n): 补 arb
      ),
    );
    if (result == null || !mounted) return;
    await _afterBatch(result, '删除');
  }

  Future<void> _afterBatch(MasterBatchResult result, String action) async {
    // 成功的从勾选里剪掉，失败的留着方便用户处理后重试。
    setState(() {
      _selectedIds = {
        for (final r in result.results)
          if (!r.ok && _selectedIds.contains(r.id)) r.id,
      };
    });
    await showMasterBatchOutcome(
      context,
      result,
      action: action,
      noun: _c.noun,
      labelOf: _labelOf,
    );
    if (mounted) await reload();
  }

  List<MasterBatchItem> _batchItems(Set<String> ids) {
    final byId = _rowsById();
    return [
      for (final id in ids)
        MasterBatchItem(
          id,
          byId[id] == null ? null : _c.versionOf?.call(byId[id] as TItem),
        ),
    ];
  }

  Map<String, TItem> _rowsById() => {
    for (final row in _page?.items ?? <TItem>[]) _c.idOf(row): row,
    for (final group in _groups)
      for (final row in group.items) _c.idOf(row): row,
  };

  String? _labelOf(String id) {
    final row = _rowsById()[id];
    return row == null ? null : _c.labelOf(row);
  }

  bool _rowWritable(TItem row) => _c.writableOf?.call(row) ?? true;

  // ---- 加载 -------------------------------------------------------------

  Future<void> _load() async {
    final generation = _categoryRequests.begin();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final category = await _c.loadCategory(widget.categoryId);
      if (!mounted || !_categoryRequests.isCurrent(generation)) return;
      setState(() {
        _category = category;
        _loading = false;
        // 切换分类：分页、筛选、facet、排序、特殊分组、勾选全部重置；
        // 树搜索的关键词随分类切换一并带入(搜索定位时右侧只显示搜索结果)。
        _page = null;
        _pageNum = 1;
        _listError = null;
        _groups = const [];
        _filters = {};
        _keyword = widget.externalKeyword ?? '';
        _kwSeed++;
        _facets = null;
        _sortKey = _c.defaultSortKey;
        _sortAsc = true;
        _selectedIds = {};
      });
      await Future.wait([_loadList(1), _loadFacets(), _loadGroups()]);
    } on ApiException catch (e) {
      if (!mounted || !_categoryRequests.isCurrent(generation)) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || !_categoryRequests.isCurrent(generation)) return;
      setState(() {
        _error = '加载分类详情失败'; // TODO(l10n): 补 arb
        _loading = false;
      });
    }
  }

  MasterPaneQuery _query({int page = 1, int? size, bool forPrint = false}) =>
      MasterPaneQuery(
        categoryId: widget.categoryId,
        page: page,
        size: size,
        keyword: _keyword.trim().isEmpty ? null : _keyword,
        filters: _filters,
        sort: _sortKey,
        order: _sortKey == null ? null : (_sortAsc ? 'asc' : 'desc'),
        forPrint: forPrint,
      );

  Future<void> _loadList(int page) async {
    final generation = _listRequests.begin();
    setState(() {
      _listLoading = true;
      _listError = null;
      _pageNum = page;
    });
    try {
      final result = await _c.loadPage(_query(page: page));
      if (!mounted || !_listRequests.isCurrent(generation)) return;
      setState(() => _page = result);
    } on ApiException catch (e) {
      if (!mounted || !_listRequests.isCurrent(generation)) return;
      setState(() => _listError = e.message);
    } catch (_) {
      if (!mounted || !_listRequests.isCurrent(generation)) return;
      setState(
        () => _listError = '加载${_c.noun}列表失败', // TODO(l10n): 补 arb
      );
    } finally {
      if (mounted && _listRequests.isCurrent(generation)) {
        setState(() => _listLoading = false);
      }
    }
  }

  /// 表头筛选下拉选项。失败不阻塞列表，静默降级为空下拉。
  Future<void> _loadFacets() async {
    try {
      final facets = await _c.loadFacets(widget.categoryId);
      if (mounted) setState(() => _facets = facets);
    } catch (_) {
      // Facets are optional; the primary list remains usable.
    }
  }

  /// 前导分组是辅助视图：失败静默，不影响主表。
  Future<void> _loadGroups() async {
    final loader = _c.loadLeadingGroups;
    final category = _category;
    if (loader == null || category == null) return;
    final generation = _groupRequests.begin();
    try {
      final groups = await loader(_query(), category);
      if (!mounted || !_groupRequests.isCurrent(generation)) return;
      setState(() => _groups = groups);
    } catch (_) {
      // 辅助视图失败静默。
    }
  }

  void _onFilterChanged(String column, String? value) {
    final param = _c.filterParamOfColumn[column] ?? column;
    setState(() {
      final next = Map<String, String?>.from(_filters);
      if (value == null) {
        next.remove(param); // 选「所有」= 不筛
      } else {
        next[param] = value; // 具体值 或 kMasterFilterNullValue(空值)
      }
      _filters = next;
    });
    reload(page: 1);
  }

  void _onKeywordChanged(String keyword) {
    setState(() => _keyword = keyword);
    reload(page: 1);
  }

  void _onSortChange(String? column, bool ascending) {
    setState(() {
      _sortKey = column;
      _sortAsc = ascending;
    });
    reload(page: 1);
  }

  Map<String, List<MasterFacetBucket>> get _columnFacets => {
    for (final e in (_facets?.fields ?? const {}).entries)
      (_c.columnOfFacetField[e.key] ?? e.key): e.value,
  };

  Map<String, int> get _columnNullCounts => {
    for (final e in (_facets?.nullCounts ?? const {}).entries)
      (_c.columnOfFacetField[e.key] ?? e.key): e.value,
  };

  Map<String, String?> get _columnFilters {
    final columnOfParam = {
      for (final e in _c.filterParamOfColumn.entries) e.value: e.key,
    };
    return {
      for (final e in _filters.entries)
        (columnOfParam[e.key] ?? e.key): e.value,
    };
  }

  Map<String, dynamic> get _exportQuery => <String, dynamic>{
    'categoryId': widget.categoryId,
    ...?_c.export?.extraQuery,
    if (_keyword.trim().isNotEmpty) 'keyword': _keyword.trim(),
    ...masterFilterQueryParams(_filters),
    if (_sortKey != null) 'sort': _sortKey,
    if (_sortKey != null) 'order': _sortAsc ? 'asc' : 'desc',
  };

  /// 打印预览：按当前分类/筛选口径拉全量(上限 2000 行)，列/格式化与表格一致。
  Future<UtenPrintTable> _printLoader() async {
    final result = await _c.loadPage(_query(size: 2000, forPrint: true));
    return UtenPrintTable(
      headers: [for (final c in _c.columns) c.label],
      rows: [
        for (final row in result.items)
          [for (final c in _c.columns) c.value(row) ?? ''],
      ],
    );
  }

  List<Widget> _exportButtons({required bool large}) {
    final export = _c.export;
    if (export == null) return const [];
    return [
      UtenPrintPreviewButton(
        title: export.title,
        subtitle: '最多前 2000 行', // TODO(l10n): 补 arb
        loader: _printLoader,
        exportEndpoint: export.endpoint,
        exportPermission: export.permission,
        exportReport: '',
        exportQuery: _exportQuery,
        exportFilename: export.title,
        type: large ? UtenButtonType.primary : UtenButtonType.tonal,
        size: large ? UtenButtonSize.large : UtenButtonSize.small,
      ),
      UtenExportButton(
        endpoint: export.endpoint,
        requiredPermission: export.permission,
        report: '',
        queryParams: _exportQuery,
        filename: export.title,
        label: export.label,
        type: large ? UtenButtonType.primary : UtenButtonType.secondary,
        size: large ? UtenButtonSize.large : UtenButtonSize.medium,
      ),
    ];
  }

  // ---- 行菜单 + 批量 ------------------------------------------------------

  List<UtenContextMenuEntry> _menuItems(TItem row) {
    final override = _c.rowMenuOverride;
    if (override != null) return override(this, row);
    final inUse = _c.statusOf(row) == '使用';
    final writable = _rowWritable(row);
    return [
      if (_c.onOpen != null) ...[
        UtenMenuItem(
          label: '查看详情', // TODO(l10n): 补 arb
          icon: Icons.open_in_new_rounded,
          onTap: () => _c.onOpen!(this, row),
        ),
        const UtenMenuDivider(),
      ],
      UtenMenuItem(
        label: inUse ? '禁用${_c.noun}' : '启用${_c.noun}', // TODO(l10n): 补 arb
        icon: inUse
            ? Icons.pause_circle_outline_rounded
            : Icons.play_circle_outline_rounded,
        enabled: _c.canStatus && writable,
        destructive: inUse,
        onTap: () => toggleStatus(row),
      ),
      if (_c.onEdit != null)
        UtenMenuItem(
          label: '编辑${_c.noun}', // TODO(l10n): 补 arb
          icon: Icons.edit_outlined,
          enabled: _c.canEdit && writable,
          onTap: () =>
              withDetail(_c.idOf(row), (detail) => _c.onEdit!(this, detail)),
        ),
      ...?_c.extraMenuItems?.call(this, row),
      UtenMenuItem(
        label: '删除${_c.noun}', // TODO(l10n): 补 arb
        icon: Icons.delete_outline_rounded,
        destructive: true,
        enabled: _c.canDelete && writable,
        onTap: () => batchDelete({_c.idOf(row)}),
      ),
    ];
  }

  List<Widget> _batchActions(BuildContext context, Set<String> ids) {
    final override = _c.batchActionsOverride;
    if (override != null) return override(this, ids);
    final extra = _c.extraBatchActions?.call(this, ids) ?? const <Widget>[];
    if (!_c.canStatus && !_c.canDelete) return extra;
    final byId = _rowsById();
    final includesReadOnly =
        _c.writableOf != null &&
        ids.any((id) => byId[id] == null || !_c.writableOf!(byId[id] as TItem));
    if (includesReadOnly) {
      return [
        ...extra,
        Text(
          _c.readOnlyBatchHint ??
              '所选${_c.noun}包含只读数据，请取消只读的再批量操作', // TODO(l10n): 补 arb
        ),
      ];
    }
    // 没勾选时按钮灰着(悬浮批量区常驻，未选态靠按钮禁用态辨识)。
    final idle = _busy || ids.isEmpty;
    return [
      ...extra,
      if (_c.canStatus) ...[
        UtenButton(
          key: const ValueKey('master-batch-disable'),
          size: UtenButtonSize.small,
          type: UtenButtonType.tonal,
          icon: Icons.pause_circle_outline_rounded,
          onPressed: idle ? null : () => batchSetStatus(ids, '禁用'),
          child: const Text('批量禁用'), // TODO(l10n): 补 arb
        ),
        UtenButton(
          key: const ValueKey('master-batch-enable'),
          size: UtenButtonSize.small,
          type: UtenButtonType.tonal,
          icon: Icons.play_circle_outline_rounded,
          onPressed: idle ? null : () => batchSetStatus(ids, '使用'),
          child: const Text('批量启用'), // TODO(l10n): 补 arb
        ),
      ],
      if (_c.canDelete)
        UtenButton(
          key: const ValueKey('master-batch-delete'),
          size: UtenButtonSize.small,
          type: UtenButtonType.danger,
          icon: Icons.delete_outline_rounded,
          onPressed: idle ? null : () => batchDelete(ids),
          child: const Text('批量删除'), // TODO(l10n): 补 arb
        ),
    ];
  }

  // ---- build -------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return UtenEmpty.error(
        message: _error,
        actionLabel: '重试', // TODO(l10n): 补 arb
        onAction: _load,
      );
    }
    final d = _category;
    if (d == null) {
      return Center(
        child: Text(
          '未选择分类', // TODO(l10n): 补 arb
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    final isSystemRoot = isSystemUncategorizedCategory(
      systemManaged: d.systemManaged,
    );
    final canMutateCategory = canMutateMasterCategory(
      hasEditPermission: widget.canEditCategory,
      systemManaged: d.systemManaged,
    );
    final exportInCard = _c.export?.inCard ?? false;
    // compact：容器 gutter 已提供水平留白；medium+：明细区自带水平内边距。
    final hPad = context.breakpoint.isCompact ? 0.0 : UtenSpacing.s16;
    final total = _page?.total ?? 0;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: hPad),
      child: UtenCollapsingHeaderScrollView(
        // 滚走区：分类信息卡——上滑即收起、腾出表格空间。
        collapsingHeader: Padding(
          padding: const EdgeInsets.fromLTRB(
            0,
            UtenSpacing.s16,
            0,
            UtenSpacing.s12,
          ),
          child: MasterDetailCard(
            title: d.name,
            icon: _c.icon,
            subtitle:
                '编号前缀 ${d.effectivePrefix ?? _c.defaultCodePrefix}${d.codePrefix == null ? '(继承)' : ''}'
                '${d.remark?.isNotEmpty == true ? ' · ${d.remark}' : ''} · 层级 L${d.level}',
            // 卡片只留标题 + 操作：层级/父级/子项数左侧分类树里都能看出。
            stats: const [],
            canEdit: canMutateCategory,
            canAddChild: widget.canAddCategory,
            canDelete: widget.canDeleteCategory && !isSystemRoot,
            onAddChild: widget.onAddChild,
            onEdit: () {
              final current = _category;
              if (current != null) widget.onEditCategory(current);
            },
            onDelete: widget.onDeleteCategory,
            deleteLabel: '删除分类', // TODO(l10n): 补 arb
            extraActions: [
              if (widget.canAddCategory && isSystemRoot)
                MasterDetailCardAction(
                  icon: Icons.add_rounded,
                  label: '新增子分类', // TODO(l10n): 补 arb
                  onPressed: widget.onAddChild,
                ),
            ],
            secondaryActions: [
              if ((widget.canEditCategory || widget.canDeleteCategory) &&
                  isSystemRoot)
                const SystemMasterCategoryProtectionNotice(),
              ...?_c.cardActions?.call(this),
              if (exportInCard) ..._exportButtons(large: false),
            ],
          ),
        ),
        // body：标题 + 搜索 + 添加(卡片收起后吸顶) + 表格(内滚)。
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
              child: Row(
                children: [
                  Icon(_c.icon, size: 18, color: theme.colorScheme.primary),
                  const SizedBox(width: UtenSpacing.s8),
                  Text(
                    '${_c.noun} ($total)', // TODO(l10n): 补 arb
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: UtenSpacing.s12),
                  Expanded(
                    child: UtenSearchBar(
                      // key 含分类 + 种子：切分类 / 树搜索写入关键词时重建搜索框。
                      key: ValueKey(
                        '${_c.keyPrefix}-search-${widget.categoryId}-$_kwSeed',
                      ),
                      hint: _c.searchHint,
                      initialValue: _keyword,
                      onChanged: _onKeywordChanged,
                    ),
                  ),
                  if (_c.canCreate && _c.onCreate != null) ...[
                    const SizedBox(width: UtenSpacing.s16),
                    UtenButton(
                      type: UtenButtonType.tonal,
                      icon: Icons.add_rounded,
                      onPressed: () => _c.onCreate!(this),
                      child: Text('添加${_c.noun}'), // TODO(l10n): 补 arb
                    ),
                  ],
                ],
              ),
            ),
            // primary:true → 表体参与「卡片折叠 → 表格内滚」联动。
            Expanded(
              child: MasterDataTableView<TItem>(
                primary: true,
                columns: _c.columns,
                items: _page?.items ?? <TItem>[],
                // 多选：最前列勾选框 + 表头三态全选；选中非空时工具条出批量操作区。
                selectable: true,
                idOf: _c.idOf,
                selectedIds: _selectedIds,
                onSelectedIdsChanged: (s) => setState(() => _selectedIds = s),
                batchActionsBuilder: _batchActions,
                rowMenuBuilder: _menuItems,
                toolbarActions: exportInCard || _c.export == null
                    ? null
                    : _exportButtons(large: true),
                leadingGroups: _groups,
                facets: _columnFacets,
                nullCounts: _columnNullCounts,
                filters: _columnFilters,
                onFilterChanged: _onFilterChanged,
                // 行底色按状态：使用=浅蓝、禁用=浅红；单击选中自动加深加亮。
                rowColor: (row) => switch (_c.statusOf(row)) {
                  '使用' => Colors.lightBlue.withValues(alpha: 0.13),
                  '禁用' => Colors.red.withValues(alpha: 0.10),
                  _ => null,
                },
                onRowTap: _c.onOpen == null
                    ? null
                    : (row) => _c.onOpen!(this, row),
                sortColumn: _sortKey,
                sortAscending: _sortAsc,
                onSortChange: _onSortChange,
                isLoading: _listLoading && _page == null,
                loadingMore: _listLoading && _page != null,
                error: _listError,
                onRetry: () => reload(),
                emptyMessage: '该分类暂无${_c.noun}', // TODO(l10n): 补 arb
                currentPage: _page?.page ?? 1,
                totalPages: _page?.totalPages ?? 1,
                onPageChange: (p) => reload(page: p),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
