import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/finance/widgets/finance_classification_correction_dialog.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import '../../support/audit_screenshot_support.dart';
import '../../shared/drafts/memory_form_draft_storage.dart';
import 'finance_requirement_test_ui.dart';

const _capture = bool.fromEnvironment('UTEN_CAPTURE_FINANCE_PARTY_UI');
const _ledger = '00000000-0000-4000-8000-000000000111';
final _boundary = GlobalKey();

void main() {
  testWidgets(
    'whole graph preserves exact text, one preview and one unknown write under eight rapid actions',
    (tester) async {
      final api = _Api()
        ..loseFirst = true
        ..gate = Completer<void>();
      final environment = await _pump(tester, api);
      if (_capture) {
        await saveAuditScreenshot(tester, _boundary, '往来分类整图更正-完整关联');
      }
      await tester.tap(find.text('PAY-100').first);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('PAY-100').first);
      await tester.pumpAndSettle();
      expect(find.text('原实际现金本币'), findsWidgets);
      expect(find.text('原账面核销本币'), findsWidgets);
      if (_capture) {
        await saveAuditScreenshot(tester, _boundary, '往来分类整图更正-实付与账面');
      }
      await tester.tap(find.text('AP-100').first);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('AP-100').first);
      await tester.pumpAndSettle();
      final raw = '9' * 130 + '.123456789012345678901234';
      final field = find
          .byWidgetPredicate(
            (w) =>
                w is UtenInput &&
                w.key?.toString().contains('来源') == false &&
                w.key?.toString().contains('货款-amountOriginal') == true,
          )
          .first;
      await tester.enterText(
        find.descendant(of: field, matching: find.byType(EditableText)),
        raw,
      );
      expect(tester.widget<UtenInput>(field).controller!.text, raw);
      await tester.enterText(
        find.descendant(of: field, matching: find.byType(EditableText)),
        '100',
      );
      await tester.enterText(financeTextField('更正依据'), '所有实际来源与已付行共同更正');
      final callback = tester
          .widget<UtenButton>(
            find.ancestor(
              of: find.text('核对整图并更正'),
              matching: find.byType(UtenButton),
            ),
          )
          .onPressed!;
      for (var repeat = 0; repeat < 8; repeat++) {
        callback();
      }
      await tester.pumpAndSettle();
      expect(api.previews, 1);
      expect(find.text('确认整图更正'), findsOneWidget);
      expect(find.byType(UtenBusyOverlay), findsNothing);
      await tester.tap(find.text('确认更正'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(api.saved, hasLength(1));
      expect(find.byType(UtenBusyOverlay), findsOneWidget);
      api.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('核对并重试原更正'), findsOneWidget);
      await tester.tap(find.text('核对并重试原更正'));
      await tester.pumpAndSettle();
      expect(api.saved, hasLength(2));
      expect(jsonEncode(api.saved.first), jsonEncode(api.saved.last));
      expect(api.actual, 1);
      expect(api.previews, 1);
      expect((api.saved.first['nodes'] as List), hasLength(2));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      environment.dispose();
    },
  );
  testWidgets(
    'explicit graph refresh keeps every raw amount and prevents eight overlapping reads',
    (tester) async {
      final api = _Api();
      final environment = await _pump(tester, api);
      final raw = '8' * 130 + '.000000000000000000000001';
      final input = find
          .byWidgetPredicate(
            (w) =>
                w is UtenInput &&
                w.key?.toString().contains('货款-amountOriginal') == true,
          )
          .first;
      await tester.enterText(
        find.descendant(of: input, matching: find.byType(EditableText)),
        raw,
      );
      final callback = tester
          .widget<TextButton>(find.widgetWithText(TextButton, '重新读取关联图'))
          .onPressed!;
      for (var i = 0; i < 8; i++) {
        callback();
      }
      await tester.pumpAndSettle();
      final restored = find
          .byWidgetPredicate(
            (w) =>
                w is UtenInput &&
                w.key?.toString().contains('货款-amountOriginal') == true,
          )
          .first;
      expect(tester.widget<UtenInput>(restored).controller!.text, raw);
      expect(api.reads, 2);
      expect(api.saved, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      environment.dispose();
    },
  );
  testWidgets(
    '512 node full graph submits every real row rather than only the virtualized viewport',
    (tester) async {
      final api = _LargeApi();
      final environment = await _pump(tester, api);
      await tester.enterText(financeTextField('更正依据'), '完整512节点原文，全模型提交');
      await tester.tap(find.text('核对整图并更正'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认更正'));
      await tester.pumpAndSettle();
      expect(api.saved, hasLength(1));
      final nodes = (api.saved.single['nodes'] as List)
          .cast<Map<String, dynamic>>();
      expect(nodes, hasLength(512));
      expect(nodes.where((n) => n['kind'] == 'AP_PAYMENT'), hasLength(511));
      expect(((nodes.last['parts'] as List).single as Map)['cashLocal'], '7.2');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      environment.dispose();
    },
  );
  testWidgets(
    'terminal APPLIED resolution reads the original success without replaying its write',
    (tester) async {
      final api = _Api()..loseFirst = true;
      final environment = await _pump(tester, api);
      await tester.enterText(financeTextField('更正依据'), '原更正已经成功，只核原回执');
      await tester.tap(find.text('核对整图并更正'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认更正'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('核对并终止旧未写请求'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('核对并封口'));
      await tester.pumpAndSettle();
      expect(api.saved, hasLength(1));
      expect(api.resolutions, hasLength(1));
      expect(api.actual, 1);
      expect(find.text('往来分类整图更正'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      environment.dispose();
    },
  );
  testWidgets(
    'unknown terminal abandonment survives hard interruption and only a saved receipt unlocks a fresh graph',
    (tester) async {
      final api = _Api()
        ..loseFirst = true
        ..failBeforeCommit = true
        ..resolutionStatus = 'ABANDONED'
        ..loseResolution = true;
      final storage = MemoryFormDraftStorage();
      var environment = await _pump(tester, api, storage: storage);
      await tester.enterText(financeTextField('更正依据'), '原完整输入与晚到请求都不得丢失');
      await tester.tap(find.text('核对整图并更正'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认更正'));
      await tester.pumpAndSettle();
      final original = jsonEncode(api.saved.single);
      await tester.tap(find.text('核对并终止旧未写请求'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('核对并封口'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      final unknown = environment.read(formDraftsProvider).single;
      expect(unknown.hasUnknownSubmission, isTrue);
      expect(api.actual, 0);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      environment.dispose();
      api.refuseReads = true;
      environment = await _pump(
        tester,
        api,
        storage: storage,
        resumeDraftId: unknown.id,
      );
      await tester.tap(find.text('核对并终止旧未写请求'));
      await tester.pumpAndSettle();
      expect(api.resolutions, hasLength(2));
      expect(
        jsonEncode(api.resolutions.first),
        jsonEncode(api.resolutions.last),
      );
      expect(api.saved, hasLength(1));
      final checkpoint = environment.read(formDraftsProvider).single;
      expect(checkpoint.hasUnknownSubmission, isFalse);
      final history = checkpoint.data['resolvedRequests'] as Map;
      final record = history.values.single as Map;
      expect(jsonEncode(record['body']), original);
      expect((record['receipt'] as Map)['status'], 'ABANDONED');
      expect(record['headers'], isEmpty);
      expect(
        tester
            .widget<UtenButton>(
              find.ancestor(
                of: find.text('核对整图并更正'),
                matching: find.byType(UtenButton),
              ),
            )
            .onPressed,
        isNull,
      );
      api.refuseReads = false;
      await tester.tap(find.text('重新读取关联图'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('核对整图并更正'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认更正'));
      await tester.pumpAndSettle();
      expect(api.saved, hasLength(2));
      expect(api.saved.first['requestId'], isNot(api.saved.last['requestId']));
      expect(api.actual, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      environment.dispose();
    },
  );
  testWidgets(
    'a failed local terminal checkpoint cannot dispatch another business command',
    (tester) async {
      final api = _Api()
        ..loseFirst = true
        ..failBeforeCommit = true
        ..resolutionStatus = 'ABANDONED';
      final storage = _FailingStorage();
      final environment = await _pump(tester, api, storage: storage);
      await tester.enterText(financeTextField('更正依据'), '本地暂不能保存终局回执时，原业务仍须封锁');
      await tester.tap(find.text('核对整图并更正'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认更正'));
      await tester.pumpAndSettle();
      storage.fail = true;
      await tester.tap(find.text('核对并终止旧未写请求'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('核对并封口'));
      await tester.pumpAndSettle();
      expect(api.saved, hasLength(1));
      expect(api.actual, 0);
      expect(
        tester
            .widget<UtenButton>(
              find.ancestor(
                of: find.text('核对并重试原更正'),
                matching: find.byType(UtenButton),
              ),
            )
            .onPressed,
        isNull,
      );
      storage.fail = false;
      await tester.tap(find.text('核对并终止旧未写请求'));
      await tester.pumpAndSettle();
      expect(api.saved, hasLength(1));
      expect(
        environment.read(formDraftsProvider).single.hasUnknownSubmission,
        isFalse,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      environment.dispose();
    },
  );
  testWidgets(
    'hard interruption while POST is still in flight restores the shared unknown fence and exact old request',
    (tester) async {
      final api = _Api()..gate = Completer<void>();
      final storage = MemoryFormDraftStorage();
      var environment = await _pump(tester, api, storage: storage);
      await tester.enterText(financeTextField('更正依据'), '请求仍在等待时硬中断，不得换号或改输入');
      await tester.tap(find.text('核对整图并更正'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认更正'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(api.saved, hasLength(1));
      expect(find.byType(UtenBusyOverlay), findsOneWidget);
      final pending = environment.read(formDraftsProvider).single;
      expect(pending.hasUnknownSubmission, isTrue);
      final body = jsonEncode(api.saved.single);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      environment.dispose();
      api.gate!.complete();
      await tester.pumpAndSettle();
      expect(api.actual, 1);
      api.refuseReads = true;
      environment = await _pump(
        tester,
        api,
        storage: storage,
        resumeDraftId: pending.id,
      );
      expect(find.text('核对并重试原更正'), findsOneWidget);
      expect(
        tester.widget<TextField>(financeTextField('更正依据')).enabled,
        isFalse,
      );
      await tester.tap(find.text('核对并重试原更正'));
      await tester.pumpAndSettle();
      expect(api.saved, hasLength(2));
      expect(jsonEncode(api.saved.last), body);
      expect(api.actual, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      environment.dispose();
    },
  );
  testWidgets(
    'private interrupted unknown graph restores full old graph and original request without fresh reads',
    (tester) async {
      final api = _Api()..loseFirst = true;
      final storage = MemoryFormDraftStorage();
      var environment = await _pump(tester, api, storage: storage);
      await tester.enterText(financeTextField('更正依据'), '未知请求保存完整原图及所有金额轴');
      await tester.tap(find.text('核对整图并更正'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认更正'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      final draft = environment.read(formDraftsProvider).single;
      expect(draft.hasUnknownSubmission, isTrue);
      expect(draft.route, contains('ledgerIds='));
      final original = jsonEncode(api.saved.single);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      environment.dispose();
      api.refuseReads = true;
      environment = await _pump(
        tester,
        api,
        storage: storage,
        resumeDraftId: draft.id,
      );
      expect(find.text('核对并重试原更正'), findsOneWidget);
      await tester.tap(find.text('核对并重试原更正'));
      await tester.pumpAndSettle();
      expect(jsonEncode(api.saved.last), original);
      expect(api.actual, 1);
      expect(api.previews, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      environment.dispose();
    },
  );
  testWidgets(
    '390 width enlarged graph keeps all axes in Uten grid and action reachable',
    (tester) async {
      final api = _Api();
      final environment = await _pump(tester, api, width: 390, scale: 1.5);
      if (_capture) {
        await saveAuditScreenshot(tester, _boundary, '往来分类整图更正-窄屏');
      }
      expect(find.text('往来分类整图更正'), findsOneWidget);
      expect(find.text('核对整图并更正'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      environment.dispose();
    },
  );
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _Api api, {
  double width = 1300,
  double scale = 1,
  MemoryFormDraftStorage? storage,
  String? resumeDraftId,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 1000);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  if (_capture) {
    await loadAuditScreenshotFonts(tester);
  }
  final container = ProviderContainer(
    overrides: [
      if (storage != null)
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'classification-reviewer'),
        ),
      if (storage != null) formDraftStorageProvider.overrideWithValue(storage),
      apiBaseUrlProvider.overrideWithValue(
        'https://classification-draft.test/api',
      ),
      sessionProvider.overrideWith(_Session.new),
      apiClientProvider.overrideWithValue(api),
      currentPermissionsProvider.overrideWithValue(const {
        'finance_report:view',
        'finance:view:all',
        'ar_ap_ledger:view',
        'supplier_settlement:confirm',
        'finance_payment:approve',
        'finance_post:execute',
      }),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: _capture ? auditScreenshotTheme(buildLightTheme()) : null,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: RepaintBoundary(key: _boundary, child: child!),
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showFinanceClassificationCorrectionDialog(
                context,
                ledgerIds: const [_ledger],
                resumeDraftId: resumeDraftId,
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
  return container;
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _Api extends ApiClient {
  _Api() : super(Dio());
  bool loseFirst = false,
      refuseReads = false,
      failBeforeCommit = false,
      loseResolution = false;
  String resolutionStatus = 'APPLIED';
  final resolutions = <Map<String, dynamic>>[];
  Completer<void>? gate;
  int previews = 0, actual = 0, reads = 0;
  final saved = <Map<String, dynamic>>[];
  final _seen = <String>{};
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    reads++;
    if (refuseReads) {
      throw StateError(
        'unknown replay must use the complete original saved graph',
      );
    }
    return {
      'ledgerIds': [_ledger],
      'direction': 'AP',
      'partyId': 'party',
      'currencyId': 'currency',
      'graphFingerprint': (reads == 1 ? 'a' : 'b') * 64,
      'nodes': [
        {
          'kind': 'SOURCE',
          'objectId': _ledger,
          'expectedBatchId': '00000000-0000-4000-8000-000000000201',
          'expectedRevision': 0,
          'fact': {
            'billNo': 'AP-100',
            'direction': 'AP',
            'status': 1,
            'billDate': '2026-11-03',
            'amountOriginal': '100',
            'amountLocal': '700',
          },
          'parts': [
            {
              'category': 'GOODS',
              'amountOriginal': '100',
              'amountLocal': '700',
            },
          ],
        },
        {
          'kind': 'AP_PAYMENT',
          'objectId': '00000000-0000-4000-8000-000000000222',
          'expectedBatchId': '00000000-0000-4000-8000-000000000202',
          'expectedRevision': 0,
          'fact': {
            'billNo': 'PAY-100',
            'status': 1,
            'billDate': '2026-11-03',
            'ledgerId': _ledger,
            'amountOriginal': '100',
            'cashLocal': '720',
            'bookLocal': '700',
          },
          'parts': [
            {
              'category': 'GOODS',
              'amountOriginal': '100',
              'cashLocal': '720',
              'bookLocal': '700',
            },
          ],
        },
      ],
      'readOnlySources': <Map<String, dynamic>>[],
    };
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/preview')) {
      previews++;
      return {
        'status': 'VALIDATED',
        'commandHash': 'c' * 64,
        'actorId': 'classification-reviewer',
      };
    }
    final input = Map<String, dynamic>.from(body! as Map);
    if (path.endsWith('/resolve')) {
      resolutions.add(
        Map<String, dynamic>.from(jsonDecode(jsonEncode(input)) as Map),
      );
      if (loseResolution) {
        loseResolution = false;
        throw ApiException('NETWORK_ERROR', '终局封口响应未收到');
      }
      return {
        'status': resolutionStatus,
        'requestId': (input['original'] as Map)['requestId'],
        'actorId': 'classification-reviewer',
        'commandHash': input['expectedCommandHash'],
      };
    }
    saved.add(input);
    if (failBeforeCommit && loseFirst) {
      loseFirst = false;
      throw ApiException('NETWORK_ERROR', '原请求未到达服务器');
    }
    if (gate != null) {
      await gate!.future;
      gate = null;
    }
    if (_seen.add(input['requestId'] as String)) actual++;
    if (loseFirst) {
      loseFirst = false;
      throw ApiException('NETWORK_ERROR', '响应未收到');
    }
    return {'status': 'APPLIED', 'requestId': input['requestId']};
  }
}

class _LargeApi extends _Api {
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    final graph = await super.get(path, query: query);
    final nodes = (graph['nodes'] as List).cast<Map<String, dynamic>>();
    final source = nodes.first;
    source['fact'] = {
      ...source['fact'] as Map,
      'amountOriginal': '511',
      'amountLocal': '3577',
    };
    source['parts'] = [
      {'category': 'GOODS', 'amountOriginal': '511', 'amountLocal': '3577'},
    ];
    final prototype = nodes.last;
    graph['nodes'] = [
      source,
      for (var i = 0; i < 511; i++)
        {
          ...prototype,
          'objectId':
              '00000000-0000-4000-8000-${(1000 + i).toString().padLeft(12, '0')}',
          'expectedBatchId':
              '00000000-0000-4000-8000-${(10000 + i).toString().padLeft(12, '0')}',
          'fact': {
            ...prototype['fact'] as Map,
            'billNo': 'PAY-${i + 1}',
            'amountOriginal': '1',
            'cashLocal': '7.2',
            'bookLocal': '7',
          },
          'parts': [
            {
              'category': 'GOODS',
              'amountOriginal': '1',
              'cashLocal': '7.2',
              'bookLocal': '7',
            },
          ],
        },
    ];
    return graph;
  }
}

class _FailingStorage extends MemoryFormDraftStorage {
  bool fail = false;
  @override
  Future<bool> compareAndSet(
    String key, {
    required String? expectedValue,
    required String? value,
  }) async {
    if (fail) {
      throw StateError('anonymous local checkpoint storage unavailable');
    }
    return super.compareAndSet(key, expectedValue: expectedValue, value: value);
  }
}
