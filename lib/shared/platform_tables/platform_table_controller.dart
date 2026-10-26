import 'dart:convert';
import 'platform_row_draft.dart';
import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/network/api_exception.dart';
import '../business_columns/business_column.dart';
import 'platform_table_binding.dart';
import 'platform_table_layout.dart';
import 'platform_table_models.dart';
import 'platform_table_repository.dart';
import '../providers/authenticated_scope_provider.dart';
import '../../core/network/server_config.dart';

enum PlatformColumnDeletionFailure { forbidden, referenced, busy, unavailable }

enum PlatformTableReadFailure {
  connection,
  forbidden,
  session,
  recordsChanged,
  initialization,
  unavailable,
}

class PlatformColumnDeletionException extends FormatException {
  const PlatformColumnDeletionException(this.failure)
    : super('Column deletion is unavailable');

  final PlatformColumnDeletionFailure failure;
}

/// Shared persistence lifecycle for master tables and editable grids. Row writes
/// are explicit CAS operations and never mutate the host's business record.
class PlatformTableController<T> extends ChangeNotifier {
  static int _nextInstance = 0;
  final int _instance = ++_nextInstance;
  PlatformTableBinding<T>? binding;
  PlatformTableRepository? repository;
  PlatformTableCapabilities? capabilities;
  PlatformTableLayout layout = const PlatformTableLayout();
  String? error;
  PlatformTableReadFailure? readFailure;
  bool loading = false;
  bool disposed = false;
  bool layoutTouched = false;
  int _generation = 0;
  String _signature = '';
  String _tableKey = '';
  Object? _sourceRevision;
  List<T> _items = const [];
  final Map<String, PlatformRowValues> _values = {};
  final Map<String, int> _edits = {};
  final Set<(int, String)> _saving = {};
  ProviderSubscription<PlatformTableLayout>? _layoutSubscription;
  ProviderSubscription<PlatformTableRepository>? _repositorySubscription;
  ProviderSubscription<AuthenticatedScope?>? _queryScopeSubscription;
  ProviderSubscription<String>? _queryServerSubscription;
  int _queryLifecycle = 0;
  bool _hasSessionQueryPreferences = false;
  int _authorizationRevision = 0;
  int get authorizationRevision => _authorizationRevision;
  int get queryLifecycle => _queryLifecycle;
  bool get hasSessionQueryPreferences => _hasSessionQueryPreferences;
  ProviderContainer? _container;
  final Map<String, PlatformColumnDefinition> _definitions = {};
  final Set<String> _recordColumnIds = {};
  final Map<String, PlatformColumnDefinition> _catalogDefinitions = {};
  final Set<(PlatformTableRepository?, String?, int, String)>
  _deletingDefinitions = {};
  Map<String, String?> Function(T)? fallbackFactsOf;
  Iterable<Listenable> Function(T)? fallbackFactListenablesOf;
  PlatformRowDraft? Function(T)? draftOf;
  Set<String> _exactFactKeys = const {};
  String get tableKey => _tableKey;
  PlatformTableLayout get _defaultLayout =>
      _container
          ?.read(platformTableLayoutProvider(_tableKey).notifier)
          .defaultValue ??
      PlatformTableLayoutNotifier(_tableKey).defaultValue;
  bool get bound => binding != null;
  PlatformColumnDefinition _visibleDefinition(
    PlatformColumnDefinition definition,
  ) =>
      definition.priceProtected &&
          capabilities?.priceVisible != true &&
          definition.scope.isNotEmpty
      ? PlatformColumnDefinition(
          id: definition.id,
          scope: definition.scope,
          name: '不能查看的列',
          type: definition.type,
          priceProtected: true,
        )
      : definition;
  List<PlatformColumnDefinition> get definitions =>
      _definitions.values.map(_visibleDefinition).toList(growable: false);
  bool get historical => binding?.snapshotOf != null;
  bool _columnEditingEnabled = false;

  /// A page must explicitly opt into authoring. Account permissions alone do
  /// not turn review/detail tables into editors, including for administrators.
  bool get columnEditingEnabled => _columnEditingEnabled && !historical;
  bool get canDefineColumns =>
      columnEditingEnabled && (!bound || capabilities?.canDefine == true);
  bool get canDefineRelatedColumns =>
      !historical &&
      binding?.allowPersonalRelatedColumns == true &&
      capabilities?.canDefineRelated == true &&
      capabilities?.relations.isNotEmpty == true;
  bool get canCustomizeColumns =>
      columnEditingEnabled || canDefineRelatedColumns;

