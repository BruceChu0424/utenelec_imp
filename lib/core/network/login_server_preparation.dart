import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/providers/shared_providers.dart';
import 'server_selection.dart';

/// The selection changed while probing; callers must discard this preparation
/// before they send any credentials. This does not retry an authentication POST.
class LoginServerPreparationCancelled implements Exception {
  const LoginServerPreparationCancelled();
}

/// Shared native automatic-selection gate. Explicit diagnostic choices and Web
/// retain their existing routing, without an extra local health request.
Future<void> prepareLoginServerSelection({
  required ServerMode mode,
  required Future<void> Function() probe,
  bool web = kIsWeb,
  bool Function()? isCurrent,
}) async {
  if (isCurrent?.call() == false) {
    throw const LoginServerPreparationCancelled();
  }
  if (web || mode != ServerMode.auto) return;
  await probe();
  if (isCurrent?.call() == false) {
    throw const LoginServerPreparationCancelled();
  }
}

/// The login UI awaits this before capturing its server/OTP context. The
/// authentication owner keeps all session intent and credential-exchange logic.
final loginServerPreparationProvider = Provider<Future<void> Function()>((ref) {
  return () async {
    if (!ref.mounted) throw const LoginServerPreparationCancelled();
    final preferences = ref.read(sharedPreferencesProvider);
    final mode = readServerMode(preferences);
    final local = localApiBaseUrl;
    final cloud = readCloudUrl(preferences);
    LocalServerReachabilityNotifier? probeOwner;
    await prepareLoginServerSelection(
      mode: mode,
      probe: () {
        final owner = ref.read(localServerReachableProvider.notifier);
        probeOwner = owner;
        return owner.probe();
      },
      isCurrent: () =>
          ref.mounted &&
          identical(preferences, ref.read(sharedPreferencesProvider)) &&
          readServerMode(preferences) == mode &&
          localApiBaseUrl == local &&
          readCloudUrl(preferences) == cloud &&
          (probeOwner == null ||
              identical(
                probeOwner,
                ref.read(localServerReachableProvider.notifier),
              )),
    );
  };
});
