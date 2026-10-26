import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/dashboard/pages/dashboard_page.dart';
import 'package:uten_imp/features/dashboard/providers/dashboard_overview_provider.dart';
import 'package:uten_imp/features/notice/providers/notice_providers.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/badge_summary_fixture.dart';
import '../../shared/drafts/memory_form_draft_storage.dart';

class _Session extends SessionNotifier {
  _Session(this.admin);
  final bool admin;
  @override
  SessionState build() => SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'download-employee',
      code: 'TEST',
      name: '工作台测试员工',
      superAdmin: admin,
    ),
  );
}

class _Snapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => SessionSnapshot();
}

void main() {
  for (final fixture in [
    (375.0, 2.0, false),
    (375.0, 2.0, true),
    (1440.0, 1.0, false),
    (1440.0, 1.0, true),
  ]) {
    testWidgets(
      'software download entry navigates and returns width=${fixture.$1} admin=${fixture.$3}',
      (tester) async {
        tester.view.physicalSize = Size(fixture.$1, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final router = GoRouter(
          initialLocation: RouteName.dashboard,
          routes: [
            GoRoute(
              path: RouteName.dashboard,
              builder: (_, _) => const DashboardPage(),
            ),
            GoRoute(
              path: RouteName.softwareDownloads,
              builder: (_, _) =>
                  Scaffold(appBar: AppBar(title: const Text('软件下载目标'))),
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              sharedPreferencesProvider.overrideWithValue(preferences),
              formDraftStorageProvider.overrideWithValue(
                MemoryFormDraftStorage(),
              ),
              sessionProvider.overrideWith(() => _Session(fixture.$3)),
              sessionSnapshotProvider.overrideWith(_Snapshot.new),
              authenticatedScopeProvider.overrideWithValue(
                const AuthenticatedScope(userId: 'download-employee'),
              ),
              dashboardOverviewProvider.overrideWith((ref) async => null),
              myCelebrationTodayProvider.overrideWith((ref) async => const []),
              fixedBadgeSummaryOverride(),
            ],
            child: MaterialApp.router(
              routerConfig: router,
              theme: buildLightTheme(),
              locale: const Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(fixture.$2)),
                child: child!,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('软件下载'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(
          find.byKey(const ValueKey('dashboard-software-downloads')),
        );
        await tester.pumpAndSettle();
        expect(find.text('软件下载目标'), findsOneWidget);
        expect(router.canPop(), isTrue);
        router.pop();
        await tester.pumpAndSettle();
        expect(find.text('你好，工作台测试员工'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
