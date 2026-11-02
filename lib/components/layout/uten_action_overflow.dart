import 'package:flutter/material.dart';

import '../../core/responsive/compact_presentation.dart';
import '../../core/theme/uten_tokens.dart';
import '../buttons/uten_button.dart';
import '../buttons/uten_export_button.dart';
import '../buttons/uten_import_button.dart';
import '../buttons/uten_refresh_button.dart';
import '../buttons/uten_tree_expansion_button.dart';
import '../buttons/uten_app_bar_action_button.dart';
import '../buttons/click_guard.dart';
import '../print/uten_print_preview.dart';
import 'uten_app_bar_action_scope.dart';
import 'uten_fit_or_compact.dart';
import 'uten_anchored_popup.dart';

/// Uten's compact action dropdown. The original controls (including async
/// progress, disabled explanations and permissions) move as one retained
/// subtree; callbacks and business decisions are never reconstructed as labels.
class UtenActionOverflow extends StatefulWidget {
  const UtenActionOverflow({
    super.key,
    required this.children,
    this.forceCompact = false,
    this.label = '更多操作',
  });

  final List<Widget> children;
  final bool forceCompact;
  final String label;

  /// Inputs and filters must remain mounted and visible beside the dropdown.
  /// Only known action controls participate; opaque page widgets stay outside.
  static bool isAction(Widget source) {
    if (source is KeyedSubtree) return isAction(source.child);
    if (source is Padding && source.child != null) {
      return isAction(source.child!);
    }
    if (source is SizedBox && source.child != null) {
      return isAction(source.child!);
    }
    if (source is Align && source.child != null) return isAction(source.child!);
    if (source is ExcludeFocus) return isAction(source.child);
    if (source is IgnorePointer && source.child != null) {
      return isAction(source.child!);
    }
    if (source is AnimatedOpacity && source.child != null) {
      return isAction(source.child!);
    }
    return source is UtenButton ||
        source is ButtonStyleButton ||
        source is IconButton ||
        source is UtenExportButton ||
        source is UtenImportButton ||
        source is UtenRefreshButton ||
        source is UtenTreeExpansionButton ||
        source is UtenAppBarActionButton ||
        source is UtenActionButton ||
        source is UtenPrintPreviewButton;
  }

  @override
  State<UtenActionOverflow> createState() => _UtenActionOverflowState();
}

/// Toolbar action rows share one compact policy; fields/statuses stay outside
/// the menu. Desktop callers retain their original Wrap geometry.
class UtenResponsiveActionWrap extends StatelessWidget {
  const UtenResponsiveActionWrap({
    super.key,
    required this.children,
    this.spacing = UtenSpacing.s8,
    this.runSpacing = UtenSpacing.s8,
  });
  final List<Widget> children;
  final double spacing;
  final double runSpacing;

  @override
  Widget build(BuildContext context) {
    final actions = children.where(UtenActionOverflow.isAction).toList();
    final compact = UtenCompactPresentation.of(context);
    final collapse = compact && actions.length > 2;
    final row = Wrap(
      spacing: compact && spacing > UtenSpacing.s4 ? UtenSpacing.s4 : spacing,
      runSpacing: compact && runSpacing > UtenSpacing.s4
          ? UtenSpacing.s4
          : runSpacing,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: collapse
          ? [
              ...children.where((child) => !UtenActionOverflow.isAction(child)),
              UtenActionOverflow(
                label: '表格操作',
                forceCompact: MediaQuery.sizeOf(context).width < 600,
                children: actions,
              ),
            ]
          : children,
    );
    return compact
        ? Align(alignment: AlignmentDirectional.centerStart, child: row)
        : row;
  }
}

class _UtenActionOverflowState extends State<UtenActionOverflow> {
  final _controller = UtenPopupController();
  final _actionsKey = GlobalKey();
  final _actionKeys = <GlobalKey>[];
  bool _open = false;
  bool _claimed = false;
  int _revision = 0;
  List<Widget>? _pendingActions;

  @override
  void didUpdateWidget(UtenActionOverflow oldWidget) {
    super.didUpdateWidget(oldWidget);
    _revision++;
    // A rebuild can revoke permissions or change the selected rows. Never keep
    // an old, already-open list of actions alive across that source revision.
    if (_open && !_claimed) {
      _claimed = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _controller.close();
      });
    }
  }

  Widget _actions({required bool menu}) {
    final sources = _pendingActions ?? widget.children;
    final revision = _revision;
    while (_actionKeys.length < sources.length) {
      _actionKeys.add(GlobalKey());
    }
    final actions = [
      for (var i = 0; i < sources.length; i++)
        KeyedSubtree(key: _actionKeys[i], child: _present(sources[i], menu)),
    ];
    return KeyedSubtree(
      key: _actionsKey,
      child: UtenMenuActionPresentation(
        enabled: menu,
        child: UtenAppBarActionScope(
          actionContext: context,
          claimAction: () {
            if (revision != _revision) return false;
            if (!menu) return true;
            if (!_open || _claimed) return false;
            _claimed = true;
            _pendingActions = sources;
            return true;
          },
          dismiss: menu
              ? () {
                  if (!mounted) return;
                  setState(() {
                    _pendingActions = null;
                    _claimed = false;
                  });
                  _controller.close();
                }
              : () {},
          // Keep stateful import/export controls mounted until their await finishes.
          child: menu
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < actions.length; i++) ...[
                      if (i > 0) const SizedBox(height: UtenSpacing.s4),
                      actions[i],
                    ],
                  ],
                )
              : Wrap(
                  spacing: UtenSpacing.s8,
                  runSpacing: UtenSpacing.s8,
                  alignment: WrapAlignment.end,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: actions,
                ),
        ),
      ),
    );
  }

  Widget _present(Widget source, bool menu) {
    if (!menu) return source;
    if (source is KeyedSubtree) {
      return KeyedSubtree(key: source.key, child: _present(source.child, menu));
    }
    if (source is Padding) {
      return Padding(
        key: source.key,
        padding: source.padding,
        child: source.child == null ? null : _present(source.child!, menu),
      );
    }
    if (source is SizedBox) {
      return SizedBox(
        key: source.key,
        width: source.width,
        height: source.height,
        child: source.child == null ? null : _present(source.child!, menu),
      );
    }
    if (source is ButtonStyleButton) {
      final revision = _revision;
      VoidCallback? before(VoidCallback? action) => action == null
          ? null
          : () {
              if (!_open || _claimed || revision != _revision) return;
              _claimed = true;
              _controller.close();
              action();
            };
      return UtenAppBarNativeActionButton(
        source: source,
        onPressed: before(source.onPressed),
        onLongPress: before(source.onLongPress),
      );
    }
    return source;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.children.isEmpty && _pendingActions == null) {
      return const SizedBox.shrink();
    }
    return UtenAnchoredPopup(
      controller: _controller,
      onChanged: (open) => setState(() {
        if (_pendingActions == null) _claimed = false;
        _open = open;
      }),
      popupBuilder: (_) =>
          SingleChildScrollView(primary: false, child: _actions(menu: true)),
      child: UtenFitOrCompact(
        forceCompact: widget.forceCompact || _open,
        expanded: _open ? const SizedBox.shrink() : _actions(menu: false),
        compact: IconButton(
          key: const ValueKey('uten-action-overflow-trigger'),
          tooltip: widget.label,
          onPressed: _controller.toggle,
          icon: const Icon(Icons.more_horiz_rounded, size: 20),
        ),
      ),
    );
  }
}
