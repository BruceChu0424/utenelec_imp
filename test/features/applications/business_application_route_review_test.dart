import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/applications/models/business_application.dart';
import 'package:uten_imp/features/applications/pages/business_application_detail_page.dart';
import 'package:uten_imp/features/applications/repositories/business_application_repository.dart';
import 'package:uten_imp/shared/attachments/attachment.dart';
import 'package:uten_imp/shared/attachments/attachment_service.dart';
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
      permissions: [Perm.applicationApplyTravel],
    ),
  );
}

class _Repo extends Fake implements BusinessApplicationRepository {
  final writes = <String>[];
  BusinessApplication value(String id, {String status = 'DRAFT'}) =>
      BusinessApplication(
        id: id,
        applicationNo: id == 'app-a' ? 'SQ20261103000001' : 'SQ20261103000002',
        kind: 'TRAVEL',
        applicantId: 'employee',
        applicantName: '申请人',
        title: id == 'app-a' ? '申请甲' : '申请乙',
        amount: '10.00',
        status: status,
        createdAt: DateTime(2026, 11, 3),
        version: 3,
        fields: const {'reason': '出差'},
      );
  @override
  Future<BusinessApplication> get(String id) async => value(id);
  @override
  Future<BusinessApplication> act(
    String id,
    String action, {
    required int version,
    String? reason,
    Map<String, dynamic>? fields,
  }) async {
    writes.add(id);
    return value(id, status: 'CANCELLED');
  }
}

class _Attachments extends Fake implements AttachmentService {
  @override
  Future<List<Attachment>> list({
    required String ownerType,
    required String ownerId,
  }) async => [];
}

void main() {
  testWidgets('new application record route retires the prior confirmation', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final repo = _Repo();
    final router = GoRouter(
      initialLocation: '/applications/app-a',
      routes: [
        GoRoute(
          path: '/applications/:id',
          builder: (_, state) => BusinessApplicationDetailPage(
            applicationId: state.pathParameters['id']!,
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
            'https://application-route.test/api',
          ),
          apiClientProvider.overrideWithValue(
            ApiClient(
              Dio(BaseOptions(baseUrl: 'https://application-route.test/api')),
            ),
          ),
          businessApplicationRepositoryProvider.overrideWithValue(repo),
          attachmentServiceProvider.overrideWithValue(_Attachments()),
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
    await tester.tap(find.text('作废申请').last);
    await tester.pumpAndSettle();
    router.go('/applications/app-b');
    await tester.pumpAndSettle();
    if (find.text('作废申请').evaluate().length > 1) {
      await tester.tap(find.text('作废申请').last);
      await tester.pumpAndSettle();
    }
    expect(
      repo.writes,
      isEmpty,
      reason:
          'A confirmation for the previous concrete application cannot mutate it after navigation.',
    );
    expect(tester.takeException(), isNull);
  });
}
