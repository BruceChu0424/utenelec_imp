import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/security/pending_refresh_revocation_store.dart';
import 'package:uten_imp/core/security/secure_storage.dart';

const _queueKey = 'auth.pending_refresh_revocations.v1';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  test(
    'queue deduplicates, refreshes recency, and keeps a hard bound',
    () async {
      var now = DateTime.utc(2026, 8, 2, 12);
      final storage = SecureStorage(const FlutterSecureStorage());
      final queue = PendingRefreshRevocationStore(
        storage,
        now: () => now,
        maxEntries: 3,
        retention: const Duration(hours: 1),
      );

      await queue.enqueue('token-1');
      now = now.add(const Duration(minutes: 1));
      await queue.enqueue('token-2');
      now = now.add(const Duration(minutes: 1));
      await queue.enqueue('token-1');
      now = now.add(const Duration(minutes: 1));
      await queue.enqueue('token-3');
      now = now.add(const Duration(minutes: 1));
      await queue.enqueue('token-4');

      expect(await queue.pendingTokens(), <String>[
        'token-1',
        'token-3',
        'token-4',
      ]);
      final encryptedStoreRecord = await storage.read(_queueKey);
      expect(encryptedStoreRecord, isNotNull);
      expect(encryptedStoreRecord, contains('token-4'));
    },
  );

  test('expired entries are erased from encrypted storage', () async {
    var now = DateTime.utc(2026, 8, 2, 12);
    final storage = SecureStorage(const FlutterSecureStorage());
    final queue = PendingRefreshRevocationStore(
      storage,
      now: () => now,
      retention: const Duration(minutes: 5),
    );
    await queue.enqueue('expiring-token');

    now = now.add(const Duration(minutes: 6));

    expect(await queue.pendingTokens(), isEmpty);
    expect(await storage.read(_queueKey), isNull);
  });

  test(
    'corrupt queue is discarded without reviving or clearing session',
    () async {
      final storage = SecureStorage(const FlutterSecureStorage());
      await storage.saveTokens(
        accessToken: 'current-access',
        refreshToken: 'current-refresh',
      );
      await storage.write(_queueKey, '{"version":1,"entries":"corrupt"}');
      final queue = PendingRefreshRevocationStore(storage);

      expect(await queue.pendingTokens(), isEmpty);
      expect(await storage.read(_queueKey), isNull);
      expect(await storage.getAccessToken(), 'current-access');
      expect(await storage.getRefreshToken(), 'current-refresh');

      expect(await queue.enqueue('new-pending-token'), isTrue);
      expect(await queue.pendingTokens(), <String>['new-pending-token']);
    },
  );

  test(
    'cross-instance concurrent enqueues do not overwrite each other',
    () async {
      const rawStorage = FlutterSecureStorage();
      final first = PendingRefreshRevocationStore(SecureStorage(rawStorage));
      final second = PendingRefreshRevocationStore(SecureStorage(rawStorage));

      await Future.wait(<Future<bool>>[
        for (var index = 0; index < 12; index++)
          (index.isEven ? first : second).enqueue('token-$index'),
        first.enqueue('same-token'),
        second.enqueue('same-token'),
      ]);

      final pending = await first.pendingTokens();
      expect(pending.toSet().length, 13);
      expect(
        pending,
        containsAll(<String>['token-0', 'token-11', 'same-token']),
      );
    },
  );

  test('invalid or oversized values never enter the queue', () async {
    final queue = PendingRefreshRevocationStore(
      SecureStorage(const FlutterSecureStorage()),
    );

    expect(await queue.enqueue(null), isFalse);
    expect(await queue.enqueue(''), isFalse);
    expect(
      await queue.enqueue(
        'x' * (PendingRefreshRevocationStore.maxTokenLength + 1),
      ),
      isFalse,
    );
    expect(await queue.pendingTokens(), isEmpty);
  });
}
