import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import '../../core/responsive/compact_presentation.dart';

import '../data_display/master_data_table_rows_controller.dart';

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
  Widget build(BuildContext context) => UtenCompactPresentation.of(context)
      ? _MeasuredPickerFooter(
          children: [summary, pagination ?? const SizedBox.shrink(), actions],
        )
      : LayoutBuilder(
          builder: (context, constraints) {
            final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
            if (constraints.maxWidth <
                (pagination == null ? 560 : 760) * scale) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(alignment: Alignment.centerLeft, child: summary),
                  if (pagination != null) ...[
                    const SizedBox(height: 8),
                    pagination!,
                  ],
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
                if (pagination != null) ...[
                  pagination!,
                  const SizedBox(width: 24),
                ],
                actions,
              ],
            );
          },
        );
}

/// Uses the controls' real laid-out widths, including a pagination widget that
/// currently renders to zero. No screen-width guess reserves an empty row.
class _MeasuredPickerFooter extends MultiChildRenderObjectWidget {
  const _MeasuredPickerFooter({required super.children});
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _PickerFooterRenderBox();
}

class _PickerFooterRenderBox extends RenderBox
    with
        ContainerRenderObjectMixin<
          RenderBox,
          ContainerBoxParentData<RenderBox>
        >,
        RenderBoxContainerDefaultsMixin<
          RenderBox,
          ContainerBoxParentData<RenderBox>
        > {
  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! ContainerBoxParentData<RenderBox>) {
      child.parentData = _PickerFooterParentData();
    }
  }

  @override
  void performLayout() {
    final summary = firstChild!;
    final pager = childAfter(summary)!;
    final actions = childAfter(pager)!;
    final loose = BoxConstraints(maxWidth: constraints.maxWidth);
    for (final child in [summary, pager, actions]) {
      child.layout(loose, parentUsesSize: true);
    }
    final hasPager = pager.size.width > 0 && pager.size.height > 0;
    final requiredWidth =
        summary.size.width +
        actions.size.width +
        12 +
        (hasPager ? pager.size.width + 24 : 0);
    final width = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : requiredWidth;
    void place(RenderBox child, double x, double y) {
      (child.parentData! as ContainerBoxParentData<RenderBox>).offset = Offset(
        x,
        y,
      );
    }

    double height;
    if (requiredWidth <= width) {
      height = [
        summary.size.height,
        pager.size.height,
        actions.size.height,
      ].reduce((a, b) => a > b ? a : b);
      place(summary, 0, (height - summary.size.height) / 2);
      place(
        actions,
        width - actions.size.width,
        (height - actions.size.height) / 2,
      );
      place(
        pager,
        hasPager ? width - actions.size.width - 24 - pager.size.width : 0,
        (height - pager.size.height) / 2,
      );
    } else {
      place(summary, 0, 0);
      height = summary.size.height;
      if (hasPager) {
        height += 8;
        place(pager, width - pager.size.width, height);
        height += pager.size.height;
      } else {
        place(pager, 0, 0);
      }
      height += 8;
      place(actions, width - actions.size.width, height);
      height += actions.size.height;
    }
    size = constraints.constrain(Size(width, height));
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);
  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

class _PickerFooterParentData extends ContainerBoxParentData<RenderBox> {}

/// Uses the table's reading page and navigation, including appended pages.
class UtenPickerPageControls<T> extends StatelessWidget {
  const UtenPickerPageControls({super.key, required this.controller});

  final MasterDataTableRowsController<T> controller;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
