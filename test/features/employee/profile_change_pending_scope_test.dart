import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/feedback/uten_notification_badge.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/employee/widgets/profile_change_pending_section.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _Api extends ApiClient {
  _Api() : super(Dio());
  Map<String, dynamic>? query;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    this.query = query;
    // In the global queue this employee appears after page one. A true scoped
    // server query returns its first three of seven complete batches.
    final matches = query?['employeeId'] == 'employee-27';
    return {
      'items': [
        if (matches)
          for (var i = 0; i < 3; i++)
            {
              'batchId': 'batch-$i',
              'employeeId': 'employee-27',
              'employeeName': '第二页员工',
              'status': 'pending',
              'itemCount': 2,
              'fieldCodes': ['phone', 'fullName'],
              'submittedAt': '2026-10-12T08:00:00+08:00',
            },
      ],
      'page': 1,
      'size': 3,
      'totalElements': matches ? 7 : 0,
      'totalPages': matches ? 3 : 1,
    };
  }
}

void main() {
  testWidgets(
    'employee pending preview searches before pagination and reports all batches',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final api = _Api();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            sharedPreferencesProvider.overrideWithValue(preferences),
            currentPermissionsProvider.overrideWithValue({Perm.profileReview}),
            masterDataSessionKeyProvider.overrideWithValue('reviewer'),
            authenticatedScopeProvider.overrideWithValue(
              const AuthenticatedScope(userId: 'reviewer'),
            ),
          ],
          child: const MaterialApp(
            locale: Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: ProfileChangePendingSection(employeeId: 'employee-27'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(api.query?['employeeId'], 'employee-27');
      expect(api.query?['status'], 'pending');
      expect(api.query?['size'], 3);
      expect(find.textContaining('第二页员工'), findsNWidgets(3));
      expect(
        tester
            .widget<UtenNotificationBadge>(find.byType(UtenNotificationBadge))
            .count,
        7,
      );
      expect(find.textContaining('(4)'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
