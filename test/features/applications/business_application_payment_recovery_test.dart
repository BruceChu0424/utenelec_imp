import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_search_bar.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/applications/models/business_application.dart';
import 'package:uten_imp/features/applications/pages/business_application_detail_page.dart';
import 'package:uten_imp/features/applications/repositories/business_application_repository.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/finance/repositories/finance_repository.dart';
import 'package:uten_imp/shared/attachments/attachment.dart';
import 'package:uten_imp/shared/attachments/attachment_service.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import '../../shared/drafts/memory_form_draft_storage.dart';
import '../../support/audit_screenshot_support.dart';

const _permissions = [
  Perm.applicationPay,
  Perm.applicationPrepaymentLinkFinance,
  Perm.financePaymentView,
  Perm.attachmentView,
  Perm.attachmentUpload,
  Perm.attachmentDownload,
];

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'finance',
      employeeId: 'finance-employee',
      code: 'F01',
      name: '财务经办',
      department: '财务部',
      permissions: _permissions,
    ),
  );
}

class _Applications extends Fake implements BusinessApplicationRepository {
  int writes = 0;
  bool committed = false;
  String kind = 'PAYMENT';
  bool loseResponses = true;
  bool posted = false;
  String? recordedDate;
  String? recordedReference;
  ApiException? rejectOnce;
  final actions = <String>[];
  final financeCandidateReads = <String>[];
  final financeKeywords = <String?>[];
  int candidateRevision = 0;
  final versions = <int>[];
  Map<String, dynamic>? sent;
  @override
  Future<BusinessApplication> get(String id) async => BusinessApplication(
    id: id,
    applicationNo: 'SQ20261103000001',
    kind: kind,
    title: '测试付款',
    amount: '1200.50',
    status: committed ? 'PAID' : 'APPROVED',
    applicantId: 'applicant',
    applicantName: '申请人',
    createdAt: DateTime(2026, 11, 3),
    approvalStage: 'PAYMENT',
    approvalStageLabel: '登记付款',
    round: 1,
    canPay: !committed,
    canLinkFinance: kind == 'PREPAYMENT' && committed && !posted,
    postingStatus: kind == 'PREPAYMENT'
        ? (posted ? 'POSTED' : 'PENDING')
        : 'NOT_REQUIRED',
    version: posted
        ? 9
        : committed
        ? 8
        : 7,
    financeDocumentId: committed && (kind != 'PREPAYMENT' || posted)
        ? 'finance-doc'
        : null,
    fields: {
      'reason': '采购付款',
      'payee': '测试单位',
      if (kind == 'PREPAYMENT') 'supplierId': 'supplier-1',
      if (kind == 'PREPAYMENT') 'supplierName': '示例供应商',
      if (committed) 'paymentReference': recordedReference ?? 'TX-001',
      if (committed && recordedDate != null) 'paymentDate': recordedDate,
    },
    events: [
      BusinessApplicationEvent(
        action: 'SUBMITTED',
        actorName: '示例申请人',
        occurredAt: DateTime(2026, 11, 3, 9),
        round: 1,
      ),
      for (final (index, stage) in [
        'DEPARTMENT',
        'FINANCE_INITIAL',
        'FINANCE_REVIEW',
        'EXECUTIVE',
      ].indexed)
        BusinessApplicationEvent(
          action: 'APPROVED',
          actorName: ['示例部门负责人', '示例财务初核人', '示例财务复核人', '示例总经办批准人'][index],
          stage: stage,
          occurredAt: DateTime(2026, 11, 3, 10 + index),
          round: 1,
        ),
      if (committed)
        BusinessApplicationEvent(
          action: 'PAID',
          actorName: '示例出纳',
          stage: 'PAYMENT',
          occurredAt: DateTime(2026, 11, 3, 15),
          round: 1,
        ),
    ],
  );
  @override
  Future<BusinessApplication> act(
    String id,
    String action, {
    required int version,
    String? reason,
    Map<String, dynamic>? fields,
  }) async {
    writes++;
    versions.add(version);
    actions.add(action);
    sent = fields;
    if (rejectOnce case final rejection?) {
      rejectOnce = null;
      throw rejection;
    }
    if (loseResponses) throw const SocketException('response lost');
    if (action == 'pay') {
      committed = true;
      recordedDate = fields!['paymentDate'] as String?;
      recordedReference = fields['paymentReference'] as String?;
    }
    if (action == 'link-finance') posted = true;
    return get(id);
  }

