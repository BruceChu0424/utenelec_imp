import '../../../shared/paging/scoped_paged_read_view_mixin.dart';
// 模具选择字段（货品编辑表单「生产」组）：分类树 + 分页明细的自适应侧窗，按编号/名称/位置/
// 备注模糊搜模具主档，点行暂选、确定后回填；表单值提交模具 UUID（mouldId），展示为「编号 名称」。
//
// 字段 State 分开保留已绑定记录的显示与尚未提交的查找文字；MasterEditForm 的当前值 /
// 恢复快照负责正式 UUID，普通输入仅查找候选，选中真实记录后才回写，取消恢复绑定显示。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/inputs/uten_reference_picker_field.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../components/layout/uten_panel_header.dart';
import '../../../components/layout/uten_picker_confirm_bar.dart';
import '../../../components/layout/uten_split_view.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../../shared/auth/permissions.dart';
import 'mould_manufacturer_field.dart';
import '../models/product_category_node.dart';
import '../repositories/mould_category_repository.dart';
import 'master_data_table_view.dart';
import 'uten_category_tree_view.dart';
import '../models/mould_node.dart';
import '../repositories/mould_repository.dart';

class MouldPickerField extends ConsumerStatefulWidget {
  const MouldPickerField({
    super.key,
    required this.initialValue,
    required this.initialDisplay,
    required this.onChanged,
    this.readBoundary,
    this.initialDisplayId,
  });

  /// 表单提交值（模具 UUID 或空串/null）。
  final String? initialValue;

  /// 只读展示文案（如「19-05-43-A Z9 146 45A插面」；详情 mouldCode/mouldName 拼接）。
  final String? initialDisplay;

  /// UUID belonging to [initialDisplay]. A goods-detail summary is usable
  /// without another mould read only when it describes the current value.
  final String? initialDisplayId;

  /// 回写提交值（mouldId 字段，UUID 字符串或 null）。
  final void Function(dynamic value) onChanged;

  /// Production hosts bind the trusted identity/API/permission snapshot. This
  /// invalidates cached reads; it does not grant mould access.
  final SensitiveReadBoundary? readBoundary;

  @override
  ConsumerState<MouldPickerField> createState() => _MouldPickerFieldState();
}

class _MouldPickerFieldState extends ConsumerState<MouldPickerField> {
  late final TextEditingController _ctl;
  late String _selectedDisplay;
  String? _selectedId;
  bool _snapshotDisplay = false;
  bool _writingDisplay = false;
  int _displayVersion = 0;
  bool _queryDirty = false;
  int _readGeneration = 0;
  ProviderSubscription<SensitiveReadBoundary>? _readSubscription;

  @override
  void initState() {
    super.initState();
    _ctl = TextEditingController();
    _adoptValue(widget.initialValue);
    _bindBoundary();
    if (!_snapshotDisplay) unawaited(_resolveBoundDisplay());
  }

  static String? _id(String? value) =>
      value == null || value.trim().isEmpty ? null : value.trim();

  String _unresolvedDisplay() => '已关联模具（名称待加载）';

  void _writeDisplay(String display) {
    _writingDisplay = true;
    _ctl.text = display;
    _writingDisplay = false;
  }

  void _adoptValue(String? value) {
    _displayVersion++;
    _selectedId = _id(value);
    _snapshotDisplay =
        _selectedId != null &&
        _id(widget.initialDisplayId) == _selectedId &&
        (widget.initialDisplay?.trim().isNotEmpty ?? false);
    _selectedDisplay = _selectedId == null
        ? ''
        : _snapshotDisplay
        ? widget.initialDisplay!.trim()
        : _unresolvedDisplay();
    _queryDirty = false;
    _writeDisplay(_selectedDisplay);
  }

