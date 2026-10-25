import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/dashboard/pages/dashboard_page.dart';
import 'package:uten_imp/features/dashboard/providers/dashboard_overview_provider.dart';
import 'package:uten_imp/features/notice/providers/notice_providers.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/badge_summary_fixture.dart';
import '../../shared/drafts/memory_form_draft_storage.dart';

class _SuperAdminSession extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'reset-retirement-admin',
      code: 'ADMIN',
      name: '管理员',
      superAdmin: true,
    ),
  );
}

class _Snapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => SessionSnapshot();
}

void main() {
  for (final width in [375.0, 1100.0]) {
    testWidgets('本机调试超管工作台也不再提供清空业务入口 ($width)', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(preferences),
            formDraftStorageProvider.overrideWithValue(
              MemoryFormDraftStorage(),
            ),
            sessionProvider.overrideWith(_SuperAdminSession.new),
            sessionSnapshotProvider.overrideWith(_Snapshot.new),
            authenticatedScopeProvider.overrideWithValue(
              const AuthenticatedScope(userId: 'reset-retirement-admin'),
            ),
            // The former debug-only entry was enabled for this exact target.
            apiBaseUrlProvider.overrideWithValue('http://127.0.0.1:8080/api'),
            currentPermissionsProvider.overrideWithValue(const {}),
            isSuperAdminProvider.overrideWithValue(true),
            dashboardOverviewProvider.overrideWith((ref) async => null),
            myCelebrationTodayProvider.overrideWith((ref) async => const []),
            fixedBadgeSummaryOverride(),
          ],
          child: const MaterialApp(
            locale: Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: DashboardPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('你好，管理员'), findsOneWidget);
      expect(find.text('系统测试'), findsNothing);
      expect(find.text('清空数据'), findsNothing);
      expect(find.text('清空业务数据'), findsNothing);
      expect(
        find.byKey(const Key('system-test-clear-data-card')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
