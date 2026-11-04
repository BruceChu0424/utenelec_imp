import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/expense/models/expense_claim.dart';
import 'package:uten_imp/features/expense/pages/expense_detail_page.dart';
import 'package:uten_imp/features/expense/repositories/expense_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'owner',
      employeeId: 'employee',
      code: 'E01',
      name: '申请人',
      permissions: [Perm.expenseApply],
    ),
  );
}

class _Repo extends Fake implements ExpenseRepository {
  final writes = <String>[];
  ExpenseClaim value(String id, {bool abandoned = false}) => ExpenseClaim(
    id: id,
    claimNo: id == 'claim-a' ? 'BX20261103000001' : 'BX20261103000002',
    applicantId: 'employee',
    applicantName: '申请人',
    title: id == 'claim-a' ? '申请甲' : '申请乙',
    items: const [],
    totalAmount: 10,
    status: ExpenseClaimStatus.rejected,
    createdAt: DateTime(2026, 11, 3),
    version: 3,
    rejectReason: '不再继续',
    abandoned: abandoned,
  );
  @override
  Future<ExpenseClaim> getById(String id) async => value(id);
  @override
  Future<ExpenseClaim> getHistoryById(String id) async =>
      value(id, abandoned: true);
  @override
  Future<ExpenseClaim?> abandon(String id, {int? expectedVersion}) async {
    writes.add(id);
    return value(id, abandoned: true);
  }
}

void main() {
  testWidgets(
    'navigating to another claim cannot confirm the old claim operation',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final repo = _Repo();
      final router = GoRouter(
        initialLocation: '/expense/claim-a',
        routes: [
          GoRoute(
            path: '/expense/:id',
            builder: (_, state) => ExpenseDetailPage(
              claimId: state.pathParameters['id']!,
              history: state.uri.queryParameters['history'] == '1',
            ),
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sessionProvider.overrideWith(_Session.new),
            sharedPreferencesProvider.overrideWithValue(prefs),
            apiBaseUrlProvider.overrideWithValue(
              'https://expense-route.test/api',
            ),
            apiClientProvider.overrideWithValue(
              ApiClient(
                Dio(BaseOptions(baseUrl: 'https://expense-route.test/api')),
              ),
            ),
            expenseRepositoryProvider.overrideWithValue(repo),
          ],
          child: MaterialApp.router(
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('放弃报销'));
      await tester.pumpAndSettle();
      expect(find.text('放弃并归档'), findsOneWidget);
      router.go('/expense/claim-b');
      await tester.pumpAndSettle();
      if (find.text('放弃并归档').evaluate().isNotEmpty) {
        await tester.tap(find.text('放弃并归档'));
        await tester.pumpAndSettle();
      }
      expect(
        repo.writes,
        isEmpty,
        reason:
            'The original confirmation must retire when the concrete record route changes.',
      );
      expect(tester.takeException(), isNull);
    },
  );
}
