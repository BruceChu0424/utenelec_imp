import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_refresh_button.dart';
import '../../../components/feedback/uten_date_range_picker.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_history_time_filter.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/native_read_view_scope_mixin.dart';
import '../../../shared/auth/permissions.dart';
import '../repositories/master_record_history_repository.dart'
    show MasterRecordRevision, masterRecordHistoryRepositoryProvider;
import '../models/master_facet.dart';
import '../widgets/master_data_table_view.dart';
import '../widgets/master_inline_edit.dart';
import '../widgets/master_record_history_labels.dart';
import '../widgets/product_category_picker_panel.dart';

class MasterRecordHistoryPage extends ConsumerStatefulWidget {
  const MasterRecordHistoryPage({
    super.key,
    this.entityType,
    this.recordId,
    this.categoryId,
    this.changeSignal,
  });
  final String? entityType;
  final String? recordId;
  final String? categoryId;
  final ValueNotifier<bool>? changeSignal;
  @override
  ConsumerState<MasterRecordHistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends ConsumerState<MasterRecordHistoryPage>
    with NativeReadViewScopeMixin<MasterRecordHistoryPage> {
  late String _entity =
      masterHistoryViewPermissions.containsKey(widget.entityType)
      ? widget.entityType!
      : 'all';
  late String? _record = widget.recordId;
  late String? _category = widget.categoryId;
  late ValueNotifier<bool> _changes =
      widget.changeSignal ?? ValueNotifier(false);
  String? _categoryName;
  String? _action;
  String _keyword = '';
  String _keywordColumn = 'recordLabel';
  String _actor = '';

  /// 修改日期门控；默认近三个月（2026-10-24 用户口径，与全站历史段一致）。
  UtenHistoryTimeValue _time = UtenHistoryTimeValue.lastThreeMonths();
  final Map<int, String?> _cursors = {1: null};
  List<MasterRecordRevision> _rows = const [];
  String? _nextCursor;
  int _page = 1;
  int _epoch = 0;
  bool _loading = false;
  bool _pickingCategory = false;
  bool _pickingDate = false;
  String? _error;
  String t(String zh, String en, String ko) =>
      masterEditText(context, zh, en, ko);
  String get _query =>
      '$_entity:$_record:$_category:$_action:$_keyword:$_actor:${_time.hashCode}';

  @override
  void initState() {
    super.initState();
    initializeNativeReadScope();
    ref.listenManual(currentPermissionsProvider, (previous, next) {
      if (!setEquals(previous, next)) _permissionsChanged();
    });
    ref.listenManual(isSuperAdminProvider, (previous, next) {
      if (previous != next) _permissionsChanged();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(reset: true));
  }

  void _permissionsChanged() {
    invalidateNativeReadAccess();
    final permission = masterHistoryViewPermissions[_entity];
    final permissions = ref.read(currentPermissionsProvider);
    if (!ref.read(isSuperAdminProvider) &&
        permission != null &&
        !permissions.contains(permission)) {
      _entity = 'all';
      _record = null;
      _category = null;
      _categoryName = null;
    }
    _clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load(reset: true);
    });
  }

