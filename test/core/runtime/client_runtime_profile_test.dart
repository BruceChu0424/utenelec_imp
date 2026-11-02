import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_base_url.dart';
import 'package:uten_imp/core/runtime/client_runtime_profile.dart';
import 'package:uten_imp/core/runtime/local_test_network_io.dart';
import 'package:uten_imp/core/runtime/native_runtime_identity.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const local = ClientRuntimeProfile(localTest: true);
  const formal = ClientRuntimeProfile.current;
  const channel = MethodChannel('runtime-profile-test');

  test('LocalTest requires one explicit loopback API and no control plane', () {
    const api = 'http://127.0.0.1:18081/api';
    local.validateConfiguration(local: api, cloud: api, controlPlane: '');
    for (final invalid in [
      '',
      '/api',
      'http://company.invalid/api',
      'http://127.0.0.1:18081/not-api',
      'http://user@127.0.0.1:18081/api',
      'http://127.0.0.1:18081/api?token=secret',
    ]) {
      expect(() => local.localApi(invalid), throwsStateError);
    }
    expect(
      () => local.validateConfiguration(
        local: api,
        cloud: 'http://localhost:18081/api',
        controlPlane: '',
      ),
      throwsStateError,
    );
    expect(
      () => local.validateConfiguration(
        local: api,
        cloud: api,
        controlPlane: 'https://dr.invalid',
      ),
      throwsStateError,
    );
    expect(
      resolveApiBaseUrl(api, releaseMode: true, web: false, localTest: true),
      api,
    );
    expect(
      () => resolveApiBaseUrl(api, releaseMode: true, web: false),
      throwsStateError,
    );
  });

  test(
    'external launches retain local files and reject remote destinations',
    () {
      final api = local.localApi('http://127.0.0.1:18081/api');
      for (final value in [
        'https://company.invalid',
        'file://company/share',
        'mailto:test@company.invalid',
        'http://127.0.0.1:18082/api',
      ]) {
        expect(
          local.allowsExternalUri(Uri.parse(value), localApi: api),
          isFalse,
        );
      }
      expect(
        local.allowsExternalUri(Uri.file('C:/local/export.pdf'), localApi: api),
        isTrue,
      );
      expect(
        formal.allowsExternalUri(
          Uri.parse('https://company.invalid'),
          localApi: api,
        ),
        isTrue,
      );
    },
  );

  test(
    'transport denies cross-origin redirects before external connection',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final subscription = server.listen((request) {
        if (request.uri.path == '/redirect') {
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set(
            HttpHeaders.locationHeader,
            'http://company.invalid/private',
          );
        } else {
          request.response.write('local-ok');
        }
        request.response.close();
      });
      addTearDown(subscription.cancel);
      final uri = Uri.parse('http://127.0.0.1:${server.port}/api');
      final client = LocalTestHttpOverrides(
        uri,
        profile: local,
      ).createHttpClient(null);
      addTearDown(() => client.close(force: true));
      expect(
        (await (await client.getUrl(uri)).close()).statusCode,
        HttpStatus.ok,
      );
      await expectLater(
        () async => (await client.getUrl(uri.resolve('/redirect'))).close(),
        throwsStateError,
      );
      await expectLater(
        () =>
            client.getUrl(Uri.parse('http://127.0.0.1:${server.port + 1}/api')),
        throwsStateError,
      );
    },
  );

  test(
    'native identity rejects mixed runners and permits only formal legacy',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => local.toMetadata(),
      );
      await verifyNativeRuntimeIdentity(
        profile: local,
        channel: channel,
        windows: true,
      );
      await expectLater(
        verifyNativeRuntimeIdentity(channel: channel, windows: true),
        throwsStateError,
      );
      messenger.setMockMethodCallHandler(channel, null);
      await verifyNativeRuntimeIdentity(channel: channel, windows: true);
      await expectLater(
        verifyNativeRuntimeIdentity(
          profile: local,
          channel: channel,
          windows: true,
        ),
        throwsStateError,
      );
    },
  );
}
