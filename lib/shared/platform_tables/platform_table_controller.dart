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
  final Set<String> _saving = {};
  ProviderSubscription<PlatformTableLayout>? _layoutSubscription;
  ProviderSubscription<PlatformTableRepository>? _repositorySubscription;
  ProviderSubscription<AuthenticatedScope?>? _queryScopeSubscription;
  ProviderSubscription<String>? _queryServerSubscription;
  int _queryLifecycle = 0;
  int get queryLifecycle => _queryLifecycle;
  ProviderContainer? _container;
  final Map<String, PlatformColumnDefinition> _definitions = {};
  final Set<String> _recordColumnIds = {};
  final Map<String, PlatformColumnDefinition> _catalogDefinitions = {};
  Map<String, String?> Function(T)? fallbackFactsOf;
  Iterable<Listenable> Function(T)? fallbackFactListenablesOf;
  PlatformRowDraft? Function(T)? draftOf;
  Set<String> _exactFactKeys = const {};
  String get tableKey => _tableKey;
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
          name: '受保护字段',
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
      layoutTouched = false;
      _layoutSubscription?.close();
      _repositorySubscription?.close();
      _queryScopeSubscription?.close();
      _queryServerSubscription?.close();
      void ownerChanged() {
        if (disposed) return;
        _queryLifecycle++;
        layoutTouched = false;
        layout = const PlatformTableLayout();
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
          container?.read(platformTableLayoutProvider(key)) ??
          const PlatformTableLayout();
      _adoptDefinitions();
      _layoutSubscription = container?.listen(
        platformTableLayoutProvider(key),
        (_, next) {
          if (disposed || next.sourceInstance == _instance) {
            return;
          }
          final priorIds = layout.added.map((column) => column.id).join('|');
          layout = next;
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
    _generation++;
    capabilities = null;
    _values.clear();
    _catalogDefinitions.clear();
    error = null;
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
      throw const FormatException('表头配置过大，请减少辅助计算列或运算步骤');
    }
    layoutTouched = true;
    value = value.copyWith(sourceInstance: _instance);
    layout = value;
    _adoptDefinitions();
    _container
        ?.read(platformTableLayoutProvider(_tableKey).notifier)
        .update(value);
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
  PlatformTableLayout localLayout(
    List<String> keys, {
    required Set<String> defaultHidden,
  }) {
    final byCanonical = {for (final key in keys) canonicalKey(key): key};
    final savedOrder = layout.order.map(canonicalKey).toList();
    final requestedOrder = savedOrder.isNotEmpty
        ? savedOrder
        : binding?.defaultColumnOrder ?? keys.map(canonicalKey).toList();
    final order = <String>[];
    for (final key in requestedOrder) {
      final local = byCanonical[canonicalKey(key)];
      if (local != null && !order.contains(local)) order.add(local);
    }
    order.addAll(keys.where((key) => !order.contains(key)));
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
    final hidden = savedOrder.isEmpty
        ? hiddenByDefault
        : {
            for (final key in layout.hidden)
              if (byCanonical.containsKey(canonicalKey(key)))
                byCanonical[canonicalKey(key)]!,
            for (final key in hiddenByDefault)
              if (!savedOrder.contains(canonicalKey(key))) key,
          };
    return layout.copyWith(
      filters: {
        for (final entry in layout.filters.entries)
          if (byCanonical.containsKey(canonicalKey(entry.key)))
            byCanonical[canonicalKey(entry.key)]!: entry.value,
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
    updateLayout(const PlatformTableLayout());
    _signature = '';
    _emit();
    unawaited(reload());
  }

  void saveQuery({
    required Map<String, String?> filters,
    String? sortColumn,
    bool sortAscending = true,
  }) {
    updateLayout(
      layout.copyWith(
        filters: {
          for (final entry in filters.entries)
            canonicalKey(entry.key): entry.value,
        },
        sortColumn: sortColumn == null ? null : canonicalKey(sortColumn),
        clearSort: sortColumn == null,
        sortAscending: sortAscending,
        hasQueryPreferences: true,
      ),
    );
  }

  void select(PlatformColumnDefinition column) {
    if (!columnEditingEnabled) {
      throw const FormatException('当前页面只能显示已有列，请在单据录入页添加列');
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

  Future<void> reload() async {
    final repo = repository;
    final owner = binding;
    if (repo == null || owner == null || disposed) return;
    final generation = ++_generation;
    loading = true;
    error = null;
    _emit();
    try {
      final scopes = await repo.scopes();
      if (disposed || generation != _generation) return;
      final matches = scopes.where((scope) => scope.scope == owner.scope);
      capabilities = matches.isEmpty ? null : matches.first;
      if (capabilities == null) throw const FormatException('当前账号不能访问此表的扩展字段');
      if (draftOf != null) {
        for (final item in _items) {
          draftOf!(item)?.priceVisible = capabilities!.priceVisible;
        }
      }
      final selected = layout.added
          .where(
            (column) =>
                column.scope == owner.scope &&
                (!column.priceProtected || capabilities!.priceVisible),
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
            .where((d) => d.scope == owner.scope)
            .map((d) => d.id)
            .toList();
        for (var start = 0; start < ids.length; start += 200) {
          final end = (start + 200).clamp(0, ids.length);
          final records = await repo.rows(
            owner.scope,
            ids.sublist(start, end),
            columnIds: columns,
          );
          if (disposed || generation != _generation) return;
          for (final row in records) {
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
        }
        _values.removeWhere(
          (id, _) => !ids.contains(id) && !_saving.contains(id),
        );
        _stageSelectedCalculations();
      }
    } catch (failure) {
      if (!disposed && generation == _generation) {
        error = platformTableError(failure);
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
      !_saving.contains(binding?.recordIdOf(item));
  bool canEdit(T item, PlatformColumnDefinition column) =>
      _canWriteFields(item) && !column.calculated && !masked(item, column);
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
    _saving.add(row.recordId);
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
          !identical(currentRepository, repository)) {
        return;
      }
      _values[row.recordId] = result;
      for (final cell in result.cells) {
        _definitions[cell.columnId] = cell.definition;
        if (cell.persisted) _recordColumnIds.add(cell.columnId);
      }
    } finally {
      _saving.remove(row.recordId);
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
