import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../components/feedback/uten_context_menu.dart';
import '../../core/theme/uten_tokens.dart';
import '../../core/l10n/gen/app_localizations.dart';
import '../../core/l10n/gen/app_localizations_zh.dart';

AppLocalizations _l10n(BuildContext context) =>
    Localizations.of<AppLocalizations>(context, AppLocalizations) ??
    AppLocalizationsZh();

/// The selected node's card and tree menu resolve the same current actions.
/// The builder is evaluated on opening so a permission refresh cannot leave a
/// previously built card offering stale actions.
class UtenHierarchyDetailMenu extends InheritedWidget {
  const UtenHierarchyDetailMenu({
    super.key,
    required this.entriesBuilder,
    required super.child,
  });

  final List<UtenContextMenuEntry> Function() entriesBuilder;

  static UtenHierarchyDetailMenu? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UtenHierarchyDetailMenu>();

  @override
  bool updateShouldNotify(UtenHierarchyDetailMenu oldWidget) =>
      entriesBuilder != oldWidget.entriesBuilder;
}

/// Read-only utilities remain useful even when a node cannot be changed.
List<UtenContextMenuEntry> utenHierarchyCopyEntries(
  BuildContext context, {
  required String name,
  String? path,
}) {
  final l10n = _l10n(context);
  return [
    UtenMenuItem(
      label: l10n.hierarchyCopyName,
      icon: Icons.content_copy_rounded,
      onTap: () => Clipboard.setData(ClipboardData(text: name)),
    ),
    if (path != null && path.isNotEmpty)
      UtenMenuItem(
        label: l10n.hierarchyCopyPath,
        icon: Icons.account_tree_outlined,
        onTap: () => Clipboard.setData(ClipboardData(text: path)),
      ),
  ];
}

class UtenHierarchyMenuButton extends StatelessWidget {
  const UtenHierarchyMenuButton({super.key, required this.entriesBuilder});

  final List<UtenContextMenuEntry> Function() entriesBuilder;

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    return IconButton.filledTonal(
      key: const ValueKey('hierarchy-detail-menu'),
      tooltip: l10n.hierarchyActions,
      style: IconButton.styleFrom(
        minimumSize: const Size.square(44),
        shape: const RoundedRectangleBorder(
          borderRadius: UtenRadius.controlAll,
        ),
      ),
      icon: const Icon(Icons.more_horiz_rounded, size: 28),
      onPressed: () {
        final box = context.findRenderObject();
        if (box is! RenderBox || !box.attached) return;
        showUtenContextMenu(
          context,
          globalPosition: box.localToGlobal(box.size.bottomRight(Offset.zero)),
          entries: entriesBuilder(),
        );
      },
    );
  }
}
