import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/network/server_config.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../../shared/providers/shared_providers.dart';

/// Only an opaque request UUID is retained, never paths, previews or secrets.
/// A new login of the same real operator may query its old durable receipt.
final serverStorageRequestOwnerProvider = Provider<String?>((ref) {
  final scope = ref.watch(authenticatedScopeProvider);
  if (scope == null || scope.actorId != null) return null;
  return sha256
      .convert(
        utf8.encode(
          jsonEncode([
            ref.watch(apiBaseUrlProvider),
            scope.userId,
            scope.businessResetGeneration,
            if (scope.businessDatasetId != null) scope.businessDatasetId,
          ]),
        ),
      )
      .toString();
});

final serverStorageRequestStoreProvider = Provider<ServerStorageRequestStore>(
  (ref) => ServerStorageRequestStore(ref.watch(sharedPreferencesProvider)),
);

class ServerStorageRequestStore {
  ServerStorageRequestStore(this.preferences);
  final SharedPreferences preferences;
  static const _prefix = 'serverStorage.lastRequest.v1.';
  static final _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );

  String? read(String owner) {
    final value = preferences.getString('$_prefix$owner');
    return value != null && _uuid.hasMatch(value) ? value : null;
  }

  Future<void> remember(String owner, String requestId) async {
    if (!_uuid.hasMatch(requestId) ||
        !await preferences.setString('$_prefix$owner', requestId)) {
      throw StateError('Cannot persist cleanup receipt tracking');
    }
  }
}
