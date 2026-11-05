import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/components/feedback/uten_reviewer_responsibility_notice.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/expense/models/expense_claim.dart';
import 'package:uten_imp/features/expense/models/expense_invoice.dart';
import 'package:uten_imp/features/expense/pages/expense_approval_detail_page.dart';
import 'package:uten_imp/features/expense/providers/expense_action_eligibility.dart';
import 'package:uten_imp/features/expense/providers/expense_providers.dart';
import 'package:uten_imp/features/expense/repositories/expense_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/task_claim_view.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/repositories/task_claim_repository.dart';

const _permissions = {
  Perm.expenseView,
  Perm.expenseApproveFinanceInitial,
  Perm.expenseApproveDepartment,
  Perm.attachmentView,
  Perm.attachmentDownload,
};

ExpenseClaim _claim(
  String id, {
  int version = 8,
  ExpenseApprovalStage stage = ExpenseApprovalStage.financeInitial,
  List<ExpenseClaimInvoice> invoices = const [],
}) => ExpenseClaim(
  id: id,
  claimNo: 'BX-$id',
  version: version,
  applicantId: 'applicant-employee',
  applicantName: '申请人',
  title: '差旅报销',
  items: const [],
  totalAmount: 128.5,
  status: ExpenseClaimStatus.submitted,
  approvalStage: stage,
  approvalRound: 1,
  canApprove: true,
  createdAt: DateTime(2026, 11, 5),
  invoices: invoices,
);

class _Repository extends Fake implements ExpenseRepository {
  final claims = {'claim-a': _claim('claim-a'), 'claim-b': _claim('claim-b')};
  final approvals = <(String, int?)>[];
  Completer<ExpenseClaim?>? approveGate;

  @override
  Future<ExpenseClaim> getById(String id) async => claims[id]!;

  @override
  Future<ExpenseClaim?> approve(String id, {int? expectedVersion}) async {
    approvals.add((id, expectedVersion));
    return approveGate == null ? null : await approveGate!.future;
  }
}

class _Reviewer extends SessionNotifier {
  int intent = 0;

  @override
  int get requestIntentEpoch => intent;

  SessionState identity({
    String id = 'reviewer-user',
    String employee = 'reviewer-employee',
    Set<String> permissions = _permissions,
  }) => SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: id,
      code: 'R001',
      name: '审批员',
      employeeId: employee,
      permissions: permissions.toList(),
    ),
  );

  @override
  SessionState build() => identity();

  void replace(SessionState next) {
    if (!state.isSameIdentity(next)) intent++;
    state = next;
  }
}

class _Api extends ApiClient {
  _Api() : super(Dio(BaseOptions(baseUrl: 'https://expense-review.test/api')));

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => const {};
}

class _Claims extends Fake implements TaskClaimRepository {
  bool blocked = false;

  @override
  Future<TaskClaimView?> claim(String targetType, String targetKey) async =>
      blocked
      ? TaskClaimView(
          targetType: targetType,
          targetKey: targetKey,
          claimedBy: 'other-employee',
          claimedByName: '其他审批员',
          claimedByMe: false,
          claimedAt: DateTime(2026, 11, 5),
          leaseUntil: DateTime(2026, 11, 6),
        )
      : null;

  @override
  Future<void> release(String targetType, String targetKey) async {}
}

class _Harness {
  _Harness(this.repository, this.reviewer, this.container, this.claimId);

  final _Repository repository;
  final _Reviewer reviewer;
  final ProviderContainer container;
  final ValueNotifier<String> claimId;
}

