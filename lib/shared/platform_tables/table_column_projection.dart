import 'dart:async';
import 'dart:convert';
import 'package:flutter/widgets.dart';

/// The exact visible table header shared by screen, download and print preview.
/// Keys are stable schema IDs. Labels and formulas are descriptive; servers must
/// resolve and authorize each key against the underlying business schema.
class TableProjectedColumn {
  const TableProjectedColumn({
    required this.key,
    required this.label,
    required this.width,
    required this.type,
    this.definition,
    this.sourceKey,
  });
  final String key;
  final String label;
  final double width;
  final String type;
  final Map<String, dynamic>? definition;
  final String? sourceKey;
  Map<String, dynamic> toJson() => {
    'key': key,
    'label': label,
    'width': width,
    'type': type,
    if (definition != null) 'definition': definition,
  };
}

class TableColumnProjection {
  const TableColumnProjection({
    required this.tableKey,
    this.scope,
    required this.columns,
    this.sourceKeys = const {},
  });
  final String tableKey;
  final String? scope;
  final List<TableProjectedColumn> columns;

  /// Client-only lookup also covers hidden fact columns used by calculations.
  final Map<String, String> sourceKeys;
  Map<String, dynamic> toJson() => {
    'tableKey': tableKey,
    if (scope != null) 'scope': scope,
    'columns': columns.map((c) => c.toJson()).toList(growable: false),
  };
}

class TableColumnProjectionController extends ChangeNotifier {
  final Map<Object, TableColumnProjection> _tables = {};
  bool _closed = false;
  final Map<Object, Object?> _owners = {};
  TableColumnProjection? resolve([String? tableKey, Object? contextOwner]) {
    final local = _tables.entries
        .where(
          (entry) =>
              (tableKey == null || entry.value.tableKey == tableKey) &&
              contextOwner != null &&
              identical(_owners[entry.key], contextOwner),
        )
        .map((entry) => entry.value)
        .toList();
    if (local.length == 1) return local.single;
    if (contextOwner != null) return null;
    final matches = _tables.values
        .where((p) => tableKey == null || p.tableKey == tableKey)
        .toList();
    return matches.length == 1 ? matches.single : null;
  }

  TableColumnProjection? forOwner(Object owner, Object? contextOwner) =>
      contextOwner != null && !identical(_owners[owner], contextOwner)
      ? null
      : _tables[owner];
  bool hasTablesFor(Object? contextOwner) => contextOwner == null
      ? _tables.isNotEmpty
      : _tables.keys.any((owner) => identical(_owners[owner], contextOwner));
  List<TableColumnProjection> get tables => List.unmodifiable(_tables.values);
  void publish(
    Object owner,
    TableColumnProjection projection, {
    Object? contextOwner,
  }) {
    _owners[owner] = contextOwner;
    final previous = _tables[owner];
    if (_closed ||
        (jsonEncode(previous?.toJson()) == jsonEncode(projection.toJson()) &&
            jsonEncode(previous?.sourceKeys) ==
                jsonEncode(projection.sourceKeys) &&
            jsonEncode(
                  previous?.columns.map((column) => column.sourceKey).toList(),
                ) ==
                jsonEncode(
                  projection.columns.map((column) => column.sourceKey).toList(),
                ))) {
      return;
    }
    _tables[owner] = projection;
    notifyListeners();
  }

  void remove(Object owner) {
    _owners.remove(owner);
    if (!_closed && _tables.remove(owner) != null) {
      scheduleMicrotask(() {
        if (!_closed) notifyListeners();
      });
    }
  }

  @override
  void dispose() {
    _closed = true;
    _tables.clear();
    super.dispose();
  }
}

/// Place around a page's table and its export/preview actions. Multiple tables
/// require an explicit tableKey; ambiguity never silently exports another table.
class TableColumnProjectionScope
    extends InheritedNotifier<TableColumnProjectionController> {
  const TableColumnProjectionScope({
    super.key,
    required TableColumnProjectionController controller,
    required super.child,
  }) : super(notifier: controller);
  static TableColumnProjectionController? maybeOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<TableColumnProjectionScope>()
          ?.notifier;
  static bool hasCurrentTables(BuildContext context) =>
      read(context)?.hasTablesFor(ModalRoute.of(context)) ?? false;
  static TableColumnProjection? resolve(
    BuildContext context, [
    String? tableKey,
  ]) {
    final host = read(context);
    final route = ModalRoute.of(context);
    final target = context
        .getInheritedWidgetOfExactType<TableColumnProjectionTarget>();
    if (target?.owner != null &&
        (tableKey == null || tableKey == target!.tableKey)) {
      return host?.forOwner(target!.owner!, route);
    }
    return host?.resolve(tableKey ?? target?.tableKey, route);
  }

  static TableColumnProjectionController? read(BuildContext context) => context
      .getInheritedWidgetOfExactType<TableColumnProjectionScope>()
      ?.notifier;
}

/// A toolbar action nested in a table automatically targets that table. Actions
/// outside tables keep the explicit-key/unique-table contract.
class TableColumnProjectionTarget extends InheritedWidget {
  const TableColumnProjectionTarget({
    super.key,
    required this.tableKey,
    this.owner,
    required super.child,
  });
  final String tableKey;
  final Object? owner;
  @override
  bool updateShouldNotify(TableColumnProjectionTarget oldWidget) =>
      oldWidget.tableKey != tableKey;
}
