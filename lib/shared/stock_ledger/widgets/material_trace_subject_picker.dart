import '../../paging/scoped_paged_read_view_mixin.dart';
import 'package:flutter/material.dart';
import 'package:uten_imp/components/buttons/uten_close_button.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../features/basic_data/widgets/master_data_table_view.dart';
import '../../../components/layout/uten_picker_confirm_bar.dart';
import '../../../core/network/api_exception.dart';
import '../../models/paged_result.dart';
import '../../providers/sensitive_read_boundary_provider.dart';
import '../material_trace_models.dart';
import '../material_trace_repository.dart';

Future<MaterialTraceSubject?> showMaterialTraceSubjectPicker(
  BuildContext context,
  WidgetRef ref, {
  required String kind,
  String initialKeyword = '',
}) {
  final container = ProviderScope.containerOf(context, listen: false);
  return showUtenAdaptivePanel<MaterialTraceSubject>(
    context: context,
    drawerWidth: 720,
    builder: (_) => UncontrolledProviderScope(
      container: container,
      child: _SubjectPicker(kind: kind, initialKeyword: initialKeyword),
    ),
  );
}

class _SubjectPicker extends ConsumerStatefulWidget {
  const _SubjectPicker({required this.kind, required this.initialKeyword});
  final String kind;
  final String initialKeyword;

  @override
  ConsumerState<_SubjectPicker> createState() => _SubjectPickerState();
}

