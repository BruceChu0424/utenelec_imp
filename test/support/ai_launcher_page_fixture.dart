import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_page_scrollbar_host.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/uten_scroll_behavior.dart';
import 'package:uten_imp/shared/ai/chat/ai_chat_models.dart';
import 'package:uten_imp/shared/ai/chat/ai_chat_overlay.dart';
import 'package:uten_imp/shared/ai/chat/ai_chat_repository.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

/// Actual default launcher and page geometry, without a live session, drafts,
/// network requests or business submissions.
class AiLauncherPageFixture {
  AiLauncherPageFixture._(this.container);

  final ProviderContainer container;

  static Future<AiLauncherPageFixture> pump(
    WidgetTester tester, {
    required Widget page,
    required String route,
    required Size size,
    List<Override> overrides = const [],
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        apiBaseUrlProvider.overrideWithValue('https://example.invalid/api'),
        authenticatedScopeProvider.overrideWithValue(null),
        sessionProvider.overrideWith(_FixtureSession.new),
        aiChatIdentityProvider.overrideWithValue((
          scope: const AuthenticatedScope(userId: 'layout-fixture'),
          server: 'https://example.invalid/api',
          permissions: 'ai:use',
          superAdmin: false,
        )),
        aiChatRepositoryProvider.overrideWithValue(_LauncherRepository()),
        ...overrides,
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          scrollBehavior: const UtenScrollBehavior(),
          builder: (_, child) => UtenPageScrollbarHost(child: child!),
          home: AiChatOverlay(currentRoute: route, child: page),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return AiLauncherPageFixture._(container);
  }

  /// Call inside testWidgets, before its pending-timer verification.
  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await tester.pump();
  }
}

class _FixtureSession extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _LauncherRepository implements AiChatRepository {
  @override
  Future<AiChatCapabilities> capabilities() async => const AiChatCapabilities(
    // The real overlay intentionally removes its launcher when canChat=false.
    // Enable the read-only UI capability while keeping optional background
    // queries disabled; the tests never open chat or send a command.
    canChat: true,
    available: true,
    settings: AiChatSettings(
      pageAware: false,
      showSuggestions: false,
      operationMemory: false,
    ),
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