  void configure(
    BuildContext context, {
    required PlatformTableDescriptor<T> descriptor,
    PlatformTableBinding<T>? explicitBinding,
    bool columnEditingEnabled = false,
    Map<String, String?> Function(T)? factsOf,
    Iterable<Listenable> Function(T)? factListenablesOf,
    PlatformRowDraft? Function(T)? stagedDraftOf,
    Set<String> exactFactKeys = const {},
  }) {
    final next =
        explicitBinding ??
        PlatformTableCatalogScope.resolve(context, descriptor);
    final key =
        next?.tableKey ??
        descriptor.tableKey ??
        '${descriptor.kind}:${descriptor.rowType}:${platformTableFingerprint(descriptor.columnKeys.join('|'))}';
    ProviderContainer? container;
    try {
      container = ProviderScope.containerOf(context, listen: false);
    } on StateError {
      /* isolated widget without app providers */
    }
    PlatformTableRepository? repo;
    String? bootstrapError;
    if (container != null && next != null) {
      try {
        repo = container.read(platformTableRepositoryProvider);
      } on UnimplementedError {
        bootstrapError = '扩展字段服务未初始化';
      }
    }
    final changed =
        key != _tableKey ||
        next?.scope != binding?.scope ||
        !identical(repository, repo);
    final wasEditing = this.columnEditingEnabled;
    binding = next;
    _columnEditingEnabled = columnEditingEnabled;
    if (wasEditing != this.columnEditingEnabled) _emit();
    repository = repo;
    fallbackFactsOf = factsOf;
    fallbackFactListenablesOf = factListenablesOf;
    _exactFactKeys = exactFactKeys;
    draftOf = stagedDraftOf ?? next?.draftOf;
    _items = descriptor.rows;
    final dataChanged = _sourceRevision != descriptor.revision;
    _sourceRevision = descriptor.revision;
    if (changed) {
      _hasSessionQueryPreferences = false;
      _authorizationRevision++;
      _generation++;
      _signature = '';
      _tableKey = key;
      _container = container;
      _values.clear();
      _edits.clear();
      _definitions.clear();
      _recordColumnIds.clear();
      _catalogDefinitions.clear();
      capabilities = null;
      error = bootstrapError;
      readFailure = bootstrapError == null
          ? null
          : PlatformTableReadFailure.initialization;
      layoutTouched = false;
      _layoutSubscription?.close();
      _repositorySubscription?.close();
      _queryScopeSubscription?.close();
      _queryServerSubscription?.close();
      void ownerChanged() {
        if (disposed) return;
        _queryLifecycle++;
        _hasSessionQueryPreferences = false;
        layoutTouched = false;
        layout = _defaultLayout;
        _invalidateAccess();
      }

      _queryScopeSubscription = container?.listen(authenticatedScopeProvider, (
        previous,
        next,
      ) {
        if (previous != next) ownerChanged();
      });
      _queryServerSubscription = container?.listen(apiBaseUrlProvider, (
        previous,
        next,
      ) {
        if (previous != next) ownerChanged();
      });
      _repositorySubscription = next == null || repo == null
          ? null
          : container?.listen(platformTableRepositoryProvider, (_, nextRepo) {
              if (disposed || identical(repository, nextRepo)) return;
              repository = nextRepo;
              _invalidateAccess();
              unawaited(reload());
            });
      layout =
          (container?.read(platformTableLayoutProvider(key)) ?? _defaultLayout)
              .copyWith(filters: const {});
      _adoptDefinitions();
      _layoutSubscription = container?.listen(
        platformTableLayoutProvider(key),
        (_, next) {
          if (disposed || next.sourceInstance == _instance) {
            return;
          }
          final priorIds = layout.added.map((column) => column.id).join('|');
          // Other instances and late preference loads may change layout/sort,
          // but their query must never replace this table's current search.
          layout = next.copyWith(filters: layout.filters);
          _adoptDefinitions();
          _emit();
          if (priorIds != next.added.map((column) => column.id).join('|')) {
            _signature = '';
            unawaited(reload());
          }
        },
      );
    }
    if (draftOf != null) {
      for (final item in _items) {
        final draft = draftOf!(item);
        if (draft == null) continue;
        if (capabilities == null) {
          draft.priceVisible = false;
          draft.canWrite = false;
        }
        for (final cell in draft.cells) {
          if (draft.ownsColumn(cell.columnId)) {
            _recordColumnIds.add(cell.columnId);
          }
          _definitions[cell.columnId] = cell.definition;
        }
      }
    }
    if (historical) {
      _values.clear();
      for (final item in _items) {
        final row = binding!.snapshotOf!(item);
        if (row != null) {
          _values[row.recordId] = row;
          for (final cell in row.cells) {
            _definitions[cell.columnId] = cell.definition;
            _recordColumnIds.add(cell.columnId);
          }
        }
      }
    }
    {
      final ids =
          _items
              .map((row) => binding?.recordIdOf(row))
              .whereType<String>()
              .where((id) => id.isNotEmpty)
              .toSet()
              .toList()
            ..sort();
      final signature =
          '${binding?.scope}|${ids.join(',')}|${layout.added.map((d) => d.id).join(',')}';
      if (changed || dataChanged || signature != _signature) {
        _signature = signature;
        unawaited(reload());
      }
    }
  }

