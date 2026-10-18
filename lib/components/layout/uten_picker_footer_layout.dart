import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';
import '../buttons/uten_button.dart';
import '../data_display/master_data_table_rows_controller.dart';
import '../inputs/uten_input_decoration.dart';

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
          final theme = Theme.of(context);
          final textHeight =
              MediaQuery.textScalerOf(
                    context,
                  ).scale(theme.textTheme.bodyMedium?.fontSize ?? 14) *
                  1.5 +
              12;
          final height = UtenControlMetrics.controlHeight(
            context,
          ).clamp(textHeight, double.infinity);
          final inputWidth = UtenControlMetrics.minimumHitExtent(
            context,
            desktop: 64,
          );
          final previous = UtenButton(
            key: const ValueKey('master-table-page-previous'),
            type: UtenButtonType.ghost,
            size: UtenButtonSize.small,
            height: height,
            onPressed: !page.busy && page.currentPage > 1
                ? () => controller.goToPage(page.currentPage - 1)
                : null,
            child: const Text('上一页'),
          );
          final next = UtenButton(
            key: const ValueKey('master-table-page-next'),
            type: UtenButtonType.ghost,
            size: UtenButtonSize.small,
            height: height,
            onPressed: !page.busy && page.currentPage < page.totalPages
                ? () => controller.goToPage(page.currentPage + 1)
                : null,
            child: const Text('下一页'),
          );
          final counter = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('第', style: theme.textTheme.bodyMedium),
              const SizedBox(width: 8),
              SizedBox(
                width: inputWidth,
                height: height,
                child: _PickerPageInput(
                  page: page,
                  goToPage: controller.goToPage,
                ),
              ),
              const SizedBox(width: 8),
              Text('/ ${page.totalPages}', style: theme.textTheme.bodyMedium),
              const SizedBox(width: 4),
              Text('页', style: theme.textTheme.bodyMedium),
            ],
          );
          return Wrap(
            key: const Key('picker-footer-pagination'),
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [previous, counter, next],
          );
        },
      );
}

class _PickerPageInput extends StatefulWidget {
  const _PickerPageInput({required this.page, required this.goToPage});
  final MasterDataPagination page;
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
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _focus,
    builder: (context, _) => DecoratedBox(
      key: const Key('picker-page-input-outline'),
      decoration: BoxDecoration(
        color: widget.page.busy
            ? Theme.of(context).colorScheme.surfaceContainerHigh
            : Theme.of(context).colorScheme.surface,
        borderRadius: UtenFilterRow.borderRadius,
        border: Border.all(
          color: _focus.hasFocus
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.outline,
          width: _focus.hasFocus ? 2 : 1,
        ),
      ),
      child: Center(
        child: TextField(
          controller: _text,
          focusNode: _focus,
          enabled: !widget.page.busy,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.done,
          textAlign: TextAlign.center,
          textAlignVertical: TextAlignVertical.center,
          style: Theme.of(context).textTheme.bodyMedium,
          decoration: const UtenInputDecoration(
            InputDecoration(
              isCollapsed: true,
              constraints: BoxConstraints(),
              filled: false,
              visualDensity: VisualDensity.standard,
              hintText: '页码',
              contentPadding: EdgeInsets.symmetric(horizontal: 8),
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              disabledBorder: InputBorder.none,
            ),
          ),
          onSubmitted: (value) {
            final target =
                (int.tryParse(value.trim()) ?? widget.page.currentPage).clamp(
                  1,
                  widget.page.totalPages,
                );
            _text.text = '$target';
            _focus.unfocus();
            widget.goToPage(target);
          },
        ),
      ),
    ),
  );
}
