import 'package:flutter/widgets.dart';

import '../../core/responsive/compact_presentation.dart';
import 'uten_page_layout.dart';

/// A collapsed toolbar control owns its own hit target. Remove the old field's
/// outer layout wrappers so its former width/insets do not survive as whitespace.
/// Input state and business callbacks remain on the original control widget.
Widget utenCompactToolbarChild(
  BuildContext context,
  Widget source, {
  bool preserveWrapperState = false,
}) {
  final compact = UtenCompactPresentation.iconSearchOf(context);
  if (!compact && !preserveWrapperState) return source;
  Widget inner(Widget child) => utenCompactToolbarChild(
    context,
    child,
    preserveWrapperState: preserveWrapperState,
  );
  if (source is Padding && source.child != null) {
    return preserveWrapperState
        ? Padding(
            key: source.key,
            padding: compact ? EdgeInsets.zero : source.padding,
            child: inner(source.child!),
          )
        : inner(source.child!);
  }
  if (source is Align && source.child != null) {
    return preserveWrapperState
        ? Align(
            key: source.key,
            alignment: source.alignment,
            widthFactor: compact ? 1 : source.widthFactor,
            heightFactor: compact ? 1 : source.heightFactor,
            child: inner(source.child!),
          )
        : inner(source.child!);
  }
  if (source is SizedBox && source.child != null) {
    return preserveWrapperState
        ? SizedBox(
            key: source.key,
            width: compact ? null : source.width,
            height: compact ? null : source.height,
            child: inner(source.child!),
          )
        : inner(source.child!);
  }
  if (source is Column && source.children.length == 1) {
    return preserveWrapperState
        ? Column(
            key: source.key,
            mainAxisAlignment: source.mainAxisAlignment,
            mainAxisSize: compact ? MainAxisSize.min : source.mainAxisSize,
            crossAxisAlignment: source.crossAxisAlignment,
            textDirection: source.textDirection,
            verticalDirection: source.verticalDirection,
            textBaseline: source.textBaseline,
            spacing: source.spacing,
            children: [inner(source.children.single)],
          )
        : inner(source.children.single);
  }
  if (source is UtenPageEdgePadding && source.child != null) {
    return preserveWrapperState
        ? source.copyWith(
            padding: compact ? EdgeInsets.zero : source.padding,
            child: inner(source.child!),
          )
        : inner(source.child!);
  }
  return source;
}

/// Reparents one retained search control from its desktop row into the compact
/// table toolbar. Callers keep their own desktop padding and toolbar actions.
class UtenResponsiveTableSearch extends StatefulWidget {
  const UtenResponsiveTableSearch({
    super.key,
    required this.search,
    required this.builder,
  });
  final Widget search;
  final Widget Function(BuildContext context, Widget? above, Widget? toolbar)
  builder;
  @override
  State<UtenResponsiveTableSearch> createState() =>
      _UtenResponsiveTableSearchState();
}

class _UtenResponsiveTableSearchState extends State<UtenResponsiveTableSearch> {
  final _key = GlobalKey();
  @override
  Widget build(BuildContext context) {
    final compact = UtenCompactPresentation.iconSearchOf(context);
    final search = KeyedSubtree(key: _key, child: widget.search);
    return widget.builder(
      context,
      compact ? null : search,
      compact ? search : null,
    );
  }
}