  void _invalidateAccess() {
    _authorizationRevision++;
    _generation++;
    capabilities = null;
    _values.clear();
    _catalogDefinitions.clear();
    error = null;
    readFailure = null;
    for (final item in _items) {
      final draft = draftOf?.call(item);
      if (draft != null) {
        draft.priceVisible = false;
        draft.canWrite = false;
      }
    }
    _emit();
  }

  void _adoptDefinitions() {
    final selectedIds = layout.added.map((column) => column.id).toSet();
    _definitions.removeWhere(
      (id, _) => !selectedIds.contains(id) && !_recordColumnIds.contains(id),
    );
    for (final column in layout.added) {
      if (column.scope.isEmpty || column.scope == binding?.scope) {
        _definitions[column.id] = column;
      }
    }
  }

  void updateLayout(PlatformTableLayout value) {
    if (utf8.encode(jsonEncode(value.toJson())).length > 16000) {
      throw const FormatException('列的设置太大，请减少自动计算的列或运算步骤');
    }
    layoutTouched = true;
    value = value.copyWith(sourceInstance: _instance);
    layout = value;
    _adoptDefinitions();
    _container
        ?.read(platformTableLayoutProvider(_tableKey).notifier)
        .update(value.copyWith(filters: const {}));
  }

  Set<String> get availableFactKeys => {
    ..._exactFactKeys.map(canonicalKey),
    for (final row in _items)
      ...?(binding?.factValuesOf?.call(row).keys.map(canonicalKey)),
  };
  bool canCalculateFact(String key) =>
      (capabilities?.supportsValues == true &&
          draftOf == null &&
          !historical) ||
      availableFactKeys.contains(canonicalKey(key));
  void rememberCatalogResults(Iterable<PlatformColumnDefinition> columns) {
    for (final column in columns) {
      _catalogDefinitions[column.id] = column;
    }
  }

