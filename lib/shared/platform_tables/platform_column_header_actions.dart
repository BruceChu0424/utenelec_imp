import 'dart:async';

import 'package:flutter/material.dart';

import '../../components/feedback/uten_context_menu.dart';
import '../../components/feedback/uten_dialog.dart';
import '../../core/l10n/gen/app_localizations.dart';
import '../../core/l10n/gen/app_localizations_zh.dart';
import '../../core/ui/app_notification.dart';
import 'platform_table_controller.dart';

/// Both table surfaces expose the same deletion of an actor-owned custom column.
/// System columns and immutable document snapshots never acquire this action.
List<UtenContextMenuEntry> platformColumnHeaderDeleteEntries<T>(
  BuildContext context,
  PlatformTableController<T> controller,
  String key,
) {
  final column = controller.columnForDeletion(key);
  if (column == null) return const [];
  final text =
      Localizations.of<AppLocalizations>(context, AppLocalizations) ??
      AppLocalizationsZh();
  return [
    const UtenMenuDivider(),
    UtenMenuItem(
      label: text.platformColumnDeleteTitle,
      icon: Icons.delete_outline_rounded,
      destructive: true,
      onTap: () => unawaited(() async {
        final repository = controller.repository;
        final revision = controller.authorizationRevision;
        bool current() =>
            context.mounted &&
            !controller.disposed &&
            identical(repository, controller.repository) &&
            revision == controller.authorizationRevision;
        if (!current() || !controller.canDeleteColumn(column)) return;
        final confirmed = await UtenDialog.show(
          context,
          title: text.platformColumnDeleteTitle,
          content: Text(text.platformColumnDeleteConfirm(column.name)),
          confirmLabel: text.platformColumnDeleteAction,
          cancelLabel: text.commonCancel,
          danger: true,
        );
        if (confirmed != true ||
            !current() ||
            !controller.canDeleteColumn(column)) {
          return;
        }
        try {
          await controller.deleteColumn(column);
        } catch (error) {
          if (!context.mounted || !current()) return;
          context.appError(
            error is PlatformColumnDeletionException
                ? switch (error.failure) {
                    PlatformColumnDeletionFailure.forbidden =>
                      text.platformColumnDeleteForbidden,
                    PlatformColumnDeletionFailure.referenced =>
                      text.platformColumnDeleteReferenced,
                    PlatformColumnDeletionFailure.busy =>
                      text.platformColumnDeleteBusy,
                    PlatformColumnDeletionFailure.unavailable =>
                      text.platformColumnDeleteUnavailable,
                  }
                : platformTableError(error),
          );
        }
      }()),
    ),
  ];
}
