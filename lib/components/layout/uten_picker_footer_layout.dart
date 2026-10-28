import 'package:flutter/material.dart';

import '../data_display/master_data_table_rows_controller.dart';
import 'uten_pagination.dart';

/// Selection, paging, and confirmation share one footer on wide panels.
/// Narrow panels wrap without shrinking text or touch targets.
class UtenPickerFooterLayout extends StatelessWidget {
  const UtenPickerFooterLayout({
    super.key,
    required this.summary,
    required this.actions,
    this.pagination,
  });

  final Widget summary;
  final Widget actions;
  final Widget? pagination;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
      if (constraints.maxWidth < (pagination == null ? 560 : 760) * scale) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(alignment: Alignment.centerLeft, child: summary),
            if (pagination != null) ...[const SizedBox(height: 8), pagination!],
            const SizedBox(height: 8),
            Align(alignment: Alignment.centerRight, child: actions),
          ],
        );
      }
      return Row(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              heightFactor: 1,
              child: summary,
            ),
          ),
          const SizedBox(width: 12),
          if (pagination != null) ...[pagination!, const SizedBox(width: 24)],
          actions,
        ],
      );
    },
  );
}

/// Uses the table's reading page and navigation, including appended pages.
class UtenPickerPageControls<T> extends StatelessWidget {
  const UtenPickerPageControls({super.key, required this.controller});

  final MasterDataTableRowsController<T> controller;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<MasterDataPagination?>(
        valueListenable: controller.pagination,
        builder: (context, page, _) {
          if (page == null || page.totalPages <= 1) {
            return const SizedBox.shrink();
          }
          return UtenPagination(
            key: const Key('picker-footer-pagination'),
            currentPage: page.currentPage,
            totalPages: page.totalPages,
            busy: page.busy,
            onPageChanged: controller.goToPage,
            inputOutlineKey: const Key('picker-page-input-outline'),
          );
        },
      );
}