  String canonicalKey(String key) => binding?.columnAliases[key] ?? key;
  String _canonicalFilterKey(String key) => key.startsWith('search.')
      ? 'search.${canonicalKey(key.substring(7))}'
      : canonicalKey(key);
  PlatformTableLayout localLayout(
    List<String> keys, {
    required Set<String> defaultHidden,
    bool insertNewColumnsAtDeclaredPosition = false,
  }) {
    final byCanonical = {for (final key in keys) canonicalKey(key): key};
    final byCanonicalFilter = {
      ...byCanonical,
      for (final entry in byCanonical.entries)
        'search.${entry.key}': 'search.${entry.value}',
    };
    final savedOrder = layout.order.map(canonicalKey).toList();
    final requestedOrder = savedOrder.isNotEmpty
        ? savedOrder
        : binding?.defaultColumnOrder ?? keys.map(canonicalKey).toList();
    final order = <String>[];
    for (final key in requestedOrder) {
      final local = byCanonical[canonicalKey(key)];
      if (local != null && !order.contains(local)) order.add(local);
    }
    if (savedOrder.isEmpty || !insertNewColumnsAtDeclaredPosition) {
      // 可编辑表格的既有口径：保存序里还没有的列一律追加表尾（锚点列由宿主
      // defaultColumnOrderAnchors 另行归位），不要改动。
      order.addAll(keys.where((key) => !order.contains(key)));
    } else {
      // 主表浏览表格的口径：保存序里还没有的列（保存之后版本新增的）插回代码
      // 默认位置——贴着列定义里它的前邻列落位，没有前邻的新前缀从最前开始。
      // 否则升级账号的新列（如货品表「模具名称」）会被追到最右端，与默认列序
      // 脱节。
      final known = order.toSet();
      for (final key in keys) {
        if (known.contains(key)) continue;
        var insertAt = 0;
        for (var i = keys.indexOf(key) - 1; i >= 0; i--) {
          final anchor = order.indexOf(keys[i]);
          if (anchor >= 0) {
            insertAt = anchor + 1;
            break;
          }
        }
        order.insert(insertAt, key);
        known.add(key);
      }
    }
    final defaults = binding?.defaultVisibleColumnKeys;
    final hiddenByDefault = defaults == null
        ? defaultHidden
        : {
            for (final key in keys)
              if (!defaults.contains(canonicalKey(key)) &&
                  !key.startsWith('platform:') &&
                  !key.startsWith('extra:'))
                key,
          };
    final hidden = {
      // A deleted selected column may still have saved record values. Honor
      // that explicit removal even before the user has customized column order.
      for (final key in layout.hidden)
        if (byCanonical.containsKey(canonicalKey(key)))
          byCanonical[canonicalKey(key)]!,
      if (savedOrder.isEmpty)
        ...hiddenByDefault
      else
        for (final key in hiddenByDefault)
          if (!savedOrder.contains(canonicalKey(key))) key,
    };
    return layout.copyWith(
      filters: {
        for (final entry in layout.filters.entries)
          if (byCanonicalFilter.containsKey(_canonicalFilterKey(entry.key)))
            byCanonicalFilter[_canonicalFilterKey(entry.key)]!: entry.value,
      },
      sortColumn: layout.sortColumn == null
          ? null
          : byCanonical[canonicalKey(layout.sortColumn!)],
      clearSort:
          layout.sortColumn != null &&
          !byCanonical.containsKey(canonicalKey(layout.sortColumn!)),
      order: order,
      hidden: hidden,
      pinned: {
        for (final key in layout.pinned)
          if (byCanonical.containsKey(canonicalKey(key)))
            byCanonical[canonicalKey(key)]!,
      },
      widths: {
        for (final entry in layout.widths.entries)
          if (byCanonical.containsKey(canonicalKey(entry.key)))
            byCanonical[canonicalKey(entry.key)]!: entry.value,
      },
    );
  }

  void saveLayout({
    required List<String> knownKeys,
    required List<String> order,
    required Set<String> hidden,
    required Set<String> pinned,
    required Map<String, double> widths,
  }) {
    final known = knownKeys.map(canonicalKey).toSet();
    updateLayout(
      layout.copyWith(
        order: [
          ...order.map(canonicalKey),
          ...layout.order.where((key) => !known.contains(key)),
        ],
        hidden: {
          ...hidden.map(canonicalKey),
          ...layout.hidden.where((key) => !known.contains(key)),
        },
        pinned: {
          ...pinned.map(canonicalKey),
          ...layout.pinned.where((key) => !known.contains(key)),
        },
        widths: {
          ...layout.widths,
          for (final entry in widths.entries)
            canonicalKey(entry.key): entry.value,
        },
      ),
    );
  }

  void resetLayout() {
    _hasSessionQueryPreferences = false;
    updateLayout(_defaultLayout);
    _signature = '';
    _emit();
    unawaited(reload());
  }

  void saveQuery({
    required Map<String, String?> filters,
    String? sortColumn,
    bool sortAscending = true,
  }) {
    _hasSessionQueryPreferences = true;
    updateLayout(
      layout.copyWith(
        filters: {
          for (final entry in filters.entries)
            _canonicalFilterKey(entry.key): entry.value,
        },
        sortColumn: sortColumn == null ? null : canonicalKey(sortColumn),
        clearSort: sortColumn == null,
        sortAscending: sortAscending,
        hasQueryPreferences: true,
      ),
    );
  }

  /// A page return starts a fresh query while retaining personal column/sort
  /// preferences. The lifecycle also invalidates already-open search menus.
  void clearSessionQuery() {
    if (disposed) return;
    _queryLifecycle++;
    _hasSessionQueryPreferences = false;
    layout = layout.copyWith(filters: const {});
    _emit();
  }

