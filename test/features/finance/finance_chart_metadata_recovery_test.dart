import '../../support/finance_command_test_support.dart';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/buttons/uten_close_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/finance/pages/finance_hub_page.dart';
import 'package:uten_imp/features/finance/widgets/finance_chart_metadata_dialog.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/drafts/form_draft.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import '../../shared/drafts/memory_form_draft_storage.dart';

const _actor = '00000000-0000-0000-0000-000000000101';
final _grants = StateProvider<Set<String>>(
  (_) => {Perm.financeReportView, Perm.financeViewAll, Perm.paymentStyleEdit},
);

void main() {
  testWidgets(
    'fresh conflict and missing receipt keep the original metadata frozen until cancellation proof, current single-account review and explicit new save',
    (tester) async {
      final api = _Api()
        ..rejectSaves = true
        ..loseFirstCancel = true;
      final storage = MemoryFormDraftStorage();
      var harness = await _mount(tester, api, storage);
      await _editAndSend(tester);
      final original = Map<String, dynamic>.from(api.writes.single);
      final draft = harness.container.read(formDraftsProvider).single;
      expect(draft.hasUnknownSubmission, isTrue);
      expect(_input(tester, '科目名称').enabled, isFalse);
      await tapFinanceOriginalAction(tester, '核对原修改结果');
      await tester.pumpAndSettle();
      expect(
        harness.container.read(formDraftsProvider).single.hasUnknownSubmission,
        isTrue,
      );
      await tapFinanceOriginalAction(tester, '核实未写并保留输入');
      await tester.pumpAndSettle();
      expect(
        harness.container.read(formDraftsProvider).single.hasUnknownSubmission,
        isTrue,
      );
      expect(api.cancellationCommits, 1);
      await _unmount(tester, harness);
      api.currentVersion = 99;
      api.currentName = '当前他人维护的名称';
      final uri = Uri.parse(draft.route);
      harness = await _mount(
        tester,
        api,
        storage,
        location: uri
            .replace(
              queryParameters: {...uri.queryParameters, 'draftId': draft.id},
            )
            .toString(),
      );
      expect(
        harness.container.read(formDraftsProvider).single.data['sent'],
        original,
      );
      await tapFinanceOriginalAction(tester, '核对原修改结果');
      await tester.pumpAndSettle();
      expect(find.text('核对当前设置'), findsOneWidget);
      expect(_input(tester, '科目名称').enabled, isTrue);
      expect(_input(tester, '科目名称').controller!.text, '库存现金（原名称修订）');
      final late = await api.put(
        '/finance/chart/1001/metadata',
        body: original,
      );
      expect(late['status'], 'CANCELLED_UNWRITTEN');
      expect(api.commits, 0);
      await tester.tap(find.text('核对当前设置'));
      await tester.pumpAndSettle();
      expect(api.metadataReads, 1);
      expect(find.text('当前他人维护的名称'), findsOneWidget);
      await tester.tap(find.text('采用当前版本，保留输入'));
      await tester.pumpAndSettle();
      expect(api.commits, 0);
      expect(
        harness.container.read(formDraftsProvider).single.data['requestId'],
        original['requestId'],
      );
      api.rejectSaves = false;
      await tester.tap(find.text('保存名称'));
      await tester.pumpAndSettle();
      expect(api.writes.last['requestId'], isNot(original['requestId']));
      expect(api.writes.last['expectedVersion'], 99);
      expect(api.writes.last['name'], original['name']);
      expect(api.writes.last['sourceReference'], original['sourceReference']);
      expect(api.commits, 1);
      expect(harness.container.read(formDraftsProvider), isEmpty);
      expect(tester.takeException(), isNull);
      await _unmount(tester, harness);
    },
  );

  testWidgets(
    'metadata cancellation remains readable after write loss and never permits a new PUT',
    (tester) async {
      final api = _Api()..rejectSaves = true;
      final harness = await _mount(tester, api, MemoryFormDraftStorage());
      await _editAndSend(tester);
      harness.container.read(_grants.notifier).state = {
        Perm.financeReportView,
        Perm.financeViewAll,
      };
      await tester.pumpAndSettle();
      await tapFinanceOriginalAction(tester, '核实未写并保留输入');
      await tester.pumpAndSettle();
      expect(find.text('核对当前设置'), findsOneWidget);
      await tester.tap(find.text('核对当前设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('采用当前版本，保留输入'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<UtenButton>(find.widgetWithText(UtenButton, '保存名称'))
            .onPressed,
        isNull,
      );
      expect(api.writes, hasLength(1));
      expect(api.commits, 0);
      await _unmount(tester, harness);
    },
  );

  testWidgets(
    'metadata later-check exit retains its unknown original request without another write',
    (tester) async {
      final api = _Api()..rejectSaves = true;
      final harness = await _mount(tester, api, MemoryFormDraftStorage());
      await _editAndSend(tester);
      await tester.tap(
        find
            .byWidgetPredicate(
              (widget) => widget is UtenCloseButton && widget.tooltip == '稍后核对',
            )
            .hitTestable(),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('finance-chart-metadata-editor')),
        findsNothing,
      );
      expect(
        harness.container.read(formDraftsProvider).single.hasUnknownSubmission,
        isTrue,
      );
      expect(api.writes, hasLength(1));
      await _unmount(tester, harness);
    },
  );
  testWidgets(
    'hard reopen through the real financial hub replays the original metadata body and version after another edit',
    (tester) async {
      final api = _Api()..loseFirst = true;
      final storage = MemoryFormDraftStorage();
      var harness = await _mount(tester, api, storage);
      await _editAndSend(tester);
      final original = jsonEncode(api.writes.single);
      final draft = harness.container.read(formDraftsProvider).single;
      expect(draft.hasUnknownSubmission, isTrue);
      expect(draft.data['sent'], api.writes.single);
      expect(api.writes.single['expectedVersion'], 7);
      expect(_input(tester, '科目名称').enabled, isFalse);
      await _unmount(tester, harness);

      api.currentVersion = 99;
      harness = await _mount(tester, api, storage, location: _resume(draft));
      expect(_input(tester, '科目名称').controller!.text, '库存现金（原名称修订）');
      expect(_input(tester, '修改依据').controller!.text, '原财务核对依据 12.');
      expect(_input(tester, '科目名称').enabled, isFalse);
      expect(api.writes, hasLength(1));
      await tester.tap(find.text('重试原修改请求'));
      await tester.pumpAndSettle();
      expect(api.writes, hasLength(2));
      expect(jsonEncode(api.writes.last), original);
      expect(api.commits, 1);
      expect(api.currentVersion, 99);
      expect(harness.container.read(formDraftsProvider), isEmpty);
      expect(tester.takeException(), isNull);
      await _unmount(tester, harness);
    },
  );

  testWidgets(
    'an unfinished name draft reopens without a PUT or replacing its original version',
    (tester) async {
      final api = _Api(), storage = MemoryFormDraftStorage();
      var harness = await _mount(tester, api, storage);
      await tester.tap(find.text('修改名称'));
      await tester.pumpAndSettle();
      await tester.enterText(_field('科目名称'), '原未完名称 12.');
      await tester.enterText(_field('修改依据'), '未完依据，不发送');
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      final draft = harness.container.read(formDraftsProvider).single;
      expect(draft.hasUnknownSubmission, isFalse);
      await _unmount(tester, harness);
      api.currentVersion = 100;
      harness = await _mount(tester, api, storage, location: _resume(draft));
      expect(_input(tester, '科目名称').controller!.text, '原未完名称 12.');
      expect(_input(tester, '修改依据').controller!.text, '未完依据，不发送');
      expect(_input(tester, '科目名称').enabled, isTrue);
      expect(
        harness.container
            .read(formDraftsProvider)
            .single
            .data['expectedVersion'],
        7,
      );
      expect(api.writes, isEmpty);
      expect(tester.takeException(), isNull);
      await _unmount(tester, harness);
    },
  );

  testWidgets(
    'losing write authority keeps the original receipt recovery available and never sends another PUT',
    (tester) async {
      final api = _Api()..loseFirst = true;
      final harness = await _mount(tester, api, MemoryFormDraftStorage());
      await _editAndSend(tester);
      final staleRetry = tester
          .widget<UtenButton>(find.widgetWithText(UtenButton, '重试原修改请求'))
          .onPressed;
      harness.container.read(_grants.notifier).state = {
        Perm.financeReportView,
        Perm.financeViewAll,
      };
      await tester.pumpAndSettle();
      await Future<void>.sync(staleRetry!);
      await tester.pumpAndSettle();
      expect(_input(tester, '科目名称').enabled, isFalse);
      expect(
        tester
            .widget<UtenButton>(find.widgetWithText(UtenButton, '重试原修改请求'))
            .onPressed,
        isNull,
      );
      expect(
        find.byKey(const Key('finance-chart-metadata-editor')),
        findsOneWidget,
      );
      await tapFinanceOriginalAction(tester, '核对原修改结果');
      await tester.pumpAndSettle();
      expect(api.writes, hasLength(1));
      expect(api.receiptReads, 1);
      expect(harness.container.read(formDraftsProvider), isEmpty);
      expect(find.text('名称已更新'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _unmount(tester, harness);
    },
  );

  for (final mismatch in ['actor', 'code', 'request', 'name']) {
    testWidgets(
      'a $mismatch mismatch cannot finish or unfreeze the original metadata request',
      (tester) async {
        final api = _Api()
          ..loseFirst = true
          ..mismatch = mismatch;
        final harness = await _mount(tester, api, MemoryFormDraftStorage());
        await _editAndSend(tester);
        final original = jsonEncode(api.writes.single);
        await tapFinanceOriginalAction(tester, '核对原修改结果');
        await tester.pumpAndSettle();
        expect(_input(tester, '科目名称').enabled, isFalse);
        expect(
          harness.container
              .read(formDraftsProvider)
              .single
              .hasUnknownSubmission,
          isTrue,
        );
        expect(jsonEncode(api.writes.single), original);
        expect(api.writes, hasLength(1));
        expect(tester.takeException(), isNull);
        await _unmount(tester, harness);
      },
    );
  }
}

Finder _field(String label) => find.descendant(
  of: find.byWidgetPredicate((w) => w is UtenInput && w.label == label),
  matching: find.byType(TextFormField),
);
UtenInput _input(WidgetTester tester, String label) => tester.widget<UtenInput>(
  find.byWidgetPredicate((w) => w is UtenInput && w.label == label),
);
Future<void> _editAndSend(WidgetTester tester) async {
  await tester.tap(find.text('修改名称'));
  await tester.pumpAndSettle();
  await tester.enterText(_field('科目名称'), '库存现金（原名称修订）');
  await tester.enterText(_field('修改依据'), '原财务核对依据 12.');
  await tester.tap(find.text('保存名称'));
  await tester.pumpAndSettle();
}

String _resume(FormDraft draft) => Uri.parse(draft.route)
    .replace(
      queryParameters: {
        ...Uri.parse(draft.route).queryParameters,
        'draftId': draft.id,
      },
    )
    .toString();

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _Harness {
  _Harness(this.container, this.router);
  final ProviderContainer container;
  final GoRouter router;
  void dispose() {
    router.dispose();
    container.dispose();
  }
}

Future<void> _unmount(WidgetTester tester, _Harness harness) async {
  await tester.pumpWidget(const SizedBox());
  harness.dispose();
}

Future<_Harness> _mount(
  WidgetTester tester,
  _Api api,
  MemoryFormDraftStorage storage, {
  String location = '/start',
}) async {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      apiBaseUrlProvider.overrideWithValue('https://chart-metadata.test/api'),
      sessionProvider.overrideWith(_Session.new),
      authenticatedScopeProvider.overrideWithValue(
        const AuthenticatedScope(userId: _actor),
      ),
      currentPermissionsProvider.overrideWith((ref) => ref.watch(_grants)),
      isSuperAdminProvider.overrideWithValue(false),
      sharedPreferencesProvider.overrideWithValue(prefs),
      formDraftStorageProvider.overrideWithValue(storage),
    ],
  );
  var updated = false;
  final router = GoRouter(
    initialLocation: location,
    routes: [
      GoRoute(
        path: '/start',
        builder: (_, _) => Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => Column(
              children: [
                TextButton(
                  onPressed: () async {
                    final result = await showFinanceChartMetadataDialog(
                      context,
                      code: '1001',
                      account: {
                        'code': '1001',
                        'name': '库存现金',
                        'version': api.currentVersion,
                      },
                    );
                    if (context.mounted) setState(() => updated = result);
                  },
                  child: const Text('修改名称'),
                ),
                if (updated) const Text('名称已更新'),
              ],
            ),
          ),
        ),
      ),
      GoRoute(path: '/finance', builder: (_, _) => const FinanceHubPage()),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Harness(container, router);
}

