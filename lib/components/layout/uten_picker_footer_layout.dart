import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';
import '../data_display/master_data_table_rows_controller.dart';
import '../inputs/uten_input_decoration.dart';
import '../inputs/uten_field_message.dart';

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
            summary,
            if (pagination != null) ...[const SizedBox(height: 8), pagination!],
            const SizedBox(height: 8),
            actions,
          ],
        );
      }
      return Row(
        children: [
          Flexible(child: summary),
          const SizedBox(width: 12),
          Expanded(child: pagination ?? const SizedBox.shrink()),
          const SizedBox(width: 12),
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
          final height = UtenFilterRow.heightOf(context);
          final inputWidth = UtenControlMetrics.minimumHitExtent(
            context,
            desktop: 54,
          );
          final previous = TextButton(
            key: const ValueKey('master-table-page-previous'),
            onPressed: !page.busy && page.currentPage > 1
                ? () => controller.goToPage(page.currentPage - 1)
                : null,
            child: const Text('上一页'),
          );
          final next = TextButton(
            key: const ValueKey('master-table-page-next'),
            onPressed: !page.busy && page.currentPage < page.totalPages
                ? () => controller.goToPage(page.currentPage + 1)
                : null,
            child: const Text('下一页'),
          );
          final counter = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: inputWidth,
                child: _PickerPageInput(
                  page: page,
                  height: height,
                  goToPage: controller.goToPage,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '/ ${page.totalPages}',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          );
          return Wrap(
            key: const Key('picker-footer-pagination'),
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 4,
            runSpacing: 4,
            children: [previous, counter, next],
          );
        },
      );
}

class _PickerPageInput extends StatefulWidget {
  const _PickerPageInput({
    required this.page,
    required this.height,
    required this.goToPage,
  });
  final MasterDataPagination page;
  final double height;
  final ValueChanged<int> goToPage;

  @override
  State<_PickerPageInput> createState() => _PickerPageInputState();
}

class _PickerPageInputState extends State<_PickerPageInput> {
  late final _text = TextEditingController(text: '${widget.page.currentPage}');
  final _focus = FocusNode();

  @override
  void didUpdateWidget(covariant _PickerPageInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focus.hasFocus &&
        oldWidget.page.currentPage != widget.page.currentPage) {
      _text.text = '${widget.page.currentPage}';
    }
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextFormField(
    errorBuilder: utenTextFieldErrorBuilder,
    controller: _text,
    focusNode: _focus,
    enabled: !widget.page.busy,
    keyboardType: TextInputType.number,
    textAlign: TextAlign.center,
    textAlignVertical: TextAlignVertical.center,
    style: Theme.of(context).textTheme.bodyMedium,
    decoration: UtenInputDecoration(
      InputDecoration(
        isDense: true,
        constraints: BoxConstraints(minHeight: widget.height),
        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
        border: const OutlineInputBorder(
          borderRadius: UtenFilterRow.borderRadius,
        ),
      ),
    ),
    onFieldSubmitted: (value) {
      final target = (int.tryParse(value.trim()) ?? widget.page.currentPage)
          .clamp(1, widget.page.totalPages);
      _text.text = '$target';
      _focus.unfocus();
      widget.goToPage(target);
    },
  );
}
