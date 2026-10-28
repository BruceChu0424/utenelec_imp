import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../core/theme/uten_tokens.dart';

/// Table-owned cards retain their theme's shape without a decorative outer line.
OutlinedBorder utenTableCardShape(BuildContext context) {
  final shape = Theme.of(context).cardTheme.shape;
  if (shape is OutlinedBorder) return shape.copyWith(side: BorderSide.none);
  return const RoundedRectangleBorder(borderRadius: UtenRadius.tableAll);
}

/// A rounded table viewport without an outer stroke. Cells stay rectangular so
/// their internal dividers remain aligned while scrolling, pinning and resizing.
/// The logical last cell (including a trailing action cell) owns its visible
/// right border; the surface does not add a decorative frame around the table.
class UtenTableSurface extends StatelessWidget {
  const UtenTableSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    position: DecorationPosition.foreground,
    decoration: const BoxDecoration(borderRadius: UtenRadius.tableAll),
    child: ClipRRect(borderRadius: UtenRadius.tableAll, child: child),
  );
}

/// Close the logical row even when fitted columns leave unused width or a rich
/// child paints an opaque background. This scrolls with the content, never a
/// fixed viewport edge masquerading as the last column.
class UtenTableRowRightEdge extends StatelessWidget {
  const UtenTableRowRightEdge({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    position: DecorationPosition.foreground,
    decoration: BoxDecoration(
      border: Border(
        right: BorderSide(
          color: Theme.of(context).colorScheme.outline,
          width: 0.5,
        ),
      ),
    ),
    child: child,
  );
}

/// Header corners belong to the header viewport, independently of any toolbar
/// above it. Clipping the full table alone leaves picker headers square when
/// that table has an empty toolbar or a pager before the header.
class UtenTableHeaderSurface extends StatelessWidget {
  const UtenTableHeaderSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: const BorderRadius.vertical(
      top: Radius.circular(UtenRadius.table),
    ),
    child: child,
  );
}

/// Paint the background behind a cell and its border above opaque contents.
/// One stable render object also preserves the old Container border inset.
class UtenTableCellFrame extends SingleChildRenderObjectWidget {
  const UtenTableCellFrame({
    super.key,
    required this.border,
    this.backgroundColor,
    this.insetBorder = false,
    required super.child,
  });
  final Border border;
  final Color? backgroundColor;
  final bool insetBorder;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderTableCellFrame(
        border,
        backgroundColor,
        padding: insetBorder ? border.dimensions : EdgeInsets.zero,
        textDirection: Directionality.maybeOf(context),
      );
  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderTableCellFrame)
      ..border = border
      ..backgroundColor = backgroundColor
      ..padding = insetBorder ? border.dimensions : EdgeInsets.zero
      ..textDirection = Directionality.maybeOf(context);
  }
}

class _RenderTableCellFrame extends RenderPadding {
  _RenderTableCellFrame(
    this._border,
    this._backgroundColor, {
    required super.padding,
    super.textDirection,
  });
  Border _border;
  Color? _backgroundColor;
  final Paint _backgroundPaint = Paint();
  set border(Border value) {
    if (_border == value) return;
    _border = value;
    markNeedsPaint();
  }

  set backgroundColor(Color? value) {
    if (_backgroundColor == value) return;
    _backgroundColor = value;
    markNeedsPaint();
  }

  @override
  bool hitTestSelf(Offset position) => true;
  @override
  void paint(PaintingContext context, Offset offset) {
    final background = _backgroundColor;
    if (background != null) {
      _backgroundPaint.color = background;
      context.canvas.drawRect(offset & size, _backgroundPaint);
    }
    super.paint(context, offset);
    _border.paint(context.canvas, offset & size, textDirection: textDirection);
  }
}