  void select(PlatformColumnDefinition column) {
    if (!columnEditingEnabled && !(column.related && canDefineRelatedColumns)) {
      throw const FormatException('当前页面只能显示已有列，请在单据录入页添加列');
    }
    if (column.related &&
        capabilities?.relations.any(
              (relation) => relation.key == column.relationKey,
            ) !=
            true) {
      throw const FormatException('该关联资料已不可查看，请重新选择');
    }
    if (layout.added.every((d) => d.id != column.id) &&
        layout.added.length >= 32) {
      throw const FormatException('最多添加 32 个扩展列');
    }
    _definitions[column.id] = column;
    updateLayout(
      layout.copyWith(
        added: [
          if (layout.added.every((d) => d.id != column.id)) column,
          ...layout.added,
        ],
        hidden: {...layout.hidden}..remove(column.key),
      ),
    );
    _signature = '';
    _stageSelectedCalculations();
    _emit();
    if (column.scope.isNotEmpty && repository != null) {
      unawaited(
        repository!.recordUse(column.scope, column.id).catchError((_) {}),
      );
    }
    unawaited(reload());
  }

  /// Layouts and document snapshots deliberately omit deletion authority.
  /// Header actions resolve the current catalog metadata without replacing any
  /// saved cell's name, formula or value with today's definition.
  PlatformColumnDefinition? columnForDeletion(String key) {
    if (!key.startsWith('platform:') || historical) return null;
    final id = key.substring('platform:'.length);
    final column = _catalogDefinitions[id] ?? _definitions[id];
    return column != null && canDeleteColumn(column) ? column : null;
  }

  bool canDeleteColumn(PlatformColumnDefinition column) =>
      !disposed &&
      !historical &&
      (column.related ? canDefineRelatedColumns : canDefineColumns) &&
      (!column.priceProtected || capabilities?.priceVisible == true) &&
      (column.scope.isEmpty
          ? !bound && layout.added.any((item) => item.id == column.id)
          : column.scope == binding?.scope && column.canDelete);

  /// Retire only the catalog entry. Saved values and formula dependencies keep
  /// their immutable definitions; deleting a header must never rewrite history.
  Future<void> deleteColumn(PlatformColumnDefinition column) async {
    if (!canDeleteColumn(column)) {
      throw const PlatformColumnDeletionException(
        PlatformColumnDeletionFailure.forbidden,
      );
    }
    if (column.scope.isEmpty &&
        definitions.any(
          (item) =>
              item.id != column.id &&
              [
                item.formula?.base,
                ...?item.formula?.steps.map((step) => step.operand),
              ].any((operand) => operand?.columnId == column.id),
        )) {
      throw const PlatformColumnDeletionException(
        PlatformColumnDeletionFailure.referenced,
      );
    }
    final repo = repository;
    final ownerScope = binding?.scope;
    final revision = authorizationRevision;
    final operation = (repo, ownerScope, revision, column.id);
    if (!_deletingDefinitions.add(operation)) {
      throw const PlatformColumnDeletionException(
        PlatformColumnDeletionFailure.busy,
      );
    }
    try {
      if (column.scope.isNotEmpty) {
        if (repo == null) {
          throw const PlatformColumnDeletionException(
            PlatformColumnDeletionFailure.unavailable,
          );
        }
        await repo.deleteDefinition(column.scope, column.id);
      }
      if (disposed ||
          !identical(repo, repository) ||
          ownerScope != binding?.scope ||
          revision != authorizationRevision ||
          !canDeleteColumn(column)) {
        return;
      }
      final key = column.key;
      updateLayout(
        layout.copyWith(
          added: layout.added.where((item) => item.id != column.id).toList(),
          order: layout.order.where((item) => item != key).toList(),
          // Persist the removal even when saved records still carry this cell.
          hidden: {...layout.hidden, key},
          pinned: {...layout.pinned}..remove(key),
          widths: {...layout.widths}..remove(key),
          filters: {...layout.filters}
            ..remove(key)
            ..remove('search.$key'),
          clearSort: layout.sortColumn == key,
        ),
      );
      if (column.scope.isNotEmpty) {
        // A live formula can still depend on an entry retired from the picker.
        _catalogDefinitions[column.id] = column;
      } else {
        _catalogDefinitions.remove(column.id);
      }
      _signature = '';
      _emit();
    } finally {
      _deletingDefinitions.remove(operation);
    }
  }

