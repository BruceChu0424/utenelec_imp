import 'package:flutter/material.dart';
import '../../components/buttons/uten_button.dart';
import '../../components/feedback/uten_dialog.dart';
import '../../core/l10n/gen/app_localizations.dart';
import '../../core/theme/uten_tokens.dart';
import 'client_update_controller.dart';

Future<bool?> showClientUpdateDialog(
  BuildContext context,
  ClientUpdateController controller, {
  Listenable? interruptSignal,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  late final DialogRoute<bool> route;
  void interrupt() {
    if (route.isActive) navigator.removeRoute(route);
  }

  route = DialogRoute<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => ClientUpdateDialog(controller: controller),
  );
  interruptSignal?.addListener(interrupt);
  controller.addOwnerDisposedListener(interrupt);
  try {
    return await navigator.push(route);
  } finally {
    interruptSignal?.removeListener(interrupt);
    controller.removeOwnerDisposedListener(interrupt);
  }
}

/// The login offer announces availability. Release notes and installation live
/// on the dedicated software update page opened by the primary action.
class ClientUpdateDialog extends StatelessWidget {
  const ClientUpdateDialog({super.key, required this.controller});
  final ClientUpdateController controller;
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return UtenAlertDialog(
      maxWidth: 460,
      icon: Center(
        child: Container(
          padding: const EdgeInsets.all(UtenSpacing.s24),
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: UtenRadius.xxlAll,
          ),
          child: Icon(
            Icons.system_update_alt_rounded,
            size: 44,
            color: scheme.onPrimaryContainer,
          ),
        ),
      ),
      title: Text(l10n.clientUpdateNewTitle, textAlign: TextAlign.center),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            controller.release?.version ?? '',
            style: theme.textTheme.headlineMedium?.copyWith(
              color: scheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: UtenSpacing.s12),
          Text(
            '${l10n.clientUpdateCurrent} ${controller.installed?.currentVersion ?? ''}',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      actions: [
        UtenButton(
          type: UtenButtonType.ghost,
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.clientUpdateLater),
        ),
        UtenButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.clientUpdateDetails),
        ),
      ],
    );
  }
}
