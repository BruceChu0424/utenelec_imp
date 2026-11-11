import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/export_context_epoch_provider.dart';
import 'complete_output_guard.dart';
import 'paged_query_identity.dart';
import 'scoped_paged_read.dart';

export 'complete_output_guard.dart';

/// View adapter for the shared complete-result/output lifecycle.
/// Callers supply their actual query and render data; identity retirement,
/// complete acceptance and confirmed-write retirement have one owner here.
mixin CompleteOutputViewMixin<W extends ConsumerStatefulWidget>
    on ConsumerState<W> {
  final completeOutputGuard = CompleteOutputGuard();
  Object get completeOutputQuery;
  bool get completeOutputHasData;
  Object get completeOutputActionQuery => completeOutputQuery;
  bool get completeOutputActionReady => completeOutputCurrent;

  Object get completeOutputIdentity => [
    ref.read(exportContextEpochProvider),
    completeOutputQuery,
  ];

  bool get completeOutputCurrent =>
      mounted &&
      completeOutputHasData &&
      completeOutputGuard.hasComplete(completeOutputIdentity);

  bool Function() captureCompleteOutput() {
    final retirement = completeOutputGuard.retirement;
    final epoch = ref.read(exportContextEpochProvider);
    final query = PagedReadQueryKey(completeOutputActionQuery);
    return () =>
        mounted &&
        completeOutputActionReady &&
        retirement == completeOutputGuard.retirement &&
        epoch == ref.read(exportContextEpochProvider) &&
        query == PagedReadQueryKey(completeOutputActionQuery);
  }

  CompleteOutputRead<T> beginCompleteOutputRead<T>(
    T? previous, {
    bool preserveEditorInput = false,
  }) => completeOutputGuard.begin(
    identity: completeOutputIdentity,
    previous: previous,
    preserveEditorInput: preserveEditorInput,
  );

  void retireCompleteOutputAfterWrite({bool confirmed = true}) {
    if (!confirmed) return;
    completeOutputGuard.retireAfterConfirmedWrite();
    if (mounted) setState(() {});
  }

  bool isCompleteOutputReadCurrent(CompleteOutputRead<Object?> read) =>
      mounted &&
      completeOutputGuard.isCurrent(read) &&
      read.identity == PagedReadQueryKey(completeOutputIdentity);

  bool mayPublishCompleteOutputPrefix(CompleteOutputRead<Object?> read) =>
      isCompleteOutputReadCurrent(read) && read.publishPrefixes;

  bool acceptCompleteOutputRead(CompleteOutputRead<Object?> read) =>
      isCompleteOutputReadCurrent(read) && completeOutputGuard.accept(read);

  bool restoreCompleteOutputRead<T>(
    CompleteOutputRead<T> read,
    void Function(T? fallback) restore, {
    Object? error,
  }) {
    if (!isCompleteOutputReadCurrent(read)) return false;
    final denied = error != null && pagedReadAccessDenied(error);
    if (denied) completeOutputGuard.retire();
    setState(() => restore(denied ? null : read.fallback));
    return true;
  }
}
