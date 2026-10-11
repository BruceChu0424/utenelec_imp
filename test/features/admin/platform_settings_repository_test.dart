import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/admin/repositories/platform_settings_repository.dart';
import 'package:uten_imp/shared/platform_branding/platform_branding.dart';

class _Api extends ApiClient {
  _Api() : super(Dio());
  Map<String, dynamic>? submitted;
  Map<String, dynamic>? response;
  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    expect(path, '/admin/platform-settings');
    submitted = body! as Map<String, dynamic>;
    return response ??
        {
          ...PlatformBranding.defaults.toUpdateJson(),
          'version': 8,
          'hasLogo': true,
        };
  }
}

void main() {
  test('logo and company fields share one versioned atomic command', () async {
    final api = _Api();
    final repo = DioPlatformSettingsRepository(api);
    final bytes = Uint8List.fromList([1, 2, 3, 4]);
    await repo.save(
      const PlatformBranding(version: 7, companyName: '甲公司'),
      logo: bytes,
    );
    expect(api.submitted!['companyName'], '甲公司');
    expect(api.submitted!['expectedVersion'], 7);
    expect(base64Decode(api.submitted!['logoBase64'] as String), bytes);
    expect(api.submitted!['removeLogo'], false);
    expect(api.submitted!.containsKey('serverEndpoint'), false);
    expect(api.submitted!.containsKey('version'), false);
  });
  test(
    'keep, remove, and oversized logo commands have separate semantics',
    () async {
      final api = _Api();
      final repo = DioPlatformSettingsRepository(api);
      await repo.save(const PlatformBranding(version: 7));
      expect(api.submitted!['logoBase64'], null);
      expect(api.submitted!['removeLogo'], false);
      await repo.save(const PlatformBranding(version: 7), removeLogo: true);
      expect(api.submitted!['removeLogo'], true);
      await expectLater(
        repo.save(const PlatformBranding(version: 7), logo: Uint8List(524289)),
        throwsFormatException,
      );
      await expectLater(
        repo.save(
          const PlatformBranding(version: 7),
          logo: Uint8List.fromList([1]),
          removeLogo: true,
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'incomplete or unconfirmed save responses do not claim success',
    () async {
      final api = _Api()..response = {};
      final repo = DioPlatformSettingsRepository(api);
      await expectLater(
        repo.save(const PlatformBranding(version: 7)),
        throwsFormatException,
      );
      api.response = {
        ...PlatformBranding.defaults.toUpdateJson(),
        'version': 7,
        'hasLogo': false,
      };
      await expectLater(
        repo.save(const PlatformBranding(version: 7)),
        throwsFormatException,
      );
    },
  );
}
