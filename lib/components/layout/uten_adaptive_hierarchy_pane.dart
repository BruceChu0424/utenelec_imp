import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Keeps the same hierarchy and detail mounted while available space changes.
/// A compact hierarchy opens inside this pane, so closing it cannot accidentally
/// dismiss an outer picker or discard its provisional multi-selection.
class UtenAdaptiveHierarchyPane extends StatefulWidget {
  const UtenAdaptiveHierarchyPane({
    super.key,
    required this.leading,
    required this.trailing,
    required this.canSplit,
    required this.splitBuilder,
    this.selectedLabel,
    this.selectionKey,
    this.noun = '分类',
    this.compactHeader,
    this.openButtonKey,
  });

  final Widget leading;
  final Widget trailing;
  final bool canSplit;
  final Widget Function(Widget leading, Widget trailing) splitBuilder;
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
    if (widget.canSplit) return widget.splitBuilder(leading, trailing);
    return PopScope(
      canPop: !_open,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _open) _close();
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () {
            if (_open) _close();
          },
        },
        child: Stack(
          children: [
            Positioned.fill(
              child: Visibility(
                visible: !_open,
                maintainState: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ?widget.compactHeader,
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                      child: OutlinedButton(
                        key: widget.openButtonKey,
                        focusNode: _triggerFocus,
                        onPressed: () => setState(() => _open = true),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
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
                    ),
                    Expanded(child: trailing),
                  ],
                ),
              ),
            ),
            Positioned.fill(
              child: Visibility(
                visible: _open,
                maintainState: true,
                child: Material(
                  color: Theme.of(context).colorScheme.surface,
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${widget.noun}目录',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                            IconButton(
                              tooltip: '返回内容',
                              onPressed: _close,
                              icon: const Icon(Icons.close_rounded),
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      Expanded(child: leading),
                    ],
                  ),
                ),
              ),
            ),
          ],
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
