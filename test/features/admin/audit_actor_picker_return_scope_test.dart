import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/admin/models/audit_log_entry.dart';
import 'package:uten_imp/features/admin/pages/admin_audit_log_page.dart';
import 'package:uten_imp/features/admin/repositories/audit_log_repository.dart';
import 'package:uten_imp/features/admin/widgets/audit_query_scope.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/repositories/public_settings_repository.dart';

final _identity = StateProvider<AuthenticatedScope?>(
  (_) => const AuthenticatedScope(userId: 'auditor-a', epoch: 1),
);
final _server = StateProvider<String>((_) => 'https://audit-a.test');
final _permissions = StateProvider<Set<String>>((_) => {'audit_log:view'});

void main() {
  for (final boundary in ['identity', 'server', 'permissions', 'equivalent']) {
    testWidgets(
      'audit return after popup pop checks $boundary before applying actor',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        tester.view.physicalSize = const Size(1440, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final container = ProviderContainer(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(preferences),
            auditLogRepositoryProvider.overrideWithValue(_Repository()),
            auditArchivePurgeModeProvider.overrideWithValue(
              AuditArchivePurgeMode.unknown,
            ),
            authenticatedScopeProvider.overrideWith(
              (ref) => ref.watch(_identity),
            ),
            apiBaseUrlProvider.overrideWith((ref) => ref.watch(_server)),
            currentPermissionsProvider.overrideWith(
              (ref) => ref.watch(_permissions),
            ),
            isSuperAdminProvider.overrideWithValue(false),
          ],
        );
        addTearDown(container.dispose);
        var popped = 0;
        final observer = _OnPopupPop(() {
          popped++;
          switch (boundary) {
            case 'identity':
              container.read(_identity.notifier).state =
                  const AuthenticatedScope(userId: 'auditor-b', epoch: 2);
            case 'server':
              container.read(_server.notifier).state = 'https://audit-b.test';
            case 'permissions':
              container.read(_permissions.notifier).state = {};
            case 'equivalent':
              container.read(_permissions.notifier).state = {'audit_log:view'};
          }
        });
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: const Locale('zh'),
              navigatorObservers: [observer],
              home: const AdminAuditLogPage(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('audit-select-actor')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('审计旧账号'));
        await tester.pump();
        await tester.tap(find.widgetWithText(FilledButton, '确定'));
        await tester.pumpAndSettle();
        expect(popped, 1);
        final composer = tester.widget<AuditQueryScopeComposer>(
          find.byType(AuditQueryScopeComposer),
        );
        expect(
          composer.selectedActor?.actorId,
          boundary == 'equivalent' ? 'user-id-not-employee-id' : isNull,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}

class _OnPopupPop extends NavigatorObserver {
  _OnPopupPop(this.onPop);
  final VoidCallback onPop;
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) onPop();
  }
}

class _Repository extends Fake implements AuditLogRepository {
  @override
  Future<AuditActorPage> actors({
    int page = 1,
    int size = 20,
    String? keyword,
  }) async => const AuditActorPage(
    items: [
      AuditActorOption(actorId: 'user-id-not-employee-id', name: '审计旧账号'),
    ],
    page: 1,
    size: 1,
    total: 1,
    totalPages: 1,
  );
}
