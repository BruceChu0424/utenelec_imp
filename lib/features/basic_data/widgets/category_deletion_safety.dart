import 'package:flutter/material.dart';

import '../../../components/feedback/uten_dialog.dart';

Future<void> showCategoryDeleteError(BuildContext context, String message) =>
    showDialog<void>(
      context: context,
      builder: (dialogContext) => UtenAlertDialog(
        showCloseButton: true,
        onClose: () => Navigator.pop(dialogContext),
        title: const UtenDialogHeading(
          title: Text('删除失败'),
          icon: Icons.error_outline_rounded,
          danger: true,
        ),
        content: Text(message),
        actionsAlignment: MainAxisAlignment.center,
      ),
    );
