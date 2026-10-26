import 'package:flutter/material.dart';

import '../../core/theme/uten_scroll_behavior.dart';
import 'uten_content_scrollbar.dart';
import 'uten_scroll_gutter.dart';
import 'uten_page_scrollbar_host.dart';
import 'uten_page_layout.dart';

/// One viewport and its independent trailing scrollbar lane. Headers that stay
/// outside the viewport can use the same gutter to keep their edges aligned.
class UtenVerticalScrollArea extends StatelessWidget {
  const UtenVerticalScrollArea({
    super.key,
    required this.controller,
    required this.child,
    this.bottomInset = 0,
    this.pageScrollbar = false,
    this.pageScrollbarPriority = UtenPageScrollbarPriority.page,
  });

  final ScrollController controller;
  final Widget child;
  final double bottomInset;

  /// Dedicated hierarchy panes remain local; page wrappers opt into the host.
  final bool pageScrollbar;
  final int pageScrollbarPriority;

  @override
  Widget build(BuildContext context) => UtenScrollbarOwnerScope(
    controller: controller,
    child: UtenPageScrollRoleScope(
      role: pageScrollbar ? UtenPageScrollRole.main : UtenPageScrollRole.local,
      child: UtenPageScrollbarSource(
        controller: controller,
        enabled: pageScrollbar,
        priority: pageScrollbarPriority,
        bottomInset: bottomInset,
        debugLabel: 'vertical-scroll-area',
        builder: (context, localVisible) => Stack(
          children: [
            UtenScrollGutter.trailing(child: child),
            Positioned(
              top: 0,
              right: 0,
              bottom: 0,
              width: UtenScrollGutter.trackWidth,
              child: UtenContentScrollbar(
                controller: controller,
                bottomInset: bottomInset,
                visible: localVisible,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
