import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/security/auth_token_issuer.dart';
import 'package:uten_imp/core/security/pending_refresh_revocation_store.dart';
import 'package:uten_imp/core/security/secure_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const raw = FlutterSecureStorage();
  final policy = AuthBackendRealmPolicy();
  final issuerA = policy.issuerFor('https://a.invalid/api');
  final issuerB = policy.issuerFor('https://b.invalid/api');

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  for (final malformedIssuer in <Object?>[
    null,
    {'baseUrl': 'https://a.invalid/api', 'trustedRelays': 'broken'},
  ]) {
    test(
      'damaged v3 issuer $malformedIssuer cannot revive legacy keys',
      () async {
        FlutterSecureStorage.setMockInitialValues({
          'auth.access_token': 'residual-access',
          'auth.refresh_token': 'residual-refresh',
          'auth.token_record.v1': jsonEncode({
            'version': 3,
            'generation': 7,
            'intentGeneration': 5,
            'sessionLineage': 'original-lineage',
            'accessToken': 'bound-access',
            'refreshToken': 'bound-refresh',
            'issuer': ?malformedIssuer,
          }),
        });
        final storage = SecureStorage(raw);
        final result = await storage.getAuthTokenSnapshot();
        expect(result.hasTokens, isFalse);
        expect(await raw.read(key: 'auth.access_token'), isNull);
        expect(await raw.read(key: 'auth.refresh_token'), isNull);
        final persisted = AuthTokenSnapshot.tryParse(
          await raw.read(key: 'auth.token_record.v1'),
        );
        expect(persisted, isNotNull);
        expect(persisted!.hasTokens, isFalse);
      },
    );
  }

  test(
    'issuer-only replacement rejects stale refresh and cleanup CAS',
    () async {
      final storage = SecureStorage(raw);
      await storage.saveTokens(
        accessToken: 'same-access',
        refreshToken: 'same-refresh',
        issuer: issuerA,
      );
      final original = await storage.getAuthTokenSnapshot();
      final replaced = {...original.toJson(), 'issuer': issuerB.toJson()};
      await raw.write(key: 'auth.token_record.v1', value: jsonEncode(replaced));

      expect(await storage.clearTokensIfUnchanged(original), isFalse);
      expect(
        await storage.saveTokensIfUnchanged(
          expected: original,
          accessToken: 'stale-refresh-access',
          refreshToken: 'stale-refresh-token',
          issuer: issuerA,
        ),
        isFalse,
      );
      final winner = await storage.getAuthTokenSnapshot();
      expect(winner.issuer, issuerB);
      expect(winner.accessToken, 'same-access');
      expect(winner.generation, original.generation);
      expect(winner.intentGeneration, original.intentGeneration);
      expect(winner.sessionLineage, original.sessionLineage);
    },
  );

  test('bound v3 refresh preserves lineage, intent and issuer', () async {
    final storage = SecureStorage(raw);
    await storage.saveTokens(
      accessToken: 'before-access',
      refreshToken: 'before-refresh',
      issuer: issuerA,
    );
    final before = await storage.getAuthTokenSnapshot();
    expect(
      await storage.saveTokensIfUnchanged(
        expected: before,
        accessToken: 'after-access',
        refreshToken: 'after-refresh',
      ),
      isTrue,
    );
    final after = await storage.getAuthTokenSnapshot();
    expect(after.issuer, issuerA);
    expect(after.generation, before.generation + 1);
    expect(after.intentGeneration, before.intentGeneration);
    expect(after.sessionLineage, before.sessionLineage);
    final record =
        jsonDecode((await raw.read(key: 'auth.token_record.v1'))!)
            as Map<String, dynamic>;
    expect(record['version'], 3);
  });

  test(
    'same token under independent issuers is removed by exact owner',
    () async {
      final queue = PendingRefreshRevocationStore(SecureStorage(raw));
      await queue.enqueue('same-token', issuer: issuerA);
      await queue.enqueue('same-token', issuer: issuerB);
      await queue.enqueue('same-token', issuer: issuerA);
      expect(await queue.pendingEntries(), hasLength(2));

      await queue.remove('same-token', issuer: issuerA);
      final remaining = await queue.pendingEntries();
      expect(remaining, hasLength(1));
      expect(remaining.single.refreshToken, 'same-token');
      expect(remaining.single.issuer, issuerB);
      await queue.remove('same-token');
      expect(await queue.pendingEntries(), hasLength(1));
      await queue.remove('same-token', issuer: issuerB);
      expect(await queue.pendingEntries(), isEmpty);
    },
  );
}
