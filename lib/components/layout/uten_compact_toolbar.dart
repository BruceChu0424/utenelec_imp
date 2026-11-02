import 'package:flutter/widgets.dart';

import '../../core/responsive/compact_presentation.dart';
import 'uten_page_layout.dart';

/// A collapsed toolbar control owns its own hit target. Remove the old field's
/// outer layout wrappers so its former width/insets do not survive as whitespace.
/// Input state and business callbacks remain on the original control widget.
Widget utenCompactToolbarChild(BuildContext context, Widget source) {
  if (!UtenCompactPresentation.iconSearchOf(context)) return source;
  if (source is Padding && source.child != null) {
    return utenCompactToolbarChild(context, source.child!);
  }
  if (source is Align && source.child != null) {
    return utenCompactToolbarChild(context, source.child!);
  }
  if (source is SizedBox && source.child != null) {
    return utenCompactToolbarChild(context, source.child!);
  }
  if (source is Column && source.children.length == 1) {
    return utenCompactToolbarChild(context, source.children.single);
  }
  if (source is UtenPageEdgePadding && source.child != null) {
    return utenCompactToolbarChild(context, source.child!);
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
