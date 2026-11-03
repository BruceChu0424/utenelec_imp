import 'package:flutter/material.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/master_batch.dart';

enum _ReferencedDeleteChoice { view, hide }

class MasterDeleteResolution {
  const MasterDeleteResolution(
    this.result, {
    this.showOutcome = true,
    this.referencesToView = const [],
  });

  final MasterBatchResult result;
  final bool showOutcome;
  final List<MasterBatchItemResult> referencesToView;
}

/// The original request has already passed server authorization/version checks.
/// Only rows explicitly marked by the server may be confirmed, using their
/// original versions. A failed/unknown retry is never replayed here.
Future<MasterDeleteResolution> resolveReferencedMasterDelete({
  required BuildContext context,
  required String noun,
  required MasterBatchResult initial,
  required List<MasterBatchItem> originalItems,
  required bool Function() isCurrent,
  required Future<MasterBatchResult> Function(List<MasterBatchItem>) hide,
  Widget Function(BuildContext, Widget)? dialogScopeBuilder,
}) async {
  final failures = initial.failures;
  final references = failures
      .where((item) => item.confirmationRequired)
      .toList(growable: false);
  if (references.isEmpty || !context.mounted || !isCurrent()) {
    return MasterDeleteResolution(initial);
  }
  final choice = await showDialog<_ReferencedDeleteChoice>(
    context: context,
    builder: (ctx) {
      final dialog = UtenAlertDialog(
        key: const Key('master-referenced-delete'),
        scrollable: false,
        showCloseButton: true,
        onClose: () => Navigator.pop(ctx),
        title: Text('$noun仍有关联业务'),
        content: SizedBox(
          width: double.maxFinite,
          height: MediaQuery.sizeOf(ctx).height * 0.55,
          child: ListView.builder(
            itemCount: failures.length + 1,
            itemBuilder: (_, index) {
              if (index == 0) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: UtenSpacing.s16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('仍然删除后，资料列表和新建单据中不再显示；已有单据、往来账和业务记录继续保留。'),
                      if (initial.succeeded > 0) ...[
                        const SizedBox(height: UtenSpacing.s8),
                        Text('已删除 ${initial.succeeded} 个$noun。以下资料尚未删除。'),
                      ],
                    ],
                  ),
                );
              }
              final item = failures[index - 1];
              return Padding(
                padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.label ?? noun,
                      style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: item.confirmationRequired
                            ? null
                            : Theme.of(ctx).colorScheme.error,
                      ),
                    ),
                    Text(item.reason ?? '该资料仍有关联业务。'),
                  ],
                ),
              );
            },
          ),
        ),
        actions: [
          UtenButton(
            key: const Key('master-referenced-delete-view'),
            type: UtenButtonType.ghost,
            onPressed: () => Navigator.pop(ctx, _ReferencedDeleteChoice.view),
            child: const Text('去查看'),
          ),
          UtenButton(
            key: const Key('master-referenced-delete-confirm'),
            type: UtenButtonType.danger,
            onPressed: () => Navigator.pop(ctx, _ReferencedDeleteChoice.hide),
            child: const Text('仍然删除'),
          ),
        ],
      );
      return dialogScopeBuilder?.call(ctx, dialog) ?? dialog;
    },
  );
  if (!context.mounted || !isCurrent()) {
    return MasterDeleteResolution(initial, showOutcome: false);
  }
  if (choice != _ReferencedDeleteChoice.hide) {
    return MasterDeleteResolution(
      initial,
      showOutcome: false,
      referencesToView: choice == _ReferencedDeleteChoice.view
          ? references
          : const [],
    );
  }
  final ids = references.map((item) => item.id).toSet();
  final retry = await hide([
    for (final item in originalItems)
      if (ids.contains(item.id)) item,
  ]);
  final byId = {for (final item in retry.results) item.id: item};
  final merged = [for (final item in initial.results) byId[item.id] ?? item];
  final succeeded = merged.where((item) => item.ok).length;
  return MasterDeleteResolution(
    MasterBatchResult(
      succeeded: succeeded,
      failed: merged.length - succeeded,
      results: merged,
    ),
  );
}
