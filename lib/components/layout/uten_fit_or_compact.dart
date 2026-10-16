import 'dart:math' as math;

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
    this.forceCompact = false,
  });

  final Widget expanded;
  final Widget compact;
  final bool forceCompact;

  @override
  State<UtenFitOrCompact> createState() => _FitState();
}

class _FitState extends State<UtenFitOrCompact> {
  final _expandedFocus = FocusNode(
    canRequestFocus: false,
    skipTraversal: true,
    debugLabel: 'Fit expanded presentation',
  );
  final _compactFocus = FocusNode(
    canRequestFocus: false,
    skipTraversal: true,
    descendantsAreFocusable: false,
    descendantsAreTraversable: false,
    debugLabel: 'Fit compact presentation',
  );
  bool _pendingCompact = false;
  bool _focusUpdateScheduled = false;

  void _onChanged(bool compact) {
    _pendingCompact = compact;
    if (_focusUpdateScheduled) return;
    _focusUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusUpdateScheduled = false;
      if (!mounted) return;
      // Update the focus tree before this frame completes. A widget rebuild
      // on the next frame leaves the newly hidden button keyboard-active.
      // External nodes retain these values through later Focus rebuilds.
      _expandedFocus
        ..descendantsAreFocusable = !_pendingCompact
        ..descendantsAreTraversable = !_pendingCompact;
      _compactFocus
        ..descendantsAreFocusable = _pendingCompact
        ..descendantsAreTraversable = _pendingCompact;
    });
  }

  @override
  void dispose() {
    _expandedFocus.dispose();
    _compactFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _FitLayout(
    onChanged: _onChanged,
    forceCompact: widget.forceCompact,
    children: [
      SelectionContainer.disabled(
        child: Focus.withExternalFocusNode(
          focusNode: _expandedFocus,
          includeSemantics: false,
          child: widget.expanded,
        ),
      ),
      SelectionContainer.disabled(
        child: Focus.withExternalFocusNode(
          focusNode: _compactFocus,
          includeSemantics: false,
          child: widget.compact,
        ),
      ),
    ],
  );
}

class _FitLayout extends MultiChildRenderObjectWidget {
  const _FitLayout({
    required this.onChanged,
    required this.forceCompact,
    required super.children,
  });

  final ValueChanged<bool> onChanged;
  final bool forceCompact;

  @override
  MultiChildRenderObjectElement createElement() => _FitElement(this);

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _FitRenderBox(onChanged, forceCompact);

  @override
  void updateRenderObject(BuildContext context, _FitRenderBox renderObject) {
    renderObject.onChanged = onChanged;
    renderObject.forceCompact = forceCompact;
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
  _FitRenderBox(this.onChanged, this._forceCompact);
  ValueChanged<bool> onChanged;
  bool _forceCompact;
  set forceCompact(bool value) {
    if (_forceCompact == value) return;
    _forceCompact = value;
    markNeedsLayout();
  }

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
      _forceCompact ||
      (width.isFinite &&
          _expanded.getMaxIntrinsicWidth(double.infinity) > width);

  @override
  double computeMinIntrinsicWidth(double height) =>
      _compact.getMinIntrinsicWidth(height);

  @override
  double computeMaxIntrinsicWidth(double height) =>
      (_forceCompact ? _compact : _expanded).getMaxIntrinsicWidth(height);

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
    return constraints.constrain(
      child.getDryLayout(constraints.copyWith(minWidth: 0)),
    );
  }

  BoxConstraints _hiddenConstraints(RenderBox child) {
    final naturalWidth = child.getMaxIntrinsicWidth(double.infinity);
    final availableWidth = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : constraints.minWidth;
    final width = math.max(
      availableWidth,
      naturalWidth.isFinite ? naturalWidth : availableWidth,
    );
    final naturalHeight = constraints.hasBoundedHeight
        ? constraints.maxHeight
        : child.getMaxIntrinsicHeight(width);
    return BoxConstraints(
      maxWidth: width,
      minHeight: constraints.minHeight,
      maxHeight: math.max(
        constraints.minHeight,
        naturalHeight.isFinite ? naturalHeight : constraints.minHeight,
      ),
    );
  }

  @override
  void performLayout() {
    final next = _needsCompact(constraints.maxWidth);
    if (compact != next) {
      compact = next;
      markNeedsSemanticsUpdate();
      onChanged(compact);
    }
    // Both retained branches must complete layout. Leaving a dirty hidden
    // descendant under a clean parent breaks the relayout-boundary contract
    // when text scaling or rebuilding actions changes that descendant again.
    // Give the hidden branch finite natural-width space: the visible budget
    // can overflow its Row, while an infinite width breaks Expanded children.
    final hidden = compact ? _expanded : _compact;
    hidden.layout(_hiddenConstraints(hidden), parentUsesSize: true);
    // Preserve shared toolbar height on the painted control, not only here.
    _active.layout(constraints.copyWith(minWidth: 0), parentUsesSize: true);
    size = constraints.constrain(_active.size);
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      context.paintChild(_active, offset);

  @override
  bool paintsChild(RenderBox child) {
    assert(child.parent == this);
    return child == _active;
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      _active.hitTest(result, position: position);

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) =>
      visitor(_active);
}

class _FitParentData extends ContainerBoxParentData<RenderBox> {}