Future<_Harness> _pump(
  WidgetTester tester, {
  _Repository? repository,
  bool claimedByOther = false,
}) async {
  UtenBusyOverlay.debugResetYield();
  SharedPreferences.setMockInitialValues(const {});
  final preferences = await SharedPreferences.getInstance();
  final repo = repository ?? _Repository();
  final reviewer = _Reviewer();
  final claimId = ValueNotifier('claim-a');
  final router = GoRouter(
    initialLocation: '/expense/approval/detail',
    routes: [
      GoRoute(
        path: '/expense/approval',
        builder: (_, _) => const Scaffold(body: Text('审批列表')),
      ),
      GoRoute(
        path: '/expense/approval/detail',
        builder: (_, _) => ValueListenableBuilder<String>(
          valueListenable: claimId,
          builder: (_, id, _) => ExpenseApprovalDetailPage(
            key: const ValueKey('expense-review-detail'),
            claimId: id,
          ),
        ),
      ),
    ],
  );
  tester.view.physicalSize = const Size(1440, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    router.dispose();
    claimId.dispose();
    UtenBusyOverlay.debugResetYield();
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        expenseRepositoryProvider.overrideWithValue(repo),
        sessionProvider.overrideWith(() => reviewer),
        sharedPreferencesProvider.overrideWithValue(preferences),
        apiClientProvider.overrideWithValue(_Api()),
        taskClaimRepositoryProvider.overrideWithValue(
          _Claims()..blocked = claimedByOther,
        ),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
  final container = ProviderScope.containerOf(
    tester.element(find.byType(ExpenseApprovalDetailPage)),
  );
  return _Harness(repo, reviewer, container, claimId);
}

Future<void> _openConfirmation(WidgetTester tester) async {
  await tester.tap(find.text('通过'));
  await tester.pumpAndSettle();
  expect(find.byType(UtenReviewerResponsibilityNotice), findsOneWidget);
  expect(find.text('审核员：审批员(R001)'), findsOneWidget);
  expect(find.textContaining('记录报销审批责任'), findsOneWidget);
  expect(find.byType(UtenBusyOverlayCard), findsNothing);
  expect(
    tester.widget<UtenButton>(find.widgetWithText(UtenButton, '通过')).isLoading,
    isFalse,
  );
}

void main() {
  testWidgets('cancelled reviewer confirmation never dispatches approval', (
    tester,
  ) async {
    final harness = await _pump(tester);
    await _openConfirmation(tester);
    expect(harness.repository.approvals, isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(harness.repository.approvals, isEmpty);
    expect(find.byType(UtenBusyOverlayCard), findsNothing);
    expect(
      tester
          .widget<UtenButton>(find.widgetWithText(UtenButton, '通过'))
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'rapid approval clicks share one confirmation and one versioned write',
    (tester) async {
      final repo = _Repository()..approveGate = Completer<ExpenseClaim?>();
      await _pump(tester, repository: repo);
      await tester.tap(find.text('通过'));
      await tester.tap(find.text('通过'));
      await tester.pumpAndSettle();
      expect(find.byType(UtenReviewerResponsibilityNotice), findsOneWidget);
      expect(find.byType(UtenBusyOverlayCard), findsNothing);
      expect(repo.approvals, isEmpty);
      await tester.tap(find.text('确认通过'));
      await tester.pump();
      // The confirmation route still fades out while the real write is pending.
      await tester.pump(const Duration(milliseconds: 400));
      expect(repo.approvals, [('claim-a', 8)]);
      expect(find.byType(UtenBusyOverlayCard), findsOneWidget);
      expect(
        tester
            .widget<UtenButton>(find.widgetWithText(UtenButton, '通过'))
            .isLoading,
        isTrue,
      );
      expect(find.byType(UtenReviewerResponsibilityNotice), findsNothing);
      repo.approveGate!.complete(null);
      await tester.pumpAndSettle();
      expect(repo.approvals, hasLength(1));
      expect(find.text('审批列表'), findsOneWidget);
      expect(find.byType(UtenBusyOverlayCard), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final change in ['permissions', 'identity']) {
    testWidgets(
      '$change changed and restored while confirming retires the old approval',
      (tester) async {
        final harness = await _pump(tester);
        await _openConfirmation(tester);
        harness.reviewer.replace(
          change == 'permissions'
              ? harness.reviewer.identity(permissions: {Perm.expenseView})
              : harness.reviewer.identity(
                  id: 'second-user',
                  employee: 'second-employee',
                ),
        );
        harness.container.read(expenseActionEligibilityProvider);
        await tester.pumpAndSettle();
        harness.reviewer.replace(harness.reviewer.identity());
        harness.container.read(expenseActionEligibilityProvider);
        await tester.pumpAndSettle();
        await tester.tap(find.text('确认通过'));
        await tester.pumpAndSettle();
        expect(harness.repository.approvals, isEmpty);
        expect(find.byType(ExpenseApprovalDetailPage), findsOneWidget);
        expect(find.byType(UtenBusyOverlayCard), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'a newer detail version invalidates an already displayed confirmation',
    (tester) async {
      final harness = await _pump(tester);
      await _openConfirmation(tester);
      harness.repository.claims['claim-a'] = _claim('claim-a', version: 9);
      harness.container.invalidate(expenseDetailProvider('claim-a'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认通过'));
      await tester.pumpAndSettle();
      expect(harness.repository.approvals, isEmpty);
      expect(find.byType(UtenBusyOverlayCard), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'switching the displayed claim cannot submit its previous confirmation',
    (tester) async {
      final harness = await _pump(tester);
      await _openConfirmation(tester);
      harness.claimId.value = 'claim-b';
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认通过'));
      await tester.pumpAndSettle();
      expect(harness.repository.approvals, isEmpty);
      expect(
        find.byKey(const ValueKey('expense-approval-summary-claim-b')),
        findsOneWidget,
      );
      expect(find.text('BX-claim-b · 差旅报销'), findsOneWidget);
      expect(find.byType(UtenBusyOverlayCard), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unverified finance invoices block approval before responsibility confirmation',
    (tester) async {
      final repo = _Repository();
      repo.claims['claim-a'] = _claim(
        'claim-a',
        invoices: const [
          ExpenseClaimInvoice(
            id: 'invoice',
            lineNo: 1,
            type: ExpenseInvoiceType.digital,
            invoiceNo: '00000001',
            totalAmount: 128.5,
            checkState: ExpenseInvoiceCheckState.unchecked,
          ),
        ],
      );
      await _pump(tester, repository: repo);
      await tester.tap(find.text('通过'));
      await tester.pumpAndSettle();
      expect(find.byType(UtenReviewerResponsibilityNotice), findsNothing);
      expect(repo.approvals, isEmpty);
      expect(find.byType(UtenBusyOverlayCard), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('department approval retains its separate invoice requirements', (
    tester,
  ) async {
    final repo = _Repository();
    repo.claims['claim-a'] = _claim(
      'claim-a',
      stage: ExpenseApprovalStage.department,
      invoices: const [
        ExpenseClaimInvoice(
          id: 'invoice',
          lineNo: 1,
          type: ExpenseInvoiceType.digital,
          invoiceNo: '00000001',
          totalAmount: 128.5,
          checkState: ExpenseInvoiceCheckState.unchecked,
        ),
      ],
    );
    await _pump(tester, repository: repo);
    await _openConfirmation(tester);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(repo.approvals, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an existing colleague claim keeps the approval entry disabled', (
    tester,
  ) async {
    final harness = await _pump(tester, claimedByOther: true);
    expect(
      tester
          .widget<UtenButton>(find.widgetWithText(UtenButton, '通过'))
          .onPressed,
      isNull,
    );
    expect(harness.repository.approvals, isEmpty);
    expect(find.byType(UtenReviewerResponsibilityNotice), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
