import 'dart:typed_data';
import 'package:crypto/crypto.dart';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/components/buttons/uten_import_button.dart';
import 'package:uten_imp/features/sales/widgets/sales_grid_columns.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/pages/sales_doc_edit_page.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/shared/attachments/attachment.dart';
import 'package:uten_imp/shared/attachments/attachment_service.dart';
import 'package:uten_imp/shared/attachments/business_attachment_section.dart';
import 'package:uten_imp/shared/attachments/pending_attachment_section.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/ai/guided/ai_guided_file_plan.dart';
import 'package:uten_imp/shared/ai/ai_job_repository.dart';
import 'package:uten_imp/shared/ai/ai_job_models.dart';
import 'package:uten_imp/shared/ai/ai_job_runner.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/sales/intake/sales_intake_launcher.dart';
import '../../sales/intake/sales_intake_fixture.dart';
import '../../sales/intake/sales_intake_test_support.dart';
import '../../../shared/drafts/memory_form_draft_storage.dart';
import '../../ai_visual/ai_visual_support.dart';

/// 新建销售订货单：保存前就有附件暂存区（G4），已有订单仍用即时上传区。
void main() {
  tearDown(() => FilePicker.platform = _Picker(const []));

  testWidgets('guided re-recognition quote handoff retains verified guided mode', (
    tester,
  ) async {
    final plan = _guidedPlan(quoteAccess: true);
    final result = _highResult();
    final line = (result['lines'] as List).first as Map<String, dynamic>;
    final selected = (line['candidates'] as List).first as Map<String, dynamic>;
    selected['listPrice'] = 0;
    selected['pricingFlag'] = 'NO_LIST_PRICE';
    result['extraColumns'] = [
      {'key': 'note', 'label': 'Source note', 'dataType': 'TEXT'},
    ];
    Object? handed;
    final jobs = _GuidedJobs(plan);
    final runner = _HandoffRunner(jobs, result);
    final files = _Files();
    final api = await _pumpEditor(
      tester,
      files,
      type: SalesDocType.order,
      guidedPlan: plan,
      permissions: plan.identity.permissions.split('\n').toSet(),
      guidedJobs: jobs,
      guidedRunner: runner,
      onQuoteOpened: (state) => handed = state.extra,
      renderQuoteHandoff: true,
    );
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    final section = tester.widget<BusinessAttachmentSection>(
      find.byKey(const ValueKey('sales-order-draft-attachments')),
    );
    final item = section.draftController!.items.single;
    section.draftActionFor!(item)!.onTap!();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sales-intake-handoff-quote')));
    await tester.pumpAndSettle();
    expect(
      handed,
      isA<AiGuidedFilePlan>(),
      reason:
          'A raw PlatformFile loses no-write and source-validation restrictions',
    );
    expect((handed as AiGuidedFilePlan).workflow, AiGuidedWorkflow.salesQuote);
    expect(
      runner.requests
          .where((request) => request.kind == aiGuidedRouteKind)
          .single
          .params,
      {'message': 'Create sales quotation'},
    );
    expect(
      runner.requests.where(
        (request) =>
            request.kind == 'SALES_DOCUMENT_INTAKE' &&
            request.params['docType'] == 'quote',
      ),
      hasLength(1),
    );
    await tester.tap(find.byKey(const ValueKey('sales-intake-import-all')));
    await tester.pumpAndSettle();
    final quotePage = find.byWidgetPredicate(
      (widget) =>
          widget is SalesDocEditPage && widget.docType == SalesDocType.quote,
    );
    expect(quotePage, findsOneWidget);
    expect(
      api.writes,
      isEmpty,
      reason:
          'Workflow changes must not create columns or save a business document',
    );
    expect(files.uploads, isEmpty);
  });

  testWidgets('guided plan cannot be applied to a different document type', (
    tester,
  ) async {
    final plan = _guidedPlan(quoteAccess: true);
    final jobs = _GuidedJobs(plan);
    final runner = FakeAiJobRunner(result: _highResult());
    final api = await _pumpEditor(
      tester,
      _Files(),
      type: SalesDocType.quote,
      guidedPlan: plan,
      guidedJobs: jobs,
      guidedRunner: runner,
      permissions: plan.identity.permissions.split('\n').toSet(),
    );
    expect(find.byType(UtenEditableGrid<SalesGridRow>), findsNothing);
    expect(runner.requests, isEmpty);
    expect(jobs.reads, isEmpty);
    expect(api.writes, isEmpty);
  });

  testWidgets(
    'guided sale validates first, fills real grid and keeps all writes manual',
    (tester) async {
      final plan = _guidedPlan();
      final jobs = _GuidedJobs(plan);
      final files = _Files();
      final api = await _pumpEditor(
        tester,
        files,
        type: SalesDocType.order,
        guidedPlan: plan,
        guidedJobs: jobs,
        guidedRunner: FakeAiJobRunner(result: _highResult()),
        storage: MemoryFormDraftStorage(),
      );
      final grid = tester.widget<UtenEditableGrid<SalesGridRow>>(
        find.byType(UtenEditableGrid<SalesGridRow>),
      );
      expect(grid.controller.rows.single.qty.text, '1800');
      expect(grid.controller.rows.single.setNameEn, isFalse);
      expect(jobs.reads, contains('route-source'));
      expect(
        find.byKey(const ValueKey('ai-guided-file-progress')),
        findsOneWidget,
      );
      expect(files.uploads, isEmpty);
      expect(api.writes, isEmpty);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(SalesDocEditPage)),
        listen: false,
      );
      final draft = container.read(formDraftsProvider).single;
      expect(
        (draft.data['guidedPlan'] as Map).containsKey('bytes'),
        isFalse,
        reason: 'original bytes live once in pending attachments',
      );
      expect(
        (((draft.data['attachments'] as Map)['items'] as List).single
            as Map)['name'],
        plan.file.name,
      );
      expect((draft.data['aiIntake'] as Map)['clientFields'], isEmpty);
      expect(tester.takeException(), isNull);
      if (kCaptureUi) {
        await tester.pump(const Duration(seconds: 6));
        await tester.pumpAndSettle();
        await capture(tester, 'guided-sales-page-wide');
      }
    },
  );

  testWidgets(
    'guided sale actual narrow page shows filled values and next step without rules',
    (tester) async {
      final plan = _guidedPlan();
      await _pumpEditor(
        tester,
        _Files(),
        type: SalesDocType.order,
        guidedPlan: plan,
        guidedJobs: _GuidedJobs(plan),
        guidedRunner: FakeAiJobRunner(result: _highResult()),
        width: 390,
        height: 1000,
      );
      expect(
        find.byKey(const ValueKey('ai-guided-file-progress')),
        findsOneWidget,
      );
      final l10n = AppLocalizations.of(
        tester.element(find.byKey(const ValueKey('ai-guided-file-progress'))),
      );
      expect(find.text(l10n.aiChatDocumentManualSave), findsOneWidget);
      expect(find.text(l10n.aiChatGuidedNoMasterWrites), findsNothing);
      expect(tester.takeException(), isNull);
      if (kCaptureUi) {
        await tester.pump(const Duration(seconds: 6));
        await tester.pumpAndSettle();
        await capture(tester, 'guided-sales-page-narrow');
      }
    },
  );

  testWidgets(
    'guided extra columns wait for review and never create reusable definitions',
    (tester) async {
      final result = _highResult()
        ..['extraColumns'] = [
          {'key': 'source-note', 'label': 'Source note', 'dataType': 'TEXT'},
        ];
      final plan = _guidedPlan();
      final files = _Files();
      final api = await _pumpEditor(
        tester,
        files,
        type: SalesDocType.order,
        guidedPlan: plan,
        guidedJobs: _GuidedJobs(plan),
        guidedRunner: FakeAiJobRunner(result: result),
      );
      expect(find.text('核对识别结果'), findsOneWidget);
      expect(api.writes, isEmpty);
      await tester.tap(find.byKey(const ValueKey('sales-intake-import-all')));
      await tester.pumpAndSettle();
      expect(api.writes, isEmpty);
      expect(files.uploads, isEmpty);
      final grid = tester.widget<UtenEditableGrid<SalesGridRow>>(
        find.byType(UtenEditableGrid<SalesGridRow>),
      );
      expect(grid.controller.rows.single.extraColumnSnapshots, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'guided review rechecks candidate access before writing any fields',
    (tester) async {
      final result = _highResult()
        ..['extraColumns'] = [
          {'key': 'note', 'label': 'Source note', 'dataType': 'TEXT'},
        ];
      final plan = _guidedPlan();
      final jobs = _GuidedJobs(plan);
      final files = _Files();
      final api = await _pumpEditor(
        tester,
        files,
        type: SalesDocType.order,
        guidedPlan: plan,
        guidedJobs: jobs,
        guidedRunner: FakeAiJobRunner(result: result),
      );
      expect(find.text('核对识别结果'), findsOneWidget);
      jobs.deniedJobId = 'job-42';
      jobs.failure = ApiException(
        'FORBIDDEN',
        'Candidate access revoked',
        httpStatus: 403,
      );
      await tester.tap(find.byKey(const ValueKey('sales-intake-import-all')));
      await tester.pumpAndSettle();
      expect(find.byType(UtenEditableGrid<SalesGridRow>), findsNothing);
      expect(find.textContaining('Candidate access revoked'), findsOneWidget);
      expect(api.writes, isEmpty);
      expect(files.uploads, isEmpty);
    },
  );

  for (final denied in ['route-source', 'job-42']) {
    testWidgets(
      'guided draft restore denies revoked $denied without showing cached customer or grid',
      (tester) async {
        final plan = _guidedPlan();
        final storage = MemoryFormDraftStorage();
        await _pumpEditor(
          tester,
          _Files(),
          type: SalesDocType.order,
          guidedPlan: plan,
          guidedJobs: _GuidedJobs(plan),
          guidedRunner: FakeAiJobRunner(result: _highResult()),
          storage: storage,
        );
        final container = ProviderScope.containerOf(
          tester.element(find.byType(SalesDocEditPage)),
          listen: false,
        );
        final draftId = container.read(formDraftsProvider).single.id;
        await tester.pumpWidget(const SizedBox());
        final jobs = _GuidedJobs(plan)
          ..deniedJobId = denied
          ..failure = ApiException(
            'FORBIDDEN',
            'Source access revoked',
            httpStatus: 403,
          );
        final api = await _pumpEditor(
          tester,
          _Files(),
          type: SalesDocType.order,
          guidedIdentity: plan.identity,
          guidedJobs: jobs,
          storage: storage,
          resumeId: draftId,
        );
        expect(find.byType(UtenEditableGrid<SalesGridRow>), findsNothing);
        expect(find.textContaining('尼日利亚SUNAS'), findsNothing);
        expect(find.text('Source access revoked'), findsOneWidget);
        expect(api.writes, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'new order shows the draft attachment area and lists picked files as pending',
    (tester) async {
      final picker = _Picker([
        PlatformFile(
          name: '销售合同.pdf',
          size: 6,
          bytes: Uint8List.fromList('%PDF-1'.codeUnits),
        ),
      ]);
      FilePicker.platform = picker;
      final files = _Files();
      await _pumpEditor(tester, files, type: SalesDocType.order);

      final draft = find.byKey(const ValueKey('sales-order-draft-attachments'));
      expect(draft, findsOneWidget);
      expect(find.byType(PendingAttachmentSection), findsOneWidget);
      expect(find.text('添加文件'), findsOneWidget);
      expect(find.text('上传'), findsNothing, reason: '没有 UUID 前不能即时上传');

      // 上传前不问分类：没有分类芯片，也没有那句暂存提示语。
      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.textContaining('保存单据后自动上传'), findsNothing);
      expect(find.textContaining('保存前可随时移除'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('pending-attachment-add')));
      await tester.pumpAndSettle();
      expect(picker.calls, 1);
      expect(find.text('销售合同.pdf'), findsOneWidget);
      expect(find.textContaining('待保存后上传'), findsOneWidget);
      expect(files.uploads, isEmpty, reason: '保存前绝不调用 presign/confirm');
      final section = tester.widget<BusinessAttachmentSection>(draft);
      expect(section.isDraft, isTrue);
      expect(section.draftController!.items.single.name, '销售合同.pdf');
      expect(section.draftController!.items.single.category, isNull);

      // 分类在文件旁边可选设置：点「＋分类」→ 选一个 → 只改这一行。
      await tester.tap(find.text('分类'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(CheckedPopupMenuItem<String>, '客户确认'),
      );
      await tester.pumpAndSettle();
      expect(section.draftController!.items.single.category, '客户确认');
      expect(files.uploads, isEmpty, reason: '设置分类不提前触发上传');
    },
  );

  testWidgets('new order without create permission has no draft area', (
    tester,
  ) async {
    await _pumpEditor(
      tester,
      _Files(),
      type: SalesDocType.order,
      permissions: const {Perm.attachmentUpload, Perm.attachmentView},
    );
    expect(
      find.byKey(const ValueKey('sales-order-draft-attachments')),
      findsOneWidget,
    );
    expect(find.text('添加文件'), findsNothing);
  });

  testWidgets('existing order keeps the live attachment area bound to its id', (
    tester,
  ) async {
    final files = _Files();
    await _pumpEditor(
      tester,
      files,
      type: SalesDocType.order,
      id: 'order-1',
      detail: const {
        'id': 'order-1',
        'billNo': 'XD202609100001',
        'billDate': '2026-09-10',
        'status': 0,
        'writable': true,
        'clientId': 'client-1',
        'currencyId': 'currency-usd',
        'settlementMethodId': 'settlement-net30',
        'taxRate': 13,
        'sellerId': 'seller-1',
        'deliverDate': '2026-09-20',
        'shipmentPolicy': 'ALLOW_PARTIAL',
        'items': <Map<String, dynamic>>[],
      },
    );
    expect(
      find.byKey(const ValueKey('sales-order-draft-attachments')),
      findsNothing,
    );
    final section = tester.widget<BusinessAttachmentSection>(
      find.byType(BusinessAttachmentSection),
    );
    expect(section.isDraft, isFalse);
    expect(section.ownerType, 'SALES_ORDER');
    expect(section.ownerId, 'order-1');
    expect(files.listed, [('SALES_ORDER', 'order-1')]);
  });

  for (final entry in [
    (
      SalesDocType.quote,
      Perm.salesQuoteCreate,
      Perm.salesQuoteEdit,
      Perm.salesQuoteView,
    ),
    (
      SalesDocType.shipment,
      Perm.salesShipmentCreate,
      Perm.salesShipmentEdit,
      Perm.salesShipmentView,
    ),
    (
      SalesDocType.customerShipment,
      Perm.salesOtherShipmentCreate,
      Perm.salesOtherShipmentEdit,
      Perm.salesOtherShipmentView,
    ),
    (
      SalesDocType.returnDoc,
      Perm.salesReturnCreate,
      Perm.salesReturnEdit,
      Perm.salesReturnView,
    ),
  ]) {
    testWidgets(
      '${entry.$1.name} supports pending files with its own document permissions',
      (tester) async {
        final files = _Files();
        await _pumpEditor(
          tester,
          files,
          type: entry.$1,
          permissions: {
            Perm.attachmentView,
            Perm.attachmentUpload,
            entry.$2,
            entry.$3,
            entry.$4,
            Perm.salesOrderPriceView,
          },
        );
        final section = tester.widget<BusinessAttachmentSection>(
          find.byType(BusinessAttachmentSection),
        );
        expect(section.isDraft, isTrue);
        expect(find.text('添加文件'), findsOneWidget);
        expect(files.uploads, isEmpty);
        if (entry.$1 == SalesDocType.shipment ||
            entry.$1 == SalesDocType.returnDoc) {
          final grid = tester.widget<UtenEditableGrid<SalesGridRow>>(
            find.byType(UtenEditableGrid<SalesGridRow>),
          );
          expect(
            grid.toolbarActions.whereType<UtenImportButton>(),
            hasLength(1),
          );
        }
      },
    );
  }

  testWidgets('historical other shipments retain their read-only scope', (
    tester,
  ) async {
    await _pumpEditor(tester, _Files(), type: SalesDocType.otherShipment);
    expect(find.byType(BusinessAttachmentSection), findsNothing);
  });
}

Future<_EditorApi> _pumpEditor(
  WidgetTester tester,
  _Files files, {
  required SalesDocType type,
  String? id,
  Map<String, dynamic>? detail,
  AiGuidedFilePlan? guidedPlan,
  AiGuidedFileIdentity? guidedIdentity,
  _GuidedJobs? guidedJobs,
  FakeAiJobRunner? guidedRunner,
  MemoryFormDraftStorage? storage,
  String? resumeId,
  void Function(GoRouterState)? onQuoteOpened,
  bool renderQuoteHandoff = false,
  double width = 1600,
  double height = 1400,
  Set<String> permissions = const {
    Perm.attachmentView,
    Perm.attachmentUpload,
    Perm.attachmentDelete,
    Perm.salesOrderCreate,
    Perm.salesOrderEdit,
    Perm.salesOrderView,
    Perm.salesOrderPriceView,
  },
}) async {
  await tester.binding.setSurfaceSize(Size(width, height));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  if (kCaptureUi) await setCaptureView(tester, Size(width, height));
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final api = _EditorApi(detail);
  final identity = guidedPlan?.identity ?? guidedIdentity;
  final progress = FakeProgressPresenter();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        attachmentServiceProvider.overrideWithValue(files),
        currentPermissionsProvider.overrideWithValue(permissions),
        sharedPreferencesProvider.overrideWithValue(preferences),
        salesMasterNameServiceProvider.overrideWithValue(
          SalesMasterNameService(api),
        ),
        if (identity == null)
          sessionProvider.overrideWith(_TestSessionNotifier.new),
        if (identity != null) ...[
          sessionProvider.overrideWith(_GuidedSession.new),
          apiBaseUrlProvider.overrideWithValue(identity.server),
          aiGuidedFileIdentityProvider.overrideWithValue(identity),
          formDraftStorageProvider.overrideWithValue(
            storage ?? MemoryFormDraftStorage(),
          ),
        ],
        if (guidedJobs != null)
          aiJobRepositoryProvider.overrideWithValue(guidedJobs),
        if (guidedRunner != null) ...[
          aiJobRunnerProvider.overrideWithValue(guidedRunner),
          salesIntakeProgressPresenterProvider.overrideWithValue(
            presenterOf(progress),
          ),
        ],
      ],
      child: RepaintBoundary(
        key: kCaptureUi ? captureBoundary : null,
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          theme: kCaptureUi ? captureTheme() : null,
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: GoRouter(
            initialLocation: identity == null
                ? '/edit'
                : '/sales/orders/new${resumeId == null ? '' : '?draftId=$resumeId'}',
            routes: [
              GoRoute(
                path: '/edit',
                builder: (_, _) => SalesDocEditPage(docType: type, id: id),
              ),
              GoRoute(
                path: '/sales/orders/new',
                builder: (_, _) => SalesDocEditPage(
                  docType: type,
                  initialGuidedPlan: guidedPlan,
                ),
              ),
              GoRoute(
                path: '/sales/quotes/new',
                builder: (_, state) {
                  onQuoteOpened?.call(state);
                  if (renderQuoteHandoff) {
                    return SalesDocEditPage(
                      docType: SalesDocType.quote,
                      initialGuidedPlan: state.extra is AiGuidedFilePlan
                          ? state.extra as AiGuidedFilePlan
                          : null,
                      initialAiJobId: state.uri.queryParameters['aiJobId'],
                      initialAiFile: state.extra is PlatformFile
                          ? state.extra as PlatformFile
                          : null,
                    );
                  }
                  return const Scaffold(body: Text('Quote handoff'));
                },
              ),
              GoRoute(
                path: '/:rest(.*)',
                builder: (_, _) => const SizedBox.shrink(),
              ),
            ],
          ),
          builder: (context, child) => Stack(
            children: [
              Positioned.fill(child: child!),
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: AppNotificationHost(),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

class _TestSessionNotifier extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _GuidedSession extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'guide-user',
      employeeId: 'guide-employee',
      code: 'G001',
      name: 'Guide user',
      permissions: [
        Perm.attachmentView,
        Perm.attachmentUpload,
        Perm.attachmentDelete,
        Perm.salesOrderCreate,
        Perm.salesOrderEdit,
        Perm.salesOrderView,
        Perm.salesOrderPriceView,
      ],
    ),
  );
}

AiGuidedFilePlan _guidedPlan({bool quoteAccess = false}) {
  final file = fakeFile('guided-order.xlsx');
  final permissions = {
    Perm.attachmentView,
    Perm.attachmentUpload,
    Perm.attachmentDelete,
    Perm.salesOrderCreate,
    Perm.salesOrderEdit,
    Perm.salesOrderView,
    Perm.salesOrderPriceView,
    if (quoteAccess) ...[Perm.salesQuoteView, Perm.salesQuoteCreate],
  }.toList()..sort();
  return AiGuidedFilePlan(
    jobId: 'route-source',
    file: file,
    workflow: AiGuidedWorkflow.salesOrder,
    identity: (
      scope: const AuthenticatedScope(userId: 'guide-user'),
      server: 'https://guided.invalid/api',
      permissions: permissions.join('\n'),
    ),
    result: AiGuidedFileResult.fromJson({
      'workflow': 'SALES_ORDER',
      'documentType': 'SALES_ORDER',
      'needsChoice': false,
      'title': 'Prepare order',
      'summary': 'Fill a local form',
      'requiresReview': true,
      'source': {
        'fileName': file.name,
        'sha256': sha256.convert(file.bytes!).toString(),
      },
    }),
  );
}

Map<String, dynamic> _highResult() {
  final data = intakeResultJson();
  data['lines'] = [(data['lines'] as List<dynamic>).first];
  data['duplicates'] = <Object>[];
  data['notices'] = <Object>[];
  data['extraColumns'] = <Object>[];
  (data['file'] as Map<String, dynamic>)['otherSheets'] = <Object>[];
  return data;
}

class _GuidedJobs implements AiJobRepository {
  _GuidedJobs(this.plan);
  final AiGuidedFilePlan plan;
  final reads = <String>[];
  final routed = <String, AiJobSnapshot>{};
  Object? failure;
  String? deniedJobId;
  @override
  Future<AiJobSnapshot> get(String jobId) async {
    reads.add(jobId);
    if (failure != null && (deniedJobId == null || deniedJobId == jobId)) {
      throw failure!;
    }
    if (routed[jobId] case final snapshot?) return snapshot;
    return AiJobSnapshot(
      id: jobId,
      kind: jobId == plan.jobId ? aiGuidedRouteKind : 'SALES_DOCUMENT_INTAKE',
      status: AiJobStatus.succeeded,
      result: jobId == plan.jobId ? plan.result.toJson() : _highResult(),
    );
  }

  @override
  Future<void> cancel(String jobId) async {}
  @override
  Future<AiJobSnapshot> submit(AiJobRequest request) async =>
      throw StateError('No automatic business submission');
}

class _HandoffRunner extends FakeAiJobRunner {
  _HandoffRunner(this.jobs, Map<String, dynamic> result)
    : super(result: result);
  final _GuidedJobs jobs;
  @override
  Future<AiJobSnapshot> run(
    AiJobRequest request, {
    AiJobProgressCallback? onProgress,
    AiJobCancelToken? cancelToken,
  }) async {
    if (request.kind != aiGuidedRouteKind) {
      return super.run(
        request,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );
    }
    requests.add(request);
    final snapshot = AiJobSnapshot(
      id: 'route-quote',
      kind: aiGuidedRouteKind,
      status: AiJobStatus.succeeded,
      result: {...jobs.plan.result.toJson(), 'workflow': 'SALES_QUOTE'},
    );
    jobs.routed[snapshot.id] = snapshot;
    return snapshot;
  }
}

class _EditorApi extends ApiClient {
  _EditorApi(this.detail) : super(Dio());

  final Map<String, dynamic>? detail;
  final writes = <String>[];
  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    writes.add(path);
    throw StateError('Unexpected business write: $path');
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (detail != null && path.endsWith('/${detail!['id']}')) {
      return detail!;
    }
    return const {
      'items': <Map<String, dynamic>>[],
      'page': 1,
      'size': 1,
      'total': 0,
      'totalPages': 0,
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [];
}

class _Files extends AttachmentService {
  _Files() : super(ApiClient(Dio()));
  final listed = <(String type, String id)>[];
  final uploads = <String>[];

  @override
  Future<List<Attachment>> list({
    required String ownerType,
    required String ownerId,
  }) async {
    listed.add((ownerType, ownerId));
    return const [];
  }

  @override
  Future<Attachment> upload({
    required String ownerType,
    required String ownerId,
    required String fileName,
    required String contentType,
    required Uint8List bytes,
    String? category,
  }) async {
    uploads.add('$ownerType/$ownerId/$fileName');
    throw StateError('not expected during this test');
  }
}

class _Picker extends FilePicker {
  _Picker(this.files);
  final List<PlatformFile> files;
  int calls = 0;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    void Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    calls++;
    return FilePickerResult(files);
  }
}