  /// User retry refreshes capability metadata too; cached grants may have changed.
  /// Only reads are repeated. Cell saves and uncertain submissions are never replayed.
  Future<void> retryRead() async {
    if (disposed || loading) return;
    try {
      repository ??= _container?.read(platformTableRepositoryProvider);
    } on UnimplementedError {
      error = '扩展字段服务未初始化';
      readFailure = PlatformTableReadFailure.initialization;
      _emit();
      return;
    }
    repository?.invalidateScopes();
    await reload();
  }

  Future<void> reload() async {
    final repo = repository;
    final owner = binding;
    if (repo == null || owner == null || disposed) return;
    final generation = ++_generation;
    loading = true;
    _emit();
    try {
      final scopes = await repo.scopes();
      if (disposed || generation != _generation) return;
      final matches = scopes.where((scope) => scope.scope == owner.scope);
      capabilities = matches.isEmpty ? null : matches.first;
      if (capabilities == null) {
        throw ApiException('FORBIDDEN', '当前账号不能访问此表的扩展字段');
      }
      if (draftOf != null) {
        for (final item in _items) {
          draftOf!(item)?.priceVisible = capabilities!.priceVisible;
        }
      }
      final selected = layout.added
          .where(
            (column) =>
                column.scope == owner.scope &&
                (!column.priceProtected || capabilities!.priceVisible) &&
                (!column.related ||
                    capabilities!.relations.any(
                      (relation) => relation.key == column.relationKey,
                    )),
          )
          .map((column) => column.id)
          .toList();
      final known = selected.isEmpty
          ? const <PlatformColumnDefinition>[]
          : await repo.search(owner.scope, '', ids: selected);
      if (disposed || generation != _generation) return;
      rememberCatalogResults(known);
      for (final column in known) {
        if (_definitions.containsKey(column.id)) {
          _definitions[column.id] = column;
        }
      }
      if (capabilities!.supportsValues && !historical) {
        final ids = _items
            .map(owner.recordIdOf)
            .whereType<String>()
            .where((id) => id.isNotEmpty)
            .toSet()
            .toList();
        final revisions = {for (final id in ids) id: _edits[id] ?? 0};
        final columns = layout.added
            .where(
              (d) =>
                  d.scope == owner.scope &&
                  (!d.related ||
                      capabilities!.relations.any(
                        (relation) => relation.key == d.relationKey,
                      )),
            )
            .map((d) => d.id)
            .toList();
        final pending = <PlatformRowValues>[];
        for (var start = 0; start < ids.length; start += 200) {
          final end = (start + 200).clamp(0, ids.length);
          final requested = ids.sublist(start, end);
          final requestedIds = requested.toSet();
          final records = await repo.rows(
            owner.scope,
            requested,
            columnIds: columns,
          );
          if (disposed || generation != _generation) return;
          // A null cell is valid. A missing/duplicate/foreign record is not a complete read.
          final seen = <String>{};
          if (records.length != requested.length ||
              records.any(
                (row) =>
                    !requestedIds.contains(row.recordId) ||
                    !seen.add(row.recordId),
              )) {
            throw ApiException('NOT_FOUND', '扩展字段记录清单已变化，请重新核对');
          }
          pending.addAll(records);
        }
        // Publish a complete read only. A later batch failure retains the prior
        // snapshot and never partially replaces a form's staged values.
        for (final row in pending) {
          if (!revisions.containsKey(row.recordId) ||
              (_edits[row.recordId] ?? 0) != revisions[row.recordId] ||
              (_values[row.recordId]?.version ?? -1) > row.version) {
            continue;
          }
          _values[row.recordId] = row;
          if (draftOf != null) {
            for (final item in _items.where(
              (item) => owner.recordIdOf(item) == row.recordId,
            )) {
              draftOf!(item)?.adopt(row);
            }
          }
          for (final cell in row.cells) {
            _definitions[cell.columnId] = cell.definition;
            if (cell.persisted) _recordColumnIds.add(cell.columnId);
          }
        }
        _values.removeWhere(
          (id, _) =>
              !ids.contains(id) &&
              !_saving.contains((_authorizationRevision, id)),
        );
        _stageSelectedCalculations();
      }
      error = null;
      readFailure = null;
    } catch (failure) {
      if (!disposed && generation == _generation) {
        if (failure is ApiException &&
            (failure.httpStatus == 401 ||
                failure.httpStatus == 403 ||
                failure.code == 'UNAUTHORIZED' ||
                failure.code == 'FORBIDDEN')) {
          // A fresh server rejection outranks cached capabilities, including
          // target permissions revoked before the local permission refresh.
          loading = false;
          _invalidateAccess();
        }
        error = platformTableError(failure);
        readFailure = switch (failure) {
          ApiException(code: 'NETWORK' || 'NETWORK_TIMEOUT') =>
            PlatformTableReadFailure.connection,
          ApiException(code: 'UNAUTHORIZED') =>
            PlatformTableReadFailure.session,
          ApiException(code: 'FORBIDDEN') => PlatformTableReadFailure.forbidden,
          ApiException(code: 'NOT_FOUND') =>
            PlatformTableReadFailure.recordsChanged,
          ApiException(httpStatus: 401) => PlatformTableReadFailure.session,
          ApiException(httpStatus: 403) => PlatformTableReadFailure.forbidden,
          ApiException(httpStatus: 404) =>
            PlatformTableReadFailure.recordsChanged,
          _ => PlatformTableReadFailure.unavailable,
        };
      }
    } finally {
      if (!disposed && generation == _generation) {
        loading = false;
        _emit();
      }
    }
  }

