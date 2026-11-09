import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/features/finance/widgets/finance_native_legacy_opening_dialog.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import '../../shared/drafts/memory_form_draft_storage.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import '../../support/audit_screenshot_support.dart';
import 'finance_requirement_test_ui.dart';

const _capture = bool.fromEnvironment('UTEN_CAPTURE_FINANCE_PARTY_UI');
final _boundary = GlobalKey();

void main() {
  for (final status in [503, 403]) {
    testWidgets(
      'legacy accepted read $status preserves input and retires only denied presentation',
      (tester) async {
        final api = _Api();
        final environment = await _pump(tester, api);
        final finder = find.byWidgetPredicate(
          (w) =>
              w is MasterDataTableView<Map<String, dynamic>> &&
              w.tableKey == 'finance.native-legacy-openings.sources',
        );
        final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
          finder,
        );
        table.onSelectedIdsChanged!({table.idOf!(table.items.single)!});
        await tester.pumpAndSettle();
        final field = find.byKey(
          ValueKey('legacy-opening-local-${table.idOf!(table.items.single)!}'),
        );
        await tester.enterText(field, '0.000000000000000000000001');
        final input = tester.widget<UtenInput>(field).controller!;
        api.readError = ApiException(
          status == 403 ? 'FORBIDDEN' : 'UNAVAILABLE',
          'legacy read $status',
          httpStatus: status,
        );
        await Future<void>.sync(table.onRetry!);
        await tester.pumpAndSettle();
        if (status == 403) {
          expect(
            find.byType(MasterDataTableView<Map<String, dynamic>>),
            findsNothing,
          );
          table.onSelectedIdsChanged!({});
          await tester.pump();
          expect(
            find.byWidgetPredicate(
              (w) =>
                  w is UtenFieldHintIcon && w.errorMessage == 'legacy read 403',
            ),
            findsOneWidget,
          );
        } else {
          expect(
            tester
                .widget<MasterDataTableView<Map<String, dynamic>>>(finder)
                .items,
            hasLength(1),
          );
        }
        expect(input.text, '0.000000000000000000000001');
        expect(api.saved, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        environment.dispose();
      },
    );
  }
  testWidgets(
    'all 251 exact legacy opening allocations load once with first-page ledger metadata',
    (tester) async {
      final api = _Api()..sourceCount = 251;
      final environment = await _pump(tester, api);
      final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
        find.byWidgetPredicate(
          (widget) =>
              widget is MasterDataTableView<Map<String, dynamic>> &&
              widget.tableKey == 'finance.native-legacy-openings.sources',
        ),
      );
      expect(table.items, hasLength(251));
      expect((table.items.last['reference'] as Map)['allocationNo'], 251);
      // Progressive complete read (2026-11-08): 50, then aligned 50/100/200 —
      // offsets 0/50/100/200, every allocation exactly once.
      expect(api.sourceQueries.map((query) => query['page']), [1, 2, 2, 2]);
      expect(api.sourceQueries.map((query) => query['size']), [
        50,
        50,
        100,
        200,
      ]);
      final legacy = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
        find.byWidgetPredicate(
          (widget) =>
              widget is MasterDataTableView<Map<String, dynamic>> &&
              widget.tableKey == 'finance.native-legacy-openings.legacy',
        ),
      );
      expect(legacy.items.single['local'], '700.0000');
      expect(api.saved, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      environment.dispose();
    },
  );

  testWidgets(
    'a failed legacy source tail never publishes its first hundred as a complete set',
    (tester) async {
      final api = _Api()
        ..sourceCount = 251
        ..failTail = true;
      final environment = await _pump(tester, api);
      final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
        find.byWidgetPredicate(
          (widget) =>
              widget is MasterDataTableView<Map<String, dynamic>> &&
              widget.tableKey == 'finance.native-legacy-openings.sources',
        ),
      );
      expect(table.items, isEmpty);
      expect(api.sourceQueries.map((query) => query['page']), [1, 2]);
      expect(api.saved, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      environment.dispose();
    },
  );

  testWidgets(
    'legacy share retry preserves exact source and native money without creating a second relationship',
    (tester) async {
      final api = _Api()..loseFirst = true;
      final environment = await _pump(tester, api);
      await tester.tap(find.text('2202').first);
      await tester.pumpAndSettle();
      final local = find
          .byWidgetPredicate(
            (widget) =>
                widget is UtenInput &&
                widget.key is ValueKey<String> &&
                (widget.key! as ValueKey<String>).value.startsWith(
                  'legacy-opening-local-',
                ),
          )
          .first;
      await tester.ensureVisible(local);
      final localField = find
          .descendant(of: local, matching: find.byType(TextField))
          .first;
      final rawLong = '8' * 130 + '.000000000000000000000000000001';
      await tester.enterText(localField, rawLong);
      expect(tester.widget<TextField>(localField).controller!.text, rawLong);
      await tester.enterText(localField, '700.0000');
      await tester.pumpAndSettle();
      await tester.ensureVisible(financeTextField('原期初与旧未结接续依据'));
      await tester.enterText(
        financeTextField('原期初与旧未结接续依据'),
        '双源核对真实UUID，原GL5000中旧未结仅700',
      );
      if (_capture) {
        await tester.pumpAndSettle();
        await saveAuditScreenshot(tester, _boundary, '旧未结接续-实际组件');
      }
      await tester.tap(find.text('保存待审核接续'));
      await tester.pumpAndSettle();
      expect(api.saved, hasLength(1));
      expect(
        tester.widget<TextField>(financeTextField('原期初与旧未结接续依据')).enabled,
        isFalse,
      );
      await tester.tap(find.text('核对并重试原提交'));
      await tester.pumpAndSettle();
      expect(api.saved, hasLength(2));
      expect(jsonEncode(api.saved.first), jsonEncode(api.saved.last));
      final share = (api.saved.first['shares'] as List).single as Map;
      expect(share['ledgerId'], 'old-ledger');
      expect(share['entryId'], 'real-opening-entry');
      expect(share['amountLocal'], '700.0000');
      expect(share['nativeOriginal'], '700.0000');
      expect(api.actual, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      environment.dispose();
    },
  );
  testWidgets(
    'narrow enlarged legacy source view keeps the real 5000 source and rejects missing assignment',
    (tester) async {
      final api = _Api();
      final environment = await _pump(tester, api, width: 390, scale: 1.5);
      await tester.tap(find.text('保存待审核接续'));
      await tester.pumpAndSettle();
      final hint = find.byWidgetPredicate(
        (widget) =>
            widget is UtenFieldHintIcon &&
            widget.errorMessage == '请选择原账套期初分配并填写接续依据。',
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
    'private unknown opening-share draft restores exact source and stable request after interruption',
    (tester) async {
      final api = _Api()..loseFirst = true;
      final storage = MemoryFormDraftStorage();
      var environment = await _pump(tester, api, storage: storage);
      await tester.tap(find.text('2202').first);
      await tester.pumpAndSettle();
      await tester.ensureVisible(financeTextField('原期初与旧未结接续依据'));
      await tester.enterText(
        financeTextField('原期初与旧未结接续依据'),
        '原源5000中明确700的私有接续草稿',
      );
      await tester.tap(find.text('保存待审核接续'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      final draft = environment.read(formDraftsProvider).single;
      expect(draft.hasUnknownSubmission, isTrue);
      expect(draft.route, contains('ledgerId=old-ledger'));
      expect(api.saved, hasLength(1));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      environment.dispose();
      environment = await _pump(
        tester,
        api,
        storage: storage,
        resumeDraftId: draft.id,
      );
      expect(find.text('核对并重试原提交'), findsOneWidget);
      await tester.tap(find.text('核对并重试原提交'));
      await tester.pumpAndSettle();
      expect(jsonEncode(api.saved.first), jsonEncode(api.saved.last));
      expect(api.actual, 1);
      expect(environment.read(formDraftsProvider), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      environment.dispose();
    },
  );
  testWidgets(
    'inflight opening share interruption restores the same body actor and headers without a new source read',
    (tester) async {
      final api = _Api()..gate = Completer<void>();
      final storage = MemoryFormDraftStorage();
      var environment = await _pump(tester, api, storage: storage);
      await tester.tap(find.text('2202').first);
      await tester.pumpAndSettle();
      await tester.enterText(
        financeTextField('原期初与旧未结接续依据'),
        '原HTTP尚未返回即中断，保留双源原始份额',
      );
      await tester.tap(find.text('保存待审核接续'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(api.saved, hasLength(1));
      expect(find.byType(UtenBusyOverlay), findsOneWidget);
      final pending = environment.read(formDraftsProvider).single;
      expect(pending.hasUnknownSubmission, isTrue);
      final body = jsonEncode(api.saved.single),
          headers = jsonEncode(api.savedHeaders.single);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      environment.dispose();
      api.gate!.complete();
      await tester.pumpAndSettle();
      api.refuseSources = true;
      environment = await _pump(
        tester,
        api,
        storage: storage,
        resumeDraftId: pending.id,
      );
      expect(find.text('核对并重试原提交'), findsOneWidget);
      expect(
        tester.widget<TextField>(financeTextField('原期初与旧未结接续依据')).enabled,
        isFalse,
      );
      await tester.tap(find.text('核对并重试原提交'));
      await tester.pumpAndSettle();
      expect(api.saved, hasLength(2));
      expect(jsonEncode(api.saved.last), body);
      expect(jsonEncode(api.savedHeaders.last), headers);
      expect(api.actual, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      environment.dispose();
    },
  );
  testWidgets(
    'lost write permission only reads the owned inflight receipt and lost read permission never restores business snapshots',
    (tester) async {
      final api = _Api()..gate = Completer<void>();
      final storage = MemoryFormDraftStorage();
      var environment = await _pump(tester, api, storage: storage);
      await tester.tap(find.text('2202').first);
      await tester.pumpAndSettle();
      await tester.enterText(
        financeTextField('原期初与旧未结接续依据'),
        '恢复后无写权限只能核对本人真实回执',
      );
      await tester.tap(find.text('保存待审核接续'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      final pending = environment.read(formDraftsProvider).single;
      final denied = MemoryFormDraftStorage()..records.addAll(storage.records);
      final sourceReads = api.sourceReads;
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      environment.dispose();
      api.gate!.complete();
      await tester.pumpAndSettle();
      api.refuseSources = true;
      environment = await _pump(
        tester,
        api,
        storage: storage,
        resumeDraftId: pending.id,
        permissions: const {
          'finance_report:view',
          'finance:view:all',
          'ar_ap_ledger:view',
        },
      );
      expect(find.text('保存待审核接续'), findsNothing);
      expect(find.text('核对并重试原提交'), findsNothing);
      await tester.tap(find.text('只读核对本人原结果'));
      await tester.pumpAndSettle();
      expect(api.receiptReads, 1);
      expect(api.saved, hasLength(1));
      expect(api.actual, 1);
      expect(api.sourceReads, sourceReads);
      expect(environment.read(formDraftsProvider), isEmpty);
      await tester.pumpWidget(const SizedBox());
      environment.dispose();
      environment = await _pump(
        tester,
        api,
        storage: denied,
        resumeDraftId: pending.id,
        permissions: const {'finance_report:view', 'finance:view:all'},
      );
      expect(find.text('2202'), findsNothing);
      expect(find.textContaining('5000'), findsNothing);
      expect(api.sourceReads, sourceReads);
      expect(api.saved, hasLength(1));
      expect(denied.records, isNotEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      environment.dispose();
    },
  );
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _Api api, {
  double width = 1200,
  double scale = 1,
  MemoryFormDraftStorage? storage,
  String? resumeDraftId,
  Set<String>? permissions,
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
          const AuthenticatedScope(userId: 'legacy-reviewer'),
        ),
      if (storage != null) formDraftStorageProvider.overrideWithValue(storage),
      apiBaseUrlProvider.overrideWithValue('https://legacy-draft.test/api'),
      sessionProvider.overrideWith(_Session.new),
      apiClientProvider.overrideWithValue(api),
      currentPermissionsProvider.overrideWithValue(
        permissions ??
            const {
              'payment_style:edit',
              'finance_post:execute',
              'finance_report:view',
              'finance:view:all',
              'ar_ap_ledger:view',
            },
      ),
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
              onPressed: () => showFinanceNativeLegacyOpeningDialog(
                context,
                ledgerId: 'old-ledger',
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
  bool loseFirst = false, refuseSources = false;
  Completer<void>? gate;
  int sourceReads = 0, receiptReads = 0;
  int sourceCount = 1;
  bool failTail = false;
  ApiException? readError;
  final sourceQueries = <Map<String, dynamic>>[];
  final savedHeaders = <Map<String, dynamic>>[];
  int actual = 0;
  final saved = <Map<String, dynamic>>[];
  static final source = <String, dynamic>{
    'reference': {'entryId': 'real-opening-entry', 'allocationNo': 1},
    'accountCode': '2202',
    'accountName': '应付账款',
    'accountingCurrencyId': 'base',
    'amountLocal': '5000.0000',
    'amountOriginal': '5000.0000',
    'effectiveFrom': '2026-10-01',
    'auxiliary': {'sourceName': '原供应商', 'sourceCode': 'SOURCE-SUP'},
  };
  Map<String, dynamic> get review => {
    'id': 'review-1',
    'status': 'DRAFT',
    'source_reference': '双源核对',
    'plan': {
      'targets': [
        {
          'legacy': {
            'ledgerId': 'old-ledger',
            'billNo': 'CJ-ORIGINAL',
            'local': '700.0000',
            'original': '700.0000',
          },
        },
      ],
      'items': [
        {
          'request': {
            'ledgerId': 'old-ledger',
            'entryId': 'real-opening-entry',
            'allocationNo': 1,
            'amountLocal': '700.0000',
            'nativeOriginal': '700.0000',
          },
          'source': source,
          'financialOriginal': '700.0000',
        },
      ],
    },
  };
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('/operations/')) {
      receiptReads++;
      return {
        ...review,
        'receiptRequestId': path.split('/').last,
        'receiptActorId': 'legacy-reviewer',
      };
    }
    if (refuseSources) {
      throw StateError(
        'pending source snapshot must never be replaced by a fresh GET',
      );
    }
    sourceReads++;
    if (path.endsWith('/choices')) {
      return {
        'currencies': [
          {'id': 'base', 'code': 'CNY', 'name': '人民币'},
        ],
      };
    }
    if (path.endsWith('/review-1')) return review;
    sourceQueries.add(Map<String, dynamic>.from(query ?? {}));
    if (readError != null) throw readError!;
    final page = (query?['page'] as num?)?.toInt() ?? 1;
    final size = (query?['size'] as num?)?.toInt() ?? 100;
    if (page > 1 && failTail) throw StateError('held source tail failure');
    return {
      'legacy': {
        'ledgerId': 'old-ledger',
        'currencyId': 'base',
        'cutoff': '2026-09-30',
        'local': '700.0000',
        'original': '700.0000',
      },
      'sources': {
        'items': [
          for (
            var i = (page - 1) * size;
            i < sourceCount && i < page * size;
            i++
          )
            sourceCount == 1
                ? source
                : {
                    ...source,
                    'reference': {
                      'entryId': 'real-opening-entry',
                      'allocationNo': i + 1,
                    },
                  },
        ],
        'page': page,
        'size': size,
        'total': sourceCount,
        'totalPages': (sourceCount + size - 1) ~/ size,
      },
      'reviews': actual == 0 ? <Map<String, dynamic>>[] : [review],
    };
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    saved.add(Map<String, dynamic>.from(body! as Map));
    savedHeaders.add(Map<String, dynamic>.from(headers ?? {}));
    if (gate != null) {
      await gate!.future;
      gate = null;
    }
    actual = 1;
    if (loseFirst) {
      loseFirst = false;
      throw ApiException('NETWORK_ERROR', '响应未收到');
    }
    return review;
  }
}
