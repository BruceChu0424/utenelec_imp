import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/expense/models/expense_claim.dart';
import 'package:uten_imp/features/expense/models/expense_invoice.dart';
import 'package:uten_imp/features/expense/models/expense_settings.dart';
import 'package:uten_imp/features/expense/pages/expense_claim_edit_page.dart';
import 'package:uten_imp/features/expense/providers/expense_settings_provider.dart';
import 'package:uten_imp/features/expense/repositories/expense_repository.dart';
import 'package:uten_imp/shared/ai/ai_job_models.dart';
import 'package:uten_imp/shared/ai/ai_job_repository.dart';
import 'package:uten_imp/shared/ai/guided/ai_guided_file_banner.dart';
import 'package:uten_imp/shared/ai/guided/ai_guided_file_plan.dart';
import 'package:uten_imp/shared/attachments/attachment.dart';
import 'package:uten_imp/shared/attachments/attachment_service.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/badges/badge_summary_provider.dart';
import 'package:uten_imp/shared/drafts/form_draft.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../shared/drafts/memory_form_draft_storage.dart';

void main() {
  testWidgets(
    'initialization uses fresh fields and performs no business or attachment write',
    (tester) async {
      final harness = await _pump(
        tester,
        plan: _plan(summary: 'FORGED_EXTRA_TITLE', amount: '999999.00'),
      );
      expect(_title(tester), '服务端核验办公费');
      expect(find.textContaining('FORGED_EXTRA_TITLE'), findsNothing);
      expect(find.textContaining('999999'), findsNothing);
      expect(
        find.byKey(const ValueKey('expense-guided-invoice-preview')),
        findsOneWidget,
      );
      final draft = harness.container.read(formDraftsProvider).single;
      expect(draft.data['title'], '服务端核验办公费');
      final items = (draft.data['items'] as List).cast<Map<String, dynamic>>();
      expect(items.single['amount'], 113);
      expect(harness.jobs.reads, ['route-job-1']);
      expect(harness.repo.creates, isEmpty);
      expect(harness.repo.invoices, isEmpty);
      expect(harness.attachments.uploads, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'manual save checkpoints created id and exact original without automatic upload',
    (tester) async {
      final harness = await _pump(tester, plan: _plan());
      await _save(tester);
      expect(harness.repo.creates, hasLength(1));
      expect(harness.repo.creates.single.title, '服务端核验办公费');
      expect(harness.repo.creates.single.items.single.amount, 113);
      final draft = harness.container.read(formDraftsProvider).single;
      expect(draft.data['createdDocId'], 'created-claim-1');
      final source = draft.data['guidedPlan'] as Map;
      expect(base64Decode(source['bytes'] as String), _bytes);
      expect(source['jobId'], 'route-job-1');
      expect(draft.hasUnknownSubmission, isFalse);
      expect(
        find.byKey(const ValueKey('expense-guided-register')),
        findsOneWidget,
      );
      expect(find.text('保存并补充凭证'), findsNothing);
      expect(find.byKey(const Key('expense-detail-stub')), findsNothing);
      expect(harness.attachments.uploads, isEmpty);
      expect(harness.repo.invoices, isEmpty);
      expect(harness.jobs.reads.length, greaterThanOrEqualTo(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unknown upload is durable and retry after reopening only reads source and claim',
    (tester) async {
      final attachments = _Attachments()..failure = NetworkException('上传回执丢失');
      final repo = _Expenses();
      final storage = MemoryFormDraftStorage();
      final first = await _pump(
        tester,
        plan: _plan(),
        repo: repo,
        storage: storage,
        attachments: attachments,
      );
      await _save(tester);
      await tester.tap(find.byKey(const ValueKey('expense-guided-register')));
      await tester.pumpAndSettle();
      expect(attachments.uploads, hasLength(1));
      expect(attachments.uploads.single['ownerId'], 'created-claim-1');
      expect(attachments.uploads.single['bytes'], _bytes);
      final checkpoint = first.container.read(formDraftsProvider).single;
      expect(checkpoint.data['guidedUploadStarted'], isTrue);
      expect(checkpoint.data['createdDocId'], 'created-claim-1');
      expect(repo.invoices, isEmpty);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      final readsBefore = repo.reads.length;
      final resumed = await _pump(
        tester,
        storage: storage,
        repo: repo,
        attachments: attachments,
        draftId: checkpoint.id,
      );
      expect(attachments.uploads, hasLength(1));
      expect(repo.creates, hasLength(1));
      await tester.tap(find.byKey(const ValueKey('expense-guided-register')));
      await tester.pumpAndSettle();
      expect(repo.reads.length, greaterThan(readsBefore));
      expect(resumed.jobs.reads.length, greaterThanOrEqualTo(2));
      expect(attachments.uploads, hasLength(1));
      expect(repo.creates, hasLength(1));
      expect(repo.invoices, isEmpty);
      expect(find.textContaining('未重复上传'), findsOneWidget);
      expect(
        resumed.container
            .read(formDraftsProvider)
            .single
            .data['guidedUploadStarted'],
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'resume source 403 hides restored title items and filled-fields and cannot save',
    (tester) async {
      final storage = MemoryFormDraftStorage();
      _seed(storage, _draftData());
      final jobs = _Jobs()..failure = ApiException('FORBIDDEN', '来源权限已收回');
      final harness = await _pump(
        tester,
        storage: storage,
        jobs: jobs,
        draftId: 'draft-1',
      );
      expect(find.textContaining('来源权限已收回'), findsOneWidget);
      expect(find.textContaining('RESTORED_SECRET_TITLE'), findsNothing);
      expect(find.textContaining('RESTORED_SECRET_ITEM'), findsNothing);
      expect(find.textContaining('731.29'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(
        find.byKey(const ValueKey('expense-guided-invoice-preview')),
        findsNothing,
      );
      expect(
        tester
            .widget<AiGuidedFileBanner>(find.byType(AiGuidedFileBanner))
            .filledFields,
        isEmpty,
      );
      expect(find.text('保存并补充凭证'), findsNothing);
      expect(harness.repo.creates, isEmpty);
      expect(harness.repo.invoices, isEmpty);
      expect(harness.attachments.uploads, isEmpty);
      expect(harness.jobs.reads, ['route-job-1']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'corrupt saved source retains the created document identity and never recreates it',
    (tester) async {
      final storage = MemoryFormDraftStorage();
      final data = _draftData(createdId: 'already-created');
      data['guidedPlan'] = {
        ...data['guidedPlan'] as Map<String, dynamic>,
        'bytes': '%broken-base64%',
      };
      _seed(storage, data);
      final harness = await _pump(tester, storage: storage, draftId: 'draft-1');
      expect(find.text('这份草稿暂时无法恢复，原草稿已保留。'), findsOneWidget);
      expect(find.text('保存并补充凭证'), findsNothing);
      expect(find.textContaining('RESTORED_SECRET_TITLE'), findsNothing);
      expect(
        harness.container.read(formDraftsProvider).single.data['createdDocId'],
        'already-created',
      );
      expect(harness.repo.creates, isEmpty);
      expect(harness.repo.invoices, isEmpty);
      expect(harness.attachments.uploads, isEmpty);
      expect(harness.jobs.reads, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}

const _server = 'https://expense-guided.invalid/api';
const _permissions = {'ai:use', Perm.expenseApply, Perm.attachmentUpload};
final _bytes = Uint8List.fromList(utf8.encode('original invoice file bytes'));
AiGuidedFileIdentity _identity() {
  final permissions = _permissions.toList()..sort();
  return (
    scope: const AuthenticatedScope(userId: 'user-1'),
    server: _server,
    permissions: permissions.join('\n'),
  );
}

Map<String, dynamic> _result({
  String summary = '服务端核验办公费',
  String amount = '113.00',
}) => {
  'workflow': 'EXPENSE_CLAIM',
  'needsChoice': false,
  'requiresReview': true,
  'fields': {
    'itemSummary': summary,
    'totalAmount': amount,
    'issueDate': '2026-10-03',
    'invoiceNo': '12345678',
  },
  'fieldConfidence': {
    'itemSummary': 'HIGH',
    'totalAmount': 'HIGH',
    'issueDate': 'HIGH',
  },
  'source': {
    'fileName': 'invoice.csv',
    'sha256': sha256.convert(_bytes).toString(),
  },
};
AiGuidedFilePlan _plan({String summary = '旧预填标题', String amount = '9999.00'}) =>
    AiGuidedFilePlan(
      jobId: 'route-job-1',
      file: PlatformFile(
        name: 'invoice.csv',
        size: _bytes.length,
        bytes: _bytes,
      ),
      result: AiGuidedFileResult.fromJson(
        _result(summary: summary, amount: amount),
      ),
      workflow: AiGuidedWorkflow.expenseClaim,
      identity: _identity(),
    );
Map<String, dynamic> _draftData({String? createdId}) => {
  'title': 'RESTORED_SECRET_TITLE',
  'remark': 'private remark',
  'items': [
    {
      'id': 'local-item',
      'category': 'OTHER',
      'amount': 731.29,
      'date': '2026-10-03',
      'description': 'RESTORED_SECRET_ITEM',
    },
  ],
  'pendingItem': null,
  'guidedPlan': _plan().toLocalDraft(),
  'guidedStatus': 'guidedFilled',
  'createdDocId': createdId,
  'guidedAttachmentId': null,
  'guidedUploadStarted': false,
};
void _seed(MemoryFormDraftStorage storage, Map<String, dynamic> data) {
  final draft = FormDraft(
    id: 'draft-1',
    title: '新建报销',
    module: BadgeModule.people,
    route: '/expense/new',
    permission: Perm.expenseApply,
    draftKind: 'expense',
    updatedAt: DateTime(2026, 10, 3),
    revision: 'rev-1',
    data: data,
  );
  final prefix = formDraftStoragePrefix(
    _server,
    const AuthenticatedScope(userId: 'user-1'),
  );
  storage.records['$prefix${draft.id}'] = jsonEncode(draft.toJson());
}

String _title(WidgetTester tester) => tester
    .widget<TextField>(find.widgetWithText(TextField, '报销标题 *').first)
    .controller!
    .text;
Future<void> _save(WidgetTester tester) async {
  final button = find.widgetWithText(UtenButton, '保存并补充凭证');
  expect(tester.widget<UtenButton>(button).onPressed, isNotNull);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

Future<_Harness> _pump(
  WidgetTester tester, {
  AiGuidedFilePlan? plan,
  String? draftId,
  _Expenses? repo,
  MemoryFormDraftStorage? storage,
  _Attachments? attachments,
  _Jobs? jobs,
}) async {
  tester.view.physicalSize = const Size(1440, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues(const {});
  final preferences = await SharedPreferences.getInstance();
  final expenses = repo ?? _Expenses(),
      files = attachments ?? _Attachments(),
      queue = jobs ?? _Jobs();
  final disk = storage ?? MemoryFormDraftStorage();
  final router = GoRouter(
    initialLocation:
        '/expense/new${draftId == null ? '' : '?draftId=$draftId'}',
    routes: [
      GoRoute(
        path: '/expense/new',
        builder: (_, _) => ExpenseClaimEditPage(initialGuidedPlan: plan),
      ),
      GoRoute(
        path: '/expense/:id',
        builder: (_, _) => const SizedBox(key: Key('expense-detail-stub')),
      ),
      GoRoute(
        path: '/dashboard',
        builder: (_, _) => const SizedBox(key: Key('dashboard-stub')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionProvider.overrideWith(_Session.new),
        currentPermissionsProvider.overrideWithValue(_permissions),
        apiBaseUrlProvider.overrideWithValue(_server),
        formDraftStorageProvider.overrideWithValue(disk),
        expenseSettingsProvider.overrideWith(
          (ref) async => const ExpenseSettings(companyName: '测试公司'),
        ),
        expenseRepositoryProvider.overrideWithValue(expenses),
        attachmentServiceProvider.overrideWithValue(files),
        aiJobRepositoryProvider.overrideWithValue(queue),
        sharedPreferencesProvider.overrideWithValue(preferences),
        badgeSummaryProvider.overrideWith(_Badges.new),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final container = ProviderScope.containerOf(
    tester.element(find.byType(ExpenseClaimEditPage)),
    listen: false,
  );
  return _Harness(container, expenses, disk, files, queue);
}

class _Harness {
  const _Harness(
    this.container,
    this.repo,
    this.storage,
    this.attachments,
    this.jobs,
  );
  final ProviderContainer container;
  final _Expenses repo;
  final MemoryFormDraftStorage storage;
  final _Attachments attachments;
  final _Jobs jobs;
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'user-1',
      employeeId: 'emp-1',
      code: 'E001',
      name: '张三',
      department: '研发部',
      permissions: ['ai:use', Perm.expenseApply, Perm.attachmentUpload],
    ),
  );
}

class _Badges extends BadgeSummaryNotifier {
  @override
  BadgeSummary build() => BadgeSummary.empty;
  @override
  Future<void> refresh() async {}
}

class _Jobs implements AiJobRepository {
  final reads = <String>[];
  Object? failure;
  @override
  Future<AiJobSnapshot> get(String jobId) async {
    reads.add(jobId);
    if (failure case final error?) throw error;
    return AiJobSnapshot(
      id: jobId,
      kind: aiGuidedRouteKind,
      status: AiJobStatus.succeeded,
      result: _result(),
    );
  }

  @override
  Future<AiJobSnapshot> submit(AiJobRequest request) =>
      throw StateError('The form must not resubmit the original file');
  @override
  Future<void> cancel(String jobId) =>
      throw StateError('The form must not cancel the source');
}

class _Expenses extends Fake implements ExpenseRepository {
  final creates = <ExpenseClaimCreateInput>[];
  final reads = <String>[];
  final invoices = <ExpenseClaimInvoiceInput>[];
  ExpenseClaim? detail;
  @override
  Future<ExpenseClaim> create(ExpenseClaimCreateInput input) async {
    creates.add(input);
    return detail = ExpenseClaim(
      id: 'created-claim-1',
      claimNo: 'BX-TEST-1',
      applicantId: 'emp-1',
      applicantName: '张三',
      title: input.title,
      items: input.items,
      totalAmount: input.items.fold(0, (total, item) => total + item.amount),
      status: ExpenseClaimStatus.draft,
      createdAt: DateTime(2026, 10, 3),
    );
  }

  @override
  Future<ExpenseClaim> getById(String id) async {
    reads.add(id);
    return detail!;
  }

  @override
  Future<ExpenseClaim> addInvoice(
    String claimId,
    ExpenseClaimInvoiceInput input,
  ) async {
    invoices.add(input);
    return detail!;
  }
}

class _Attachments extends Fake implements AttachmentService {
  final uploads = <Map<String, Object>>[];
  Object? failure;
  @override
  Future<Attachment> uploadGuarded({
    required String ownerType,
    required String ownerId,
    required String fileName,
    required String contentType,
    required Uint8List bytes,
    required bool Function() canContinue,
    String? category,
  }) async {
    expect(canContinue(), isTrue);
    uploads.add({
      'ownerType': ownerType,
      'ownerId': ownerId,
      'fileName': fileName,
      'bytes': Uint8List.fromList(bytes),
    });
    if (failure case final error?) throw error;
    return Attachment(
      id: 'attachment-1',
      ownerType: ownerType,
      ownerId: ownerId,
      storageKey: 'test-original',
      originalName: fileName,
      sizeBytes: bytes.length,
      uploadedBy: 'user-1',
      sha256: sha256.convert(bytes).toString(),
    );
  }
}