class _SubjectPickerState extends ConsumerState<_SubjectPicker>
    with ScopedPagedReadViewMixin<_SubjectPicker> {
  @override
  void scopedPagedReadOwnerChanged() {
    if (mounted) {
      setState(_invalidate);
    }
    if (mounted) {
      setState(() {
        _error = scopedPagedReadRejection?.message;
      });
    }
  }

  final _controller = TextEditingController();
  final _rows = MasterDataTableRowsController<MaterialTraceSubject>();
  MaterialTraceSubject? _selected;
  PagedResult<MaterialTraceSubject>? _data;
  SensitiveReadBoundary? _loadedBoundary;
  String? _loadedKeyword;
  String _keyword = '';
  String? _error;
  bool _loading = false;
  bool _rowsReady = false;
  bool _exact = false;
  int _request = 0;

  bool get _batch => widget.kind == 'batch';

  @override
  void initState() {
    super.initState();
    _keyword = widget.initialKeyword.trim();
    _controller.text = _keyword;
    ref.listenManual(sensitiveReadBoundaryProvider, (old, next) {
      if (old == next) return;
      setState(() {
        _invalidate();
        _error = '账号、服务器或权限已变化，请重新搜索';
      });
    });
    if (_keyword.isNotEmpty) _load(1);
  }

  void _invalidate() {
    ++_request;
    _data = null;
    _loadedBoundary = null;
    _loadedKeyword = null;
    _loading = false;
    _rowsReady = false;
    _error = null;
    _selected = null;
    _rows.update(const []);
  }

  void _input(String text) {
    setState(() {
      _keyword = text.trim();
      _invalidate();
    });
  }

  Future<void> _load(int page, {bool useCache = false}) async {
    if (!mounted || _keyword.isEmpty) return;
    final request = ++_request;
    final keyword = _keyword;
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    final repository = ref.read(materialTraceRepositoryProvider);
    setState(() {
      _loading = true;
      _error = null;
      _rowsReady = false;
    });
    final kind = widget.kind, exact = _exact;
    Object pagingQuery() => [
      ref.read(materialTraceRepositoryProvider),
      widget.kind,
      _keyword,
      _exact,
    ];
    try {
      final data = await readScopedPage<MaterialTraceSubject>(
        page,
        query: pagingQuery(),
        currentQuery: pagingQuery,
        useCache: useCache,
        fetchPage: (target) => repository.subjects(
          kind: kind,
          keyword: keyword,
          exact: exact,
          page: target,
        ),
      );
      if (!mounted ||
          request != _request ||
          boundary != ref.read(sensitiveReadBoundaryProvider)) {
        return;
      }
      setState(() {
        _data = data;
        _loadedBoundary = boundary;
        _loadedKeyword = keyword;
        _loading = false;
      });
      _reconcileSelection(request);
    } catch (error) {
      if (!mounted || request != _request) return;
      setState(() {
        _error = error is ApiException ? error.message : '查询失败，请重试';
        _loading = false;
        _selected = null;
      });
    }
  }

  // The shared table may need another layout to merge/evict pages. Reconcile
  // against its settled window rather than only the latest server page.
  void _reconcileSelection(int request) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || request != _request) return;
      if (_rows.isAppending) {
        _reconcileSelection(request);
        WidgetsBinding.instance.ensureVisualUpdate();
        return;
      }
      setState(() {
        final selected = _selected;
        if (selected != null) {
          _selected = _rows.items
              .where((item) => item.identity == selected.identity)
              .firstOrNull;
        }
        _rowsReady = true;
      });
    });
  }

  bool _canSelect(MaterialTraceSubject item) =>
      mounted &&
      !_loading &&
      _rowsReady &&
      _error == null &&
      _loadedBoundary == ref.read(sensitiveReadBoundaryProvider) &&
      _loadedKeyword == _keyword &&
      item.id.isNotEmpty &&
      item.type.isNotEmpty &&
      _rows.items.contains(item);

  void _select(MaterialTraceSubject item) {
    if (_canSelect(item)) setState(() => _selected = item);
  }

  void _confirm() {
    final item = _selected;
    if (item != null && _canSelect(item)) Navigator.of(context).pop(item);
  }

  @override
  void dispose() {
    ++_request;
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ListTile(
        title: Text(_batch ? '选择生产批次' : '选择追溯单据'),
        trailing: UtenCloseButton(
          tooltip: '关闭',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: UtenSearchBar(
          key: const Key('material-trace-subject-search'),
          controller: _controller,
          hint: _batch ? '输入生产批次号或报工单号' : '输入采购、委外、生产或出入库单号',
          debounce: const Duration(milliseconds: 250),
          onInputChanged: _input,
          onChanged: (_) => _load(1),
          onSubmitted: (_) => _load(1),
        ),
      ),
      CheckboxListTile(
        dense: true,
        controlAffinity: ListTileControlAffinity.leading,
        title: const Text('精确匹配编号'),
        value: _exact,
        onChanged: (value) {
          setState(() {
            _exact = value ?? false;
            _invalidate();
          });
          _load(1);
        },
      ),
      Expanded(
        child: MasterDataTableView<MaterialTraceSubject>(
          expensiveRowMounts: false,
          key: ValueKey(('material-trace-subjects', widget.kind)),
          columns: [
            MasterColumnDef(
              key: 'code',
              label: _batch ? '生产批次号' : '单据号',
              width: 210,
              value: (item) => item.code.isEmpty ? item.displayName : item.code,
              columnSearchEnabled: false,
            ),
            MasterColumnDef(
              key: 'type',
              label: '类型',
              width: 130,
              value: (item) => materialTraceSubjectTypeLabel(item.type),
              columnSearchEnabled: false,
            ),
            MasterColumnDef(
              key: 'date',
              label: '日期',
              width: 120,
              value: (item) => item.documentDate,
              columnSearchEnabled: false,
            ),
            MasterColumnDef(
              key: 'goods',
              label: '货品 / 摘要',
              width: 230,
              value: (item) =>
                  item.goodsName ??
                  (item.label != item.code ? item.label : null),
              columnSearchEnabled: false,
            ),
            MasterColumnDef(
              key: 'status',
              label: '状态',
              width: 100,
              value: (item) => item.status == null
                  ? null
                  : materialTraceStatusLabel(item.status!),
              columnSearchEnabled: false,
            ),
          ],
          items: _data?.items ?? const [],
          rowsController: _rows,
          idOf: (item) => '${item.type}:${item.id}',
          rowWidgetKeyOf: (item) =>
              ValueKey(('material-trace-subject', item.type, item.id)),
          singleTapRows: true,
          isSelected: (item) => item.identity == _selected?.identity,
          onRowTap: _select,
          facets: const {},
          nullCounts: const {},
          filters: const {},
          onFilterChanged: (_, _) {},
          currentPage: _data?.page ?? 1,
          totalPages: _data?.totalPages ?? 1,
          paginationScope: (widget.kind, _keyword, _exact, _loadedBoundary),
          onPageChange: (page) => _load(page, useCache: true),
          isLoading: _loading && _data == null,
          loadingMore: _loading && _data != null,
          error: _error,
          onRetry: () => _load(_rows.visiblePage ?? _data?.page ?? 1),
          emptyMessage: _keyword.isEmpty
              ? (_batch ? '输入生产批次号或报工单号开始搜索' : '输入单号开始搜索')
              : '没有当前权限范围内的匹配记录',
          showFullscreenToggle: false,
          showColumnChooser: false,
          enableTextSelection: false,
        ),
      ),
      UtenPickerConfirmBar(
        selectedCount: _selected == null ? 0 : 1,
        selectedLabel: _selected == null
            ? null
            : '${materialTraceSubjectTypeLabel(_selected!.type)} · ${_selected!.code.isEmpty ? _selected!.displayName : _selected!.code}',
        confirmButtonKey: const Key('material-trace-subject-confirm'),
        confirmEnabled: _selected != null && _canSelect(_selected!),
        onConfirm: _confirm,
      ),
    ],
  );
}