  @override
  void dispose() {
    if (widget.changeSignal == null) _changes.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant MasterRecordHistoryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.changeSignal != widget.changeSignal) {
      if (oldWidget.changeSignal == null) _changes.dispose();
      _changes = widget.changeSignal ?? ValueNotifier(false);
    }
    if (oldWidget.entityType != widget.entityType ||
        oldWidget.recordId != widget.recordId ||
        oldWidget.categoryId != widget.categoryId) {
      _entity = masterHistoryViewPermissions.containsKey(widget.entityType)
          ? widget.entityType!
          : 'all';
      _record = widget.recordId;
      _category = widget.categoryId;
      _categoryName = null;
      _action = null;
      _keyword = '';
      _keywordColumn = 'recordLabel';
      _actor = '';
      _time = UtenHistoryTimeValue.lastThreeMonths();
      invalidateNativeReadAccess();
      _clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load(reset: true);
      });
    }
  }

  void _clear() {
    _epoch++;
    if (!mounted) return;
    setState(() {
      _rows = const [];
      _loading = false;
      _error = null;
      _cursors
        ..clear()
        ..[1] = null;
      _nextCursor = null;
      _page = 1;
    });
  }

  @override
  void nativeReadOwnerChanged() => _clear();
  @override
  void nativeReadPermissionChanged() => _clear();
  @override
  Future<void> nativeReadReload() => _load(reset: true);

  Future<void> _load({bool reset = false, int? page}) async {
    if (reset) {
      _cursors
        ..clear()
        ..[1] = null;
      page = 1;
    }
    final target = page ?? _page;
    if (!_cursors.containsKey(target)) return;
    final accepts = captureNativeRead(_query, () => _query);
    if (!accepts()) return;
    final epoch = ++_epoch;
    setState(() {
      _loading = true;
      _error = null;
      _rows = const [];
    });
    try {
      final range = _time.range;
      final response = await ref
          .read(masterRecordHistoryRepositoryProvider)
          .list(
            entityType: _entity == 'all' ? null : _entity,
            recordId: _record,
            categoryId: _category,
            action: _action,
            actorKeyword: _actor.trim().isEmpty ? null : _actor.trim(),
            keyword: _keyword.trim().isEmpty ? null : _keyword.trim(),
            dateFrom: range == null
                ? null
                : ChinaDateTime.formatDate(range.start),
            dateTo: range == null ? null : ChinaDateTime.formatDate(range.end),
            cursor: _cursors[target],
          );
      if (!accepts() || epoch != _epoch) return;
      acceptNativeRead();
      setState(() {
        _rows = response.entries;
        _page = target;
        _nextCursor = response.nextCursor;
        if (response.nextCursor != null) {
          _cursors[target + 1] = response.nextCursor;
        }
        _loading = false;
      });
    } catch (error) {
      if (!accepts() || epoch != _epoch) return;
      setState(() {
        _loading = false;
        _error = error is ApiException
            ? error.message
            : t(
                '加载修改历史失败，请重试',
                'Could not load change history. Try again.',
                '변경 기록을 불러오지 못했습니다.',
              );
      });
    }
  }

  Map<String, String?> get _filters => {
    if (_entity != 'all') 'entityType': _entity,
    if (_action != null) 'action': _action,
    if (_keyword.isNotEmpty) 'search.$_keywordColumn': _keyword,
    if (_actor.isNotEmpty) 'search.actorName': _actor,
  };

  void _filterChanged(String key, String? value) {
    if (_filters[key] == value) return;
    if (!const {
      'entityType',
      'action',
      'search.recordLabel',
      'search.recordCode',
      'search.actorName',
    }.contains(key)) {
      return;
    }
    if (key == 'entityType' &&
        value != null &&
        (!masterHistoryViewPermissions.containsKey(value) ||
            (!ref.read(isSuperAdminProvider) &&
                !ref
                    .read(currentPermissionsProvider)
                    .contains(masterHistoryViewPermissions[value])))) {
      return;
    }
    setState(() {
      switch (key) {
        case 'entityType':
          _entity = value ?? 'all';
          _record = null;
          _category = null;
          _categoryName = null;
        case 'action':
          _action = value;
        case 'search.recordLabel':
        case 'search.recordCode':
          _keywordColumn = key.substring('search.'.length);
          _keyword = value?.trim() ?? '';
        case 'search.actorName':
          _actor = value?.trim() ?? '';
      }
    });
    _load(reset: true);
  }

  Future<void> _pickDate() async {
    if (_pickingDate || _loading || !nativeReadAccessConfirmed) return;
    final query = _query;
    final owns = captureNativeOwnership();
    setState(() => _pickingDate = true);
    try {
      final range = await showUtenDateRangePicker(
        context: context,
        firstDate: DateTime.utc(2020),
        lastDate: ChinaDateTime.today(),
        initialDateRange: _time.range,
        helpText: t('筛选修改日期', 'Filter change dates', '변경 날짜 필터'),
        wrap: (context, child) =>
            trackNativeReadDialog(context, child, readOnly: true),
      );
      if (!owns() || query != _query || range == null) return;
      setState(() => _time = UtenHistoryTimeValue.range(range));
      await _load(reset: true);
    } finally {
      if (mounted) setState(() => _pickingDate = false);
    }
  }

  Future<void> _pickCategory() async {
    if (_pickingCategory ||
        _entity == 'all' ||
        _loading ||
        !nativeReadAccessConfirmed ||
        !_canCategory) {
      return;
    }
    final query = _query;
    final owns = captureNativeOwnership();
    setState(() => _pickingCategory = true);
    try {
      final tree = await ref
          .read(masterRecordHistoryRepositoryProvider)
          .categories(entityType: _entity);
      if (!mounted || !owns() || query != _query) return;
      final selected = await showUtenProductCategoryPickerPanel(
        context,
        tree: tree,
        selectedId: _category,
        hideEmptyCategories: false,
        scopeBuilder: (panelContext, child) =>
            trackNativeReadDialog(panelContext, child, readOnly: true),
        title: t('筛选分类', 'Filter categories', '분류 필터'),
        subtitle: t(
          '包含下级与已删除分类的历史',
          'Includes descendants and deleted categories',
          '하위 및 삭제된 분류 기록 포함',
        ),
      );
      if (!owns() || query != _query || selected == null) return;
      setState(() {
        _category = selected.id;
        _categoryName = selected.name;
        _record = null;
      });
      await _load(reset: true);
    } catch (error) {
      if (mounted && owns()) context.appApiError(error);
    } finally {
      if (mounted) setState(() => _pickingCategory = false);
    }
  }

  Future<void> _open(MasterRecordRevision row) async {
    if (_loading || !nativeReadAccessConfirmed) return;
    final accepts = captureNativeOwnership();
    await context.push<bool>(
      '${RouteName.basicinfoHistory}/${Uri.encodeComponent(row.entityType)}/${Uri.encodeComponent(row.id)}',
      extra: _changes,
    );
    if (accepts() && _changes.value) await _load(reset: true);
  }

  void _back() {
    if (context.canPop()) {
      context.pop(_changes.value);
    } else {
      backTo(context, defaultPath: RouteName.basicinfo);
    }
  }

  bool get _canCategory {
    final permission = masterHistoryCategoryPermissions[_entity];
    return permission != null &&
        (ref.read(isSuperAdminProvider) ||
            ref.read(currentPermissionsProvider).contains(permission)) &&
        nativeReadAccessConfirmed &&
        !_loading;
  }

  void _clearFilters() {
    setState(() {
      _entity = 'all';
      _record = null;
      _category = null;
      _categoryName = null;
      _action = null;
      _keyword = '';
      _keywordColumn = 'recordLabel';
      _actor = '';
      _time = UtenHistoryTimeValue.lastThreeMonths();
    });
    _load(reset: true);
  }

  MasterColumnDef<MasterRecordRevision> _historyColumn({
    required String key,
    required String label,
    required double width,
    required String Function(MasterRecordRevision) value,
    bool columnSearchEnabled = false,
    bool facetSearchEnabled = false,
    String? info,
    MasterHeaderFilterAction? headerFilterAction,
    bool emphasized = false,
  }) => MasterColumnDef(
    key: key,
    label: label,
    width: width,
    value: value,
    columnSearchEnabled: columnSearchEnabled,
    facetSearchEnabled: facetSearchEnabled,
    info: info,
    headerFilterAction: headerFilterAction,
    cellBuilder: (context, row) {
      final text = value(row);
      return Text(
        text.isEmpty ? '—' : text,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: MasterDataTableCellScope.maybeOf(context)?.foregroundColor,
          fontWeight: emphasized ? FontWeight.w600 : null,
        ),
      );
    },
  );

  List<MasterColumnDef<MasterRecordRevision>> _columns() => [
    _historyColumn(
      key: 'recordCode',
      label: t('编号', 'Code', '번호'),
      width: 160,
      value: (row) => row.recordCode,
      columnSearchEnabled: true,
      info: t(
        '搜索编号、名称或修改摘要',
        'Search code, name or change summary',
        '번호, 이름 또는 변경 요약 검색',
      ),
    ),
    _historyColumn(
      // Keep the established name key for saved layouts and server searches.
      key: 'recordLabel',
      label: t('名称', 'Name', '이름'),
      width: 260,
      value: (row) =>
          row.recordName.isNotEmpty ? row.recordName : row.recordLabel,
      columnSearchEnabled: true,
      emphasized: true,
      info: t(
        '搜索编号、名称或修改摘要',
        'Search code, name or change summary',
        '번호, 이름 또는 변경 요약 검색',
      ),
    ),
    _historyColumn(
      key: 'recordedAt',
      label: t('修改时间', 'Time', '변경 시간'),
      width: 178,
      value: (row) => ChinaDateTime.formatIsoInstant(row.recordedAt),
      headerFilterAction: MasterHeaderFilterAction(
        onTap: _pickDate,
        enabled: nativeReadAccessConfirmed && !_loading && !_pickingDate,
        value: _time.range == null
            ? null
            : '${ChinaDateTime.formatDate(_time.range!.start)} ~ '
                  '${ChinaDateTime.formatDate(_time.range!.end)}',
      ),
    ),
    _historyColumn(
      key: 'entityType',
      label: t('资料类型', 'Record type', '자료 유형'),
      width: 130,
      value: (row) => masterHistoryEntityLabel(context, row.entityType),
      facetSearchEnabled: true,
    ),
    _historyColumn(
      key: 'action',
      label: t('操作', 'Action', '작업'),
      width: 100,
      value: (row) => masterHistoryActionLabel(context, row.action),
      facetSearchEnabled: true,
    ),
    _historyColumn(
      key: 'categoryName',
      label: t('分类', 'Category', '분류'),
      width: 165,
      value: (row) => row.categoryName,
      info: _entity == 'all'
          ? t('先选择资料类型', 'Choose a record type first', '자료 유형 먼저 선택')
          : t(
              '包含下级与已删除分类的历史',
              'Includes descendants and deleted categories',
              '하위 및 삭제된 분류 기록 포함',
            ),
      headerFilterAction: MasterHeaderFilterAction(
        onTap: _pickCategory,
        enabled: _canCategory && !_pickingCategory,
        value: _category == null
            ? null
            : (_categoryName ?? t('当前分类', 'Current category', '현재 분류')),
      ),
    ),
    _historyColumn(
      key: 'actorName',
      label: t('操作人', 'Operator', '작업자'),
      width: 155,
      value: (row) => row.actorName,
      columnSearchEnabled: true,
    ),
    _historyColumn(
      key: 'sourceType',
      label: t('修改范围', 'Changed area', '변경 범위'),
      width: 120,
      value: (row) => masterHistorySourceLabel(context, row.sourceType),
    ),
    _historyColumn(
      key: 'summary',
      label: t('修改摘要', 'Change summary', '변경 요약'),
      width: 320,
      value: (row) => row.summary,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final permissions = ref.watch(currentPermissionsProvider);
    final admin = ref.watch(isSuperAdminProvider);
    final allowed = masterHistoryViewPermissions.entries.where(
      (entry) => admin || permissions.contains(entry.value),
    );
    final hasAccess = allowed.isNotEmpty;
    return Scaffold(
      appBar: UtenAppBar(
        title: t('修改历史', 'Change history', '변경 기록'),
        leading: UtenBackButton(onPressed: _back),
        actions: [
          UtenRefreshButton(
            busy: _loading,
            onRefresh: () => _load(reset: true),
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: Column(
            children: [
              if (_loading || _pickingCategory || _pickingDate)
                const LinearProgressIndicator(),
              Expanded(
                child: MasterDataTableView<MasterRecordRevision>(
                  key: const Key('master-record-history-table'),
                  tableKey: 'master.record.history',
                  preserveQueryOnReturn: true,
                  columns: _columns(),
                  requiredLeadingColumnKeys: const [
                    'recordCode',
                    'recordLabel',
                  ],
                  items: hasAccess ? _rows : const [],
                  idOf: (row) => row.id,
                  facets: {
                    'entityType': [
                      for (final entry in allowed)
                        MasterFacetBucket(
                          value: entry.key,
                          count: 0,
                          label: masterHistoryEntityLabel(context, entry.key),
                        ),
                    ],
                    'action': [
                      for (final action in const [
                        'CREATE',
                        'EDIT',
                        'DELETE',
                        'RESTORE',
                        'STATUS',
                      ])
                        MasterFacetBucket(
                          value: action,
                          count: 0,
                          label: masterHistoryActionLabel(context, action),
                        ),
                    ],
                  },
                  nullCounts: const {},
                  filters: _filters,
                  serverColumnSearch: true,
                  facetSearchScope: (_query, _epoch),
                  onFilterChanged: _filterChanged,
                  onRowTap: _loading ? null : _open,
                  isLoading: _loading,
                  error: _error,
                  onRetry: () => _load(),
                  emptyMessage: hasAccess
                      ? t(
                          '暂无符合筛选的修改记录',
                          'No matching changes',
                          '일치하는 변경 기록이 없습니다',
                        )
                      : t(
                          '当前没有资料历史查看权限',
                          'No access to record history',
                          '기록 조회 권한이 없습니다',
                        ),
                  showPaginationControls: false,
                  paginationScope: (_query, _page),
                  toolbarLeadingActions: [
                    if (_record != null)
                      InputChip(
                        label: Text(t('当前资料', 'Current record', '현재 자료')),
                        onDeleted: _loading
                            ? null
                            : () {
                                setState(() => _record = null);
                                _load(reset: true);
                              },
                      ),
                    if (_category != null)
                      InputChip(
                        label: Text(
                          _categoryName ??
                              t('当前分类', 'Current category', '현재 분류'),
                        ),
                        onDeleted: _loading
                            ? null
                            : () {
                                setState(() {
                                  _category = null;
                                  _categoryName = null;
                                });
                                _load(reset: true);
                              },
                      ),
                    if (_filters.isNotEmpty ||
                        _record != null ||
                        _category != null ||
                        _time.range != null)
                      UtenButton(
                        type: UtenButtonType.ghost,
                        size: UtenButtonSize.small,
                        onPressed: _loading ? null : _clearFilters,
                        child: Text(t('清除筛选', 'Clear filters', '필터 지우기')),
                      ),
                  ],
                  toolbarActions: [
                    UtenButton(
                      type: UtenButtonType.secondary,
                      onPressed: _loading || _page <= 1
                          ? null
                          : () => _load(page: _page - 1),
                      child: Text(t('上一页', 'Previous', '이전')),
                    ),
                    Text(t('第 $_page 页', 'Page $_page', '$_page 페이지')),
                    UtenButton(
                      type: UtenButtonType.secondary,
                      onPressed: _loading || _nextCursor == null
                          ? null
                          : () => _load(page: _page + 1),
                      child: Text(t('下一页', 'Next', '다음')),
                    ),
                  ],
                  rowColor: (row) => row.action == 'DELETE'
                      ? UtenColors.error.withValues(alpha: 0.06)
                      : row.action == 'RESTORE'
                      ? UtenColors.success.withValues(alpha: 0.07)
                      : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
