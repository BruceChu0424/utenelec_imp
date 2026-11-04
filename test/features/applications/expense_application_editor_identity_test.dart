import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/router/editor_resource_key.dart';
import 'package:uten_imp/features/applications/models/business_application.dart';
import 'package:uten_imp/features/applications/pages/business_application_edit_page.dart';
import 'package:uten_imp/features/applications/repositories/business_application_repository.dart';
import 'package:uten_imp/features/expense/models/expense_claim.dart';
import 'package:uten_imp/features/expense/models/expense_item.dart';
import 'package:uten_imp/features/expense/models/expense_settings.dart';
import 'package:uten_imp/features/expense/pages/expense_claim_edit_page.dart';
import 'package:uten_imp/features/expense/providers/expense_settings_provider.dart';
import 'package:uten_imp/features/expense/repositories/expense_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/widgets/editor_identity_notice.dart';

import '../../shared/drafts/memory_form_draft_storage.dart';

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'owner',
      employeeId: 'employee',
      code: 'E01',
      name: '申请人',
      permissions: [Perm.expenseApply, Perm.applicationApply],
    ),
  );
}

// A and B intentionally have the same version: an obsolete form must not
// overwrite a different record even when its optimistic version happens to fit.
class _Applications extends Fake implements BusinessApplicationRepository {
  final writes = <(String, BusinessApplicationInput)>[];

  BusinessApplication value(String id) => BusinessApplication(
    id: id,
    applicationNo: 'SQ-$id',
    kind: 'PAYMENT',
    title: id == 'record-a' ? '申请甲' : '申请乙',
    amount: id == 'record-a' ? '11.11' : '27.89',
    status: 'DRAFT',
    applicantId: 'employee',
    applicantName: '申请人',
    createdAt: DateTime(2026, 11, 3),
    version: 7,
    fields: {
      'reason': id == 'record-a' ? '甲申请事由' : '乙申请事由',
      'payee': id == 'record-a' ? '甲收款单位' : '乙收款单位',
    },
  );

  @override
  Future<BusinessApplication> get(String id) async => value(id);

  @override
  Future<BusinessApplication> update(
    String id,
    BusinessApplicationInput input,
  ) async {
    writes.add((id, input));
    return value(id);
  }

  @override
  Future<Map<String, dynamic>> counts() async => {};
}

class _Expenses extends Fake implements ExpenseRepository {
  final writes = <(String, ExpenseClaimCreateInput)>[];

  ExpenseClaim value(String id) => ExpenseClaim(
    id: id,
    claimNo: 'BX-$id',
    applicantId: 'employee',
    applicantName: '申请人',
    title: id == 'record-a' ? '报销甲' : '报销乙',
    status: ExpenseClaimStatus.draft,
    totalAmount: id == 'record-a' ? 11.11 : 27.89,
    createdAt: DateTime(2026, 11, 3),
    version: 7,
    items: [
      ExpenseItem(
        id: 'item-$id',
        category: ExpenseCategory.travel,
        amount: id == 'record-a' ? 11.11 : 27.89,
        date: DateTime(2026, 11, 3),
        description: id == 'record-a' ? '甲住宿' : '乙住宿',
      ),
    ],
  );

  @override
  Future<ExpenseClaim> getById(String id) async => value(id);

  @override
  Future<ExpenseClaim> update(String id, ExpenseClaimCreateInput input) async {
    writes.add((id, input));
    return value(id);
  }
}