  Future<void> _resolveBoundDisplay() async {
    final id = _selectedId;
    final version = _displayVersion;
    final boundary = widget.readBoundary;
    final generation = _readGeneration;
    if (id == null || !_isCurrent(boundary, generation)) return;
    if (boundary != null &&
        !boundary.superAdmin &&
        !boundary.permissions.contains(Perm.mouldView)) {
      _unavailableDisplay();
      return;
    }
    try {
      final detail = await ref.read(mouldRepositoryProvider).detail(id);
      if (!_isCurrent(boundary, generation) ||
          version != _displayVersion ||
          _selectedId != id) {
        return;
      }
      if (detail.id != id) {
        _unavailableDisplay();
        return;
      }
      final display = _mouldLabel(
        MouldListItem(id: detail.id, code: detail.code, name: detail.name),
      );
      if (display.isEmpty) {
        _unavailableDisplay();
        return;
      }
      setState(() {
        _selectedDisplay = display;
        if (!_queryDirty) _writeDisplay(display);
      });
    } catch (_) {
      // A missing/restricted reference remains a truthful unresolved UUID.
      // Resolving presentation must never clear or replace the form's value.
      if (_isCurrent(boundary, generation) &&
          version == _displayVersion &&
          _selectedId == id) {
        _unavailableDisplay();
      }
    }
  }

  void _unavailableDisplay() {
    setState(() {
      _selectedDisplay = '已关联模具（名称暂不可用）';
      if (!_queryDirty) _writeDisplay(_selectedDisplay);
    });
  }

  void _bindBoundary() {
    _readSubscription?.close();
    _readSubscription = widget.readBoundary == null
        ? null
        : ref.listenManual(sensitiveReadBoundaryProvider, (previous, next) {
            if (!mounted || previous == next) return;
            setState(() {
              _readGeneration++;
              _displayVersion++;
              if (!_snapshotDisplay && _selectedId != null) {
                _selectedDisplay = _unresolvedDisplay();
                _queryDirty = false;
                _writeDisplay(_selectedDisplay);
              }
            });
            final generation = _readGeneration;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted &&
                  generation == _readGeneration &&
                  !_snapshotDisplay) {
                unawaited(_resolveBoundDisplay());
              }
            });
          });
  }

  bool _isCurrent(SensitiveReadBoundary? boundary, int generation) =>
      mounted &&
      !_writingDisplay &&
      generation == _readGeneration &&
      widget.readBoundary == boundary &&
      (boundary == null || boundary == ref.read(sensitiveReadBoundaryProvider));

  @override
  void didUpdateWidget(covariant MouldPickerField oldWidget) {
    super.didUpdateWidget(oldWidget);
    var resolve = false;
    if (oldWidget.readBoundary != widget.readBoundary) {
      _readGeneration++;
      _displayVersion++;
      _bindBoundary();
      resolve = !_snapshotDisplay;
    }
    if (_id(oldWidget.initialValue) != _id(widget.initialValue)) {
      _readGeneration++;
      if (_id(widget.initialValue) != _selectedId) {
        _adoptValue(widget.initialValue);
        resolve = !_snapshotDisplay;
      }
    } else if (_selectedId != null &&
        _id(widget.initialDisplayId) == _selectedId &&
        (oldWidget.initialDisplay != widget.initialDisplay ||
            oldWidget.initialDisplayId != widget.initialDisplayId) &&
        (widget.initialDisplay?.trim().isNotEmpty ?? false)) {
      _displayVersion++;
      _snapshotDisplay = true;
      _selectedDisplay = widget.initialDisplay!.trim();
      if (!_queryDirty) _writeDisplay(_selectedDisplay);
    }
    if (resolve) unawaited(_resolveBoundDisplay());
  }

  @override
  void dispose() {
    _readSubscription?.close();
    _ctl.dispose();
    super.dispose();
  }

  void _set(dynamic uuid, String display) {
    setState(() {
      _displayVersion++;
      _readGeneration++;
      _selectedId = _id(uuid as String?);
      _snapshotDisplay = false;
      _selectedDisplay = display;
      _queryDirty = false;
      _writeDisplay(display);
    });
    widget.onChanged(uuid);
  }

  Future<void> _pick(
    String keyword,
    SensitiveReadBoundary? boundary,
    int generation,
  ) async {
    if (!_isCurrent(boundary, generation)) return;
    final picked = await showUtenAdaptivePanel<MouldListItem>(
      context: context,
      drawerWidth: 960,
      builder: (ctx) => _MouldSearchSheet(
        initialKeyword: _queryDirty ? keyword : '',
        readBoundary: boundary,
        isCurrent: () => _isCurrent(boundary, generation),
      ),
    );
    if (picked == null || !_isCurrent(boundary, generation)) return;
    _set(picked.id, _mouldLabel(picked));
  }

  static String _mouldLabel(MouldListItem m) {
    final code = m.code ?? '';
    final name = m.name ?? '';
    if (code.isEmpty) return name;
    if (name.isEmpty) return code;
    return '$code $name';
  }

  @override
  Widget build(BuildContext context) {
    final boundary = widget.readBoundary;
    final generation = _readGeneration;
    bool current() => _isCurrent(boundary, generation);
    return UtenReferencePickerField<MouldListItem>(
      controller: _ctl,
      label: '模具',
      hint: '模具',
      suggestionScope: (boundary, generation),
      isCurrent: current,
      loadSuggestions: (query) async {
        if (!current()) return const [];
        final result = await ref
            .read(mouldRepositoryProvider)
            .search(query, size: 8);
        return current() ? result.items : const [];
      },
      labelOf: _mouldLabel,
      onInputChanged: (text) => _queryDirty = text != _selectedDisplay,
      onSelected: (mould) {
        if (current()) _set(mould.id, _mouldLabel(mould));
      },
      onOpenPicker: (keyword) => _pick(keyword, boundary, generation),
      onClear: () {
        if (current()) _set(null, '');
      },
      onEditingDismissed: () {
        // An unfinished lookup must not visually replace a committed UUID.
        if (_ctl.text != _selectedDisplay) {
          _ctl.text = _selectedDisplay;
        }
        _queryDirty = false;
      },
      optionBuilder: (context, mould) => ListTile(
        dense: true,
        title: Text(
          _mouldLabel(mould),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: (mould.categoryName ?? '').isEmpty
            ? null
            : Text(mould.categoryName!),
      ),
    );
  }
}

