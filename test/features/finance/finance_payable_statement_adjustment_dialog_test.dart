import 'dart:convert';
import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/finance/widgets/finance_payable_statement_adjustment_dialog.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import '../../support/audit_screenshot_support.dart';
import '../../shared/drafts/memory_form_draft_storage.dart';
import 'finance_requirement_test_ui.dart';

const _capture = bool.fromEnvironment('UTEN_CAPTURE_FINANCE_PARTY_UI');
final _boundary = GlobalKey();

void main() {
  testWidgets(
    'adjustment permission rejection hides accepted facts while keeping exact entered amount',
    (tester) async {
      final api = _Api();
      final environment = await _pump(tester, api);
      await tester.tap(find.text('AP-ORIGINAL-80').first);
      await tester.pumpAndSettle();
      await _input(tester, 'amount', '0.000000000000000000000001');
      final input = tester
          .widget<UtenInput>(_editor('amount').first)
          .controller!;
      final table = tester
          .widgetList<MasterDataTableView<Map<String, dynamic>>>(
            find.byWidgetPredicate(
              (w) => w is MasterDataTableView<Map<String, dynamic>>,
            ),
          )
          .singleWhere((w) => w.onSelectedIdsChanged != null);
      api.readError = ApiException(
        'FORBIDDEN',
        'adjustment read revoked',
        httpStatus: 403,
      );
      await Future<void>.sync(table.onRetry!);
      await tester.pumpAndSettle();
      expect(
        find.byType(MasterDataTableView<Map<String, dynamic>>),
        findsNothing,
      );
      table.onSelectedIdsChanged!({});
      await tester.pump();
      expect(input.text, '0.000000000000000000000001');
      // Complete-read failures append an anonymous correlation ref to the
      // ApiException message (a7a54d709), so pin the base message by prefix.
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is UtenFieldHintIcon &&
              w.errorMessage?.startsWith('adjustment read revoked') == true,
        ),
        findsOneWidget,
      );
      expect(api.saved, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      environment.dispose();
    },
  );
  testWidgets(
    'target and adjustment directories collect both axes once without a Cartesian read',
    (tester) async {
      final api = _CompleteApi();
      final environment = await _pump(tester, api);
      final tables = tester
          .widgetList<MasterDataTableView<Map<String, dynamic>>>(
            find.byWidgetPredicate(
              (w) => w is MasterDataTableView<Map<String, dynamic>>,
            ),
          )
          .toList();
      final targets = tables.singleWhere((w) => w.items.length == 251);
      final records = tables.singleWhere((w) => w.items.length == 151);
      expect(targets.items.last['billNo'], 'AP-COMPLETE-250');
      expect(records.items.last['source_reference'], 'record-150');
      expect(targets.onPageChange, isNull);
      expect(records.onPageChange, isNull);
      expect(
        api.queries.map(
          (q) => (q['part'], q['page'], q['size'], q['adjustmentPage']),
        ),
        [
          ('targets', 1, 100, null),
          ('targets', 2, 100, null),
          ('targets', 3, 100, null),
          ('adjustments', null, null, 1),
          ('adjustments', null, null, 2),
          ('adjustments', null, null, 3),
          ('adjustments', null, null, 4),
        ],
      );
      expect(api.queries.map((q) => q['readSnapshotRevision']), [
        null,
        'targets-snapshot',
        'targets-snapshot',
        null,
        'adjustments-snapshot',
        'adjustments-snapshot',
        'adjustments-snapshot',
      ]);
      expect(
        targets.items.map((row) => row['ledgerId']).toSet(),
        hasLength(251),
      );
      expect(records.items.map((row) => row['id']).toSet(), hasLength(151));
      expect(
        targets.items.every(
          (row) =>
              row['balanceOriginal'] == '0.000000000000000000000001' &&
              row['balanceLocal'] == '90071992547409.0001',
        ),
        isTrue,
      );
      expect(
        records.items.every(
          (row) =>
              row['released_original'] == '0.000000000000000000000001' &&
              row['released_local'] == '90071992547409.0001',
        ),
        isTrue,
      );
      final before = api.queries.length;
      await tester.drag(
        find.byType(MasterDataTableView<Map<String, dynamic>>).first,
        const Offset(0, -900),
      );
      await tester.pumpAndSettle();
      expect(api.queries, hasLength(before));
      expect(api.saved, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      environment.dispose();
    },
  );
  for (final failure in ['denial', 'scope change', 'data version mismatch']) {
    testWidgets('later record $failure publishes neither directory nor write', (
      tester,
    ) async {
      final api = _CompleteApi()
        ..scopeDrift = failure == 'scope change'
        ..dataDrift = failure == 'data version mismatch'
        ..denyRecordTail = failure == 'denial';
      final environment = await _pump(tester, api);
      final tables = tester
          .widgetList<MasterDataTableView<Map<String, dynamic>>>(
            find.byWidgetPredicate(
              (w) => w is MasterDataTableView<Map<String, dynamic>>,
            ),
          );
      expect(tables, isNotEmpty);
      final targets = tables.singleWhere(
        (w) => w.tableKey == 'finance.payable-statement-adjustments.targets',
      );
      expect(targets.items, isEmpty);
      expect(
        targets.error,
        contains(switch (failure) {
          'denial' => 'record tail forbidden',
          'scope change' => '数据在读取期间已变化',
          _ => '调整范围已变化',
        }),
      );
      expect(
        tables
            .where(
              (w) =>
                  w.tableKey == 'finance.payable-statement-adjustments.records',
            )
            .every((w) => w.items.isEmpty),
        isTrue,
      );
      final original = tables.singleWhere(
        (w) => w.tableKey == 'finance.payable-statement-adjustments.original',
      );
      expect(original.items.single['periodAmountOriginal'], isNull);
      expect(original.items.single['releasedOriginal'], isNull);
      expect(original.items.single['currency'], '待核');
      expect(api.saved, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      environment.dispose();
    });
  }
  testWidgets(
    'document fee has no default decision and unknown result replays exactly one original request',
    (tester) async {
      final api = _Api()
        ..loseFirst = true
        ..gate = Completer<void>();
      final environment = await _pump(tester, api);
      if (_capture) {
        await saveAuditScreenshot(tester, _boundary, '手续费尾数逐单处理-原件与应付');
      }
      await tester.tap(find.text('AP-ORIGINAL-80').first);
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<UtenDropdownField>(find.byType(UtenDropdownField))
            .every((field) => field.value == null),
        isTrue,
      );
      await _select(tester, 'HANDLING_FEE', '手续费');
      await _select(tester, 'STILL_OWED', '仍欠');
      await _select(tester, 'GOODS', '货款');
      final rawLong = '9' * 130 + '.123456789012345678901234';
      await _input(tester, 'amount', rawLong);
      expect(
        tester.widget<UtenInput>(_editor('amount').first).controller!.text,
        rawLong,
      );
      await _input(tester, 'amount', '0.000000000000000000000001');
      await _input(tester, 'attribution', '此原货款归属');
      await _input(tester, 'source', '原件确认此尾数仍欠，不自动凑整');
      await tester.ensureVisible(financeTextField('本次处理依据'));
      await tester.enterText(financeTextField('本次处理依据'), '明确本单仍欠');
      await tester.tap(find.text('预览逐笔金额'));
      await tester.pumpAndSettle();
      if (_capture) {
        final field = find
            .byWidgetPredicate(
              (widget) =>
                  widget is UtenDropdownField &&
                  widget.items.any((item) => item.value == 'HANDLING_FEE'),
            )
            .first;
        await tester.ensureVisible(field);
        await tester.pumpAndSettle();
        await saveAuditScreenshot(tester, _boundary, '手续费尾数逐单处理-实际组件');
      }
      final saveButton = tester
          .widget<UtenButton>(
            find
                .ancestor(
                  of: find.text('保存待审核处理'),
                  matching: find.byType(UtenButton),
                )
                .last,
          )
          .onPressed!;
      for (int repeat = 0; repeat < 8; repeat++) {
        saveButton();
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(api.saved, hasLength(1));
      expect(find.byType(UtenBusyOverlay), findsOneWidget);
      api.gate!.complete();
      await tester.pumpAndSettle();
      expect(api.saved, hasLength(1));
      expect(find.text('核对并重试原操作'), findsOneWidget);
      await tester.tap(find.text('核对并重试原操作'));
      await tester.pumpAndSettle();
      expect(api.saved, hasLength(2));
      expect(jsonEncode(api.saved.first), jsonEncode(api.saved.last));
      expect(api.actual, 1);
      final line = (api.saved.first['lines'] as List).single as Map;
      expect(line['amountOriginal'], '0.000000000000000000000001');
      expect(line['decision'], 'STILL_OWED');
      expect(line['counterpartStyleId'], isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      environment.dispose();
    },
  );
  testWidgets(
    'narrow enlarged document fee keeps waiting actions reachable and never invents a missing target',
    (tester) async {
      final api = _Api();
      final environment = await _pump(tester, api, width: 390, scale: 1.5);
      await tester.tap(find.text('预览逐笔金额'));
      await tester.pumpAndSettle();
      final hint = find.byWidgetPredicate(
        (widget) =>
            widget is UtenFieldHintIcon &&
            widget.errorMessage == '请选择原件完整覆盖的实际应付',
      );
      expect(hint, findsOneWidget);
      await tester.tap(hint);
      await tester.pumpAndSettle();
      expect(api.saved, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      environment.dispose();
    },
  );
  testWidgets(
    'private unknown fee draft restores exact original scope and command after interruption',
    (tester) async {
      final api = _Api()..loseFirst = true;
      final storage = MemoryFormDraftStorage();
      var environment = await _pump(tester, api, storage: storage);
      await tester.tap(find.text('AP-ORIGINAL-80').first);
      await tester.pumpAndSettle();
      await _select(tester, 'HANDLING_FEE', '手续费');
      await _select(tester, 'STILL_OWED', '仍欠');
      await _select(tester, 'GOODS', '货款');
      await _input(tester, 'amount', '0.000000000000000000000001');
      await _input(tester, 'attribution', '原货款明确归属');
      await _input(tester, 'source', '本原件实际确认仍欠');
      await tester.ensureVisible(financeTextField('本次处理依据'));
      await tester.enterText(financeTextField('本次处理依据'), '私有草稿须保留原请求');
      await tester.tap(find.text('预览逐笔金额'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存待审核处理'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      final draft = environment.read(formDraftsProvider).single;
      expect(draft.hasUnknownSubmission, isTrue);
      expect(draft.route, contains('statementReviewId='));
      expect(draft.route, isNot(contains('私有草稿')));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      environment.dispose();
      environment = await _pump(
        tester,
        api,
        storage: storage,
        resumeDraftId: draft.id,
      );
      expect(find.text('核对并重试原操作'), findsOneWidget);
      expect(api.saved, hasLength(1));
      await tester.tap(find.text('核对并重试原操作'));
      await tester.pumpAndSettle();
      expect(api.actual, 1);
      expect(jsonEncode(api.saved.first), jsonEncode(api.saved.last));
      expect(environment.read(formDraftsProvider), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      environment.dispose();
    },
  );
  testWidgets(
    'unknown approval keeps its original action and never turns a successful retry into reversal',
    (tester) async {
      final api = _RecordApi()..loseFirst = true;
      final environment = await _pump(tester, api);
      final record = find.text('匿名待审核减免');
      await tester.ensureVisible(record);
      await tester.tap(record);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(record);
      await tester.pumpAndSettle();
      expect(find.text('原应付单号'), findsWidgets);
      expect(find.text('不欠'), findsWidgets);
      await tester.tap(find.text('审核处理').last);
      await tester.pumpAndSettle();
      expect(api.paths, hasLength(1));
      expect(find.text('核对并重试原操作'), findsOneWidget);
      await tester.tap(find.text('核对并重试原操作'));
      await tester.pumpAndSettle();
      expect(api.paths, hasLength(2));
      expect(api.paths.first, api.paths.last);
      expect(api.paths.every((path) => path.endsWith('/approve')), isTrue);
      expect(api.actual, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      environment.dispose();
    },
  );
}

Finder _editor(String key) => find.byWidgetPredicate(
  (widget) =>
      widget is UtenInput &&
      widget.key is ValueKey<String> &&
      (widget.key! as ValueKey<String>).value.startsWith('fee-$key-'),
);
Future<void> _input(WidgetTester tester, String key, String text) async {
  final input = _editor(key).first;
  await tester.ensureVisible(input);
  await tester.pumpAndSettle();
  await tester.enterText(
    find.descendant(of: input, matching: find.byType(TextField)).first,
    text,
  );
  await tester.pumpAndSettle();
}

Future<void> _select(WidgetTester tester, String key, String label) async {
  final dropdown = find
      .byWidgetPredicate(
        (widget) =>
            widget is UtenDropdownField &&
            widget.items.any((item) => item.value == key),
      )
      .first;
  await tester.ensureVisible(dropdown);
  await tester.tap(dropdown);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
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
          const AuthenticatedScope(userId: 'fee-reviewer'),
        ),
      if (storage != null) formDraftStorageProvider.overrideWithValue(storage),
      apiBaseUrlProvider.overrideWithValue('https://fee-draft.test/api'),
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
              onPressed: () => showFinancePayableStatementAdjustmentDialog(
                context,
                statementReviewId: '00000000-0000-4000-8000-000000000111',
                expectedSourceFingerprint: 'a' * 64,
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
  bool loseFirst = false;
  Completer<void>? gate;
  int actual = 0;
  ApiException? readError;
  final saved = <Map<String, dynamic>>[];
  final _seen = <String>{};
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (readError != null) throw readError!;
    final part = query?['part'];
    expect(part, anyOf('targets', 'adjustments'));
    return {
      'scope': 'all',
      'readScopeVersion': 'same-owner',
      'readDataVersion': 'same-data',
      'readSnapshotRevision': '$part-snapshot',
      'original': {'periodAmountOriginal': '80.0000'},
      'currency': {'code': 'TEST', 'name': '匿名原币'},
      'targets': [
        {
          'ledgerId': '00000000-0000-4000-8000-000000000222',
          'billNo': 'AP-ORIGINAL-80',
          'sourceDocNo': 'RC-ORIGINAL',
          'fingerprint': 'b' * 64,
          'balanceOriginal': '60.0000',
          'balanceLocal': '420.0000',
        },
      ],
      'accounts': <Map<String, dynamic>>[],
      'adjustments': <Map<String, dynamic>>[],
      'page': 1,
      'size': query?['size'] ?? 100,
      'total': 1,
      'totalPages': 1,
      'adjustmentPage': 1,
      'adjustmentPages': 0,
      'adjustmentSize': 50,
      'adjustmentTotal': 0,
    };
  }

  @override
  Future<Map<String, dynamic>> postCancellable(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    CancelToken? cancelToken,
  }) async {
    final input = Map<String, dynamic>.from(body! as Map);
    return {
      'planHash': 'c' * 64,
      'periodAmountOriginal': '80.0000',
      'releasedOriginal': '0',
      'releasedLocal': '0',
      'precisionChoicesJson': '{"version":1,"choices":{}}',
      'lines': [
        for (final line in input['lines'] as List)
          {
            'input': line,
            'amountLocal': '0',
            'targetBeforeOriginal': '60.0000',
            'targetAfterOriginal': '60.0000',
            'targetBeforeLocal': '420.0000',
            'targetAfterLocal': '420.0000',
          },
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    final input = Map<String, dynamic>.from(body! as Map);
    saved.add(input);
    if (gate != null) {
      await gate!.future;
      gate = null;
    }
    if (_seen.add(input['requestId'] as String)) actual++;
    if (loseFirst) {
      loseFirst = false;
      throw ApiException('NETWORK_ERROR', '响应未收到');
    }
    return {'id': '00000000-0000-4000-8000-000000000333'};
  }
}

class _RecordApi extends _Api {
  static const id = '00000000-0000-4000-8000-000000000444';
  final paths = <String>[];
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/$id')) {
      return {
        'id': id,
        'status': actual == 0 ? 'DRAFT' : 'APPROVED',
        'plan': {
          'items': [
            {
              'preview': {
                'targetBillNo': 'AP-ORIGINAL-80',
                'targetSourceDocNo': 'RC-ORIGINAL',
                'amountLocal': '35.0000',
                'counterpartAccountCode': '630199',
                'debtAccount': {'accountCode': '2202'},
                'input': {
                  'targetLedgerId': '00000000-0000-4000-8000-000000000222',
                  'decision': 'RELEASED',
                  'feeKind': 'HANDLING_FEE',
                  'category': 'GOODS',
                  'amountOriginal': '5.0000',
                  'attributionReference': '本原货款',
                  'sourceReference': '原件真实确认',
                },
              },
            },
          ],
        },
      };
    }
    return {
      ...await super.get(path, query: query),
      'adjustmentPage': 1,
      'adjustmentPages': 1,
      'adjustmentTotal': 1,
      'adjustments': [
        {
          'id': id,
          'status': actual == 0 ? 'DRAFT' : 'APPROVED',
          'released_original': '5.0000',
          'released_local': '35.0000',
          'source_reference': '匿名待审核减免',
        },
      ],
    };
  }

  @override
  Future<List<Map<String, dynamic>>> postList(
    String path, {
    Object? body,
  }) async {
    paths.add(path);
    actual = 1;
    if (loseFirst) {
      loseFirst = false;
      throw ApiException('NETWORK_ERROR', '审核响应未收到');
    }
    return [
      {'adjustmentId': id, 'status': 'APPROVED'},
    ];
  }
}

class _CompleteApi extends _Api {
  final queries = <Map<String, dynamic>>[];
  bool denyRecordTail = false, scopeDrift = false, dataDrift = false;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    queries.add(Map.of(query ?? {}));
    final page = query?['page'] as int? ?? 1;
    final size = query?['size'] as int? ?? 100;
    final recordPage = query?['adjustmentPage'] as int? ?? 1;
    final part = query?['part'];
    final partPage = part == 'targets' ? page : recordPage;
    expect(
      query?['readSnapshotRevision'],
      partPage == 1 ? isNull : '$part-snapshot',
    );
    if (denyRecordTail && part == 'adjustments' && recordPage == 2) {
      throw ApiException('FORBIDDEN', 'record tail forbidden', httpStatus: 403);
    }
    final start = (page - 1) * size, recordStart = (recordPage - 1) * 50;
    return {
      ...await super.get(path, query: query),
      'page': page,
      'size': size,
      'total': 251,
      'totalPages': (251 + size - 1) ~/ size,
      'readScopeVersion': scopeDrift && part == 'adjustments' && recordPage > 1
          ? 'changed-owner'
          : 'same-owner',
      'readDataVersion': dataDrift && part == 'adjustments'
          ? 'changed-data'
          : 'same-data',
      'targets': [
        for (var i = start; i < start + size && i < 251; i++)
          {
            'ledgerId':
                '00000000-0000-4000-8000-${i.toString().padLeft(12, '0')}',
            'billNo': 'AP-COMPLETE-$i',
            'fingerprint': 'b' * 64,
            'balanceOriginal': '0.000000000000000000000001',
            'balanceLocal': '90071992547409.0001',
          },
      ],
      'adjustmentPage': recordPage,
      'adjustmentPages': 4,
      'adjustmentTotal': 151,
      'adjustments': [
        for (var i = recordStart; i < recordStart + 50 && i < 151; i++)
          {
            'id': 'record-$i',
            'status': 'DRAFT',
            'source_reference': 'record-$i',
            'released_original': '0.000000000000000000000001',
            'released_local': '90071992547409.0001',
          },
      ],
    };
  }
}