class _Api extends ApiClient {
  _Api() : super(Dio());
  bool loseFirst = false, rejectSaves = false, loseFirstCancel = false;
  String? mismatch;
  int currentVersion = 7, commits = 0, receiptReads = 0, metadataReads = 0;
  int cancellationCommits = 0;
  String currentName = '库存现金';
  final writes = <Map<String, dynamic>>[];
  final cancellations = <Map<String, dynamic>>[];
  final receipts = <String, Map<String, dynamic>>{};
  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    final sent = Map<String, dynamic>.from(body! as Map);
    writes.add(sent);
    final id = sent['requestId'].toString();
    final old = receipts[id];
    if (old != null) {
      if (!_sameBody(old['requestBody'] as Map, sent)) {
        throw StateError('原metadata请求编号不能用于不同正文');
      }
      return Map<String, dynamic>.from(old['result'] as Map);
    }
    if (rejectSaves || sent['expectedVersion'] != currentVersion) {
      throw ApiException(
        'CONFLICT',
        '科目目录已变化，请保留原请求核对',
        httpStatus: 409,
        hasResponseCode: true,
      );
    }
    commits++;
    final previous = currentName;
    currentName = sent['name'].toString();
    currentVersion++;
    final result = {
      'status': 'UPDATED',
      'code': '1001',
      'previousName': previous,
      'requestId': id,
      'name': sent['name'],
      'sourceReference': sent['sourceReference'],
    };
    receipts[id] = _envelope(sent, 'SUCCEEDED', result);
    if (loseFirst && writes.length == 1) throw NetworkTimeoutException();
    return result;
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('/metadata/operations/')) {
      receiptReads++;
      final stored = receipts[path.split('/').last];
      if (stored == null) return {'found': false};
      final response = _response(stored);
      if (response['outcome'] == 'CANCELLED_UNWRITTEN') return response;
      return {
        for (final key in [
          'found',
          'requestId',
          'actorId',
          'operation',
          'outcome',
          'result',
        ])
          key: response[key],
      };
    }
    if (path == '/finance/chart/1001/metadata') {
      metadataReads++;
      return {'code': '1001', 'name': currentName, 'version': currentVersion};
    }
    return {};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];
  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
    bool preserveUnauthorizedSession = false,
  }) async {
    if (path.endsWith('/cancel')) {
      final command = Map<String, dynamic>.from(body! as Map);
      cancellations.add(command);
      final sent = Map<String, dynamic>.from(command['requestBody'] as Map);
      final id = sent['requestId'].toString();
      if (command['actorId'] != _actor ||
          command['operation'] != 'CHART_METADATA_UPDATE' ||
          command['method'] != 'PUT' ||
          command['path'] != '/finance/chart/1001/metadata' ||
          command['requestId'] != id) {
        throw StateError('取消核对必须保留原actor、动作和请求');
      }
      final old = receipts[id];
      if (old != null && !_sameBody(old['requestBody'] as Map, sent)) {
        throw StateError('取消正文与原请求不同');
      }
      if (old == null) {
        cancellationCommits++;
        receipts[id] = _envelope(sent, 'CANCELLED_UNWRITTEN', {
          'cancelled': true,
          'status': 'CANCELLED_UNWRITTEN',
          'requestId': id,
          'code': '1001',
          'name': sent['name'],
          'sourceReference': sent['sourceReference'],
        });
      }
      if (loseFirstCancel && cancellations.length == 1) {
        throw NetworkTimeoutException();
      }
      return _response(receipts[id]!);
    }
    return {};
  }

  Map<String, dynamic> _envelope(
    Map<String, dynamic> sent,
    String outcome,
    Map<String, dynamic> result,
  ) => {
    'found': true,
    'requestId': sent['requestId'],
    'actorId': _actor,
    'operation': 'CHART_METADATA_UPDATE',
    'method': 'PUT',
    'path': '/finance/chart/1001/metadata',
    'requestBody': Map<String, dynamic>.from(sent),
    'outcome': outcome,
    'result': result,
  };
  Map<String, dynamic> _response(Map<String, dynamic> stored) {
    final copy = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(stored)) as Map,
    );
    final result = copy['result'] as Map;
    if (mismatch == 'actor') copy['actorId'] = 'another-actor';
    if (mismatch == 'code') result['code'] = '1002';
    if (mismatch == 'request') {
      copy['requestId'] = result['requestId'] =
          '00000000-0000-0000-0000-000000000999';
    }
    if (mismatch == 'name') result['name'] = '另一个名称';
    return copy;
  }

  bool _sameBody(Map<Object?, Object?> left, Map<Object?, Object?> right) =>
      left.length == right.length &&
      left.entries.every((entry) => right[entry.key] == entry.value);
}