/// 分类与可按列搜索的明细选择窗，确认暂选记录后回填模具 UUID。
class _MouldSearchSheet extends ConsumerStatefulWidget {
  const _MouldSearchSheet({
    this.initialKeyword = '',
    this.readBoundary,
    required this.isCurrent,
  });
  final String initialKeyword;
  final SensitiveReadBoundary? readBoundary;
  final bool Function() isCurrent;

  @override
  ConsumerState<_MouldSearchSheet> createState() => _MouldSearchSheetState();
}

class _MouldSearchSheetState extends ConsumerState<_MouldSearchSheet>
    with ScopedPagedReadViewMixin<_MouldSearchSheet> {
  @override
  void scopedPagedReadOwnerChanged() {
    _boundaryChanged = true;
    _requestVersion++;
    if (mounted) {
      setState(() {
        _results = const [];
        _picked = null;
        _loading = false;
      });
    }
    _closeStaleRoute();
    if (mounted) {
      setState(() {
        _error = scopedPagedReadRejection?.message;
      });
    }
  }

  late final _searchCtl = TextEditingController(text: widget.initialKeyword);
  List<MouldListItem> _results = const [];
  final _rows = MasterDataTableRowsController<MouldListItem>();
  MouldListItem? _picked;
  bool _loading = false;
  String? _error;
  String _query = '';
  List<ProductCategoryNode> _tree = const [];
  String? _categoryId;
  String _categoryName = '全部分类';
  String? _treeError;
  bool _treeLoading = true;
  final Map<String, String?> _filters = {};
  MouldFacets? _facets;
  int _requestVersion = 0;
  int _page = 1;
  int _requestedPage = 1;
  int _totalPages = 1;
  bool _boundaryChanged = false;
  bool _closeScheduled = false;
  ProviderSubscription<SensitiveReadBoundary>? _readSubscription;

  bool get _canRead =>
      mounted &&
      !_boundaryChanged &&
      widget.isCurrent() &&
      (widget.readBoundary == null ||
          widget.readBoundary == ref.read(sensitiveReadBoundaryProvider));

  void _closeStaleRoute() {
    if (_closeScheduled) return;
    _closeScheduled = true;
    final route = ModalRoute.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final navigator = route?.navigator;
      if (route == null || navigator == null || !route.isActive) return;
      if (route.isCurrent) {
        navigator.pop();
      } else {
        navigator.removeRoute(route);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    if (widget.readBoundary != null) {
      _readSubscription = ref.listenManual(sensitiveReadBoundaryProvider, (
        previous,
        next,
      ) {
        if (!mounted || previous == next || _boundaryChanged) return;
        setState(() {
          _boundaryChanged = true;
          _requestVersion++;
          _results = const [];
          _picked = null;
          _tree = const [];
          _facets = null;
          _loading = false;
        });
        _closeStaleRoute();
      });
    }
    if (!_canRead) return;
    // 进滑窗先给一页默认结果，空关键词也能选。
    _loadTree();
    _search(widget.initialKeyword);
    _loadFacets();
  }

  @override
  void dispose() {
    _readSubscription?.close();
    _searchCtl.dispose();
    super.dispose();
  }

  void _onInputChanged(String text) {
    if (!_canRead) return;
    setState(() {
      _requestVersion++;
      _query = text.trim();
      _results = const [];
      _picked = null;
      _page = 1;
      _requestedPage = 1;
      _totalPages = 1;
      _error = null;
      _loading = true;
    });
  }

  Future<void> _search(
    String text, {
    int page = 1,
    bool useCache = false,
  }) async {
    final query = text.trim();
    if (!_canRead || query != _searchCtl.text.trim()) return;
    final requestVersion = ++_requestVersion;
    setState(() {
      _query = query;
      _requestedPage = page;
      _picked = null;
      _loading = true;
      _error = null;
    });
    try {
      final repo = ref.read(mouldRepositoryProvider);
      final category = _categoryId;
      final filters = Map<String, String?>.unmodifiable(_filters);
      Object pagingQuery() => [
        ref.read(mouldRepositoryProvider),
        _categoryId,
        _query,
        _filters,
      ];
      final result = await readScopedPage<MouldListItem>(
        page,
        query: pagingQuery(),
        currentQuery: pagingQuery,
        useCache: useCache,
        isCurrent: () => _canRead,
        fetchPage: (target) => category == null
            ? repo.listGlobal(
                keyword: query,
                page: target,
                size: 50,
                filters: filters,
              )
            : repo.list(
                category,
                keyword: query,
                page: target,
                size: 50,
                filters: filters,
              ),
      );
      if (!_canRead || requestVersion != _requestVersion) return;
      setState(() {
        _results = result.items;
        _page = result.page;
        _totalPages = result.totalPages < 1 ? 1 : result.totalPages;
        _loading = false;
      });
    } catch (_) {
      if (!_canRead || requestVersion != _requestVersion) return;
      setState(() {
        _error = '模具搜索失败，请重试';
        _loading = false;
      });
    }
  }

  Future<void> _loadTree() async {
    if (!_canRead) return;
    setState(() {
      _treeLoading = true;
      _treeError = null;
    });
    try {
      final tree = await ref.read(mouldCategoryRepositoryProvider).tree();
      if (_canRead) {
        setState(() {
          _tree = hoistSingleRootTree(tree);
          _treeLoading = false;
        });
      }
    } catch (_) {
      if (_canRead) {
        setState(() {
          _treeError = '分类加载失败';
          _treeLoading = false;
        });
      }
    }
  }

  Future<void> _loadFacets() async {
    if (!_canRead) return;
    final category = _categoryId;
    try {
      final repo = ref.read(mouldRepositoryProvider);
      final facets = await (category == null
          ? repo.globalFacets()
          : repo.facets(category));
      if (_canRead && category == _categoryId) setState(() => _facets = facets);
    } catch (_) {
      /* The primary list and free-text search remain available. */
    }
  }

  void _chooseCategory(ProductCategoryNode? node) {
    if (!_canRead) return;
    setState(() {
      _categoryId = node?.id;
      _categoryName = node == null ? '全部分类' : categoryNodeLabel(node);
      _filters.clear();
      _facets = null;
    });
    _search(_searchCtl.text);
    _loadFacets();
  }

  void _confirm() {
    if (!_canRead || _loading || _error != null || _picked == null) return;
    final current = _rows.items
        .where((row) => row.id == _picked!.id)
        .firstOrNull;
    if (current != null) Navigator.pop(context, current);
  }

  Widget _categoryTree() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ListTile(
        key: const Key('mould-picker-all-categories'),
        dense: true,
        selected: _categoryId == null,
        title: const Text('全部分类'),
        onTap: () => _chooseCategory(null),
      ),
      Expanded(
        child: _treeLoading
            ? const Center(child: CircularProgressIndicator())
            : _treeError != null
            ? Center(
                child: TextButton(
                  onPressed: _loadTree,
                  child: Text('$_treeError，重试'),
                ),
              )
            : UtenCategoryTreeView<ProductCategoryNode>(
                nodes: _tree,
                selectedIds: {?_categoryId},
                onNodeTap: _chooseCategory,
                expandOnRowTap: true,
                sortByCode: false,
              ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    if (!_canRead) {
      _closeStaleRoute();
      return const SizedBox.shrink();
    }
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          UtenPanelHeader(title: '选择模具', onClose: () => Navigator.pop(context)),
          const Divider(height: 1),
          Expanded(
            child: UtenSplitView(
              initialLeadingWidth: 240,
              minLeadingWidth: 180,
              maxLeadingWidth: 400,
              selectedLeadingLabel: _categoryName,
              selectedLeadingKey: _categoryId,
              openLeadingButtonKey: const Key('mould-picker-open-categories'),
              leading: Padding(
                padding: UtenPanelSpacing.body(context),
                child: _categoryTree(),
              ),
              trailing: Padding(
                padding: UtenPanelSpacing.body(context),
                child: Column(
                  children: [
                    UtenSearchBar(
                      controller: _searchCtl,
                      hint: '模具编号 / 名称 / 位置 / 制造商 / 备注',
                      onInputChanged: _onInputChanged,
                      onChanged: _search,
                      onSubmitted: _search,
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: MasterDataTableView<MouldListItem>(
                        expensiveRowMounts: false,
                        key: const Key('mould-picker-results'),
                        rowsController: _rows,
                        columns: [
                          MasterColumnDef(
                            key: 'code',
                            label: '模具编号',
                            width: 160,
                            value: (m) => m.code,
                          ),
                          MasterColumnDef(
                            key: 'categoryName',
                            label: '系列 / 分类',
                            width: 150,
                            value: (m) => m.categoryName,
                          ),
                          MasterColumnDef(
                            key: 'name',
                            label: '模具名称',
                            width: 220,
                            value: (m) => m.name,
                          ),
                          MasterColumnDef(
                            key: 'place',
                            label: '存放位置',
                            width: 110,
                            value: (m) => m.place,
                          ),
                          MasterColumnDef(
                            key: 'manufacturer',
                            label: '制造商',
                            width: 110,
                            value: (m) => m.manufacturer,
                            cellBuilder: (_, m) =>
                                MouldManufacturerValue(value: m.manufacturer),
                          ),
                          MasterColumnDef(
                            key: 'remark',
                            label: '备注',
                            width: 180,
                            value: (m) => m.remark,
                          ),
                        ],
                        items: _results,
                        facets: _facets?.fields ?? const {},
                        nullCounts: _facets?.nullCounts ?? const {},
                        filters: _filters,
                        serverColumnSearch: true,
                        onFilterChanged: (key, value) {
                          if (!_canRead) return;
                          setState(() {
                            if (value == null) {
                              _filters.remove(key);
                            } else {
                              _filters[key] = value;
                            }
                          });
                          _search(_searchCtl.text);
                        },
                        idOf: (m) => m.id,
                        rowKeyOf: (m) => m.id,
                        isSelected: (m) => _picked?.id == m.id,
                        singleTapRows: true,
                        showFullscreenToggle: false,
                        onRowTap: (m) {
                          if (!_canRead || _loading) return;
                          final current = _rows.items
                              .where((row) => row.id == m.id)
                              .firstOrNull;
                          if (current != null) {
                            setState(() => _picked = current);
                          }
                        },
                        currentPage: _page,
                        totalPages: _totalPages,
                        paginationScope: (
                          _query,
                          _categoryId,
                          _filters.toString(),
                        ),
                        isLoading: _loading,
                        error: _error,
                        onRetry: () => _search(_query, page: _requestedPage),
                        onPageChange: (page) =>
                            _search(_query, page: page, useCache: true),
                        emptyMessage: '没有匹配的模具',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          UtenPickerConfirmBar(
            selectedCount: _picked == null ? 0 : 1,
            selectedLabel: _picked == null
                ? null
                : _MouldPickerFieldState._mouldLabel(_picked!),
            confirmEnabled:
                _picked != null && !_loading && _error == null && _canRead,
            onConfirm: _confirm,
          ),
        ],
      ),
    );
  }
}