  @override
  Future<Map<String, dynamic>> prepaymentFinanceCandidates(
    String id, {
    int page = 1,
    String? keyword,
  }) async {
    financeCandidateReads.add(id);
    financeKeywords.add(keyword);
    return {
      'items': [
        {
          'id': 'finance-doc',
          'billNo': keyword?.isNotEmpty == true
              ? 'FK-$keyword-$candidateRevision'
              : 'FK20261103000002',
          'billDate': recordedDate,
          'amountLocalText': '1200.50',
          'status': 1,
        },
      ],
      'page': 1,
      'size': 24,
      'total': 1,
      'totalPages': 1,
    };
  }
}

class _Attachments extends Fake implements AttachmentService {
  @override
  Future<List<Attachment>> list({
    required String ownerType,
    required String ownerId,
  }) async => [
    Attachment(
      id: 'evidence-$ownerType',
      ownerType: ownerType,
      ownerId: ownerId,
      storageKey: 'fixture/evidence.pdf',
      originalName: ownerType == 'BUSINESS_APPLICATION_PAYMENT'
          ? '示例银行付款回单.pdf'
          : '示例付款申请附件.pdf',
      contentType: 'application/pdf',
      sizeBytes: 2048,
      originalAvailability: 'AVAILABLE',
    ),
  ];
}

class _Finance extends Fake implements FinanceRepository {
  @override
  Future<PagedResult<FinanceDocListItem>> list({
    int page = 1,
    int size = 20,
    FinanceDocFilter filter = const FinanceDocFilter(),
    String? sort,
    String? order,
  }) async => const PagedResult(
    items: [
      FinanceDocListItem(
        id: 'finance-doc',
        billNo: 'FK20261103000001',
        billDate: '2026-11-03',
        amountLocalText: '1200.50',
        status: 1,
      ),
    ],
    page: 1,
    size: 24,
    total: 1,
    totalPages: 1,
  );
}