Future<GoRouter> _mount(
  WidgetTester tester, {
  required bool application,
  required bool keyed,
  required _Applications applications,
  required _Expenses expenses,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  tester.view.physicalSize = const Size(1440, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final prefix = application ? '/applications' : '/expense';
  final router = GoRouter(
    initialLocation: '$prefix/record-a/edit',
    routes: [
      GoRoute(
        path: '$prefix/:id/edit',
        builder: (_, state) {
          final key = keyed ? editorResourceKey(state.uri) : null;
          return application
              ? BusinessApplicationEditPage(
                  key: key,
                  applicationId: state.pathParameters['id']!,
                )
              : ExpenseClaimEditPage(
                  key: key,
                  claimId: state.pathParameters['id']!,
                );
        },
      ),
      GoRoute(
        path: '$prefix/:id',
        builder: (_, state) =>
            Scaffold(body: Text('saved ${state.pathParameters['id']}')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionProvider.overrideWith(_Session.new),
        currentPermissionsProvider.overrideWithValue({
          Perm.expenseApply,
          Perm.applicationApply,
        }),
        sharedPreferencesProvider.overrideWithValue(prefs),
        formDraftStorageProvider.overrideWithValue(MemoryFormDraftStorage()),
        apiBaseUrlProvider.overrideWithValue(
          'https://editor-identity.test/api',
        ),
        apiClientProvider.overrideWithValue(
          ApiClient(
            Dio(BaseOptions(baseUrl: 'https://editor-identity.test/api')),
          ),
        ),
        expenseSettingsProvider.overrideWith(
          (_) async => const ExpenseSettings(companyName: '测试公司'),
        ),
        businessApplicationRepositoryProvider.overrideWithValue(applications),
        expenseRepositoryProvider.overrideWithValue(expenses),
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
  return router;
}

void main() {
  for (final application in [false, true]) {
    final name = application ? 'application' : 'expense';
    final pageType = application
        ? BusinessApplicationEditPage
        : ExpenseClaimEditPage;
    final titleLabel = application ? '申请标题 *' : '报销标题 *';
    final saveLabel = application ? '保存并补充凭证' : '保存';
    final prefix = application ? '/applications' : '/expense';

    testWidgets(
      '$name unkeyed GoRouter reuse permanently retires A inputs and callbacks',
      (tester) async {
        final applications = _Applications();
        final expenses = _Expenses();
        final router = await _mount(
          tester,
          application: application,
          keyed: false,
          applications: applications,
          expenses: expenses,
        );
        final oldState = tester.state(find.byType(pageType));
        await tester.enterText(
          find.widgetWithText(TextField, titleLabel),
          '原单未保存输入',
        );
        final originalSave = tester
            .widget<UtenButton>(find.widgetWithText(UtenButton, saveLabel))
            .onPressed!;

        router.go('$prefix/record-b/edit');
        await tester.pumpAndSettle();
        expect(
          identical(oldState, tester.state(find.byType(pageType))),
          isTrue,
          reason: 'This template route must genuinely reuse its editor State.',
        );
        expect(find.byType(EditorIdentityNotice), findsOneWidget);
        expect(find.widgetWithText(TextField, titleLabel), findsNothing);
        originalSave();
        await tester.pumpAndSettle();

        // Returning to the original URL cannot revive the retired form.
        router.go('$prefix/record-a/edit');
        await tester.pumpAndSettle();
        expect(find.byType(EditorIdentityNotice), findsOneWidget);
        originalSave();
        await tester.pumpAndSettle();
        expect(applications.writes, isEmpty);
        expect(expenses.writes, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '$name production resource keys replace A State and save B inputs only',
      (tester) async {
        final applications = _Applications();
        final expenses = _Expenses();
        final router = await _mount(
          tester,
          application: application,
          keyed: true,
          applications: applications,
          expenses: expenses,
        );
        final oldState = tester.state(find.byType(pageType));
        await tester.enterText(
          find.widgetWithText(TextField, titleLabel),
          '原单未保存输入',
        );

        router.go('$prefix/record-b/edit');
        await tester.pumpAndSettle();
        expect(
          identical(oldState, tester.state(find.byType(pageType))),
          isFalse,
        );
        expect(find.byType(EditorIdentityNotice), findsNothing);
        final title = find.widgetWithText(TextField, titleLabel);
        expect(
          tester.widget<TextField>(title).controller!.text,
          application ? '申请乙' : '报销乙',
        );
        await tester.enterText(title, '乙单修订');
        await tester.tap(find.widgetWithText(UtenButton, saveLabel));
        await tester.pumpAndSettle();

        if (application) {
          final (id, input) = applications.writes.single;
          expect(id, 'record-b');
          expect(input.id, 'record-b');
          expect(input.expectedVersion, 7);
          expect(input.title, '乙单修订');
          expect(input.amount, '27.89');
          expect(input.fields['reason'], '乙申请事由');
          expect(input.fields['payee'], '乙收款单位');
        } else {
          final (id, input) = expenses.writes.single;
          expect(id, 'record-b');
          expect(input.expectedVersion, 7);
          expect(input.title, '乙单修订');
          expect(input.items.single.id, 'item-record-b');
          expect(input.items.single.amount, 27.89);
          expect(input.items.single.description, '乙住宿');
        }
        expect(find.text('saved record-b'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
