import 'package:flutter/material.dart';
import '../buttons/uten_close_button.dart';
import 'package:flutter/services.dart';

import '../../core/responsive/compact_presentation.dart';
import '../../core/theme/uten_tokens.dart';
import 'uten_compact_toolbar.dart';
import 'uten_collapsing_header_scroll_view.dart';
import 'uten_content_container.dart';
import 'uten_page_layout.dart';
import 'uten_scroll_gutter.dart';

/// Keeps the same hierarchy and detail mounted while available space changes.
/// A compact hierarchy opens inside this pane, so closing it cannot accidentally
/// dismiss an outer picker or discard its provisional multi-selection.
class UtenAdaptiveHierarchyPane extends StatefulWidget {
  const UtenAdaptiveHierarchyPane({
    super.key,
    required this.leading,
    required this.trailing,
    required this.canSplit,
    this.leadingWidth = 300,
    this.separator = const SizedBox.shrink(),
    this.separatorWidth = 0,
    this.selectedLabel,
    this.selectionKey,
    this.noun = '分类',
    this.compactHeader,
    this.openButtonKey,
  });

  final Widget leading;
  final Widget trailing;
  final bool canSplit;
  final double leadingWidth;
  final Widget separator;
  final double separatorWidth;
  final String? selectedLabel;
  final Object? selectionKey;
  final String noun;
  final Widget? compactHeader;
  final Key? openButtonKey;

  @override
  State<UtenAdaptiveHierarchyPane> createState() =>
      _AdaptiveHierarchyPaneState();
}

class _AdaptiveHierarchyPaneState extends State<UtenAdaptiveHierarchyPane> {
  final _leadingKey = GlobalKey();
  final _trailingKey = GlobalKey();
  final _compactHeaderKey = GlobalKey();
  final _triggerFocus = FocusNode();
  bool _open = false;

  @override
  void didUpdateWidget(UtenAdaptiveHierarchyPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.canSplit) {
      _open = false;
    }
  }

  void _close() {
    setState(() => _open = false);
    _triggerFocus.requestFocus();
  }

  @override
  void dispose() {
    _triggerFocus.dispose();
    super.dispose();
  }

  Widget _buildCompactContent(Widget trailing) {
    final compact = UtenCompactPresentation.iconSearchOf(context);
    final directory = UtenPageEdgePadding.pane(
      padding: EdgeInsets.all(compact ? 0 : 8),
      child: OutlinedButton(
        key: widget.openButtonKey,
        focusNode: _triggerFocus,
        onPressed: () => setState(() => _open = true),
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: compact ? 0 : 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.selectedLabel ?? '选择${widget.noun}',
                  softWrap: true,
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.account_tree_rounded, size: 20),
            ],
          ),
        ),
      ),
    );
    final header = Visibility(
      visible: !widget.canSplit,
      maintainState: true,
      maintainAnimation: true,
      child: KeyedSubtree(
        key: _compactHeaderKey,
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: compact ? 4 : 0),
          child: Flex(
            direction: compact ? Axis.horizontal : Axis.vertical,
            verticalDirection: compact
                ? VerticalDirection.down
                : VerticalDirection.up,
            crossAxisAlignment: compact
                ? CrossAxisAlignment.center
                : CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                flex: compact ? 1 : 0,
                fit: FlexFit.tight,
                child: directory,
              ),
              Visibility(
                visible: widget.compactHeader != null,
                maintainState: true,
                child: SizedBox(
                  width: compact ? 8 : 0,
                  height: compact ? 0 : 8,
                ),
              ),
              Flexible(
                flex: 0,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: compact
                        ? UtenControlMetrics.minimumHitExtent(context) * 3
                        : double.infinity,
                  ),
                  child: utenCompactToolbarChild(
                    context,
                    widget.compactHeader ?? const SizedBox.shrink(),
                    preserveWrapperState: true,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return UtenCollapsingHeaderScrollView(
      stableBodyViewport: true,
      collapsingHeader: header,
      body: trailing,
    );
  }

  @override
  Widget build(BuildContext context) {
    final leading = KeyedSubtree(
      key: _leadingKey,
      child: UtenHierarchyPanelScope(
        onSelection: widget.canSplit ? null : _close,
        child: widget.leading,
      ),
    );
    final trailing = KeyedSubtree(key: _trailingKey, child: widget.trailing);
    final showDirectory = !widget.canSplit && _open;
    final ownEdges =
        UtenPageScrollRoleScope.isPageOf(context) &&
        !UtenContentInsetsScope.isPresentOf(context);
    return UtenPagePaneScope(
      split: widget.canSplit,
      child: UtenContentContainer(
        selectable: false,
        applyGutter: !widget.canSplit && ownEdges,
        child: PopScope(
          canPop: !showDirectory,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && showDirectory) _close();
          },
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): () {
                if (showDirectory) _close();
              },
            },
            // These slots keep their Element and render parents across widths.
            // In particular, a live Tooltip/OverlayPortal is never activated
            // in a different parent while an ancestor LayoutBuilder lays out.
            child: Stack(
              fit: StackFit.expand,
              children: [
                PositionedDirectional(
                  start: widget.canSplit
                      ? widget.leadingWidth + widget.separatorWidth
                      : 0,
                  end: 0,
                  top: 0,
                  bottom: 0,
                  child: Visibility(
                    visible: !showDirectory,
                    maintainState: true,
                    maintainAnimation: true,
                    child: _buildCompactContent(trailing),
                  ),
                ),
                PositionedDirectional(
                  start: 0,
                  end: widget.canSplit ? null : 0,
                  width: widget.canSplit ? widget.leadingWidth : null,
                  top: 0,
                  bottom: 0,
                  child: Visibility(
                    visible: widget.canSplit || showDirectory,
                    maintainState: true,
                    maintainAnimation: true,
                    child: Material(
                      color: Theme.of(context).colorScheme.surface,
                      child: Column(
                        children: [
                          Visibility(
                            visible: !widget.canSplit,
                            maintainState: true,
                            maintainAnimation: true,
                            child: Column(
                              children: [
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    4,
                                    4,
                                    4,
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          '${widget.noun}目录',
                                          style: Theme.of(
                                            context,
                                          ).textTheme.titleMedium,
                                        ),
                                      ),
                                      UtenCloseButton(
                                        tooltip: '返回内容',
                                        onPressed: _close,
                                      ),
                                    ],
                                  ),
                                ),
                                const Divider(height: 1),
                              ],
                            ),
                          ),
                          Expanded(child: leading),
                        ],
                      ),
                    ),
                  ),
                ),
                PositionedDirectional(
                  start: widget.leadingWidth,
                  width: widget.separatorWidth,
                  top: 0,
                  bottom: 0,
                  child: Visibility(
                    visible: widget.canSplit,
                    maintainState: true,
                    maintainAnimation: true,
                    child: widget.separator,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Explicit row selection closes a compact hierarchy. Search-driven location,
/// counts arriving and permission refreshes never dismiss a user's open tree.
class UtenHierarchyPanelScope extends InheritedWidget {
  const UtenHierarchyPanelScope({
    super.key,
    required this.onSelection,
    required super.child,
  });
  final VoidCallback? onSelection;

  static UtenHierarchyPanelScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UtenHierarchyPanelScope>();

  @override
  bool updateShouldNotify(UtenHierarchyPanelScope oldWidget) =>
      onSelection != oldWidget.onSelection;
}
