import '../../support/audit_screenshot_support.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/business_precision.dart';
import 'package:uten_imp/core/network/business_precision_coordinator.dart';
import 'package:uten_imp/features/finance/config/finance_doc_config.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/finance/shared/finance_document_intent.dart';
import 'package:uten_imp/features/finance/widgets/finance_document_review_command.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import '../../support/finance_command_test_support.dart';
import '../../shared/drafts/memory_form_draft_storage.dart';

const _doc = '00000000-0000-0000-0000-000000000201';
final _token = List.filled(64, 'a').join();
Map<String, dynamic> _source(FinanceDocType type) => {
  'id': _doc,
  'billNo': '原财务单据',
  'status': 0,
  'approvalVersion':
      type == FinanceDocType.receipt || type == FinanceDocType.payment
      ? 7
      : null,
  'approvalSnapshot': _token,
  'items': <Object>[],
  'approvalPlatformFields': {
    _scope(type): [
      {'recordId': _doc, 'cells': <Object>[]},
    ],
    '${_scope(type)}_item': <Object>[],
  },
};
String _scope(FinanceDocType type) => switch (type) {
  FinanceDocType.receipt => 'finance_receipt',
  FinanceDocType.payment => 'finance_payment',
  FinanceDocType.expense => 'finance_expense',
  FinanceDocType.otherIncome => 'finance_other_income',
  FinanceDocType.bankTransfer => 'finance_bank_transfer',
};

class _Adapter implements HttpClientAdapter {
  final writes =
      <
        ({String path, Map<String, dynamic> body, Map<String, dynamic> choices})
      >[];
  final receipts = <String, Map<String, dynamic>>{};
  bool lose = true, requirePrecision = true, reject = false, loseCancel = false;
  final cancellations = <Map<String, dynamic>>[];
  Map<String, dynamic> choices(RequestOptions o) {
    final h = o.headers[businessPrecisionHeader];
    return h is String
        ? Map<String, dynamic>.from(
            (jsonDecode(utf8.decode(base64Url.decode(h))) as Map)['choices']
                as Map,
          )
        : {};
  }