  // A selected display formula is part of the submitted form's column set.
  // Stage its selection only after source metadata is hydrated, preserving all
  // existing cells and the CAS version. Read-only tables remain projections.
  void _stageSelectedCalculations() {
    if (draftOf == null) return;
    final selected = layout.added
        .where((column) => !layout.hidden.contains(column.key))
        .map((column) => _definitions[column.id] ?? column)
        .where((column) => column.calculated && column.formula != null);
    for (final item in _items) {
      final draft = draftOf!(item);
      if (draft == null ||
          !_canWriteFields(item) ||
          ((binding?.recordIdOf(item)?.isNotEmpty ?? false) && !draft.loaded)) {
        continue;
      }
      for (final column in selected) {
        if (!masked(item, column) && !draft.ownsColumn(column.id)) {
          draft.setValue(column, null);
          _recordColumnIds.add(column.id);
        }
      }
    }
  }

  PlatformRowValues? rowValues(T item) {
    final draft = draftOf?.call(item);
    if (draft != null && (draft.loaded || draft.dirty)) return draft.snapshot;
    return historical
        ? binding?.snapshotOf?.call(item)
        : _values[binding?.recordIdOf(item)];
  }

  PlatformColumnCell? cell(T item, String id) {
    final cells = rowValues(item)?.cells.where((c) => c.columnId == id);
    return cells == null || cells.isEmpty ? null : cells.first;
  }

  bool masked(T item, PlatformColumnDefinition column) =>
      cell(item, column.id)?.masked == true ||
      (column.priceProtected && capabilities?.priceVisible != true);
  String? value(
    T item,
    PlatformColumnDefinition column, [
    Set<String> visiting = const {},
  ]) {
    if (column.related &&
        capabilities?.relations.any(
              (relation) => relation.key == column.relationKey,
            ) !=
            true) {
      return null;
    }
    if (masked(item, column)) return '***';
    if (repository != null && capabilities == null) return null;
    final stored = cell(item, column.id);
    if (historical && capabilities?.supportsValues != false && stored == null) {
      return null;
    }
    if (stored != null &&
        (capabilities?.supportsValues != false || historical) &&
        !(draftOf != null && column.calculated)) {
      return stored.value;
    }
    if (!column.calculated ||
        column.formula == null ||
        visiting.contains(column.id)) {
      return stored?.value;
    }
    final facts = <String, String?>{
      for (final entry
          in (fallbackFactsOf?.call(item) ?? const <String, String?>{}).entries)
        canonicalKey(entry.key): entry.value,
      for (final entry
          in (binding?.factValuesOf?.call(item) ?? const <String, String?>{})
              .entries)
        canonicalKey(entry.key): entry.value,
    };
    final allowed = capabilities?.facts
        .where((fact) => !fact.priceProtected || capabilities!.priceVisible)
        .map((f) => f.key)
        .toSet();
    return column.formula!.calculate((operand) {
      if (operand.constant != null) {
        return businessExactDecimal(operand.constant);
      }
      if (operand.fact != null) {
        if (allowed != null && !allowed.contains(operand.fact)) return null;
        return platformExactFact(
          facts[operand.fact] ?? facts[canonicalKey(operand.fact!)],
        );
      }
      final referenced =
          _definitions[operand.columnId] ??
          _catalogDefinitions[operand.columnId];
      return referenced == null
          ? null
          : businessExactDecimal(
              value(item, referenced, {...visiting, column.id}),
            );
    });
  }

