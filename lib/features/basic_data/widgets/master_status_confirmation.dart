import 'package:flutter/material.dart';

import '../../../components/feedback/uten_dialog.dart';
import '../../../core/l10n/gen/app_localizations.dart';

Future<bool> confirmMasterStatusChange(
  BuildContext context, {
  required bool disabling,
  required String label,
  int count = 1,
  Widget Function(BuildContext context, Widget dialog)? dialogScopeBuilder,
}) async {
  final l10n = AppLocalizations.of(context);
  return await showDialog<bool>(
        context: context,
        builder: (dialogContext) {
          final dialog = UtenAlertDialog(
            title: Text(
              disabling
                  ? l10n.masterStatusDisableTitle
                  : l10n.masterStatusEnableTitle,
            ),
            content: Text(
              disabling
                  ? l10n.masterStatusDisableBody(label, count)
                  : l10n.masterStatusEnableBody(label, count),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  if (dialogContext.mounted) {
                    Navigator.pop(dialogContext, false);
                  }
                },
                child: Text(l10n.commonCancel),
              ),
              FilledButton(
                style: disabling
                    ? FilledButton.styleFrom(
                        backgroundColor: Theme.of(
                          dialogContext,
                        ).colorScheme.error,
                        foregroundColor: Theme.of(
                          dialogContext,
                        ).colorScheme.onError,
                      )
                    : null,
                onPressed: () {
                  if (dialogContext.mounted) Navigator.pop(dialogContext, true);
                },
                child: Text(l10n.commonConfirm),
              ),
            ],
          );
          return dialogScopeBuilder?.call(dialogContext, dialog) ?? dialog;
        },
      ) ==
      true;
}
