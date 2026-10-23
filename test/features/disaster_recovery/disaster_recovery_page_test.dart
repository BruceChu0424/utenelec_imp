import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/disaster_recovery/disaster_recovery_page.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

class OfflineSession extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

void main() {
  test('production rescue address must be independently trusted HTTPS', () {
    expect(
      trustedRescueUri('https://dr.example.com:8443', releaseMode: true)?.host,
      'dr.example.com',
    );
    for (final address in [
      '',
      '/api',
      'http://dr.example.com',
      'https://user:pass@dr.example.com',
      'https://dr.example.com?next=evil',
      'https://dr.example.com#token',
      'https://dr.example.com/untrusted',
    ]) {
      expect(
        trustedRescueUri(address, releaseMode: true),
        isNull,
        reason: address,
      );
    }
    expect(
      trustedRescueUri('http://127.0.0.1:9087', releaseMode: false),
      isNotNull,
    );
    expect(
      trustedRescueUri('http://127.0.0.1:9087', releaseMode: true),
      isNull,
    );
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets('rescue opens while ERP is unavailable at scale $scale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(720, 1600);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Uri? launched;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sessionProvider.overrideWith(
              () => throw StateError(
                'Recovery must not initialize the business session',
              ),
            ),
            apiBaseUrlProvider.overrideWithValue(
              'https://unavailable-company.example/api',
            ),
            apiClientProvider.overrideWith(
              (ref) => throw StateError('Business API must not be requested'),
            ),
            disasterRecoveryUriProvider.overrideWithValue(
              Uri.parse('https://dr.example.com:8443'),
            ),
            rescueLauncherProvider.overrideWithValue((uri) async {
              launched = uri;
              return true;
            }),
          ],
          child: MaterialApp(
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: const DisasterRecoveryPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('open-independent-rescue')),
      );
      await tester.tap(find.byKey(const Key('open-independent-rescue')));
      await tester.pumpAndSettle();
      expect(launched.toString(), 'https://dr.example.com:8443');
      expect(find.text('绑定独立救援身份'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
