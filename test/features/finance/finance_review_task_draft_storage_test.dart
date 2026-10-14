import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/finance/pages/finance_sales_order_review_page.dart';
import 'package:uten_imp/features/finance/pages/finance_procurement_approval_review_page.dart';
import 'package:uten_imp/features/finance/pages/finance_quote_review_page.dart';
import 'package:uten_imp/features/finance/pages/finance_sales_shipment_audit_review_page.dart';
import 'package:uten_imp/shared/drafts/review_task_draft.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_storage_native.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/repositories/task_claim_repository.dart';

import '../../helpers/finance_claim_fixture.dart';
import '../../support/native_detail_reader_overrides.dart';

enum _Review { sales, procurement, quote, shipment }

class _Fixture {
  _Fixture(this.kind);
  final _Review kind;
  int version = 3;
  bool committed = false;
  int businessPosts = 0;
  int reviewsRead = 0;
  Map<String, dynamic> submittedBody = {};
  String? mismatchedShipmentRate;
  bool viewOnly = false;
  late final Directory directory;
  late final SharedPreferences preferences;
  late final ApiClient api;
  Completer<FormDraft>? submissionJournalFlushed;
  Completer<void>? _submissionJournalRelease;
  int journalFlushes = 0;
  final journalObservations = <Map<String, Object?>>[];

  void holdSubmissionJournal() {
    submissionJournalFlushed = Completer<FormDraft>();
    _submissionJournalRelease = Completer<void>();
  }

  void releaseSubmissionJournal() {
    final release = _submissionJournalRelease;
    if (release != null && !release.isCompleted) release.complete();
  }

  NativeFormDraftStorage storage() => NativeFormDraftStorage(
    directoryProvider: () async => directory,
    afterJournalFlush: () async {
      journalFlushes++;
      final flushed = submissionJournalFlushed;
      final release = _submissionJournalRelease;
      if (flushed == null || release == null || flushed.isCompleted) return;
      await for (final entity in directory.list(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('pending.json')) continue;
        final journal = jsonDecode(await entity.readAsString()) as Map;
        final payload = journal['payload'];
        if (payload is! String) continue;
        final draft = FormDraft.fromJson(
          Map<String, dynamic>.from(jsonDecode(payload) as Map),
        );
        final command = draft.data['command'];
        journalObservations.add({
          'route': draft.route,
          'unknown': draft.hasUnknownSubmission,
          'action': command is Map ? command['action'] : null,
        });
        final location = Uri.parse(draft.route);
        if (location.path != route ||
            location.queryParameters.isNotEmpty ||
            !draft.hasUnknownSubmission ||
            command is! Map ||
            command['action'] != 'approve') {
          continue;
        }
        flushed.complete(draft);
        await release.future;
        return;
      }
    },
  );

  String submissionDiagnostics(ProviderContainer container) {
    final drafts = container.read(formDraftsProvider);
    return 'kind=${kind.name}, posts=$businessPosts, reads=$reviewsRead, '
        'journalFlushed=${submissionJournalFlushed?.isCompleted}, '
        'flushes=$journalFlushes, observed=$journalObservations, '
        'drafts=${drafts.length}, unknown=${drafts.map((draft) => draft.hasUnknownSubmission).toList()}';
  }

  Future<void> waitForUnknownSubmission(
    WidgetTester tester,
    ProviderContainer container,
  ) async {
    await _waitForState(
      tester,
      () {
        final drafts = container.read(formDraftsProvider);
        return businessPosts == 1 &&
            drafts.length == 1 &&
            drafts.single.hasUnknownSubmission &&
            !editor(tester).formDraftBusy;
      },
      phase: 'one POST, its unknown native checkpoint, and an idle editor',
      diagnostics: () => submissionDiagnostics(container),
    );
    final prefix = container.read(formDraftsProvider.notifier).ownerKey!;
    final stored = await tester.runAsync(
      () => NativeFormDraftStorage(
        directoryProvider: () async => directory,
      ).readAll(prefix).timeout(const Duration(seconds: 10)),
    );
    final durable = FormDraft.fromJson(
      Map<String, dynamic>.from(jsonDecode(stored!.values.single) as Map),
    );
    expect(durable.id, container.read(formDraftsProvider).single.id);
    expect(durable.hasUnknownSubmission, isTrue);
    expect(durable.data['command'], isA<Map<String, dynamic>>());
  }

