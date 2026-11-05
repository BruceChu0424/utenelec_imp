import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import 'package:flutter/material.dart';
import '../../../core/network/original_command.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_dialog_modules.dart';

/// The same original request proof is used by new commands and typed legacy
/// adapters. This does not change their server fingerprint or success shape.
typedef FinanceOriginalCommand = OriginalCommand;

bool financeOriginalIdentityCanMutate(AuthenticatedScope? scope) =>
    scope != null && !scope.readOnly && scope.actorId == null;

Future<bool> showFinanceCurrentVersionReview(
  BuildContext context, {
  required List<(String label, String input, String current)> rows,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialogContext) => UtenAlertDialog(
        title: const UtenDialogTitleWithHint(
          title: Text('核对当前设置'),
          info: '仅采用当前版本依据，保留本次业务输入；确认后仍需点击保存才会发送新请求。',
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final row in rows)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(row.$1, style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        SizedBox(
                          width: MediaQuery.sizeOf(context).width < 600
                              ? (MediaQuery.sizeOf(context).width - 96)
                                    .clamp(120, 240)
                                    .toDouble()
                              : 280,
                          child: UtenDialogField(
                            label: const Text('本次输入'),
                            child: SelectableText(row.$2),
                          ),
                        ),
                        SizedBox(
                          width: MediaQuery.sizeOf(context).width < 600
                              ? (MediaQuery.sizeOf(context).width - 96)
                                    .clamp(120, 240)
                                    .toDouble()
                              : 280,
                          child: UtenDialogField(
                            label: const Text('当前设置'),
                            child: SelectableText(row.$3),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        ),
        actions: [
          UtenButton(
            type: UtenButtonType.secondary,
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('返回原输入'),
          ),
          UtenButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('采用当前版本，保留输入'),
          ),
        ],
      ),
    ) ??
    false;

List<Widget> financeOriginalRequestActions(
  BuildContext context, {
  required bool busy,
  required String receiptLabel,
  required Future<void> Function() receipt,
  required Future<void> Function() cancel,
  required ValueChanged<bool> onMenuChanged,
  List<UtenMenuItem> extraMenuActions = const [],
}) {
  final scope = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(authenticatedScopeProvider);
  return [
    _FinanceOriginalRequestMenu(
      busy: busy,
      receiptLabel: receiptLabel,
      receipt: receipt,
      cancel: cancel,
      onMenuChanged: onMenuChanged,
      canCancel: financeOriginalIdentityCanMutate(scope),
      extraActions: extraMenuActions,
    ),
  ];
}

class _FinanceOriginalRequestMenu extends StatefulWidget {
  const _FinanceOriginalRequestMenu({
    required this.busy,
    required this.receiptLabel,
    required this.receipt,
    required this.cancel,
    required this.onMenuChanged,
    required this.canCancel,
    this.extraActions = const [],
  });
  final bool busy;
  final bool canCancel;
  final List<UtenMenuItem> extraActions;
  final String receiptLabel;
  final Future<void> Function() receipt, cancel;
  final ValueChanged<bool> onMenuChanged;
  @override
  State<_FinanceOriginalRequestMenu> createState() =>
      _FinanceOriginalRequestMenuState();
}

class _FinanceOriginalRequestMenuState
    extends State<_FinanceOriginalRequestMenu> {
  final _controller = UtenContextMenuController();
  bool _open = false;
  Future<void> _show(BuildContext anchorContext) async {
    if (widget.busy || _open) return;
    final anchor = anchorContext.findRenderObject();
    if (anchor is! RenderBox || !anchor.attached) return;
    final changed = widget.onMenuChanged;
    setState(() => _open = true);
    changed(true);
    try {
      await showUtenContextMenu(
        context,
        globalPosition: anchor.localToGlobal(Offset(0, anchor.size.height)),
        controller: _controller,
        entries: [
          ...widget.extraActions,
          UtenMenuItem(
            label: widget.receiptLabel,
            icon: Icons.fact_check_outlined,
            onTap: widget.receipt,
          ),
          UtenMenuItem(
            label: '核实未写并保留输入',
            enabled: widget.canCancel,
            icon: Icons.rule_outlined,
            onTap: widget.cancel,
          ),
        ],
      );
    } finally {
      if (mounted) setState(() => _open = false);
      changed(false);
    }
  }

  @override
  void dispose() {
    _controller.dismiss();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Builder(
    builder: (anchorContext) => UtenButton(
      type: UtenButtonType.secondary,
      onPressed: widget.busy || _open ? null : () => _show(anchorContext),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('原请求操作'),
          SizedBox(width: 4),
          Icon(Icons.arrow_drop_down, size: 20),
        ],
      ),
    ),
  );
}
