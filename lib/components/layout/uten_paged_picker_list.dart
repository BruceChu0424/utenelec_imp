import 'dart:async';

import 'package:flutter/material.dart';

import '../../features/basic_data/widgets/master_data_table_view.dart';

export '../data_display/master_data_table_rows_controller.dart';

/// A bounded picker list with the same bidirectional page window as tables.
/// The caller retains ownership of selection, fetching, and confirmation.
class UtenPagedPickerList<T> extends StatelessWidget {
  const UtenPagedPickerList({
    super.key,
    required this.items,
    required this.idOf,
    required this.itemBuilder,
    required this.currentPage,
    required this.totalPages,
    required this.onPageChange,
    this.paginationScope,
    this.paginationRevision,
    this.loading = false,
    this.error,
    this.onRetry,
    this.emptyMessage = '暂无可选记录',
    this.separatorBuilder,
    this.padding = EdgeInsets.zero,
    this.rowsController,
  });

  final List<T> items;
  final String Function(T) idOf;
  final Widget Function(BuildContext, T) itemBuilder;
  final IndexedWidgetBuilder? separatorBuilder;
  final int currentPage;
  final int totalPages;
  final FutureOr<void> Function(int) onPageChange;
  final Object? paginationScope;
  final Object? paginationRevision;
  final bool loading;
  final String? error;
  final VoidCallback? onRetry;
  final String emptyMessage;
  final EdgeInsetsGeometry padding;
  final MasterDataTableRowsController<T>? rowsController;

  @override
  Widget build(BuildContext context) => MasterDataTableView<T>(
    columns: const [],
    items: items,
    facets: const {},
    nullCounts: const {},
    filters: const {},
    onFilterChanged: (_, _) {},
    rowKeyOf: idOf,
    rowsController: rowsController,
    listItemBuilder: itemBuilder,
    listSeparatorBuilder: separatorBuilder,
    listPadding: padding,
    currentPage: currentPage,
    totalPages: totalPages,
    onPageChange: onPageChange,
    paginationScope: paginationScope,
    paginationRevision: paginationRevision,
    isLoading: loading && items.isEmpty,
    loadingMore: loading && items.isNotEmpty,
    error: error,
    onRetry: onRetry,
    emptyMessage: emptyMessage,
    showFullscreenToggle: false,
    showColumnChooser: false,
    enableTextSelection: false,
  );
}