  String get id => '${kind.name}-subject';
  String get route =>
      '/finance/${switch (kind) {
        _Review.sales => 'sales-order-confirmations',
        _Review.procurement => 'procurement-approvals',
        _Review.quote => 'quote-review',
        _Review.shipment => 'sales-shipment-audits',
      }}/$id';
  String get inputKey => switch (kind) {
    _Review.sales => 'finance-review-confirm-remark',
    _Review.procurement => 'finance-order-review-rate-field',
    _Review.quote => 'quote-finance-deal-line',
    _Review.shipment => 'finance-audit-exchange-rate',
  };
  String get approveKey => switch (kind) {
    _Review.sales => 'finance-review-confirm',
    _Review.procurement => 'finance-order-review-approve',
    _Review.quote => 'quote-finance-confirm',
    _Review.shipment => 'finance-shipment-audit-approve',
  };
  String get confirmKey => switch (kind) {
    _Review.sales => 'finance-review-confirm-submit',
    _Review.procurement => 'finance-order-review-approve-submit',
    _Review.quote => 'quote-finance-confirm-submit',
    _Review.shipment => 'finance-shipment-audit-confirm',
  };
  FormDraftDescriptor get descriptor => switch (kind) {
    _Review.sales => FormDraftCatalog.financeSalesOrderReview,
    _Review.procurement => FormDraftCatalog.financeProcurementReview,
    _Review.quote => FormDraftCatalog.financeQuoteReview,
    _Review.shipment => FormDraftCatalog.financeShipmentReview,
  };

  Future<void> initialize() async {
    directory = await Directory.systemTemp.createTemp('uten_finance_review_');
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          final terminal =
              request.method == 'POST' &&
              (request.path.endsWith('/finance-confirmation') ||
                  request.path.endsWith('/batch-approve') ||
                  request.path.endsWith('/finance-confirm') ||
                  request.path.endsWith('/finance-audit'));
          if (terminal) {
            businessPosts++;
            committed = true;
            submittedBody = request.data is Map
                ? Map<String, dynamic>.from(request.data as Map)
                : {};
            handler.reject(
              DioException(
                requestOptions: request,
                type: DioExceptionType.connectionError,
                error: const SocketException('lost decision acknowledgement'),
              ),
            );
            return;
          }
          handler.resolve(
            Response(
              requestOptions: request,
              statusCode: 200,
              data: _response(request.path),
            ),
          );
        },
      ),
    );
    api = ApiClient(dio);
  }

  Object _response(String path) {
    if (path.endsWith('/finance-confirmation/review')) {
      reviewsRead++;
      return {
        'orderId': id,
        'billNo': 'SO1',
        'financeReviewRevision': version,
        'financeConfirmed': committed,
        'financeConfirmedAt': committed ? '2026-10-11T12:00:00Z' : null,
        if (committed) 'financeConfirmRemark': submittedBody['remark'],
        'items': [
          {
            'itemId': 'line',
            'lineNo': 1,
            'qty': '2',
            'price': '80',
            'discount': '1',
            'amountOriginal': '160',
          },
        ],
      };
    }
    if (path.contains('/procurement-approvals/') && path.endsWith('/review')) {
      reviewsRead++;
      return {
        'caseId': id,
        'orderId': 'purchase-order',
        'orderType': 'PURCHASE',
        'billNo': 'PO1',
        'status': committed ? 'APPROVED' : 'PENDING',
        'attempt': 1,
        'version': committed ? version + 1 : version,
        'allowedActions': committed || viewOnly
            ? <String>[]
            : ['EDIT', 'APPROVE', 'REJECT'],
        'exchangeRate': '1',
        if (committed)
          'financeExchangeRate': submittedBody['exchangeRate']?.toString(),
        'items': [
          {
            'orderItemId': 'line',
            'lineNo': 1,
            'qty': '2',
            'price': '80',
            'amountOriginal': '160',
          },
        ],
        'history': committed
            ? [
                {
                  'attempt': 1,
                  'eventType': 'APPROVED',
                  'reason': submittedBody['remark'],
                },
              ]
            : <Map<String, dynamic>>[],
      };
    }
    if (path.endsWith('/finance-review')) {
      reviewsRead++;
      return {
        'id': id,
        'quoteId': id,
        'billNo': 'QT1',
        'status': committed ? 1 : 2,
        'reviewRevision': committed ? version + 1 : version,
        'financeActions': viewOnly
            ? <String>[]
            : committed
            ? ['reopen']
            : ['edit', 'return', 'confirm'],
        'financeConfirmedAt': committed ? '2026-10-11T12:00:00Z' : null,
        'validUntil': '2026-11-01',
        'financeRemark': '',
        'totalOriginal': '160',
        'lines': [
          {
            'itemId': 'line',
            'lineNo': 1,
            'qty': '2',
            'listPrice': '80',
            'currentMasterPrice': '80',
            'dealPrice': '80',
            'discount': '1',
            'priceSource': 'MASTER',
            'amount': '160',
          },
        ],
        'revisions': committed
            ? [
                {'action': 'CONFIRM', 'revision': version + 1},
              ]
            : <Map<String, dynamic>>[],
      };
    }
    if (path.endsWith('/finance-audit-info')) {
      reviewsRead++;
      return {
        'shipmentId': id,
        'reviewRevision': version,
        'contentHash': 'commercial-$version',
        'financeAudit': committed ? 1 : 0,
        'allowedActions': committed || viewOnly
            ? <String>[]
            : ['APPROVE', 'REJECT'],
        'suggestedExchangeRate': '1',
        'financeRateReady': true,
        if (committed)
          'shipmentExchangeRate':
              mismatchedShipmentRate ??
              submittedBody['exchangeRate']?.toString(),
        'baseCurrency': false,
        'billingMode': 'BILLABLE',
      };
    }
    if (path == '/sales/shipments/$id') {
      return {
        'id': id,
        'billNo': 'SP1',
        'status': 0,
        'financeAudit': committed ? 1 : 0,
        'financeAuditedAt': committed ? '2026-10-11T12:00:00Z' : null,
        'warehouseWorkStatus': 'PENDING_PICK',
        'salesConfirmed': true,
        'financeReviewPending': !committed,
        'items': [
          {'id': 'line', 'qty': 2, 'price': 80, 'amountOriginal': 160},
        ],
      };
    }
    return {'items': <Object>[]};
  }

  Widget get page => switch (kind) {
    _Review.sales => FinanceSalesOrderReviewPage(id: id),
    _Review.procurement => FinanceProcurementApprovalReviewPage(caseId: id),
    _Review.quote => FinanceQuoteReviewPage(id: id),
    _Review.shipment => FinanceSalesShipmentAuditReviewPage(id: id),
  };

  Future<ProviderContainer> mount(
    WidgetTester tester, {
    String? location,
  }) async {
    final router = GoRouter(
      initialLocation: location ?? route,
      routes: [
        GoRoute(path: route, builder: (_, _) => page),
        GoRoute(
          path: '/${Uri.parse(route).pathSegments.take(2).join('/')}',
          builder: (_, _) => const Scaffold(body: Text('review queue')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...nativeDetailReaderOverrides(),
          sharedPreferencesProvider.overrideWithValue(preferences),
          apiClientProvider.overrideWithValue(api),
          formDraftStorageProvider.overrideWithValue(storage()),
          isSuperAdminProvider.overrideWithValue(false),
          currentPermissionsProvider.overrideWithValue({
            Perm.salesOrderFinanceView,
            if (!viewOnly) Perm.salesOrderFinanceConfirm,
            Perm.financeOrderApprovalView,
            if (!viewOnly) Perm.financeOrderApprovalApprove,
            if (!viewOnly) Perm.financeOrderApprovalReject,
            Perm.salesQuoteFinanceView,
            if (!viewOnly) Perm.salesQuoteFinanceConfirm,
            Perm.salesShipmentFinanceView,
            if (!viewOnly) Perm.salesShipmentFinanceApprove,
            if (!viewOnly) Perm.salesShipmentFinanceReject,
          }),
          taskClaimRepositoryProvider.overrideWithValue(FinanceClaimFixture()),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
        ),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(page.runtimeType)),
    );
    final reviewEditor =
        editor(tester) as ReviewTaskDraftMixin<ConsumerStatefulWidget>;
    await _waitForState(
      tester,
      () =>
          reviewEditor.reviewDraftSource['subjectId'] == id &&
          reviewEditor.reviewDraftSource['version'] != null,
      phase: 'the loaded review source before editing',
      diagnostics: () =>
          '${submissionDiagnostics(container)}, '
          'source=${reviewEditor.reviewDraftSource}',
    );
    final storageReady = container.read(formDraftsProvider.notifier).ready;
    var storageFinished = false;
    Object? storageError;
    StackTrace? storageStack;
    unawaited(
      storageReady.then<void>(
        (_) => storageFinished = true,
        onError: (Object error, StackTrace stack) {
          storageError = error;
          storageStack = stack;
          storageFinished = true;
        },
      ),
    );
    // The native future also resumes fake-zone microtasks. Keep pumping while
    // waiting instead of suspending the entire test inside runAsync.
    await _waitForState(
      tester,
      () => storageFinished,
      phase: 'the current native storage notifier to finish loading',
      diagnostics: () => submissionDiagnostics(container),
    );
    if (storageError != null) {
      Error.throwWithStackTrace(storageError!, storageStack!);
    }
    await storageReady;
    // Source details become visible before the native draft binding finishes.
    // Build the restoration layer before checking that it has really retired.
    await tester.pump();
    final resumeId = Uri.parse(location ?? route).queryParameters['draftId'];
    await _waitForState(
      tester,
      () =>
          find.text('正在准备草稿保护…').evaluate().isEmpty &&
          (resumeId == null ||
              reviewEditor.formDraftRecoveryId == resumeId ||
              reviewEditor.formDraftRestorationBlocked),
      phase: 'native draft binding and its restoration layer to finish',
      diagnostics: () =>
          '${submissionDiagnostics(container)}, '
          'resume=$resumeId, bound=${reviewEditor.formDraftRecoveryId}, '
          'restorationBlocked=${reviewEditor.formDraftRestorationBlocked}',
    );
    return container;
  }

  FormDraftMixin<ConsumerStatefulWidget> editor(WidgetTester tester) =>
      tester.state(find.byType(page.runtimeType))
          as FormDraftMixin<ConsumerStatefulWidget>;
  String rawInput(WidgetTester tester) {
    final data =
        (tester.state(find.byType(page.runtimeType))
                as ReviewTaskDraftMixin<ConsumerStatefulWidget>)
            .captureReviewInputs();
    return switch (kind) {
      _Review.sales => data['confirmRemark'] as String,
      _Review.procurement => data['rate'] as String,
      _Review.quote =>
        ((data['lines'] as Map)['line'] as Map)['deal'] as String,
      _Review.shipment => data['rate'] as String,
    };
  }

  Future<TextField> inputField(WidgetTester tester) async {
    if (kind == _Review.sales) {
      await tester.runAsync(() => tester.tap(find.byKey(ValueKey(approveKey))));
      await _settle(tester);
    }
    return tester.widget<TextField>(find.byKey(ValueKey(inputKey)));
  }

  Future<void> removeStorage() async {
    if (!directory.absolute.path.startsWith(
          '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}',
        ) ||
        !directory.path.contains('uten_finance_review_')) {
      throw StateError('Unexpected test storage path');
    }
    await directory.delete(recursive: true);
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var index = 0; index < 80; index++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> _waitForState(
  WidgetTester tester,
  bool Function() ready, {
  required String phase,
  required String Function() diagnostics,
}) async {
  final elapsed = Stopwatch()..start();
  while (!ready()) {
    if (elapsed.elapsed > const Duration(seconds: 10)) {
      fail('Timed out waiting for $phase: ${diagnostics()}');
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  testWidgets(
    'shipment different confirmed exchange rate preserves the original native checkpoint',
    (tester) async {
      tester.view.physicalSize = const Size(2600, 1700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = _Fixture(_Review.shipment);
      await tester.runAsync(fixture.initialize);
      addTearDown(() => tester.runAsync(fixture.removeStorage));
      final container = await fixture.mount(tester);
      await tester.runAsync(
        () => tester.tap(find.byKey(ValueKey(fixture.approveKey))),
      );
      await _settle(tester);
      await tester.runAsync(
        () => tester.tap(find.byKey(ValueKey(fixture.confirmKey))),
      );
      await fixture.waitForUnknownSubmission(tester, container);
      expect(fixture.businessPosts, 1);
      final draft = container.read(formDraftsProvider).single;
      fixture.mismatchedShipmentRate = '2';
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      final reopened = await fixture.mount(
        tester,
        location: draft.resumeLocation,
      );
      final before = fixture.reviewsRead;
      await tester.runAsync(
        () => tester.tap(
          find.byKey(const Key('review-task-draft-read-recovery')),
        ),
      );
      await _settle(tester);
      expect(fixture.reviewsRead, greaterThan(before));
      expect(fixture.businessPosts, 1);
      expect(reopened.read(formDraftsProvider).single.id, draft.id);
      expect(
        reopened.read(formDraftsProvider).single.hasUnknownSubmission,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );
  for (final kind in _Review.values) {
    testWidgets(
      '${kind.name} revoked edit authority retains native read recovery for the same owner',
      (tester) async {
        tester.view.physicalSize = const Size(2600, 1700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final fixture = _Fixture(kind);
        await tester.runAsync(fixture.initialize);
        addTearDown(() => tester.runAsync(fixture.removeStorage));
        final container = await fixture.mount(tester);
        await tester.runAsync(
          () => tester.tap(find.byKey(ValueKey(fixture.approveKey))),
        );
        await _settle(tester);
        await tester.runAsync(
          () => tester.tap(find.byKey(ValueKey(fixture.confirmKey))),
        );
        await fixture.waitForUnknownSubmission(tester, container);
        expect(fixture.businessPosts, 1);
        final draft = container.read(formDraftsProvider).single;
        fixture.viewOnly = true;
        await tester.pumpWidget(const SizedBox.shrink());
        await _settle(tester);
        final reopened = await fixture.mount(
          tester,
          location: draft.resumeLocation,
        );
        final before = fixture.reviewsRead;
        expect(find.byKey(ValueKey(fixture.approveKey)), findsNothing);
        await tester.runAsync(
          () => tester.tap(
            find.byKey(const Key('review-task-draft-read-recovery')),
          ),
        );
        await _waitForState(
          tester,
          () =>
              fixture.reviewsRead > before &&
              reopened.read(formDraftsProvider).isEmpty &&
              find.text('review queue').evaluate().length == 1,
          phase: 'the GET-confirmed outcome to retire the native draft',
          diagnostics: () => fixture.submissionDiagnostics(reopened),
        );
        expect(fixture.reviewsRead, greaterThan(before));
        expect(fixture.businessPosts, 1);
        expect(reopened.read(formDraftsProvider), isEmpty);
        expect(find.text('review queue'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      '${kind.name} raw review input survives native storage and a fresh editor',
      (tester) async {
        tester.view.physicalSize = const Size(2600, 1700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final fixture = _Fixture(kind);
        await tester.runAsync(fixture.initialize);
        addTearDown(() => tester.runAsync(fixture.removeStorage));
        final container = await fixture.mount(tester);
        final field = await fixture.inputField(tester);
        await tester.runAsync(() async {
          field.controller!.text = '7.';
          field.onChanged?.call('7.');
          await fixture.editor(tester).saveFormDraftNow();
        });
        final draft = container.read(formDraftsProvider).single;
        expect(reviewTaskDraftsFor([draft], fixture.descriptor, fixture.id), [
          draft,
        ]);
        expect(
          reviewTaskDraftsFor([draft], fixture.descriptor, 'other-subject'),
          isEmpty,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await _settle(tester);
        await fixture.mount(tester, location: draft.resumeLocation);
        expect(fixture.rawInput(tester), '7.');
        expect(fixture.businessPosts, 0);
      },
    );

    testWidgets(
      '${kind.name} changed source version preserves native input and blocks reapplication',
      (tester) async {
        tester.view.physicalSize = const Size(2600, 1700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final fixture = _Fixture(kind);
        await tester.runAsync(fixture.initialize);
        addTearDown(() => tester.runAsync(fixture.removeStorage));
        final container = await fixture.mount(tester);
        final field = await fixture.inputField(tester);
        await tester.runAsync(() async {
          field.controller!.text = '7.';
          field.onChanged?.call('7.');
          await fixture.editor(tester).saveFormDraftNow();
        });
        final draft = container.read(formDraftsProvider).single;
        await tester.pumpWidget(const SizedBox.shrink());
        await _settle(tester);
        fixture.version++;
        final reopened = await fixture.mount(
          tester,
          location: draft.resumeLocation,
        );
        expect(fixture.rawInput(tester), isNot('7.'));
        expect(fixture.editor(tester).formDraftRestorationBlocked, isTrue);
        expect(reopened.read(formDraftsProvider).single.id, draft.id);
        expect(fixture.businessPosts, 0);
      },
    );

    testWidgets(
      '${kind.name} lost acknowledgement recovers the exact reviewed outcome with GET and no replay',
      (tester) async {
        tester.view.physicalSize = const Size(2600, 1700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final fixture = _Fixture(kind);
        await tester.runAsync(fixture.initialize);
        addTearDown(() => tester.runAsync(fixture.removeStorage));
        final container = await fixture.mount(tester);
        await tester.runAsync(
          () => tester.tap(find.byKey(ValueKey(fixture.approveKey))),
        );
        await _settle(tester);
        if (kind == _Review.shipment) {
          fixture.holdSubmissionJournal();
          addTearDown(fixture.releaseSubmissionJournal);
        }
        await tester.runAsync(
          () => tester.tap(find.byKey(ValueKey(fixture.confirmKey))),
        );
        if (kind == _Review.shipment) {
          await _waitForState(
            tester,
            () => fixture.submissionJournalFlushed!.isCompleted,
            phase: 'the real native pre-submit journal to flush',
            diagnostics: () => fixture.submissionDiagnostics(container),
          );
        }
        FormDraft? flushed;
        if (kind == _Review.shipment) {
          try {
            // A flushed journal is durable, but the real native transaction is
            // intentionally unfinished. The old fixed settling window cannot
            // prove that this safe pre-submit boundary has completed.
            await _settle(tester);
            flushed = await fixture.submissionJournalFlushed!.future;
            expect(fixture.businessPosts, 0);
            expect(fixture.editor(tester).formDraftBusy, isTrue);
            expect(flushed.hasUnknownSubmission, isTrue);
            expect(flushed.data['command'], {
              'action': 'approve',
              'source': {
                'subjectId': fixture.id,
                'version': fixture.version,
                'contentHash': 'commercial-${fixture.version}',
                'lineIds': ['line'],
              },
              'request': {'exchangeRate': '1'},
            });
          } finally {
            fixture.releaseSubmissionJournal();
            await fixture.waitForUnknownSubmission(tester, container);
          }
        } else {
          await fixture.waitForUnknownSubmission(tester, container);
        }
        expect(fixture.businessPosts, 1);
        final draft = container.read(formDraftsProvider).single;
        if (flushed != null) expect(draft.id, flushed.id);
        expect(draft.hasUnknownSubmission, isTrue);
        await tester.pumpWidget(const SizedBox.shrink());
        await _settle(tester);
        final reopened = await fixture.mount(
          tester,
          location: draft.resumeLocation,
        );
        await _waitForState(
          tester,
          () =>
              reopened
                  .read(formDraftsProvider)
                  .any(
                    (row) => row.id == draft.id && row.hasUnknownSubmission,
                  ) &&
              find
                  .byKey(const Key('review-task-draft-read-recovery'))
                  .evaluate()
                  .isNotEmpty,
          phase: 'the reopened editor to expose the original native checkpoint',
          diagnostics: () => fixture.submissionDiagnostics(reopened),
        );
        final readBefore = fixture.reviewsRead;
        await tester.runAsync(
          () => tester.tap(
            find.byKey(const Key('review-task-draft-read-recovery')),
          ),
        );
        await _waitForState(
          tester,
          () =>
              fixture.reviewsRead > readBefore &&
              reopened.read(formDraftsProvider).isEmpty &&
              find.text('review queue').evaluate().length == 1,
          phase:
              'GET recovery and durable checkpoint completion without replay',
          diagnostics: () => fixture.submissionDiagnostics(reopened),
        );
        expect(fixture.reviewsRead, greaterThan(readBefore));
        expect(fixture.businessPosts, 1);
        expect(reopened.read(formDraftsProvider), isEmpty);
        expect(find.text('review queue'), findsOneWidget);
      },
    );
  }
}
