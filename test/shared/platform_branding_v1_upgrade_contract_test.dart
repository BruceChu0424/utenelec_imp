import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/shared/platform_branding/platform_branding_cache.dart';

/// Frozen v1 on-disk contract. Do not build this fixture from today's model or
/// defaults: a later release must still read choices written by the old client.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'future clients continue reading saved v1 names, colors and accepted bounds',
    () async {
      const endpoint = 'https://company.example/api';
      final historicalFields = <String, String>{
        'companyName': '企' * 120,
        'companyAliases': List.generate(
          4,
          (index) => '$index别名${'名' * 117}',
        ).join('\n'),
        'platformName': '台' * 80,
        'tagline': '标' * 160,
        'primaryColor': '#123456',
        'secondaryColor': '#FEDCBA',
        'loginNotice': '${'通' * 494}\r\n\t通知\n',
        'supportPhone': '1' * 50,
        'supportEmail': '${'a' * 107}@example.test',
        'website': 'https://example.test/${'p' * 179}',
      };
      SharedPreferences.setMockInitialValues({
        // This literal key is part of the prior client's stable storage identity.
        'uten.platform_branding.cache': jsonEncode({
          'schema': 1,
          'entries': [
            {
              'endpoint': endpoint,
              'branding': {
                ...historicalFields,
                'version': 7,
                'hasLogo': false,
                'updatedAt': '2026-10-10T12:13:14Z',
              },
            },
          ],
        }),
        'themeMode': 'dark',
        'unrelated.preference': 'preserve',
      });
      final preferences = await SharedPreferences.getInstance();
      final original = preferences.getString('uten.platform_branding.cache');
      final previous = PlatformBrandingCache(preferences).readBrand(endpoint);
      expect(previous, isNotNull);
      expect(previous!.version, 7);
      expect(previous.hasLogo, false);
      for (final field in historicalFields.entries) {
        expect(
          previous.toUpdateJson()[field.key],
          field.value,
          reason:
              'old ${field.key} must not fall back to a new package default',
        );
      }
      expect(preferences.getString('uten.platform_branding.cache'), original);
      expect(preferences.getString('themeMode'), 'dark');
      expect(preferences.getString('unrelated.preference'), 'preserve');
    },
  );
}