Widget _app(
  _Applications repository,
  MemoryFormDraftStorage storage,
  SharedPreferences prefs,
  String location, {
  GlobalKey? captureKey,
}) {
  final router = GoRouter(
    initialLocation: location,
    routes: [
      GoRoute(
        path: '/applications/:id',
        builder: (_, s) => BusinessApplicationDetailPage(
          applicationId: s.pathParameters['id']!,
        ),
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      sessionProvider.overrideWith(_Session.new),
      sharedPreferencesProvider.overrideWithValue(prefs),
      formDraftStorageProvider.overrideWithValue(storage),
      apiBaseUrlProvider.overrideWithValue('https://applications.test/api'),
      apiClientProvider.overrideWithValue(
        ApiClient(Dio(BaseOptions(baseUrl: 'https://applications.test/api'))),
      ),
      businessApplicationRepositoryProvider.overrideWithValue(repository),
      attachmentServiceProvider.overrideWithValue(_Attachments()),
      financeRepositoryProvider(
        FinanceDocType.payment,
      ).overrideWithValue(_Finance()),
    ],
    child: MaterialApp.router(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      theme: captureKey == null
          ? buildLightTheme()
          : auditScreenshotTheme(buildLightTheme()),
      builder: (context, child) =>
          RepaintBoundary(key: captureKey, child: child!),
      routerConfig: router,
    ),
  );
}

void main() {
  testWidgets(
    'prepayment finance search uses shared explicit submission and refreshes a completed same query without writing',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final repository = _Applications()
        ..kind = 'PREPAYMENT'
        ..committed = true
        ..recordedDate = '2026-11-03'
        ..loseResponses = false;
      await tester.pumpWidget(
        _app(
          repository,
          MemoryFormDraftStorage(),
          prefs,
          '/applications/prepayment-1',
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('关联预付账务'));
      await tester.pumpAndSettle();
      final search = find.descendant(
        of: find.byKey(const Key('application-finance-candidate-search')),
        matching: find.byType(TextField),
      );
      expect(find.byType(UtenSearchBar), findsWidgets);
      await tester.enterText(search, 'FK');
      await tester.pump(const Duration(milliseconds: 400));
      expect(repository.financeKeywords, ['']);
      await tester.showKeyboard(search);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(repository.financeKeywords, ['', 'FK']);
      expect(find.textContaining('FK-FK-0'), findsOneWidget);
      repository.candidateRevision = 1;
      await tester.showKeyboard(search);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(repository.financeKeywords, ['', 'FK', 'FK']);
      expect(find.textContaining('FK-FK-1'), findsOneWidget);
      expect(repository.writes, 0);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'a definite first rejection releases only its send marker and preserves the editable payment inputs',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final storage = MemoryFormDraftStorage();
      final repository = _Applications()
        ..loseResponses = false
        ..rejectOnce = ApiException(
          'VALIDATION_FAILED',
          '请补充付款证明',
          httpStatus: 400,
          hasResponseCode: true,
        );
      await tester.pumpWidget(
        _app(repository, storage, prefs, '/applications/rejected-payment'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('登记付款').last);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('FK20261103000001'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, '付款凭证号 / 交易流水号 *'),
        'VALID-REF  ',
      );
      await tester.tap(find.text('关联并登记付款'));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(BusinessApplicationDetailPage)),
        listen: false,
      );
      final draft = container.read(formDraftsProvider).single;
      expect(draft.hasUnknownSubmission, isFalse);
      expect(draft.data['paymentReference'], 'VALID-REF  ');
      expect(repository.writes, 1);
      await tester.tap(find.text('登记付款').last);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(
              find.widgetWithText(TextField, '付款凭证号 / 交易流水号 *'),
            )
            .controller!
            .text,
        'VALID-REF  ',
      );
      await tester.tap(find.text('关联并登记付款'));
      await tester.pumpAndSettle();
      expect(repository.writes, 2);
      expect(repository.sent!['paymentReference'], 'VALID-REF');
      expect(container.read(formDraftsProvider), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'supplier prepayment records cash evidence first and later links only dedicated prepayment candidates',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final storage = MemoryFormDraftStorage();
      final repository = _Applications()
        ..kind = 'PREPAYMENT'
        ..loseResponses = false;
      final capture =
          Platform.environment['UTEN_APPLICATION_QA_CAPTURE'] == '1';
      final captureKey = capture ? GlobalKey() : null;
      if (capture) await loadAuditScreenshotFonts(tester);
      await tester.pumpWidget(
        _app(
          repository,
          storage,
          prefs,
          '/applications/prepayment-1',
          captureKey: captureKey,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('登记付款').last);
      await tester.pumpAndSettle();
      expect(find.text('登记供应商预付款'), findsOneWidget);
      expect(find.textContaining('FK20261103000001'), findsNothing);
      await tester.enterText(
        find.widgetWithText(TextField, '付款凭证号 / 交易流水号 *'),
        'TX-001',
      );
      if (capture) {
        await tester.pumpAndSettle();
        await saveAuditScreenshot(
          tester,
          captureKey!,
          'manual-prepayment-register',
        );
      }
      await tester.tap(find.text('确认登记预付款'));
      await tester.pumpAndSettle();
      expect(repository.actions, ['pay']);
      expect(repository.sent!.containsKey('financeDocumentId'), isFalse);
      expect(repository.sent!.containsKey('financeDocumentType'), isFalse);
      expect(find.textContaining('已付款 待财务入账'), findsOneWidget);
      if (capture) {
        await saveAuditScreenshot(
          tester,
          captureKey!,
          'manual-prepayment-pending',
        );
      }
      await tester.tap(find.text('关联预付账务'));
      await tester.pumpAndSettle();
      expect(repository.financeCandidateReads, ['prepayment-1']);
      await tester.tap(find.textContaining('FK20261103000002'));
      await tester.pumpAndSettle();
      if (capture) {
        await saveAuditScreenshot(
          tester,
          captureKey!,
          'manual-prepayment-link',
        );
      }
      expect(
        find.text('1200.50 元'),
        findsOneWidget,
        reason: 'dedicated exact candidate money must be visible, not a dash',
      );
      await tester.tap(find.text('确认关联预付账务'));
      await tester.pumpAndSettle();
      expect(repository.actions, ['pay', 'link-finance']);
      expect(repository.versions, [7, 8]);
      expect(repository.sent, {
        'financeDocumentType': 'PAYMENT',
        'financeDocumentId': 'finance-doc',
      });
      final accounting = tester.widget<Text>(find.textContaining('账务状态'));
      expect(accounting.textSpan!.toPlainText(), contains('已关联预付账务'));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'payment response loss retains the original record selection and raw reference for explicit recovery',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final repository = _Applications();
      final storage = MemoryFormDraftStorage();
      Widget buildApp(String location) =>
          _app(repository, storage, prefs, location);
      await tester.pumpWidget(buildApp('/applications/application-1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('登记付款').last);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('FK20261103000001'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, '付款凭证号 / 交易流水号 *'),
        'TX-001  ',
      );
      await tester.tap(find.text('关联并登记付款'));
      await tester.pumpAndSettle();
      expect(repository.writes, 1);
      expect(repository.sent!['paymentReference'], 'TX-001');
      expect(
        repository.sent!.keys.any((key) => key.startsWith('_local')),
        isFalse,
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(BusinessApplicationDetailPage)),
        listen: false,
      );
      final draft = container.read(formDraftsProvider).single;
      expect(draft.data['paymentReference'], 'TX-001  ');
      expect(draft.data['createdDocId'], 'application-1');
      expect(draft.hasUnknownSubmission, isTrue);
      await expectLater(
        container.read(formDraftsProvider.notifier).delete(draft.id),
        throwsA(isA<FormDraftUnknownSubmission>()),
      );
      expect(
        (draft.data['_applicationPaymentCommand'] as Map)['expectedVersion'],
        7,
      );
      await tester.tap(find.text('刷新核对'));
      await tester.pumpAndSettle();
      expect(repository.writes, 1);
      await tester.tap(find.text('登记付款').last);
      await tester.pumpAndSettle();
      final reference = tester.widget<TextField>(
        find.widgetWithText(TextField, '付款凭证号 / 交易流水号 *'),
      );
      expect(reference.controller!.text, 'TX-001  ');
      expect(find.text('关联并登记付款'), findsOneWidget);
      expect(
        repository.writes,
        1,
        reason: 'opening a restored input panel must not replay payment',
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.pumpWidget(buildApp(draft.resumeLocation));
      await tester.pumpAndSettle();
      expect(find.text('核对付款结果'), findsOneWidget);
      expect(
        repository.writes,
        1,
        reason: 'restart must not replay the frozen payment',
      );
      await tester.tap(find.text('核对付款结果'));
      await tester.pumpAndSettle();
      expect(repository.writes, 1);
      await tester.tap(find.text('继续原付款登记'));
      await tester.pumpAndSettle();
      expect(repository.writes, 2);
      expect(
        repository.versions,
        [7, 7],
        reason: 'explicit continuation is bound to the original version',
      );
      expect(repository.sent!['paymentReference'], 'TX-001');
      final currentContainer = ProviderScope.containerOf(
        tester.element(find.byType(BusinessApplicationDetailPage)),
        listen: false,
      );
      final pending = currentContainer.read(formDraftsProvider).single;
      repository.committed = true;
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.pumpWidget(buildApp(pending.resumeLocation));
      await tester.pumpAndSettle();
      expect(
        find.text('核对付款结果'),
        findsOneWidget,
        reason:
            'a paid authoritative result still opens the protected receipt recovery',
      );
      await tester.tap(find.text('核对付款结果'));
      await tester.pumpAndSettle();
      final recoveredContainer = ProviderScope.containerOf(
        tester.element(find.byType(BusinessApplicationDetailPage)),
        listen: false,
      );
      expect(recoveredContainer.read(formDraftsProvider), isEmpty);
      expect(
        repository.writes,
        2,
        reason: 'confirmed payment recovery is read-only',
      );
      expect(tester.takeException(), isNull);
    },
  );
}
