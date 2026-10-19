import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:uten_imp/core/network/connection_recovery.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/shared/platform_branding/platform_brand_logo.dart';
import 'package:uten_imp/shared/platform_branding/platform_branding.dart';
import 'package:uten_imp/shared/platform_branding/platform_branding_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

final _endpoint = StateProvider<String>((ref) => 'https://a.example/api');

Map<String, dynamic> _json(String company, {bool hasLogo = false}) => {
  ...PlatformBranding.defaults.toUpdateJson(),
  'version': 1,
  'companyName': company,
  'platformName': '$company ERP',
  'hasLogo': hasLogo,
  'updatedAt': null,
};

double _contrast(Color foreground, Color background) {
  final a = foreground.computeLuminance();
  final b = background.computeLuminance();
  return (a > b ? (a + 0.05) / (b + 0.05) : (b + 0.05) / (a + 0.05));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences preferences;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
  });

  test('wrong payloads cannot masquerade as successfully loaded defaults', () {
    for (final invalid in [
      <String, dynamic>{},
      {..._json('甲'), 'companyName': ''},
      {..._json('甲'), 'primaryColor': '#123'},
      {..._json('甲'), 'secondaryColor': 'javascript:alert(1)'},
      {..._json('甲'), 'version': 1.5},
      {..._json('甲'), 'hasLogo': 'true'},
    ]) {
      expect(() => PlatformBranding.fromJson(invalid), throwsFormatException);
    }
    expect(PlatformBranding.fromJson(_json('甲')).usesDefaultArtwork, isFalse);
    expect(
      PlatformBranding.defaults.toUpdateJson().containsKey('version'),
      isFalse,
    );
  });

  test(
    'custom colors reach all Material controls and retain status colors',
    () {
      const brand = PlatformBranding(
        primaryColor: '#FFF000',
        secondaryColor: '#E02060',
      );
      for (final builder in [buildLightTheme, buildDarkTheme]) {
        final original = builder();
        final theme = builder(branding: brand);
        final scheme = theme.colorScheme;
        expect(
          _contrast(scheme.primary, scheme.onPrimary),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          _contrast(scheme.secondary, scheme.onSecondary),
          greaterThanOrEqualTo(4.5),
        );
        expect(scheme.error, original.colorScheme.error);
        expect(scheme.surface, original.colorScheme.surface);
        expect(
          theme.filledButtonTheme.style!.backgroundColor!.resolve({}),
          scheme.primary,
        );
        expect(
          theme.filledButtonTheme.style!.foregroundColor!.resolve({}),
          scheme.onPrimary,
        );
        expect(
          theme.navigationRailTheme.indicatorColor,
          scheme.primaryContainer,
        );
        expect(
          theme.checkboxTheme.fillColor!.resolve({WidgetState.selected}),
          scheme.primary,
        );
        expect(
          theme.switchTheme.trackColor!.resolve({WidgetState.selected}),
          scheme.primary,
        );
        expect(
          theme.radioTheme.fillColor!.resolve({WidgetState.selected}),
          scheme.primary,
        );
        expect(theme.progressIndicatorTheme.color, scheme.primary);
        expect(theme.floatingActionButtonTheme.backgroundColor, scheme.primary);
        expect(
          theme.inputDecorationTheme.focusedBorder!.borderSide.color,
          scheme.primary,
        );
        final indicator = theme.tabBarTheme.indicator! as BoxDecoration;
        expect(indicator.color, scheme.secondaryContainer);
        expect(theme.tabBarTheme.labelColor, scheme.onSecondaryContainer);
      }
      expect(buildLightTheme().colorScheme.primary, const Color(0xFF0F766E));
    },
  );

  test(
    'server changes remove the previous company before the next read',
    () async {
      final a = Completer<Map<String, dynamic>>();
      final b = Completer<Map<String, dynamic>>();
      final requests = <RequestOptions>[];
      final container = ProviderContainer(
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
                  requests.add(options);
                  final response = endpoint.contains('a.example') ? a : b;
                  response.future.then(
                    (json) => handler.resolve(
                      Response(
                        requestOptions: options,
                        data: json,
                        statusCode: 200,
                      ),
                    ),
                  );
                },
              ),
            );
            return dio;
          }),
        ],
      );
      addTearDown(container.dispose);
      final oldFuture = container.read(platformBrandingProvider.future);
      a.complete(_json('甲公司'));
      await oldFuture;
      expect(
        container.read(platformBrandingSnapshotProvider).companyName,
        '甲公司',
      );
      container.read(_endpoint.notifier).state = 'https://b.example/api';
      expect(
        container.read(platformBrandingSnapshotProvider).companyName,
        PlatformBranding.defaults.companyName,
      );
      b.complete(_json('乙公司'));
      await container.read(platformBrandingProvider.future);
      expect(
        container.read(platformBrandingSnapshotProvider).companyName,
        '乙公司',
      );
      expect(requests.map((r) => r.baseUrl).toSet(), {
        'https://a.example/api',
        'https://b.example/api',
      });
      expect(
        requests.every(
          (r) => !r.headers.keys.any(
            (key) => key.toLowerCase() == 'authorization',
          ),
        ),
        isTrue,
      );
    },
  );

  test(
    'public Dio sends only to the trusted API and refuses redirects',
    () async {
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          apiBaseUrlProvider.overrideWithValue('https://trusted.example/api'),
        ],
      );
      addTearDown(container.dispose);
      final dio = container.read(platformBrandingDioProvider);
      RequestOptions? request;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            request = options;
            handler.resolve(
              Response(
                requestOptions: options,
                data: _json('甲'),
                statusCode: 200,
              ),
            );
          },
        ),
      );
      await dio.get<dynamic>('/platform/branding');
      expect(
        request!.uri.toString(),
        'https://trusted.example/api/platform/branding',
      );
      expect(request!.followRedirects, isFalse);
      expect(
        request!.headers.keys.any(
          (key) => key.toLowerCase() == 'authorization',
        ),
        isFalse,
      );
    },
  );

  test(
    'a late previous-server response cannot replace the current company',
    () async {
      final a = Completer<Map<String, dynamic>>();
      final b = Completer<Map<String, dynamic>>();
      final startedA = Completer<void>();
      final container = ProviderContainer(
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
                  final response = endpoint.contains('a.example') ? a : b;
                  if (endpoint.contains('a.example')) startedA.complete();
                  response.future.then(
                    (json) => handler.resolve(
                      Response(
                        requestOptions: options,
                        data: json,
                        statusCode: 200,
                      ),
                    ),
                  );
                },
              ),
            );
            return dio;
          }),
        ],
      );
      addTearDown(container.dispose);
      container.read(platformBrandingProvider);
      await startedA.future;
      container.read(_endpoint.notifier).state = 'https://b.example/api';
      final current = container.read(platformBrandingProvider.future);
      b.complete(_json('乙公司'));
      await current;
      a.complete(_json('迟到甲公司'));
      await Future<void>.delayed(Duration.zero);
      expect(
        container.read(platformBrandingSnapshotProvider).companyName,
        '乙公司',
      );
    },
  );

  test(
    'temporary same-server failure retains that company with an explicit error',
    () async {
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          apiBaseUrlProvider.overrideWithValue('https://trusted.example/api'),
          connectionRecoveryProvider.overrideWith(
            (ref) => ConnectionRecoveryController(probe: () async => true),
          ),
        ],
      );
      addTearDown(container.dispose);
      final dio = container.read(platformBrandingDioProvider);
      var count = 0;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (count++ == 0) {
              handler.resolve(
                Response(
                  requestOptions: options,
                  data: _json('本公司'),
                  statusCode: 200,
                ),
              );
            } else {
              handler.reject(
                DioException(
                  requestOptions: options,
                  type: DioExceptionType.connectionError,
                ),
              );
            }
          },
        ),
      );
      await container.read(platformBrandingProvider.future);
      container.invalidate(platformBrandingProvider);
      await expectLater(
        container.read(platformBrandingProvider.future),
        throwsA(isA<DioException>()),
      );
      expect(container.read(platformBrandingProvider).hasError, isTrue);
      expect(
        container.read(platformBrandingSnapshotProvider).companyName,
        '本公司',
      );
    },
  );

  testWidgets('empty unsaved preview fields have a usable placeholder', (
    tester,
  ) async {
    const brand = PlatformBranding(companyName: '', platformName: '');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiBaseUrlProvider.overrideWithValue('https://trusted.example/api'),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                PlatformBrandLogo(branding: brand),
                PlatformBrandLogo(
                  branding: brand,
                  width: 40,
                  height: 40,
                  compact: true,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(find.text('企'), findsOneWidget);
    expect(find.text('企业平台'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'custom company with no logo shows its identity without Uten artwork',
    (tester) async {
      const brand = PlatformBranding(companyName: '新公司', platformName: '新公司平台');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiBaseUrlProvider.overrideWithValue('https://trusted.example/api'),
            platformBrandingSnapshotProvider.overrideWithValue(brand),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  PlatformBrandLogo(),
                  PlatformBrandLogo(width: 40, height: 40, compact: true),
                ],
              ),
            ),
          ),
        ),
      );
      expect(find.text('新公司平台'), findsOneWidget);
      expect(find.text('新'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    },
  );
}