  ResponseBody json(Object? body, [int status = 200]) =>
      ResponseBody.fromString(
        jsonEncode(body),
        status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
  Map<String, dynamic> receipt(
    String path,
    Map<String, dynamic> body,
    Map<String, dynamic> policy, {
    bool cancelled = false,
  }) => {
    'found': true,
    'requestId': body['requestId'],
    'actorId': financeCommandTestActor,
    'operation': path.endsWith('unapprove')
        ? 'FINANCE_DOCUMENT_UNAPPROVE'
        : 'FINANCE_DOCUMENT_APPROVE',
    'method': 'POST',
    'path': path,
    'requestBody': body,
    'outcome': cancelled ? 'CANCELLED_UNWRITTEN' : 'SUCCEEDED',
    'precisionChoices': policy,
    'precisionContext': {
      'available': true,
      'choices': policy,
      'usedChoices': cancelled ? <String, dynamic>{} : policy,
    },
    'result': cancelled
        ? {'cancelled': true}
        : path.endsWith('unapprove')
        ? {
            'id': '00000000-0000-0000-0000-000000000202',
            'unapprovalOriginalId': _doc,
            'status': 0,
            'items': <Object>[],
          }
        : {'id': _doc, 'status': 1, 'items': <Object>[]},
  };
  @override
  Future<ResponseBody> fetch(
    RequestOptions o,
    Stream<Uint8List>? body,
    Future<void>? cancel,
  ) async {
    if (o.method == 'GET') {
      return json(receipts[o.path.split('/').last] ?? {'found': false});
    }
    final value = Map<String, dynamic>.from(o.data as Map);
    if (o.path.endsWith('/cancel')) {
      cancellations.add(value);
      final original = Map<String, dynamic>.from(value['requestBody'] as Map);
      final key = original['requestId'] as String;
      final result = receipts.putIfAbsent(
        key,
        () => receipt(
          value['path'] as String,
          original,
          Map<String, dynamic>.from(value['precisionChoices'] as Map),
          cancelled: true,
        ),
      );
      if (loseCancel) {
        loseCancel = false;
        throw DioException(
          requestOptions: o,
          type: DioExceptionType.receiveTimeout,
        );
      }
      return json(result);
    }
    final policy = choices(o);
    writes.add((path: o.path, body: value, choices: policy));
    if (reject) return json({'code': 'CONFLICT', 'message': '单据已变化'}, 409);
    final key = value['requestId'] as String;
    if (receipts.containsKey(key)) return json(receipts[key]);
    if (requirePrecision && policy.isEmpty) {
      return json({
        'code': 'PRECISION_CHOICE_REQUIRED',
        'message': '选择原精度',
        'details': {
          'calculationKey': 'finance.allocation',
          'groupKey': 'finance.allocation',
          'label': '分摊计算',
          'maxScale': 30,
          'suggestedScale': 4,
          'reason': 'NON_TERMINATING',
          'notWritten': true,
        },
      }, 422);
    }
    final result = receipt(o.path, value, policy);
    receipts[key] = result;
    if (lose) {
      throw DioException(
        requestOptions: o,
        type: DioExceptionType.receiveTimeout,
      );
    }
    return json(result);
  }

  @override
  void close({bool force = false}) {}
}

Future<ProviderContainer> _open(
  WidgetTester tester,
  _Adapter adapter,
  MemoryFormDraftStorage storage, {
  String? resume,
  bool write = true,
  bool readOnly = false,
  bool unapprove = false,
  FinanceDocType type = FinanceDocType.payment,
  GlobalKey? capture,
  double zoom = 1,
  double bottomInset = 0,
}) async {
  final dio = Dio(BaseOptions(baseUrl: 'https://finance-command.test/api'))
    ..httpClientAdapter = adapter;
  final container = ProviderContainer(
    overrides: [
      ...financeCommandTestOverrides(
        permissions: false,
        identity: false,
        storage: storage,
      ),
      authenticatedScopeProvider.overrideWithValue(
        AuthenticatedScope(userId: financeCommandTestActor, readOnly: readOnly),
      ),
      currentPermissionsProvider.overrideWithValue({
        FinanceDocConfig.by(type).listPerm,
        if (write)
          (unapprove
              ? FinanceDocConfig.by(type).reversePerm!
              : FinanceDocConfig.by(type).approvePerm!),
      }),
      apiClientProvider.overrideWithValue(ApiClient(dio)),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: auditScreenshotTheme(buildLightTheme()),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(viewInsets: EdgeInsets.only(bottom: bottomInset)),
          child: RepaintBoundary(
            key: capture,
            child: UtenDisplayZoomBox(fontFactor: zoom, child: child!),
          ),
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showFinanceDocumentReviewCommand(
                context,
                type: type,
                documentId: _doc,
                unapprove: unapprove,
                factsSnapshot: unapprove && resume == null
                    ? List.filled(64, 'f').join()
                    : null,
                reviewedDetail: FinanceDocDetail.fromJson(_source(type)),
                resumeDraftId: resume,
              ),
              child: const Text('打开审核'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开审核'));
  await tester.pumpAndSettle();
  return container;
}

Future<void> _originalAction(WidgetTester tester, String label) async {
  if (find.text(label).evaluate().isEmpty) {
    await tester.tap(find.text('原请求操作'));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  setUp(prepareFinanceCommandTest);
  testWidgets(
    'actual review command negotiates4DOWN, hard close does not adopt later4UP, original receipt proves original choices',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var asks = 0;
      var release = BusinessPrecisionCoordinator.instance.register((_) async {
        asks++;
        return const BusinessPrecisionChoice(4, 'DOWN');
      });
      final adapter = _Adapter(), storage = MemoryFormDraftStorage();
      var env = await _open(tester, adapter, storage);
      await tester.tap(find.text('确认审核'));
      await tester.pumpAndSettle();
      expect(asks, 1);
      expect(adapter.writes, hasLength(2));
      expect(adapter.writes.last.choices['finance.allocation'], {
        'scale': 4,
        'rounding': 'DOWN',
      });
      final draft = env.read(formDraftsProvider).single;
      expect(draft.hasUnknownSubmission, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      env.dispose();
      release();
      release = BusinessPrecisionCoordinator.instance.register((_) async {
        asks++;
        return const BusinessPrecisionChoice(4, 'HALF_UP');
      });
      env = await _open(tester, adapter, storage, resume: draft.id);
      adapter.lose = false;
      expect(
        find.text('这份草稿暂时无法恢复，原草稿已保留。'),
        findsNothing,
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((v) => v.data)
            .join(' | '),
      );
      expect(
        find.text('重试原审核'),
        findsOneWidget,
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((v) => v.data)
            .join(' | '),
      );
      await tester.tap(find.text('重试原审核'));
      await tester.pumpAndSettle();
      expect(asks, 1);
      expect(adapter.writes.last.body, adapter.writes[1].body);
      expect(adapter.writes.last.choices, adapter.writes[1].choices);
      expect(env.read(formDraftsProvider), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      env.dispose();
      release();
    },
  );
  testWidgets(
    '409 plus GET false stays original; lost cancel restores tombstone and requires explicit current review',
    (tester) async {
      final adapter = _Adapter()
        ..reject = true
        ..requirePrecision = false
        ..loseCancel = true;
      final storage = MemoryFormDraftStorage();
      var env = await _open(tester, adapter, storage);
      await tester.tap(find.text('确认审核'));
      await tester.pumpAndSettle();
      final original = adapter.writes.single.body,
          draft = env.read(formDraftsProvider).single;
      await _originalAction(tester, '核对原审核结果');
      await tester.pumpAndSettle();
      expect(env.read(formDraftsProvider).single.hasUnknownSubmission, isTrue);
      await _originalAction(tester, '核实未写并保留输入');
      await tester.pumpAndSettle();
      expect(env.read(formDraftsProvider).single.hasUnknownSubmission, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      env.dispose();
      env = await _open(
        tester,
        adapter,
        storage,
        resume: draft.id,
        write: false,
      );
      await _originalAction(tester, '核对原审核结果');
      await tester.pumpAndSettle();
      expect(find.text('重新核对当前单据'), findsOneWidget);
      expect(adapter.writes, hasLength(1));
      expect(adapter.cancellations.single['requestBody'], original);
      expect(adapter.cancellations.single['precisionChoices'], isEmpty);
      expect(env.read(formDraftsProvider).single.hasUnknownSubmission, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      env.dispose();
    },
  );
  testWidgets(
    'unapproval hard recovery keeps original facts and original successor proof, without a new capability',
    (tester) async {
      final adapter = _Adapter()..requirePrecision = false,
          storage = MemoryFormDraftStorage();
      var env = await _open(tester, adapter, storage, unapprove: true);
      await tester.tap(find.text('确认反审'));
      await tester.pumpAndSettle();
      final body = adapter.writes.single.body,
          draft = env.read(formDraftsProvider).single;
      expect(body['expectedSnapshot'], List.filled(64, 'f').join());
      expect(body['idempotencyKey'], body['requestId']);
      await tester.pumpWidget(const SizedBox.shrink());
      env.dispose();
      env = await _open(
        tester,
        adapter,
        storage,
        unapprove: true,
        resume: draft.id,
      );
      adapter.lose = false;
      await tester.tap(find.text('重试原反审'));
      await tester.pumpAndSettle();
      expect(adapter.writes.last.body, body);
      expect(env.read(formDraftsProvider), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      env.dispose();
    },
  );
  test(
    'original executed precision label omits internal purpose keys and uses proven choices only',
    () {
      final text = financeDocumentPrecisionLabel({
        'precisionContext': {
          'available': true,
          'usedChoices': {
            'finance.internal.share': {'scale': 4, 'rounding': 'DOWN'},
            'money.internal.other': {'scale': 4, 'rounding': 'DOWN'},
          },
        },
      });
      expect(text, '（原计算精度：4位截断）');
    },
  );
  for (final width in [1280.0, 390.0]) {
    testWidgets(
      'review pending $width keeps original request actions reachable with large text and keyboard',
      (tester) async {
        const captureEnabled = bool.fromEnvironment(
          'UTEN_FINANCE_COMMAND_CAPTURE',
        );
        if (captureEnabled) await loadAuditScreenshotFonts(tester);
        await tester.binding.setSurfaceSize(Size(width, 844));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final key = GlobalKey(),
            adapter = _Adapter()
              ..reject = true
              ..requirePrecision = false;
        final env = await _open(
          tester,
          adapter,
          MemoryFormDraftStorage(),
          capture: key,
          zoom: width < 600 ? 1.5 : 1,
          bottomInset: width < 600 ? 280 : 0,
        );
        await tester.ensureVisible(find.text('确认审核'));
        await tester.tap(find.text('确认审核'));
        await tester.pumpAndSettle();
        final title = find.text('采购付款单审核');
        await tester.ensureVisible(title);
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(title).dy, greaterThanOrEqualTo(0));
        if (captureEnabled) {
          await saveAuditScreenshot(
            tester,
            key,
            'finance-document-review-pending-${width.toInt()}-header',
          );
        }
        await tester.ensureVisible(find.text('重试原审核'));
        await tester.pumpAndSettle();
        expect(find.text('重试原审核').hitTestable(), findsOneWidget);
        expect(find.text('稍后核对').hitTestable(), findsOneWidget);
        if (captureEnabled) {
          await saveAuditScreenshot(
            tester,
            key,
            'finance-document-review-pending-${width.toInt()}-actions',
          );
        }
        if (width < 600) {
          await tester.tap(find.text('原请求操作'));
          await tester.pumpAndSettle();
          expect(find.text('查看原单据').hitTestable(), findsOneWidget);
          expect(find.text('核对原审核结果').hitTestable(), findsOneWidget);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        env.dispose();
      },
    );
  }
  test(
    'restored document intent cannot switch operation or detach its reviewed token',
    () {
      final source = FinanceDocDetail.fromJson(_source(FinanceDocType.payment));
      final intent = FinanceDocumentIntent(
        type: FinanceDocType.payment,
        documentId: _doc,
        actorId: financeCommandTestActor,
        operation: 'FINANCE_DOCUMENT_APPROVE',
        body: {
          'requestId': '00000000-0000-0000-0000-000000000501',
          'expectedVersion': 7,
          'expectedSnapshot': _token,
        },
        precisionChoices: {},
      );
      expect(
        () => FinanceDocumentIntent.restore(
          intent.toJson(),
          type: FinanceDocType.payment,
          documentId: _doc,
          actorId: financeCommandTestActor,
          choices: {},
          expectedOperation: 'FINANCE_DOCUMENT_UNAPPROVE',
        ),
        throwsFormatException,
      );
      intent.validateReviewedDetail(source);
      intent.body['expectedSnapshot'] = List.filled(64, 'b').join();
      expect(
        () => intent.validateReviewedDetail(source),
        throwsFormatException,
      );
    },
  );
  for (final type in FinanceDocType.values) {
    test(
      '$type reviewed token includes complete frozen platform projection and real nullable version',
      () {
        final source = _source(type),
            detail = FinanceDocDetail.fromJson(_source(type));
        expect(financeDocumentHasReviewSnapshot(detail, type: type), isTrue);
        source['approvalPlatformFields'] = <String, dynamic>{};
        expect(
          financeDocumentHasReviewSnapshot(
            FinanceDocDetail.fromJson(source),
            type: type,
          ),
          isFalse,
        );
        expect(
          detail.approvalVersion,
          type == FinanceDocType.receipt || type == FinanceDocType.payment
              ? 7
              : null,
        );
      },
    );
  }
}
