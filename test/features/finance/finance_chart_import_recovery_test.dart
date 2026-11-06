import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/finance/pages/finance_hub_page.dart';
import 'package:uten_imp/features/finance/widgets/finance_chart_import_workbench.dart';
import 'package:uten_imp/features/finance/widgets/finance_entry_file_picker.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import '../../shared/drafts/memory_form_draft_storage.dart';
import '../../support/finance_command_test_support.dart';
import '../../support/finance_chart_import_test_support.dart';
import '../../support/native_detail_reader_overrides.dart';

// Java/Postgres UUID identities may have non-RFC version bits. These are
// server-owned preview identities, not replacement client-generated intents.
const _root = financeChartImportTestRoot, _child = financeChartImportTestChild;
final _bytes = financeChartImportTestBytes, _sha = financeChartImportTestSha;
final _grants = StateProvider<Set<String>>((_) => {});

typedef _Transport = FinanceChartImportTestTransport;

class _Env {
  _Env(this.container, this.dio, this.router);
  final ProviderContainer container;
  final Dio dio;
  final GoRouter? router;
  Future<void> close(WidgetTester t) async {
    await t.pumpWidget(const SizedBox.shrink());
    router?.dispose();
    container.dispose();
    dio.close(force: true);
  }
}

Future<_Env> _open(
  WidgetTester t,
  _Transport transport,
  MemoryFormDraftStorage storage, {
  FormDraft? resume,
  bool hub = false,
  bool write = true,
  bool read = true,
  String pickedName = '本次选择别名.xls',
  double width = 1280,
  double scale = 1,
}) async {
  await t.binding.setSurfaceSize(Size(width, 900));
  addTearDown(() => t.binding.setSurfaceSize(null));
  final dio = Dio(BaseOptions(baseUrl: 'https://finance-command.test/api'))
    ..httpClientAdapter = transport;
  final container = ProviderContainer(
    overrides: [
      ...nativeDetailReaderOverrides(
        includeSession: false,
        includeServer: false,
      ),
      sessionProvider.overrideWith(FinanceChartImportTestSession.new),
      authenticatedScopeProvider.overrideWithValue(
        const AuthenticatedScope(userId: financeCommandTestActor),
      ),
      apiBaseUrlProvider.overrideWithValue('https://finance-command.test/api'),
      apiClientProvider.overrideWithValue(ApiClient(dio)),
      currentPermissionsProvider.overrideWith((ref) => ref.watch(_grants)),
      _grants.overrideWith(
        (_) => {
          if (read) ...{Perm.financeReportView, Perm.financeViewAll},
          if (write) Perm.paymentStyleEdit,
        },
      ),
      sharedPreferencesProvider.overrideWithValue(
        await SharedPreferences.getInstance(),
      ),
      formDraftStorageProvider.overrideWithValue(storage),
      financeEntryFilePickerProvider.overrideWithValue(
        () async =>
            PlatformFile(name: pickedName, size: _bytes.length, bytes: _bytes),
      ),
    ],
  );
  GoRouter? router;
  final Widget app;
  if (hub) {
    final uri = Uri.parse(resume!.route);
    router = GoRouter(
      initialLocation: uri
          .replace(
            queryParameters: {...uri.queryParameters, 'draftId': resume.id},
          )
          .toString(),
      routes: [
        GoRoute(path: '/finance', builder: (_, _) => const FinanceHubPage()),
      ],
    );
    app = MaterialApp.router(
      theme: buildLightTheme(),
      routerConfig: router,
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
    );
  } else {
    app = MaterialApp(
      theme: buildLightTheme(),
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showFinanceChartImportWorkbench(
              context,
              resumeDraftId: resume?.id,
            ),
            child: const Text('打开导入'),
          ),
        ),
      ),
    );
  }
  await t.pumpWidget(
    UncontrolledProviderScope(container: container, child: app),
  );
  await t.pumpAndSettle();
  if (!hub) {
    await t.tap(find.text('打开导入'));
    await t.pumpAndSettle();
  }
  return _Env(container, dio, router);
}