  bool _canWriteFields(T item) =>
      columnEditingEnabled &&
      binding?.canEditValues == true &&
      (binding?.canEditRow?.call(item) ?? true) &&
      capabilities?.supportsValues == true &&
      (rowValues(item)?.canWrite == true ||
          (draftOf?.call(item) != null &&
              (binding?.recordIdOf(item)?.isEmpty ?? true) &&
              capabilities?.canCreate == true)) &&
      !_saving.contains((_authorizationRevision, binding?.recordIdOf(item)));
  bool canEdit(T item, PlatformColumnDefinition column) =>
      _canWriteFields(item) &&
      !column.calculated &&
      !column.related &&
      !masked(item, column);
  Future<void> saveCell(
    T item,
    PlatformColumnDefinition column,
    String? value,
  ) async {
    if (!canEdit(item, column)) throw const FormatException('当前记录不可编辑扩展字段');
    final draft = draftOf?.call(item);
    if (draft != null) {
      draft.setValue(column, value?.trim().isEmpty == true ? null : value);
      _definitions[column.id] = column;
      _recordColumnIds.add(column.id);
      _emit();
      return;
    }
    final row = rowValues(item)!;
    final scope = binding!.scope;
    final currentTable = _tableKey;
    final currentRepository = repository;
    final authorization = _authorizationRevision;
    final operation = (authorization, row.recordId);
    _saving.add(operation);
    _edits[row.recordId] = (_edits[row.recordId] ?? 0) + 1;
    _emit();
    try {
      final result = await repository!.save(
        scope,
        row.recordId,
        expectedVersion: row.version,
        cells: [
          for (final cell in row.cells)
            if (cell.persisted && cell.columnId != column.id)
              cell.toWriteJson(),
          {
            'columnId': column.id,
            'value': value?.trim().isEmpty == true ? null : value,
          },
        ],
      );
      if (disposed ||
          scope != binding?.scope ||
          currentTable != _tableKey ||
          authorization != _authorizationRevision ||
          !identical(currentRepository, repository)) {
        return;
      }
      if ((_values[row.recordId]?.version ?? -1) > result.version) return;
      _values[row.recordId] = result;
      for (final cell in result.cells) {
        _definitions[cell.columnId] = cell.definition;
        if (cell.persisted) _recordColumnIds.add(cell.columnId);
      }
    } finally {
      _saving.remove(operation);
      _emit();
    }
  }

  Map<String, dynamic> projectionDefinition(PlatformColumnDefinition column) {
    final dependencies = <String, PlatformColumnDefinition>{};
    void visit(PlatformColumnDefinition current) {
      final formula = current.formula;
      if (formula == null) return;
      for (final operand in [
        formula.base,
        ...formula.steps.map((step) => step.operand),
      ]) {
        final next =
            _definitions[operand.columnId] ??
            _catalogDefinitions[operand.columnId];
        if (next == null ||
            next.id == column.id ||
            dependencies.containsKey(next.id)) {
          continue;
        }
        dependencies[next.id] = next;
        visit(next);
      }
    }

    visit(column);
    return {
      ..._visibleDefinition(column).toJson(),
      if (dependencies.isNotEmpty)
        'dependencies': dependencies.values
            .map((d) => _visibleDefinition(d).toJson())
            .toList(),
    };
  }

  void _emit() {
    scheduleMicrotask(() {
      if (!disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    disposed = true;
    _generation++;
    _layoutSubscription?.close();
    _repositorySubscription?.close();
    _queryScopeSubscription?.close();
    _queryServerSubscription?.close();
    super.dispose();
  }
}

String platformTableError(Object error) => error is ApiException
    ? error.message
    : error is FormatException
    ? error.message
    : '扩展字段读取或保存失败，请重试';
