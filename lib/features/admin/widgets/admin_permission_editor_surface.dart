import 'package:flutter/material.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/layout/uten_page_layout.dart';
import '../../../components/layout/uten_scroll_gutter.dart';
import '../../../core/theme/uten_tokens.dart';

/// The permission search/filter/tree is the page workspace in a merged layout.
/// Separate desktop panes and local dialogs retain their original card inset.
class AdminPermissionEditorSurface extends StatelessWidget {
  const AdminPermissionEditorSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final pageWorkspace =
        UtenPagePaneScope.splitOf(context) == false &&
        UtenPageScrollRoleScope.isPageOf(context) &&
        UtenContentInsetsScope.isPresentOf(context);
    // Keep the same element structure while a window crosses the split limit;
    // the catalog owns search/filter/expansion state below this surface.
    return UtenCard(
      padding: pageWorkspace
          ? EdgeInsets.zero
          : const EdgeInsets.all(UtenSpacing.s16),
      variant: pageWorkspace ? UtenCardVariant.outlined : UtenCardVariant.solid,
      showBorder: !pageWorkspace,
      borderRadius: pageWorkspace ? 0 : UtenRadius.card,
      child: child,
    );
  }
}
