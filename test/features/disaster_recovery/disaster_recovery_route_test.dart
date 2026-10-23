import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/router/app_router.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/disaster_recovery/disaster_recovery_page.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

class RouteSession extends SessionNotifier {
  RouteSession(this.status);
  final AuthStatus status;
  @override
  SessionState build() => SessionState(status: status);
}

void main() {
  for (final status in [
    AuthStatus.unauthenticated,
    AuthStatus.mustChangePassword,
  ]) {
    testWidgets(
      'independent rescue route bypasses business auth state $status',
      (tester) async {
        final container = ProviderContainer(
          overrides: [
            sessionProvider.overrideWith(() => RouteSession(status)),
            apiBaseUrlProvider.overrideWithValue(
              'https://unavailable.example/api',
            ),
            apiClientProvider.overrideWith(
              (ref) => throw StateError('Business API unavailable'),
            ),
            rescueLauncherProvider.overrideWithValue((uri) async => true),
          ],
        );
        addTearDown(container.dispose);
        final router = container.read(appRouterProvider);
        router.go(RouteName.disasterRecovery);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(
              routerConfig: router,
              locale: const Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(DisasterRecoveryPage), findsOneWidget);
        expect(
          find.byKey(const Key('open-independent-rescue')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
