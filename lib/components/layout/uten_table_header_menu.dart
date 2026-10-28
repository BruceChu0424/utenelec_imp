import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';
import '../inputs/uten_dropdown_scroll_scope.dart';

/// Shared header-menu geometry for read tables and editable grids. Recompute on
/// every overlay layout, including window resize, zoom and keyboard changes.
class UtenTableHeaderMenu extends StatefulWidget {
  const UtenTableHeaderMenu({
    super.key,
    required this.anchorContext,
    required this.onClose,
    required this.child,
  });

  final BuildContext anchorContext;
  final VoidCallback onClose;
  final Widget child;

  @override
  State<UtenTableHeaderMenu> createState() => _UtenTableHeaderMenuState();
}

class _UtenTableHeaderMenuState extends State<UtenTableHeaderMenu> {
  Rect? _lastAnchor;
  @override
  void initState() {
    super.initState();
    _watchAnchor();
  }

  // Follow painted movement without scheduling idle frames. Positioned panels
  // let hover/focus hint portals resolve layout outside a paint-only follower.
  void _watchAnchor() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.anchorContext.mounted) return;
      final anchor = widget.anchorContext.findRenderObject();
      if (anchor is RenderBox && anchor.attached && anchor.hasSize) {
        final next = anchor.localToGlobal(Offset.zero) & anchor.size;
        if (_lastAnchor != next) setState(() => _lastAnchor = next);
      }
      _watchAnchor();
    });
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final anchor = widget.anchorContext.findRenderObject();
      final surface = Overlay.of(
        widget.anchorContext,
        rootOverlay: true,
      ).context.findRenderObject();
      if (anchor is! RenderBox || surface is! RenderBox || !anchor.hasSize) {
        return const SizedBox.shrink();
      }
      final media = MediaQuery.of(context);
      final origin = surface.globalToLocal(anchor.localToGlobal(Offset.zero));
      final viewport = constraints.biggest;
      final leftLimit = media.padding.left + 8;
      final rightLimit = math.max(
        leftLimit,
        viewport.width - media.padding.right - 8,
      );
      final topLimit = media.padding.top + 8;
      final bottomLimit = math.max(
        topLimit,
        viewport.height -
            math.max(media.viewInsets.bottom, media.padding.bottom) -
            8,
      );
      final desiredWidth = 320 * media.textScaler.scale(14) / 14;
      final width = math.min(
        desiredWidth.clamp(280.0, 480.0),
        rightLimit - leftLimit,
      );
      final left = origin.dx.clamp(
        leftLimit,
        math.max(leftLimit, rightLimit - width),
      );
      final anchorTop = origin.dy.clamp(topLimit, bottomLimit).toDouble();
      final anchorBottom = (origin.dy + anchor.size.height)
          .clamp(topLimit, bottomLimit)
          .toDouble();
      final below = math.max(0.0, bottomLimit - anchorBottom - 2);
      final above = math.max(0.0, anchorTop - topLimit - 2);
      final openAbove = below < 200 && above > below;
      final height = math.min(420.0, openAbove ? above : below);
      // Clamp even an anchor scrolled partly outside the visible viewport.
      final menuY = openAbove ? anchorTop - 2 : anchorBottom + 2;
      return Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: widget.onClose,
            ),
          ),
          Positioned(
            left: left.toDouble(),
            top: openAbove ? null : menuY,
            bottom: openAbove ? viewport.height - menuY : null,
            child: TapRegion(
              onTapOutside: (_) => widget.onClose(),
              child: Material(
                key: const Key('uten-table-header-menu'),
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                elevation: 8,
                borderRadius: BorderRadius.circular(UtenRadius.md),
                clipBehavior: Clip.antiAlias,
                child: SizedBox(
                  width: width,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: height),
                    child: widget.child,
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}

/// Search and choices share one scroll viewport so enlarged text and short
/// windows never leave a fixed search row overflowing the available height.
class UtenTableHeaderMenuList extends StatelessWidget {
  const UtenTableHeaderMenuList({
    super.key,
    this.search,
    required this.entries,
  });
  final Widget? search;
  final List<Widget> entries;

  @override
  Widget build(BuildContext context) => UtenDropdownScrollScope(
    child: CustomScrollView(
      primary: false,
      shrinkWrap: true,
      slivers: [
        if (search != null) SliverToBoxAdapter(child: search),
        SliverList.list(children: entries),
      ],
    ),
  );
}
