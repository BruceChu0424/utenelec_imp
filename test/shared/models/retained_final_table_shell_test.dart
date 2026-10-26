import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/hr_task/widgets/hr_celebration_history_panel.dart';
import 'package:uten_imp/features/profile/pages/my_profile_changes_page.dart';
import 'package:uten_imp/features/security/pages/security_blacklist_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

import '../../helpers/badge_summary_fixture.dart';

class _Snapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => SessionSnapshot();
}

class _Api extends ApiClient {
  _Api(this.target) : super(Dio());
  final String target;
  final requests = <Completer<Map<String, dynamic>>>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path != target) return const {};
    final gate = Completer<Map<String, dynamic>>();
    requests.add(gate);
    return gate.future;
  }
}

void main() {
  for (final entry in <(String, Widget, String, String)>[
    (
      '本人资料变更',
      const MyProfileChangesPage(),
      ApiEndpoints.profileMyChanges,
      'my-profile-changes-table',
    ),
    (
      '祝福历史',
      const Scaffold(body: HrCelebrationHistoryPanel(type: 'birthday')),
      '/org/hr-tasks/celebrations/history',
      'hr-celebration-history-table',
    ),
    (
      '访客黑名单',
      const SecurityBlacklistPage(),
      ApiEndpoints.securityBlacklist,
      'security-blacklist-table',
    ),
  ]) {
    testWidgets('${entry.$1}慢请求/拒权/重试时静态表头常驻', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _Api(entry.$3);
      final container = ProviderContainer(
        retry: (count, error) => null,
        overrides: [
          apiClientProvider.overrideWithValue(api),
          apiBaseUrlProvider.overrideWithValue('https://fixture.invalid/api'),
          masterDataSessionKeyProvider.overrideWithValue('fixed-reader'),
          sessionSnapshotProvider.overrideWith(_Snapshot.new),
          authenticatedScopeProvider.overrideWithValue(
            const AuthenticatedScope(userId: 'reader'),
          ),
          currentPermissionsProvider.overrideWithValue(const {}),
          isSuperAdminProvider.overrideWithValue(false),
          fixedBadgeSummaryOverride(badgeSummaryFixture()),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: entry.$2,
          ),
        ),
      );
      await tester.pump();
      final finder = find.byKey(Key(entry.$4));
      MasterDataTableView<Object?> table() => tester.widget(finder);
      expect(api.requests, hasLength(1));
      expect(table().columns, isNotEmpty);
      expect(table().isLoading, isTrue);
      api.requests.single.completeError(
        ApiException('FORBIDDEN', 'denied', httpStatus: 403),
      );
      await tester.pumpAndSettle();
      expect(table().columns, isNotEmpty);
      expect(table().error, isNotNull);
      expect(table().items, isEmpty);
      table().onRetry!();
      await tester.pump();
      expect(api.requests, hasLength(2));
      expect(table().isLoading, isTrue);
      api.requests.last.complete({
        'items': <Object?>[],
        'page': 1,
        'size': 20,
        'total': 0,
        'totalPages': 0,
      });
      await tester.pumpAndSettle();
      expect(table().columns, isNotEmpty);
      expect(table().isLoading, isFalse);
      expect(table().error, isNull);
      expect(tester.takeException(), isNull);
    });
  }
}
