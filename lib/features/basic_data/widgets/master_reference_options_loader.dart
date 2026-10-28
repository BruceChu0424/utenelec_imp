import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_task_progress_dialog.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../shared/auth/read_owner_fence.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import 'master_edit_owner.dart';

final _pendingReferenceReads =
    <String, ({Object ticket, bool Function() current})>{};

/// Reference reads share one visible wait, identity fence and error policy.
/// Empty options may either remain optional or block opening a required field.
Future<List<T>?> loadMasterReferenceOptions<T>({
  required BuildContext context,
  required WidgetRef ref,
  required String resourceKey,
  required String title,
  required Future<List<T>> Function() load,
  required String errorFallback,
  String? emptyMessage,
  MasterEditOwner? owner,
}) async {
  final reader = captureReadOwner(ref);
  bool current() => context.mounted && reader() && owner?.isCurrent != false;
  if (!current() || _pendingReferenceReads[resourceKey]?.current() == true) {
    return null;
  }
  final ticket = Object();
  _pendingReferenceReads[resourceKey] = (ticket: ticket, current: current);
  final changes = ValueNotifier<int>(0);
  final subscription = ref.listenManual(exportContextEpochProvider, (_, _) {
    changes.value++;
  });
  try {
    final values = await runUtenBlockingTask<List<T>>(
      context: context,
      title: title,
      isCurrent: current,
      invalidation: owner == null
          ? changes
          : Listenable.merge([owner, changes]),
      onRouteCreated: owner?.trackRoute,
      task: () => owner == null ? load() : owner.run(load),
    );
    if (!context.mounted || !current()) return null;
    if (values.isEmpty && emptyMessage != null) {
      context.appError(emptyMessage);
      return null;
    }
    return values;
  } catch (error) {
    if (context.mounted && current()) {
      context.appApiError(error, fallback: errorFallback);
    }
    return null;
  } finally {
    subscription.close();
    changes.dispose();
    if (identical(_pendingReferenceReads[resourceKey]?.ticket, ticket)) {
      _pendingReferenceReads.remove(resourceKey);
    }
  }
}
