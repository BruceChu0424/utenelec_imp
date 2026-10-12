import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image/image.dart' as img;

import 'package:uten_imp/core/network/connection_recovery.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/network/server_selection.dart';
import 'package:uten_imp/core/performance/performance_tier.dart';
import 'package:uten_imp/shared/platform_branding/platform_branding.dart';
import 'package:uten_imp/shared/platform_branding/platform_branding_cache.dart';
import 'package:uten_imp/shared/platform_branding/platform_branding_provider.dart';
import 'package:uten_imp/shared/providers/font_scale_provider.dart';
import 'package:uten_imp/shared/providers/locale_provider.dart';
import 'package:uten_imp/shared/providers/performance_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/providers/theme_provider.dart';

const _a = 'https://a.example/api';
const _b = 'https://b.example/api';
final _endpoint = StateProvider<String>((ref) => _a);
bool _current() => true;

PlatformBranding _brand(
  String endpoint, {
  int version = 7,
  bool hasLogo = true,
}) => PlatformBranding(
  version: version,
  companyName: endpoint == _a ? '甲公司' : '乙公司',
  companyAliases: 'ACME ELECTRIC',
  platformName: endpoint == _a ? '甲平台' : '乙平台',
  primaryColor: '#123456',
  secondaryColor: '#987654',
  hasLogo: hasLogo,
).forServer(endpoint);

Map<String, dynamic> _json(PlatformBranding brand) => {
  ...brand.toUpdateJson(),
  'version': brand.version,
  'hasLogo': brand.hasLogo,
  'updatedAt': brand.updatedAt,
};

