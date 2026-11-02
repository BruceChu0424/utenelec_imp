import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Retains a small read through a short page departure. The owner must still
/// watch its identity/permission/write proofs; this lease never grants access.
void retainReadSnapshot(
  Ref ref, {
  Duration idleFor = const Duration(seconds: 60),
}) {
  final retention = ref.keepAlive();
  Timer? idle;
  var disposed = false;
  ref.onCancel(() {
    if (disposed) return;
    idle?.cancel();
    idle = Timer(idleFor, retention.close);
  });
  ref.onResume(() {
    idle?.cancel();
  });
  ref.onDispose(() {
    disposed = true;
    idle?.cancel();
  });
}
