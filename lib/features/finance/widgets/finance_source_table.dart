import 'package:flutter/material.dart';
import '../../../core/tables/uten_table_header_group.dart';
import '../../basic_data/widgets/master_data_table_view.dart';

/// Map-backed finance previews use the existing Uten table, paging and toolbar.
/// Column definitions come from the owner; this adapter owns no money or business selection rules.
Widget financeSourceTable({
  required String tableKey,
  required List<MasterColumnDef<Map<String, dynamic>>> columns,
  required List<Map<String, dynamic>> rows,
  required String Function(Map<String, dynamic>) idOf,
  bool busy = false,
  String? error,
  VoidCallback? retry,
  int page = 1,
  int pages = 1,
  ValueChanged<int>? onPage,
  ValueChanged<Map<String, dynamic>>? onOpen,
  bool Function(Map<String, dynamic>)? canOpen,
  List<Widget>? actions,
  Object? scope,
  bool showColumnChooser = true,
  bool selectable = false,
  Set<String> selectedIds = const {},
  ValueChanged<Set<String>>? onSelectedIdsChanged,
}) => MasterDataTableView<Map<String, dynamic>>(
  tableKey: tableKey,
  columns: columns,
  items: rows,
  idOf: idOf,
  selectable: selectable,
  selectedIds: selectedIds,
  onSelectedIdsChanged: onSelectedIdsChanged,
  facets: const {},
  nullCounts: const {},
  filters: const {},
  onFilterChanged: (_, _) {},
  onRowTap: onOpen,
  canOpenRow: canOpen,
  isLoading: busy,
  error: error,
  onRetry: retry,
  currentPage: page,
  totalPages: pages,
  onPageChange: onPage,
  showPaginationControls: onPage != null,
  paginationScope: scope,
  toolbarActions: actions,
  showColumnChooser: showColumnChooser,
  virtualized: true,
  expensiveRowMounts: false,
);

MasterColumnDef<Map<String, dynamic>> financeSourceColumn(
  String key,
  String label, {
  double width = 150,
  String type = 'text',
  String? Function(Map<String, dynamic>)? value,
  List<UtenTableHeaderGroup> headerGroups = const [],
}) => MasterColumnDef<Map<String, dynamic>>(
  key: key,
  label: label,
  width: width,
  type: type,
  headerGroups: headerGroups,
  value: value ?? (row) => row[key]?.toString(),
  exactValueOf: type == 'money' || type == 'number'
      ? (row) => row['${key}Exact']?.toString() ?? row[key]?.toString()
      : null,
  columnSearchEnabled: false,
);
