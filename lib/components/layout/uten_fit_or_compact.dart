import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Uses the actual natural width of [expanded], including its labels, icons and
/// text scaling. Only the fitting presentation paints, receives input or enters
/// the semantics tree. Unlike a LayoutBuilder this also supports intrinsic
/// sizing, which keeps filter fields aligned with their search field.
class UtenFitOrCompact extends StatefulWidget {
  const UtenFitOrCompact({
    super.key,
    required this.expanded,
    required this.compact,
  });

  final Widget expanded;
  final Widget compact;

  @override
  State<UtenFitOrCompact> createState() => _FitState();
}

class _FitState extends State<UtenFitOrCompact> {
  bool _compact = false;

  void _onChanged(bool compact) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _compact != compact) setState(() => _compact = compact);
    });
  }

  @override
  Widget build(BuildContext context) => _FitLayout(
    onChanged: _onChanged,
    children: [
      SelectionContainer.disabled(
        child: ExcludeFocus(excluding: _compact, child: widget.expanded),
      ),
      SelectionContainer.disabled(
        child: ExcludeFocus(excluding: !_compact, child: widget.compact),
      ),
    ],
  );
}

class _FitLayout extends MultiChildRenderObjectWidget {
  const _FitLayout({required this.onChanged, required super.children});

  final ValueChanged<bool> onChanged;

  @override
  MultiChildRenderObjectElement createElement() => _FitElement(this);

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _FitRenderBox(onChanged);

  @override
  void updateRenderObject(BuildContext context, _FitRenderBox renderObject) {
    renderObject.onChanged = onChanged;
  }
}

class _FitElement extends MultiChildRenderObjectElement {
  _FitElement(_FitLayout super.widget);

  @override
  void debugVisitOnstageChildren(ElementVisitor visitor) {
    final render = renderObject as _FitRenderBox;
    visitor(children.elementAt(render.compact ? 1 : 0));
  }
}

class _FitRenderBox extends RenderBox
    with
        ContainerRenderObjectMixin<
          RenderBox,
          ContainerBoxParentData<RenderBox>
        >,
        RenderBoxContainerDefaultsMixin<
          RenderBox,
          ContainerBoxParentData<RenderBox>
        > {
  _FitRenderBox(this.onChanged);
  ValueChanged<bool> onChanged;
  bool compact = false;

  RenderBox get _expanded => firstChild!;
  RenderBox get _compact => lastChild!;
  RenderBox get _active => compact ? _compact : _expanded;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! ContainerBoxParentData<RenderBox>) {
      child.parentData = _FitParentData();
    }
  }

  bool _needsCompact(double width) =>
      width.isFinite && _expanded.getMaxIntrinsicWidth(double.infinity) > width;

  @override
  double computeMinIntrinsicWidth(double height) =>
      _compact.getMinIntrinsicWidth(height);

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _expanded.getMaxIntrinsicWidth(height);

  @override
  double computeMinIntrinsicHeight(double width) =>
      (_needsCompact(width) ? _compact : _expanded).getMinIntrinsicHeight(
        width,
      );

  @override
  double computeMaxIntrinsicHeight(double width) =>
      (_needsCompact(width) ? _compact : _expanded).getMaxIntrinsicHeight(
        width,
      );

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final child = _needsCompact(constraints.maxWidth) ? _compact : _expanded;
    return constraints.constrain(child.getDryLayout(constraints.loosen()));
  }

  @override
  void performLayout() {
    final next = _needsCompact(constraints.maxWidth);
    if (compact != next) {
      compact = next;
      markNeedsSemanticsUpdate();
      onChanged(compact);
    }
    _active.layout(constraints.loosen(), parentUsesSize: true);
    size = constraints.constrain(_active.size);
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      context.paintChild(_active, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      _active.hitTest(result, position: position);

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) =>
      visitor(_active);
}

class _FitParentData extends ContainerBoxParentData<RenderBox> {}
