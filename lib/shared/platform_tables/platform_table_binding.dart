import 'platform_row_draft.dart';
import 'package:flutter/widgets.dart';

import 'platform_table_models.dart';

/// Business adapters provide real record identities; the table never derives IDs
/// from a row number, label, or an object's hash code.
class PlatformTableBinding<T> {
  const PlatformTableBinding({
    required this.tableKey,
    required this.scope,
    required this.recordIdOf,
    this.canEditValues = false,
    this.canEditRow,
    this.snapshotOf,
    this.factValuesOf,
    this.factListenablesOf,
    this.draftOf,
    this.columnAliases = const {},
    this.defaultVisibleColumnKeys,
    this.defaultColumnOrder,
    this.revealPopulatedColumnKeys = const {},
  });

  final String tableKey;
  final String scope;
  final String? Function(T row) recordIdOf;
  final bool canEditValues;
  final bool Function(T row)? canEditRow;
  final Map<String, String?> Function(T row)? factValuesOf;
  final Iterable<Listenable> Function(T row)? factListenablesOf;
  final PlatformRowDraft? Function(T row)? draftOf;
  final Map<String, String> columnAliases;
  final List<String>? defaultVisibleColumnKeys;
  final List<String>? defaultColumnOrder;
  final Set<String> revealPopulatedColumnKeys;

  /// Historical approval/detail adapters can supply their immutable snapshot.
  /// When supplied, current metadata is never fetched as a historical substitute.
  final PlatformRowValues? Function(T row)? snapshotOf;

  PlatformTableBinding<T> copyWith({
    String? tableKey,
    String? scope,
    String? Function(T row)? recordIdOf,
    bool? canEditValues,
    bool Function(T row)? canEditRow,
    PlatformRowValues? Function(T row)? snapshotOf,
    Map<String, String?> Function(T row)? factValuesOf,
    Iterable<Listenable> Function(T row)? factListenablesOf,
    PlatformRowDraft? Function(T row)? draftOf,
    Map<String, String>? columnAliases,
    List<String>? defaultVisibleColumnKeys,
    List<String>? defaultColumnOrder,
    Set<String>? revealPopulatedColumnKeys,
  }) => PlatformTableBinding<T>(
    tableKey: tableKey ?? this.tableKey,
    scope: scope ?? this.scope,
    recordIdOf: recordIdOf ?? this.recordIdOf,
    canEditValues: canEditValues ?? this.canEditValues,
    canEditRow: canEditRow ?? this.canEditRow,
    snapshotOf: snapshotOf ?? this.snapshotOf,
    factValuesOf: factValuesOf ?? this.factValuesOf,
    factListenablesOf: factListenablesOf ?? this.factListenablesOf,
    draftOf: draftOf ?? this.draftOf,
    columnAliases: columnAliases ?? this.columnAliases,
    defaultVisibleColumnKeys:
        defaultVisibleColumnKeys ?? this.defaultVisibleColumnKeys,
    defaultColumnOrder: defaultColumnOrder ?? this.defaultColumnOrder,
    revealPopulatedColumnKeys:
        revealPopulatedColumnKeys ?? this.revealPopulatedColumnKeys,
  );
}

class PlatformTableDescriptor<T> {
  const PlatformTableDescriptor({
    required this.kind,
    required this.columnKeys,
    required this.rows,
    this.tableKey,
    this.revision,
  });
  final String kind;
  final Object? revision;
  final String? tableKey;
  final List<String> columnKeys;
  final List<T> rows;
  Type get rowType => T;
}

typedef PlatformTableResolver =
    PlatformTableBinding<T>? Function<T>(PlatformTableDescriptor<T> table);

/// App-owned typed registrations live outside the shared widgets. Private row
/// models and report maps may instead pass an explicit binding to their table.
class PlatformTableCatalogScope extends InheritedWidget {
  const PlatformTableCatalogScope({
    super.key,
    required this.resolver,
    required super.child,
  });
  final PlatformTableResolver resolver;

  static PlatformTableBinding<T>? resolve<T>(
    BuildContext context,
    PlatformTableDescriptor<T> table,
  ) => context
      .dependOnInheritedWidgetOfExactType<PlatformTableCatalogScope>()
      ?.resolver<T>(table);

  @override
  bool updateShouldNotify(PlatformTableCatalogScope oldWidget) =>
      !identical(resolver, oldWidget.resolver);
}
