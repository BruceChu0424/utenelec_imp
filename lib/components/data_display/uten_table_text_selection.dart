import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show Selectable, SelectedContent, SelectionRegistrar;
import 'package:flutter/services.dart';

import '../../core/l10n/gen/app_localizations.dart';
import '../../core/l10n/gen/app_localizations_zh.dart';

import '../feedback/uten_context_menu.dart';

/// Shared body selection and copy action for read and editable tables.
///
/// Keep one instance in the table State and one [SelectionArea] around its body.
/// Header drag/resize controls stay outside that region. Row menus capture the
/// selected text before their existing row-selection notifications rebuild cells.
class UtenTableTextSelection {
  final areaKey = GlobalKey<SelectionAreaState>();
  String _selectedText = '';
  int _revision = 0;

  void onSelectionChanged(SelectedContent? content) {
    _selectedText = content?.plainText ?? '';
  }

  /// Forget selection when the table's rows or business identity change.
  void clear() {
    _revision++;
    _selectedText = '';
    areaKey.currentState?.selectableRegion.clearSelection();
  }

  /// [tableContext] must be the table's own context, above all of its cells.
  /// An input elsewhere on the page must never contribute its selected text.
  List<UtenContextMenuEntry> copyMenuEntries(BuildContext tableContext) {
    final text = _focusedInputSelection(tableContext) ?? _selectedText;
    if (text.isEmpty) return const [];
    final revision = _revision;
    return [
      UtenMenuItem(
        label:
            (Localizations.of<AppLocalizations>(
                      tableContext,
                      AppLocalizations,
                    ) ??
                    AppLocalizationsZh())
                .tableCopySelectedText,
        icon: Icons.copy_rounded,
        preserveSelectionAfterAction: true,
        onTap: () async {
          if (tableContext.mounted && revision == _revision) {
            await Clipboard.setData(ClipboardData(text: text));
          }
        },
      ),
      const UtenMenuDivider(),
    ];
  }

  String? _focusedInputSelection(BuildContext tableContext) {
    final focusContext = FocusManager.instance.primaryFocus?.context;
    final input = focusContext?.findAncestorStateOfType<EditableTextState>();
    if (input == null || input.widget.obscureText) return null;

    var belongsToTable = false;
    input.context.visitAncestorElements((ancestor) {
      if (identical(ancestor, tableContext)) {
        belongsToTable = true;
        return false;
      }
      return true;
    });
    if (!belongsToTable) return null;

    final value = input.widget.controller.value;
    final selection = value.selection;
    if (!selection.isValid ||
        selection.isCollapsed ||
        selection.end > value.text.length) {
      return null;
    }
    return selection.textInside(value.text);
  }
}

/// Keeps a cell subtree mounted while a frozen copy owns text selection.
///
/// Swapping a disabled container in and out would recreate native input fields.
/// Changing only the registrar leaves their state and focus intact.
class UtenTableTextSelectionGate extends StatelessWidget {
  const UtenTableTextSelectionGate({
    super.key,
    required this.enabled,
    required this.child,
  });

  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) => SelectionRegistrarScope(
    registrar: enabled
        ? SelectionContainer.maybeOf(context) ??
              const _IgnoredSelectionRegistrar()
        : const _IgnoredSelectionRegistrar(),
    child: child,
  );
}

class _IgnoredSelectionRegistrar implements SelectionRegistrar {
  const _IgnoredSelectionRegistrar();

  @override
  void add(Selectable selectable) {}

  @override
  void remove(Selectable selectable) {}
}