Finder button(String text) =>
    find.widgetWithText(UtenButton, text).hitTestable();
Future<void> action(WidgetTester t, String text) async {
  await tapFinanceOriginalAction(t, text);
  await t.pumpAndSettle();
}

void main() {
  setUp(prepareFinanceCommandTest);
  testWidgets(
    'unknown private upload persists only sha/name/size before dispatch, Hub lookup recovers original renamed source without another upload',
    (t) async {
      final transport = _Transport()..loseUpload = true;
      final storage = MemoryFormDraftStorage();
      String? before;
      transport.beforeUpload = () {
        before = storage.records.values.join('\n');
      };
      var env = await _open(t, transport, storage);
      expect(transport.uploads, 1);
      expect(before, isNotNull);
      expect(before, contains(_sha));
      expect(before, contains('本次选择别名.xls'));
      expect(before, contains('"storageSize":${_bytes.length}'));
      final draft = env.container.read(formDraftsProvider).single;
      expect((draft.data['upload'] as Map)['sha256'], _sha);
      expect((draft.data['upload'] as Map)['sourceName'], '本次选择别名.xls');
      expect((draft.data['upload'] as Map)['storageSize'], _bytes.length);
      expect(jsonEncode(draft.data), isNot(contains('原件字面科目名称')));
      expect(jsonEncode(draft.data), isNot(contains(base64Encode(_bytes))));
      await t.tap(button('稍后核对'));
      await t.pumpAndSettle();
      await env.close(t);
      env = await _open(
        t,
        transport,
        storage,
        resume: draft,
        hub: true,
        write: false,
      );
      expect(
        transport.calls.where(
          (call) => call.path == '/finance/chart/imports/by-sha/$_sha',
        ),
        hasLength(1),
      );
      expect(transport.uploads, 1);
      expect(transport.applyCalls, isEmpty);
      expect(find.text('原始目录.xls'), findsWidgets);
      expect(find.text('本次选择别名.xls'), findsWidgets);
      expect(t.takeException(), isNull);
      await env.close(t);
    },
  );
  testWidgets(
    'apply lost success keeps original nonRFC importId, real Hub reads original receipt with write loss without another mutation',
    (t) async {
      final transport = _Transport(), storage = MemoryFormDraftStorage();
      var env = await _open(t, transport, storage);
      await t.tap(button('确认导入科目目录'));
      await t.pumpAndSettle();
      expect(transport.applied, 1);
      expect(transport.applyCalls.single.body, {'importId': _root});
      final draft = env.container.read(formDraftsProvider).single;
      expect((draft.data['pending'] as Map)['body'], {'importId': _root});
      await t.tap(button('稍后核对'));
      await t.pumpAndSettle();
      await env.close(t);
      env = await _open(
        t,
        transport,
        storage,
        resume: draft,
        hub: true,
        write: false,
      );
      expect(find.textContaining('原批次已确认导入'), findsWidgets);
      await action(t, '核对原导入结果');
      expect(transport.applyCalls, hasLength(1));
      expect(transport.applied, 1);
      expect(env.container.read(formDraftsProvider), isEmpty);
      expect(t.takeException(), isNull);
      await env.close(t);
    },
  );
  testWidgets(
    'stale apply GET false never releases; cancellation stops old ID, explicit repreview creates child with new current versions and no upload',
    (t) async {
      final transport = _Transport()
        ..rejectApply = true
        ..loseApply = false;
      final storage = MemoryFormDraftStorage();
      final env = await _open(t, transport, storage);
      final originalRows = jsonEncode(transport.preview(_root)['rows']);
      final oldConfirm = t.widget<UtenButton>(button('确认导入科目目录')).onPressed!;
      await t.tap(button('确认导入科目目录'));
      await t.pumpAndSettle();
      await action(t, '核对原导入结果');
      expect(button('重试原导入请求'), findsOneWidget);
      await action(t, '核实未写并保留输入');
      expect(button('确认导入科目目录'), findsNothing);
      transport.currentVersion = 9;
      transport.rejectApply = false;
      await t.tap(button('按当前版本重新预览').last);
      await t.pumpAndSettle();
      expect(transport.reviewCalls, hasLength(1));
      expect(transport.reviews, 1);
      expect(transport.uploads, 1);
      expect(jsonEncode(transport.preview(_root)['rows']), originalRows);
      expect(
        ((transport.preview(_child)['rows'] as List).single
            as Map)['existingVersion'],
        9,
      );
      expect(
        ((transport.preview(_child)['rows'] as List).single as Map)['code'],
        '1001',
      );
      expect(
        ((transport.preview(_child)['rows'] as List).single as Map)['name'],
        '原件字面科目名称',
      );
      oldConfirm();
      await t.pumpAndSettle();
      expect(transport.applyCalls, hasLength(1));
      await t.tap(button('确认导入科目目录'));
      await t.pumpAndSettle();
      expect(transport.applyCalls.map((call) => call.body), [
        {'importId': _root},
        {'importId': _child},
      ]);
      expect(transport.applied, 1);
      expect(env.container.read(formDraftsProvider), isEmpty);
      await env.close(t);
    },
  );
  testWidgets(
    'repreview lost success restores original UUID and parent through Hub, loads child and still requires explicit apply',
    (t) async {
      final transport = _Transport()
        ..rejectApply = true
        ..loseApply = false
        ..loseReview = true;
      final storage = MemoryFormDraftStorage();
      var env = await _open(t, transport, storage);
      await t.tap(button('确认导入科目目录'));
      await t.pumpAndSettle();
      await action(t, '核实未写并保留输入');
      await t.tap(button('按当前版本重新预览').last);
      await t.pumpAndSettle();
      final original = transport.reviewCalls.single.body;
      final draft = env.container.read(formDraftsProvider).single;
      await env.close(t);
      env = await _open(
        t,
        transport,
        storage,
        resume: draft,
        hub: true,
        write: false,
      );
      await action(t, '核对原导入结果');
      expect(transport.reviewCalls.single.body, original);
      expect(transport.reviewCalls, hasLength(1));
      expect(transport.applied, 0);
      expect(transport.uploads, 1);
      expect(
        (env.container.read(formDraftsProvider).single.data)['previewId'],
        _child,
      );
      expect(t.takeException(), isNull);
      await env.close(t);
    },
  );
  testWidgets(
    'by-sha not found never claims unsaved, later keeps private upload without a financial cancellation',
    (t) async {
      final transport = _Transport()
        ..loseUpload = true
        ..lookupMissing = true;
      final env = await _open(t, transport, MemoryFormDraftStorage());
      await t.tap(button('核对原上传'));
      await t.pumpAndSettle();
      expect(find.textContaining('不能据此认定未上传'), findsOneWidget);
      await t.tap(button('稍后核对'));
      await t.pumpAndSettle();
      expect(env.container.read(formDraftsProvider), hasLength(1));
      expect(transport.applyCalls, isEmpty);
      expect(
        transport.calls.where((call) => call.path.endsWith('/cancel')),
        isEmpty,
      );
      expect(t.takeException(), isNull);
      await env.close(t);
    },
  );
  testWidgets(
    'read withdrawal does not expose old import data or send another upload or application',
    (t) async {
      final transport = _Transport();
      final storage = MemoryFormDraftStorage();
      var env = await _open(t, transport, storage);
      await t.tap(button('确认导入科目目录'));
      await t.pumpAndSettle();
      final draft = env.container.read(formDraftsProvider).single;
      await env.close(t);
      env = await _open(
        t,
        transport,
        storage,
        resume: draft,
        read: false,
        write: false,
      );
      expect(find.text('访问范围已变化'), findsOneWidget);
      expect(find.text('原件字面科目名称'), findsNothing);
      expect(transport.uploads, 1);
      expect(transport.applyCalls, hasLength(1));
      expect(storage.records, isNotEmpty);
      expect(t.takeException(), isNull);
      await env.close(t);
    },
  );
  testWidgets(
    'apply cancellation response loss is recovered by original GET and never releases the stopped ID for apply',
    (t) async {
      final transport = _Transport()
        ..rejectApply = true
        ..loseCancel = true;
      final storage = MemoryFormDraftStorage();
      var env = await _open(t, transport, storage);
      await t.tap(button('确认导入科目目录'));
      await t.pumpAndSettle();
      await action(t, '核实未写并保留输入');
      expect(button('重试原导入请求'), findsOneWidget);
      final draft = env.container.read(formDraftsProvider).single;
      await env.close(t);
      transport.loseCancel = false;
      env = await _open(t, transport, storage, resume: draft, hub: true);
      await action(t, '核对原导入结果');
      expect(button('确认导入科目目录'), findsNothing);
      expect(transport.applyCalls, hasLength(1));
      expect(transport.applied, 0);
      final retained = env.container.read(formDraftsProvider).single;
      expect(retained.data['pending'], isNull);
      expect(
        ((retained.data['retired'] as Map)['receipt'] as Map)['outcome'],
        'CANCELLED_UNWRITTEN',
      );
      expect(t.takeException(), isNull);
      await env.close(t);
    },
  );
  testWidgets(
    'late original apply after hard disposal cannot overtake a cancellation tombstone or republish into the recovered owner',
    (t) async {
      final gate = Completer<void>();
      final transport = _Transport()
        ..holdApply = gate
        ..loseApply = false;
      final storage = MemoryFormDraftStorage();
      var env = await _open(t, transport, storage);
      final submit = t.widget<UtenButton>(button('确认导入科目目录')).onPressed!;
      submit();
      submit();
      await t.pump();
      await t.pump(const Duration(milliseconds: 150));
      expect(transport.applyCalls, hasLength(1));
      expect(transport.applied, 0);
      final draft = env.container.read(formDraftsProvider).single;
      await env.close(t);
      await t.pumpAndSettle();
      env = await _open(t, transport, storage, resume: draft, hub: true);
      await action(t, '核实未写并保留输入');
      gate.complete();
      await t.pumpAndSettle();
      expect(transport.applied, 0);
      expect(transport.applyCalls, hasLength(1));
      final retained = env.container.read(formDraftsProvider).single;
      expect(retained.data['pending'], isNull);
      expect(
        ((retained.data['retired'] as Map)['receipt'] as Map)['requestId'],
        _root,
      );
      expect(button('确认导入科目目录'), findsNothing);
      expect(t.takeException(), isNull);
      await env.close(t);
    },
  );
  testWidgets(
    'a successful repreview envelope with wrong lineage cannot clear its original request or enable apply',
    (t) async {
      final transport = _Transport()
        ..rejectApply = true
        ..wrongReview = true;
      final env = await _open(t, transport, MemoryFormDraftStorage());
      await t.tap(button('确认导入科目目录'));
      await t.pumpAndSettle();
      await action(t, '核实未写并保留输入');
      await t.tap(button('按当前版本重新预览').last);
      await t.pumpAndSettle();
      expect(button('重试原导入请求'), findsOneWidget);
      expect(button('确认导入科目目录'), findsNothing);
      final pending =
          env.container.read(formDraftsProvider).single.data['pending'] as Map;
      expect(pending['sourceId'], _root);
      expect(pending['operation'], 'CHART_IMPORT_REPREVIEW');
      expect(transport.applyCalls, hasLength(1));
      expect(transport.applied, 0);
      expect(t.takeException(), isNull);
      await env.close(t);
    },
  );
  testWidgets(
    'narrow enlarged original preview and original request actions remain reachable',
    (t) async {
      final transport = _Transport(),
          env = await _open(
            t,
            transport,
            MemoryFormDraftStorage(),
            width: 390,
            scale: 1.5,
          );
      expect(t.takeException(), isNull);
      await t.tap(button('确认导入科目目录'));
      await t.pumpAndSettle();
      await action(t, '核对原导入结果');
      expect(transport.applied, 1);
      expect(t.takeException(), isNull);
      await env.close(t);
    },
  );
}