Map<String, Object?> _allPrefs(SharedPreferences prefs) => {
  for (final key in prefs.getKeys()) key: prefs.get(key),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences preferences;
  late Uint8List png;
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'themeMode': 'dark',
      'fontScale': 'giant',
      'locale': 'ko_KR',
      'performancePreference': 'lite',
      'uten.server_mode': 'cloud',
      'unrelated.personal.preference': 'keep me',
    });
    preferences = await SharedPreferences.getInstance();
    png = Uint8List.fromList(img.encodePng(img.Image(width: 4, height: 4)));
  });

  ProviderContainer container({
    bool offline = false,
    PlatformBranding? remoteBrand,
  }) {
    return ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        apiBaseUrlProvider.overrideWithValue(_a),
        connectionRecoveryProvider.overrideWith(
          (ref) => ConnectionRecoveryController(probe: () async => true),
        ),
        platformBrandingDioProvider.overrideWith((ref) {
          final dio = Dio(BaseOptions(baseUrl: _a));
          dio.interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                expect(options.method, 'GET');
                if (offline) {
                  handler.reject(
                    DioException(
                      requestOptions: options,
                      type: DioExceptionType.connectionError,
                    ),
                  );
                } else {
                  handler.resolve(
                    Response(
                      requestOptions: options,
                      statusCode: 200,
                      data: options.path.endsWith('/logo')
                          ? png
                          : _json(remoteBrand ?? _brand(_a)),
                    ),
                  );
                }
              },
            ),
          );
          return dio;
        }),
      ],
    );
  }

  test(
    'public brand and PNG survive a fresh client container with unavailable server',
    () async {
      final first = container();
      await first.read(platformBrandingProvider.future);
      final logoListen = first.listen(
        platformBrandingLogoProvider(7),
        (_, _) {},
      );
      expect(await first.read(platformBrandingLogoProvider(7).future), png);
      logoListen.close();
      first.dispose();
      await preferences.reload();
      final persisted = _allPrefs(preferences);

      final updatedClient = container(offline: true);
      addTearDown(updatedClient.dispose);
      // First frame reads the confirmed company, while a fresh request is pending.
      final snapshot = updatedClient.read(platformBrandingSnapshotProvider);
      expect(snapshot.companyName, '甲公司');
      expect(snapshot.primaryColor, '#123456');
      expect(snapshot.companyAliases, 'ACME ELECTRIC');
      await expectLater(
        updatedClient.read(platformBrandingProvider.future),
        throwsA(isA<DioException>()),
      );
      expect(updatedClient.read(platformBrandingProvider).hasError, isTrue);
      final secondListen = updatedClient.listen(
        platformBrandingLogoProvider(7),
        (_, _) {},
      );
      expect(
        await updatedClient.read(platformBrandingLogoProvider(7).future),
        png,
      );
      secondListen.close();
      expect(_allPrefs(preferences), persisted);
    },
  );

  test(
    'theme font language performance and server preference survive fresh containers without defaults overwriting them',
    () async {
      final cache = PlatformBrandingCache(preferences);
      await cache.saveBrand(_a, _brand(_a), isCurrent: _current);
      final before = _allPrefs(preferences);
      for (var clientVersion = 1; clientVersion <= 3; clientVersion++) {
        final client = container(offline: true);
        expect(client.read(themeProvider), ThemeMode.dark);
        expect(client.read(fontScaleProvider).manual, FontScale.giant);
        expect(client.read(localeProvider), koreanLocale);
        expect(client.read(performanceProvider), PerformanceTier.lite);
        expect(readServerMode(preferences), ServerMode.cloud);
        expect(
          client.read(platformBrandingSnapshotProvider).companyName,
          '甲公司',
        );
        await expectLater(
          client.read(platformBrandingProvider.future),
          throwsA(isA<DioException>()),
        );
        client.dispose();
      }
      expect(_allPrefs(preferences), before);
      expect(
        preferences.getString(PlatformBrandingCache.preferenceKey),
        isNot(contains('clientVersion')),
      );
    },
  );

  test(
    'server-valid login notice keeps CR LF and TAB exactly across a cache reload',
    () async {
      const notice = '第一行\r\n第二行\t说明\r第三行';
      final brand = const PlatformBranding(
        version: 8,
        companyName: '甲公司',
        platformName: '甲平台',
        loginNotice: notice,
        supportEmail: 'ops\u00A0@example.test',
      ).forServer(_a);
      final firstClient = container(remoteBrand: brand);
      expect(
        (await firstClient.read(platformBrandingProvider.future)).loginNotice,
        notice,
      );
      firstClient.dispose();
      final cache = PlatformBrandingCache(preferences);
      await preferences.reload();
      expect(
        PlatformBrandingCache(preferences).readBrand(_a)?.loginNotice,
        notice,
      );
      expect(
        PlatformBrandingCache(preferences).readBrand(_a)?.supportEmail,
        'ops\u00A0@example.test',
      );
      final invalid = const PlatformBranding(
        version: 9,
        companyName: '甲公司',
        platformName: '甲平台',
        loginNotice: '错误\u0085控制',
      ).forServer(_a);
      await cache.saveBrand(_a, invalid, isCurrent: _current);
      expect(cache.readBrand(_a)?.version, 8);
    },
  );

  test(
    'reused endpoint and version cannot mix a newly confirmed company with the previous company logo',
    () async {
      final cache = PlatformBrandingCache(preferences);
      await cache.saveBrand(_a, _brand(_a), isCurrent: _current);
      await cache.saveLogo(_a, 7, png, isCurrent: _current);
      final replacement = const PlatformBranding(
        version: 7,
        companyName: '全新公司',
        platformName: '全新平台',
        hasLogo: true,
      ).forServer(_a);
      await cache.saveBrand(_a, replacement, isCurrent: _current);
      expect(cache.readBrand(_a)?.companyName, '全新公司');
      expect(cache.readLogo(_a, 7), isNull);
      await cache.saveBrand(_a, _brand(_a), isCurrent: _current);
      await cache.saveLogo(_a, 7, png, isCurrent: _current);
      final changedNotice = PlatformBranding.fromJson({
        ..._json(_brand(_a)),
        'loginNotice': '同版本恢复的不同提示',
      }).forServer(_a);
      await cache.saveBrand(_a, changedNotice, isCurrent: _current);
      expect(cache.readLogo(_a, 7), isNull);
    },
  );

  test(
    'cache switches by exact endpoint and web relative API also binds origin',
    () async {
      final cache = PlatformBrandingCache(preferences);
      await cache.saveBrand(_a, _brand(_a), isCurrent: _current);
      await cache.saveBrand(_b, _brand(_b), isCurrent: _current);
      expect(cache.readBrand(_a)?.companyName, '甲公司');
      expect(cache.readBrand(_b)?.companyName, '乙公司');
      expect(cache.readBrand('https://a.example/other-api'), isNull);
      expect(cache.readBrand('https://unconfigured.example/api'), isNull);
      expect(
        platformBrandingCacheScope(
          '/api',
          web: true,
          browserUri: Uri.parse('https://a.example/path'),
        ),
        isNot(
          platformBrandingCacheScope(
            '/api',
            web: true,
            browserUri: Uri.parse('https://b.example/path'),
          ),
        ),
      );
    },
  );

  test(
    'a fresh authoritative restore to a lower version replaces cached metadata and drops the previous logo',
    () async {
      final cache = PlatformBrandingCache(preferences);
      await cache.saveBrand(_a, _brand(_a, version: 100), isCurrent: _current);
      await cache.saveLogo(_a, 100, png, isCurrent: _current);
      await cache.saveBrand(_a, _brand(_a, version: 3), isCurrent: _current);
      expect(cache.readBrand(_a)?.version, 3);
      expect(cache.readLogo(_a, 100), isNull);
      expect(cache.readLogo(_a, 3), isNull);
      await cache.saveLogo(_a, 3, png, isCurrent: _current);
      expect(cache.readLogo(_a, 3), png);
      await cache.saveBrand(
        _a,
        _brand(_a, version: 4, hasLogo: false),
        isCurrent: _current,
      );
      expect(cache.readLogo(_a, 3), isNull);
      expect(cache.readLogo(_a, 4), isNull);
    },
  );

  test(
    'new logo arriving before metadata waits for exact version binding',
    () async {
      final cache = PlatformBrandingCache(preferences);
      await cache.saveLogo(_a, 7, png, isCurrent: _current);
      expect(
        preferences.containsKey(PlatformBrandingCache.preferenceKey),
        isFalse,
      );
      await cache.saveBrand(_a, _brand(_a), isCurrent: _current);
      expect(cache.readLogo(_a, 7), png);
      await cache.saveLogo(_a, 8, png, isCurrent: _current);
      await cache.saveBrand(_a, _brand(_a, version: 9), isCurrent: _current);
      expect(cache.readLogo(_a, 8), isNull);
      expect(cache.readLogo(_a, 9), isNull);
    },
  );

  test(
    'rolling-upgrade metadata and logo 404 retain last confirmed company and logo across cold containers',
    () async {
      final cache = PlatformBrandingCache(preferences);
      await cache.saveBrand(_a, _brand(_a), isCurrent: _current);
      await cache.saveLogo(_a, 7, png, isCurrent: _current);
      final before = _allPrefs(preferences);
      for (var upgradeAttempt = 0; upgradeAttempt < 2; upgradeAttempt++) {
        final logoChecked = Completer<void>();
        final client = ProviderContainer(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(preferences),
            apiBaseUrlProvider.overrideWithValue(_a),
            connectionRecoveryProvider.overrideWith(
              (ref) => ConnectionRecoveryController(probe: () async => true),
            ),
            platformBrandingDioProvider.overrideWith((ref) {
              final dio = Dio(BaseOptions(baseUrl: _a));
              dio.interceptors.add(
                InterceptorsWrapper(
                  onRequest: (options, handler) {
                    if (!options.path.endsWith('/logo')) {
                      handler.reject(
                        DioException(
                          requestOptions: options,
                          response: Response(
                            requestOptions: options,
                            statusCode: 404,
                          ),
                          type: DioExceptionType.badResponse,
                        ),
                      );
                      return;
                    }
                    handler.resolve(
                      Response(requestOptions: options, statusCode: 404),
                    );
                    logoChecked.complete();
                  },
                ),
              );
              return dio;
            }),
          ],
        );
        expect(
          client.read(platformBrandingSnapshotProvider).companyName,
          '甲公司',
        );
        await expectLater(
          client.read(platformBrandingProvider.future),
          throwsA(isA<DioException>()),
        );
        final listen = client.listen(
          platformBrandingLogoProvider(7),
          (_, _) {},
        );
        expect(await client.read(platformBrandingLogoProvider(7).future), png);
        await logoChecked.future;
        await Future<void>.delayed(Duration.zero);
        expect(cache.readLogo(_a, 7), png);
        expect(
          client.read(platformBrandingSnapshotProvider).companyName,
          '甲公司',
        );
        listen.close();
        client.dispose();
        await preferences.reload();
      }
      expect(_allPrefs(preferences), before);
    },
  );

  test(
    'disposed previous-server requests cannot write either metadata or logo cache',
    () async {
      final old = Completer<Map<String, dynamic>>();
      final oldStarted = Completer<void>();
      final client = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          apiBaseUrlProvider.overrideWith((ref) => ref.watch(_endpoint)),
          connectionRecoveryProvider.overrideWith(
            (ref) => ConnectionRecoveryController(probe: () async => true),
          ),
          platformBrandingDioProvider.overrideWith((ref) {
            final endpoint = ref.watch(apiBaseUrlProvider);
            final dio = Dio(BaseOptions(baseUrl: endpoint));
            dio.interceptors.add(
              InterceptorsWrapper(
                onRequest: (options, handler) {
                  if (endpoint == _a) {
                    oldStarted.complete();
                    old.future.then(
                      (data) => handler.resolve(
                        Response(
                          requestOptions: options,
                          data: data,
                          statusCode: 200,
                        ),
                      ),
                    );
                  } else {
                    handler.resolve(
                      Response(
                        requestOptions: options,
                        data: _json(_brand(_b)),
                        statusCode: 200,
                      ),
                    );
                  }
                },
              ),
            );
            return dio;
          }),
        ],
      );
      addTearDown(client.dispose);
      client.read(platformBrandingProvider);
      await oldStarted.future;
      client.read(_endpoint.notifier).state = _b;
      await client.read(platformBrandingProvider.future);
      old.complete(_json(_brand(_a)));
      await Future<void>.delayed(Duration.zero);
      final cache = client.read(platformBrandingCacheProvider);
      expect(cache.readBrand(_a), isNull);
      expect(cache.readBrand(_b)?.companyName, '乙公司');
      await cache.saveLogo(_b, 7, png, isCurrent: () => false);
      expect(cache.readLogo(_b, 7), isNull);
    },
  );

  test(
    'a stale requested-version 404 cannot erase the newer confirmed version logo',
    () async {
      final cache = PlatformBrandingCache(preferences);
      await cache.saveBrand(_a, _brand(_a, version: 8), isCurrent: _current);
      await cache.saveLogo(_a, 8, png, isCurrent: _current);
      final before = _allPrefs(preferences);
      final client = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          apiBaseUrlProvider.overrideWithValue(_a),
          platformBrandingDioProvider.overrideWith((ref) {
            final dio = Dio(BaseOptions(baseUrl: _a));
            dio.interceptors.add(
              InterceptorsWrapper(
                onRequest: (options, handler) {
                  expect(options.queryParameters['v'], 7);
                  handler.resolve(
                    Response(requestOptions: options, statusCode: 404),
                  );
                },
              ),
            );
            return dio;
          }),
        ],
      );
      addTearDown(client.dispose);
      final listen = client.listen(platformBrandingLogoProvider(7), (_, _) {});
      expect(await client.read(platformBrandingLogoProvider(7).future), isNull);
      expect(cache.readLogo(_a, 8), png);
      expect(_allPrefs(preferences), before);
      listen.close();
    },
  );

  test(
    'a fresh server hasLogo=false removes old artwork and survives a later disconnected restart',
    () async {
      final cache = PlatformBrandingCache(preferences);
      await cache.saveBrand(_a, _brand(_a), isCurrent: _current);
      await cache.saveLogo(_a, 7, png, isCurrent: _current);
      final online = container(
        remoteBrand: _brand(_a, version: 8, hasLogo: false),
      );
      expect(
        (await online.read(platformBrandingProvider.future)).hasLogo,
        isFalse,
      );
      expect(cache.readLogo(_a, 7), isNull);
      online.dispose();
      await preferences.reload();
      final offline = container(offline: true);
      addTearDown(offline.dispose);
      expect(offline.read(platformBrandingSnapshotProvider).hasLogo, isFalse);
      expect(offline.read(platformBrandingSnapshotProvider).companyName, '甲公司');
      await expectLater(
        offline.read(platformBrandingProvider.future),
        throwsA(isA<DioException>()),
      );
      expect(cache.readLogo(_a, 7), isNull);
    },
  );

  test(
    'broken cache DTO and bitmap are safely ignored without touching other prefs',
    () async {
      final cache = PlatformBrandingCache(preferences);
      final original = _allPrefs(preferences);
      for (final broken in [
        'not JSON',
        '{}',
        jsonEncode({
          'schema': 1,
          'entries': [
            {
              'endpoint': _a,
              'branding': {..._json(_brand(_a)), 'primaryColor': 'BAD'},
            },
          ],
        }),
      ]) {
        await preferences.setString(
          PlatformBrandingCache.preferenceKey,
          broken,
        );
        expect(cache.readBrand(_a), isNull);
        expect(cache.readLogo(_a, 7), isNull);
        expect(
          _allPrefs(preferences)..remove(PlatformBrandingCache.preferenceKey),
          original,
        );
      }
      await cache.saveBrand(_a, _brand(_a), isCurrent: _current);
      await cache.saveLogo(_a, 7, png, isCurrent: _current);
      final decoded =
          jsonDecode(
                preferences.getString(PlatformBrandingCache.preferenceKey)!,
              )
              as Map<String, dynamic>;
      final corruptedEntry =
          (decoded['entries'] as List).first as Map<String, dynamic>;
      corruptedEntry['logoSha256'] = '0' * 64;
      await preferences.setString(
        PlatformBrandingCache.preferenceKey,
        jsonEncode(decoded),
      );
      expect(cache.readBrand(_a)?.companyName, '甲公司');
      expect(cache.readLogo(_a, 7), isNull);
      expect(
        _allPrefs(preferences)..remove(PlatformBrandingCache.preferenceKey),
        original,
      );
      final giantHeader = Uint8List.fromList(png);
      ByteData.sublistView(giantHeader).setUint32(16, 100000);
      expect(isSafePlatformLogo(giantHeader), isFalse);
      expect(isSafePlatformLogo(png.sublist(0, 33)), isFalse);
    },
  );

  test(
    'unknown payloads and defaults never become saved settings during disconnected startup',
    () async {
      final before = _allPrefs(preferences);
      final client = container(offline: true);
      addTearDown(client.dispose);
      expect(
        client.read(platformBrandingSnapshotProvider),
        PlatformBranding.defaults,
      );
      await expectLater(
        client.read(platformBrandingProvider.future),
        throwsA(isA<DioException>()),
      );
      expect(_allPrefs(preferences), before);
      await client
          .read(platformBrandingCacheProvider)
          .saveBrand(_a, PlatformBranding.defaults, isCurrent: _current);
      expect(_allPrefs(preferences), before);
    },
  );

  test(
    'bounded cleanup removes only old branding slots and leaves all personal preferences unchanged',
    () async {
      final before = _allPrefs(preferences);
      final cache = PlatformBrandingCache(preferences);
      for (final endpoint in [_a, _b, 'https://c.example/api']) {
        await cache.saveBrand(endpoint, _brand(endpoint), isCurrent: _current);
        await cache.saveLogo(endpoint, 7, png, isCurrent: _current);
      }
      expect(cache.readBrand(_a), isNull);
      expect(cache.readBrand(_b), isNotNull);
      expect(cache.readBrand('https://c.example/api'), isNotNull);
      expect(
        _allPrefs(preferences)..remove(PlatformBrandingCache.preferenceKey),
        before,
      );
      expect(
        preferences.getString(PlatformBrandingCache.preferenceKey)!.length,
        lessThan(1500100),
      );
    },
  );
}
