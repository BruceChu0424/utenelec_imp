import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/sensitive_read_boundary_provider.dart';
import '../providers/session_provider.dart';

/// Bind an editor's command before secure-storage awaits. A temporary sticky
/// listener also detects A → B → A while credentials are being read.
Future<R> runSensitiveWrite<R>(
  WidgetRef ref, {
  required bool Function() isCurrent,
  required Future<R> Function() write,
}) async {
  final boundary = ref.read(sensitiveReadBoundaryProvider);
  final session = ref.read(sessionProvider.notifier);
  final intent = session.requestIntentEpoch;
  var invalidated = false;
  final subscription = ref.listenManual(sensitiveReadBoundaryProvider, (
    _,
    next,
  ) {
    if (next != boundary) invalidated = true;
  });
  bool current() =>
      !invalidated &&
      isCurrent() &&
      identical(ref.read(sessionProvider.notifier), session) &&
      session.requestIntentEpoch == intent &&
      boundary.identity != null &&
      !boundary.identity!.readOnly &&
      ref.read(sensitiveReadBoundaryProvider) == boundary;
  try {
    final scope = await boundary.api.captureRequestScope(isCurrent: current);
    final result = await scope.run(write);
    scope.checkCurrent();
    return result;
  } finally {
    invalidated = true;
    subscription.close();
  }
}
