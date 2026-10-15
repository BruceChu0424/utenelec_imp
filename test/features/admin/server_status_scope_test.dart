import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/admin/models/server_status.dart';
import 'package:uten_imp/features/admin/providers/server_status_snapshot_cache.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

void main() {
  final endpoint = StateProvider<String>((ref) => 'https://company-a/api');
  final identity = StateProvider<AuthenticatedScope?>(
    (ref) => const AuthenticatedScope(userId: 'operator', epoch: 1),
  );

  for (final boundary in ['server', 'account', 'session', 'logout']) {
    test('server measurement cache is retired on $boundary change', () {
      final container = ProviderContainer(
        overrides: [
          apiBaseUrlProvider.overrideWith((ref) => ref.watch(endpoint)),
          authenticatedScopeProvider.overrideWith((ref) => ref.watch(identity)),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        serverStatusSnapshotCacheProvider,
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      final snapshot = ServerStatusSnapshot.fromJson({
        'status': 'NORMAL',
        'sampledAt': DateTime.now().toUtc().toIso8601String(),
      });
      container.read(serverStatusSnapshotCacheProvider.notifier).state =
          snapshot;
      expect(container.read(serverStatusSnapshotCacheProvider), same(snapshot));

      switch (boundary) {
        case 'server':
          container.read(endpoint.notifier).state = 'https://company-b/api';
        case 'account':
          container.read(identity.notifier).state = const AuthenticatedScope(
            userId: 'other',
            epoch: 1,
          );
        case 'session':
          container.read(identity.notifier).state = const AuthenticatedScope(
            userId: 'operator',
            epoch: 2,
          );
        case 'logout':
          container.read(identity.notifier).state = null;
      }

      expect(container.read(serverStatusSnapshotCacheProvider), isNull);
    });
  }
}
