import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/data_write_revision.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/security/auth_token_issuer.dart';
import 'package:uten_imp/core/security/secure_storage.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

// Exercise the owning provider's actual interceptor order, not a reconstructed
// test pipeline. This protects every feature sharing this client from drift.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'production client retains read capacity and write receipts across epochs',
    () => HttpOverrides.runWithHttpOverrides(() async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var epoch = 0, writes = 0, refreshes = 0, rejectedWrites = 0;
      final subscription = server.listen((request) async {
        await request.drain<void>();
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path == '/api/auth/refresh') {
          refreshes++;
          request.response.write(
            jsonEncode({
              'accessToken': 'fixture-access-$epoch',
              'refreshToken': 'fixture-refresh',
            }),
          );
        } else if (request.headers.value('authorization') !=
            'Bearer fixture-access-$epoch') {
          if (request.method == 'PUT') rejectedWrites++;
          request.response.statusCode = 401;
          request.response.write('{"code":"UNAUTHORIZED"}');
        } else {
          if (request.method == 'PUT') {
            writes++;
            epoch++;
          }
          request.response.write(jsonEncode({'epoch': epoch}));
        }
        await request.response.close();
      });
      final base = 'http://127.0.0.1:${server.port}/api';
      final storage = SecureStorage(const FlutterSecureStorage());
      await storage.saveTokens(
        issuer: AuthBackendRealmPolicy().issuerFor(base),
        accessToken: 'fixture-access-0',
        refreshToken: 'fixture-refresh',
      );
      final container = ProviderContainer(
        overrides: [
          apiBaseUrlProvider.overrideWithValue(base),
          secureStorageProvider.overrideWithValue(storage),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
      );
      try {
        final api = container.read(apiClientProvider);
        for (var round = 0; round < 20; round++) {
          // Some reads and some writes encounter an explicit auth rejection.
          // A transport timeout/unknown write is never made replayable here.
          if (round.isOdd) epoch++;
          await api
              .put(
                '/admin/users/fixture/permission-overrides',
                body: {'grants': <String>[], 'revokes': <String>[]},
              )
              .timeout(const Duration(seconds: 5));
          expect(
            container.read(dataWriteRevisionProvider),
            round + 1,
            reason: 'Every confirmed write publishes exactly one receipt',
          );
          final replies = await Future.wait([
            api.get('/admin/users'),
            api.get('/admin/users/fixture/effective-permissions'),
            api.get('/admin/server-status'),
            api.get('/notices/summary'),
          ]).timeout(const Duration(seconds: 5));
          expect(replies.map((reply) => reply['epoch']), everyElement(epoch));
          expect(writes, round + 1, reason: 'No duplicate business writes');
        }
        expect(rejectedWrites, 10);
        expect(refreshes, 30);
        expect(identical(container.read(apiClientProvider), api), isTrue);
      } finally {
        container.dispose();
        await subscription.cancel();
        await server.close(force: true);
      }
    }, _RealNetwork()),
  );
}

class _RealNetwork extends HttpOverrides {}
