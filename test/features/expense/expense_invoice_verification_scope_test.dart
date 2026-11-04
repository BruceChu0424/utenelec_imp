import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/expense/models/expense_claim.dart';
import 'package:uten_imp/features/expense/models/expense_invoice.dart';
import 'package:uten_imp/features/expense/repositories/expense_repository.dart';
import 'package:uten_imp/features/expense/widgets/expense_invoice_section.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

const _permissions = {
  Perm.expenseApproveFinanceInitial,
  Perm.attachmentView,
  Perm.attachmentDownload,
};

final _testPermissions = StateProvider<Set<String>>((ref) => _permissions);

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'finance',
      employeeId: 'finance-employee',
      code: 'F1',
      name: '财务初核',
    ),
  );
}

class _Snapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => SessionSnapshot();
}

const _invoice = ExpenseClaimInvoice(
  id: 'invoice',
  lineNo: 1,
  type: ExpenseInvoiceType.digital,
  invoiceNo: '12345678901234567890',
  totalAmount: 100,
  checkState: ExpenseInvoiceCheckState.amountsMatch,
);
ExpenseClaim _claim() => ExpenseClaim(
  id: 'claim',
  claimNo: 'BX1',
  applicantId: 'applicant',
  applicantName: '申请人',
  title: '测试报销',
  items: const [],
  totalAmount: 100,
  status: ExpenseClaimStatus.reviewing,
  createdAt: DateTime(2026, 11, 3),
  version: 3,
  approvalStage: ExpenseApprovalStage.financeInitial,
  canApprove: true,
  invoices: [_invoice],
);

class _Repository extends Fake implements ExpenseRepository {
  int calls = 0, reads = 0;
  bool loseResponse = false;
  final gate = Completer<ExpenseClaim>();
  @override
  Future<ExpenseClaim> getById(String id) async {
    reads++;
    return _claim();
  }

  @override
  Future<ExpenseClaim> verifyInvoice(
    String claimId,
    String invoiceId, {
    required int expectedVersion,
    required bool verified,
    required String remark,
  }) {
    calls++;
    if (loseResponse) throw NetworkTimeoutException();
    return gate.future;
  }
}

Future<ProviderContainer> _open(
  WidgetTester tester,
  _Repository repository,
) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(ApiClient(Dio())),
      apiBaseUrlProvider.overrideWithValue('https://verify.test/api'),
      sessionProvider.overrideWith(_Session.new),
      sessionSnapshotProvider.overrideWith(_Snapshot.new),
      currentPermissionsProvider.overrideWith(
        (ref) => ref.watch(_testPermissions),
      ),
      isSuperAdminProvider.overrideWithValue(false),
      expenseRepositoryProvider.overrideWithValue(repository),
      sharedPreferencesProvider.overrideWithValue(preferences),
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
        home: Scaffold(
          body: SingleChildScrollView(
            child: ExpenseInvoiceSection(
              claim: _claim(),
              editable: false,
              canVerify: true,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.textContaining('#1'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField).last, '按原件人工核对，日期与金额一致');
  return container;
}

void main() {
  testWidgets(
    'invoice verification freezes one command and shows the shared overlay',
    (tester) async {
      final repository = _Repository();
      await _open(tester, repository);
      final save = tester.widget<UtenButton>(
        find.widgetWithText(UtenButton, '保存'),
      );
      final futures = [
        for (var i = 0; i < 8; i++) Future<void>.sync(save.onPressed!),
      ];
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(repository.calls, 1);
      expect(find.text('正在处理票据查验'), findsOneWidget);
      repository.gate.complete(_claim());
      await Future.wait(futures);
      await tester.pumpAndSettle();
      expect(find.text('正在处理票据查验'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'unknown verification keeps input and performs a read before another command',
    (tester) async {
      final repository = _Repository()..loseResponse = true;
      await _open(tester, repository);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(repository.calls, 1);
      expect(find.text('核对结果'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField).last).controller!.text,
        '按原件人工核对，日期与金额一致',
      );
      await tester.tap(find.text('核对结果'));
      await tester.pumpAndSettle();
      expect(repository.calls, 1);
      expect(repository.reads, 1);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'revoking then restoring a grant cannot revive the old verification dialog',
    (tester) async {
      final repository = _Repository();
      final container = await _open(tester, repository);
      container.read(_testPermissions.notifier).state = const {};
      await tester.pumpAndSettle();
      container.read(_testPermissions.notifier).state = _permissions;
      await tester.pumpAndSettle();
      expect(find.text('授权已变化'), findsOneWidget);
      expect(find.text('保存'), findsNothing);
      expect(repository.calls, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
