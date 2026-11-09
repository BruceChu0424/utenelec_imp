import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/components/layout/uten_pagination.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:uten_imp/components/buttons/uten_close_button.dart';
import 'package:uten_imp/components/buttons/uten_refresh_button.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/finance/widgets/finance_material_statement_dialog.dart';
import 'package:uten_imp/features/finance/config/finance_requirement_names.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_navigation.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import '../../shared/drafts/memory_form_draft_storage.dart';

const _ctx = '20000000-0000-4000-8000-000000000001',
    _evidence = '20000000-0000-4000-8000-000000000002';
final _scope = StateProvider<AuthenticatedScope?>(
  (ref) => const AuthenticatedScope(userId: 'material-maker'),
);
void main() {
  testWidgets(
    'material evidence permission rejection retires the accepted context on refresh',
    (t) async {
      await _size(t);
      final api = _Api(historyRows: 251);
      final env = await _pump(t, api, MemoryFormDraftStorage(), editor: false);
      expect(find.widgetWithText(UtenButton, '维护本组资料'), findsOneWidget);
      api.denyHistoryTail = true;
      final refreshing = Future<void>.sync(
        t.widget<UtenRefreshButton>(find.byType(UtenRefreshButton)).onRefresh,
      );
      await t.pumpAndSettle();
      await refreshing;
      expect(
        find.byType(MasterDataTableView<Map<String, dynamic>>),
        findsNothing,
      );
      expect(find.widgetWithText(UtenButton, '维护本组资料'), findsNothing);
      expect(find.text('history tail forbidden'), findsOneWidget);
      expect(api.posts, isEmpty);
      expect(t.takeException(), isNull);
      await _dispose(t, env);
    },
  );
  testWidgets('all 251 material evidence records stay local while scrolling', (
    t,
  ) async {
    await _size(t);
    final api = _Api(historyRows: 251);
    final env = await _pump(t, api, MemoryFormDraftStorage(), editor: false);
    await t.tap(find.text('审核记录'));
    await t.pumpAndSettle();
    final finder = find.byWidgetPredicate(
      (w) =>
          w is MasterDataTableView<Map<String, dynamic>> &&
          w.tableKey == 'finance.material.evidence.$_ctx',
    );
    final table = t.widget<MasterDataTableView<Map<String, dynamic>>>(finder);
    expect(table.items, hasLength(251));
    expect(table.items.last['id'], 'history-250');
    expect(table.onPageChange, isNull);
    // Progressive complete read (2026-11-08): 50, then aligned 50/100/200 —
    // offsets 0/50/100/200, every row exactly once.
    expect(api.historyQueries.map((q) => q['page']), [1, 2, 2, 2]);
    expect(api.historyQueries.map((q) => q['size']), [50, 50, 100, 200]);
    expect(api.historyQueries.every((q) => q['contextId'] == _ctx), isTrue);
    final before = api.historyQueries.length;
    await t.drag(finder, const Offset(0, -900));
    await t.pumpAndSettle();
    await t.drag(finder, const Offset(0, 900));
    await t.pumpAndSettle();
    expect(api.historyQueries, hasLength(before));
    expect(api.posts, isEmpty);
    expect(t.takeException(), isNull);
    await _dispose(t, env);
  });
  testWidgets(
    'denied evidence continuation does not publish partial context or allow an editor',
    (t) async {
      await _size(t);
      final api = _Api(historyRows: 251, denyHistoryTail: true);
      final env = await _pump(t, api, MemoryFormDraftStorage(), editor: false);
      expect(api.historyQueries.map((q) => q['page']), [1, 2]);
      expect(find.widgetWithText(UtenButton, '原表导入比对'), findsNothing);
      expect(find.widgetWithText(UtenButton, '维护本组资料'), findsNothing);
      final table = t.widget<MasterDataTableView<Map<String, dynamic>>>(
        find.byWidgetPredicate(
          (w) =>
              w is MasterDataTableView<Map<String, dynamic>> &&
              w.tableKey == 'finance.material.contexts',
        ),
      );
      expect(table.error, isNotNull);
      expect(api.posts, isEmpty);
      expect(t.takeException(), isNull);
      await _dispose(t, env);
    },
  );
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
    'exact unfinished input restores without silently rounding or posting',
    (t) async {
      await _size(t);
      final api = _Api(), storage = MemoryFormDraftStorage();
      var env = await _pump(t, api, storage);
      _field(t, '期初结余(KG)').text =
          '12345678901234567890.123456789012345678901234';
      _field(t, '核对依据').text = '原期初签认依据，未保存原文';
      await t.pump(const Duration(milliseconds: 650));
      await t.pumpAndSettle();
      final draft = env.container.read(formDraftsProvider).single;
      expect(
        (draft.data['input'] as Map)['balanceWeightKg'],
        '12345678901234567890.123456789012345678901234',
      );
      await _dispose(t, env);
      env = await _pump(t, api, storage, resume: draft.id);
      expect(
        _field(t, '期初结余(KG)').text,
        '12345678901234567890.123456789012345678901234',
      );
      expect(_field(t, '核对依据').text, '原期初签认依据，未保存原文');
      expect(api.posts, isEmpty);
      expect(t.takeException(), isNull);
      await _dispose(t, env);
    },
  );
  testWidgets(
    'unknown request freezes input and exact original command survives restart and later conflict',
    (t) async {
      await _size(t);
      final api = _Api(timeout: true), storage = MemoryFormDraftStorage();
      var env = await _pump(t, api, storage);
      _field(t, '期初结余(KG)').text = '1.000000000000000000000001';
      _field(t, '核对依据').text = '双人核对期初原文';
      final send = Future<void>.sync(_button(t, '保存草稿').onPressed!);
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(api.posts, hasLength(1));
      api.first.completeError(NetworkTimeoutException());
      await send;
      await t.pumpAndSettle();
      final first = jsonEncode(api.posts.single),
          draft = env.container.read(formDraftsProvider).single;
      expect(
        t
            .widget<UtenInput>(
              find.byWidgetPredicate(
                (w) => w is UtenInput && w.label == '期初结余(KG)',
              ),
            )
            .enabled,
        isFalse,
      );
      await _dispose(t, env);
      env = await _pump(t, api, storage, resume: draft.id);
      await Future<void>.sync(_button(t, '按原请求重试').onPressed!);
      await t.pumpAndSettle();
      expect(api.posts, hasLength(2));
      expect(jsonEncode(api.posts.last), first);
      expect(_button(t, '保存草稿').onPressed, isNull);
      expect(
        t
            .widget<UtenInput>(
              find.byWidgetPredicate(
                (w) => w is UtenInput && w.label == '期初结余(KG)',
              ),
            )
            .enabled,
        isFalse,
      );
      final frozenHint = find.byWidgetPredicate(
        (w) => w is UtenFieldHintIcon && w.info == '原请求结果待核，参数已冻结，不能换版本重复发送。',
      );
      expect(frozenHint, findsOneWidget);
      await t.tap(frozenHint);
      await t.pumpAndSettle();
      expect(find.text('原请求结果待核，参数已冻结，不能换版本重复发送。'), findsOneWidget);
      expect(_field(t, '期初结余(KG)').text, '1.000000000000000000000001');
      expect(t.takeException(), isNull);
      await _dispose(t, env);
    },
  );
  testWidgets(
    'only an exact actor cancellation receipt releases unknown request and preserves original input',
    (t) async {
      await _size(t);
      final api = _Api(timeout: true, cancelActor: 'someone-else'),
          env = await _pump(t, api, MemoryFormDraftStorage());
      _field(t, '期初结余(KG)').text = '2.125000000000000000000001';
      _field(t, '核对依据').text = '原未写入资料保留';
      final original = _button(t, '保存草稿').onPressed!;
      final send = Future<void>.sync(original);
      await Future<void>.sync(original);
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(api.posts, hasLength(1));
      api.first.completeError(NetworkTimeoutException());
      await send;
      await t.pumpAndSettle();
      await Future<void>.sync(_button(t, '终止尚未写入的原请求').onPressed!);
      await t.pumpAndSettle();
      expect(
        t
            .widget<UtenInput>(
              find.byWidgetPredicate(
                (w) => w is UtenInput && w.label == '期初结余(KG)',
              ),
            )
            .enabled,
        isFalse,
      );
      api.cancelActor = 'material-maker';
      await Future<void>.sync(_button(t, '终止尚未写入的原请求').onPressed!);
      await t.pumpAndSettle();
      expect(_field(t, '期初结余(KG)').text, '2.125000000000000000000001');
      expect(
        t
            .widget<UtenInput>(
              find.byWidgetPredicate(
                (w) => w is UtenInput && w.label == '期初结余(KG)',
              ),
            )
            .enabled,
        isTrue,
      );
      expect(find.widgetWithText(UtenButton, '按原请求重试'), findsNothing);
      expect(
        api.posts.where(
          (p) => p['path'] == '/finance/material-statements/drafts',
        ),
        hasLength(1),
      );
      expect(t.takeException(), isNull);
      await _dispose(t, env);
    },
  );
  testWidgets(
    'retiring authenticated owner hides original inputs and blocks stale callbacks',
    (t) async {
      await _size(t);
      final api = _Api(), env = await _pump(t, api, MemoryFormDraftStorage());
      final callback = _button(t, '保存草稿').onPressed!;
      env.container.read(_scope.notifier).state = const AuthenticatedScope(
        userId: 'different-finance',
      );
      await t.pumpAndSettle();
      await Future<void>.sync(callback);
      await t.pumpAndSettle();
      expect(api.posts, isEmpty);
      expect(find.textContaining('期初结余(KG)'), findsNothing);
      expect(t.takeException(), isNull);
      await _dispose(t, env);
    },
  );
  testWidgets(
    'narrow workbench and retained exact input use the same Uten controls without layout overflow',
    (t) async {
      await _size(t);
      t.view.physicalSize = const Size(430, 650);
      await t.binding.setSurfaceSize(const Size(430, 650));
      final api = _Api(), env = await _pump(t, api, MemoryFormDraftStorage());
      expect(_field(t, '期初结余(KG)').text, '10.000000000000000000000001');
      expect(t.takeException(), isNull);
      await _dispose(t, env);
    },
  );
  testWidgets(
    'independent sidebar reference editor preserves period price without inventing a bound material context',
    (t) async {
      await _size(t);
      final api = _Api(),
          env = await _pump(t, api, MemoryFormDraftStorage(), editor: false);
      await t.tap(find.text('原隐藏旁算资料'));
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(UtenButton, '新增原旁算资料'));
      await t.pumpAndSettle();
      _field(t, '原隐藏位置（1至4）').text = '3';
      _field(t, '产品名称（57#）').text = '原旁算16A圆插铜粒';
      _field(t, '本型号／有效期间参考报价').text = '0.036';
      _field(t, '核对依据').text = '原附件4 L7/O7，本型号本期间参考资料';
      final sending = Future<void>.sync(_button(t, '保存草稿').onPressed!);
      await t.pump();
      await sending;
      await t.pumpAndSettle();
      final request = api.posts.single['body'] as Map<String, dynamic>;
      expect(request['kind'], 'SIDEBAR');
      final input = request['input'] as Map<String, dynamic>;
      expect(input['slot'], 3);
      expect(input['referencePrice'], '0.036');
      expect(input['materialContextId'], isNull);
      expect(input['dateFrom'], '2026-09-01');
      expect(_field(t, '本型号／有效期间参考报价').text, '0.036');
      expect(t.takeException(), isNull);
      await _dispose(t, env);
    },
  );
  testWidgets(
    'two thousand original rows keep ten exact headers and source-body-free interruption mapping',
    (t) async {
      await _size(t);
      final api = _Api(originalRows: 2000), storage = MemoryFormDraftStorage();
      var env = await _pump(t, api, storage, editor: false);
      await t.tap(find.widgetWithText(UtenButton, '原表导入比对'));
      await t.pumpAndSettle();
      _field(t, '恢复原件编号').text = 'source-file';
      await t.tap(find.widgetWithText(UtenButton, '读取原件及同源结果'));
      await t.pumpAndSettle();
      final table = t
          .widgetList<MasterDataTableView<Map<String, dynamic>>>(
            find.byWidgetPredicate(
              (w) => w is MasterDataTableView<Map<String, dynamic>>,
            ),
          )
          .firstWhere(
            (w) => w.tableKey == 'finance.material.original-comparison',
          );
      expect(table.virtualized, isTrue);
      expect(table.items, hasLength(2000));
      expect(table.columns.map((c) => c.label).toList(), api.headers);
      expect(
        table.items.first['10'],
        '12345678901234.000000000000000000000001',
      );
      await t.tap(find.text('逐行明确对应'));
      await t.pumpAndSettle();
      await _chooseCalculatedRow(t, index: 0);
      expect(find.byType(UtenPagination), findsNothing);
      await t.pumpAndSettle();
      final last = t.widget<UtenEditableGrid<EditableGridRow>>(
        find.byWidgetPredicate((w) => w is UtenEditableGrid<EditableGridRow>),
      );
      expect(last.controller.rows, hasLength(2000));
      await _chooseCalculatedRow(t, index: 1999, last: true);
      await t.pump(const Duration(milliseconds: 650));
      await t.pumpAndSettle();
      final comparisonHeader = find.ancestor(
        of: find.textContaining(
          '${FinanceRequirementNames.otherReceivableStatement}原表导入比对',
        ),
        matching: find.byType(UtenDialogHeader),
      );
      expect(comparisonHeader, findsOneWidget);
      final onClose = t.widget<UtenDialogHeader>(comparisonHeader).onClose;
      expect(onClose, isNotNull);
      final closeButton = find.descendant(
        of: comparisonHeader,
        matching: find.byType(UtenCloseButton),
      );
      expect(closeButton, findsOneWidget);
      final closeAction = t.widget<UtenCloseButton>(closeButton).onPressed;
      expect(closeAction, isNotNull);
      final close = Future<void>.sync(closeAction!);
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(FilledButton, '保存草稿'));
      var closed = false;
      Object? closeError;
      close.then(
        (_) => closed = true,
        onError: (Object e) {
          closeError = e;
          closed = true;
        },
      );
      for (var i = 0; i < 500 && !closed; i++) {
        await t.pump(const Duration(milliseconds: 20));
        await t.runAsync(() => Future<void>.delayed(Duration.zero));
      }
      expect(closeError, isNull);
      expect(closed, isTrue);
      await t.pumpAndSettle();
      final draft = env.container.read(formDraftsProvider).single;
      expect(draft.data['mode'], 'COMPARE');
      expect(draft.data['mappingPage'], 1);
      expect(
        (draft.data['mapping'] as List)
            .cast<Map<String, dynamic>>()
            .last['reportRowKey'],
        'r1999',
      );
      expect(
        (draft.data['mapping'] as List)
            .cast<Map<String, dynamic>>()
            .first['reportRowKey'],
        'r0',
      );
      expect(jsonEncode(draft.data), isNot(contains('PRIVATE_ORIGINAL_BODY')));
      expect(
        jsonEncode(draft.data),
        isNot(contains('12345678901234.000000000000000000000001')),
      );
      await _dispose(t, env);
      env = await _pump(t, api, storage, resume: draft.id, editor: false);
      expect(_field(t, '恢复原件编号').text, 'source-file');
      await t.tap(find.text('逐行明确对应'));
      await t.pumpAndSettle();
      expect(find.byType(UtenPagination), findsNothing);
      final mappingGrid = find.byWidgetPredicate(
        (w) => w is UtenEditableGrid<EditableGridRow>,
      );
      final vertical = find
          .ancestor(
            of: mappingGrid,
            matching: find.byWidgetPredicate(
              (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
            ),
          )
          .first;
      final scrolling = t.state<ScrollableState>(vertical);
      scrolling.position.jumpTo(scrolling.position.maxScrollExtent);
      await t.pumpAndSettle();
      await Scrollable.ensureVisible(
        t.element(find.byKey(const ValueKey('finance-material-match-2003'))),
      );
      await t.pumpAndSettle();
      expect(find.text('2026-09-01 / 原产品 / 原单1999'), findsOneWidget);
      scrolling.position.jumpTo(scrolling.position.minScrollExtent);
      await t.pumpAndSettle();
      expect(find.text('2026-09-01 / 原产品 / 原单0'), findsOneWidget);
      expect(api.posts, isEmpty);
      var compared = false;
      Object? compareError;
      Future<void>.sync(_button(t, '按明确对应比对').onPressed!).then(
        (_) => compared = true,
        onError: (Object error) {
          compareError = error;
          compared = true;
        },
      );
      for (var i = 0; i < 1500 && !compared; i++) {
        await t.pump(const Duration(milliseconds: 20));
        await t.runAsync(() => Future<void>.delayed(Duration.zero));
      }
      expect(compareError, isNull);
      expect(compared, isTrue);
      await t.pumpAndSettle();
      final submitted = ((api.posts.single['body'] as Map)['rows'] as List)
          .cast<Map<String, dynamic>>();
      expect(submitted, hasLength(2));
      expect(submitted.first['sourceRow'], 4);
      expect(submitted.last['sourceRow'], 2003);
      expect(t.takeException(), isNull);
      await _dispose(t, env);
    },
  );
}

Future<void> _chooseCalculatedRow(
  WidgetTester t, {
  required int index,
  bool last = false,
}) async {
  if (last) {
    final grid = find.byWidgetPredicate(
      (w) => w is UtenEditableGrid<EditableGridRow>,
    );
    final vertical = find
        .ancestor(
          of: grid,
          matching: find.byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
          ),
        )
        .first;
    final state = t.state<ScrollableState>(vertical);
    state.position.jumpTo(state.position.maxScrollExtent);
    await t.pumpAndSettle();
  }
  final selected = find.byKey(
    ValueKey('finance-material-match-${last ? 2003 : 4}'),
  );
  await Scrollable.ensureVisible(t.element(selected));
  await t.pumpAndSettle();
  final opened = Future<void>.sync(t.widget<UtenButton>(selected).onPressed!);
  await t.pumpAndSettle();
  final table = t
      .widgetList<MasterDataTableView<Map<String, dynamic>>>(
        find.byWidgetPredicate(
          (w) => w is MasterDataTableView<Map<String, dynamic>>,
        ),
      )
      .firstWhere((w) => w.tableKey == 'finance.material.comparison-targets');
  table.onRowTap!(table.items[index]);
  await t.pumpAndSettle();
  await opened;
}

Future<void> _size(WidgetTester t) async {
  t.view.physicalSize = const Size(1500, 1100);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  await t.binding.setSurfaceSize(const Size(1500, 1100));
  addTearDown(() => t.binding.setSurfaceSize(null));
}

TextEditingController _field(WidgetTester t, String label) => t
    .widget<UtenInput>(
      find.byWidgetPredicate((w) => w is UtenInput && w.label == label),
    )
    .controller!;
UtenButton _button(WidgetTester t, String label) =>
    t.widget(find.widgetWithText(UtenButton, label));
typedef _Env = ({ProviderContainer container, GoRouter router});

class _LocalSession extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _LocalSnapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => SessionSnapshot();
}

Future<_Env> _pump(
  WidgetTester t,
  _Api api,
  MemoryFormDraftStorage storage, {
  String? resume,
  bool editor = true,
}) async {
  final c = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      sessionProvider.overrideWith(_LocalSession.new),
      sessionSnapshotProvider.overrideWith(_LocalSnapshot.new),
      authenticatedScopeProvider.overrideWith((ref) => ref.watch(_scope)),
      currentPermissionsProvider.overrideWithValue({
        Perm.financeReportView,
        Perm.financeViewAll,
        Perm.paymentStyleEdit,
        Perm.financePostExecute,
      }),
      apiBaseUrlProvider.overrideWithValue('https://test.example/api'),
      formDraftStorageProvider.overrideWithValue(storage),
    ],
  );
  final router = GoRouter(
    initialLocation: '/finance',
    routes: [
      DraftAwareGoRoute(
        path: '/finance',
        builder: (context, state) => Scaffold(
          body: UtenButton(
            onPressed: () => showFinanceMaterialStatementDialog(
              context,
              initialContextId: _ctx,
              initialEvidenceId: resume == null && editor ? _evidence : null,
              resumeDraftId: resume,
              dateFrom: '2026-09-01',
              dateTo: '2026-09-30',
            ),
            child: const Text('打开维护'),
          ),
        ),
      ),
    ],
  );
  await t.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp.router(
        routerConfig: router,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await t.pumpAndSettle();
  await t.tap(find.text('打开维护'));
  if (resume != null && !editor) {
    var ready = false;
    for (var i = 0; i < 1500 && !ready; i++) {
      await t.pump(const Duration(milliseconds: 20));
      await t.runAsync(() => Future<void>.delayed(Duration.zero));
      ready =
          find
              .byWidgetPredicate(
                (w) => w.runtimeType.toString() == '_MaterialCompare',
              )
              .evaluate()
              .isNotEmpty &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty &&
          find.byType(LinearProgressIndicator).evaluate().isEmpty;
    }
    expect(
      ready,
      isTrue,
      reason:
          'Large durable draft restore must finish while native codec and UI both receive event turns',
    );
  }
  await t.pumpAndSettle();
  return (container: c, router: router);
}

Future<void> _dispose(WidgetTester t, _Env env) async {
  await t.pumpWidget(const SizedBox());
  env.router.dispose();
  env.container.dispose();
}

class _Api extends ApiClient {
  _Api({
    this.timeout = false,
    this.originalRows = 0,
    this.cancelActor = 'material-maker',
    this.historyRows = 0,
    this.denyHistoryTail = false,
  }) : super(Dio(BaseOptions(baseUrl: 'https://test.example/api')));
  final bool timeout;
  final int originalRows, historyRows;
  bool denyHistoryTail;
  final historyQueries = <Map<String, dynamic>>[];
  String cancelActor;
  List<String> get headers =>
      ((((jsonDecode(
                            File(
                              'server/src/main/resources/finance/template-contract-v1.json',
                            ).readAsStringSync(),
                          )
                          as Map)['templates']
                      as Map)['otherReceivableStatement']
                  as Map)['headers']
              as List)
          .cast<String>();
  final first = Completer<Map<String, dynamic>>();
  final posts = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/finance/material-statements/comparison-targets') {
      return {
        'rows': [
          for (int i = 0; i < originalRows; i++)
            {
              '__rowKey': 'r$i',
              'billDate': '2026-09-01',
              'goodsName': '原产品',
              'spec': '原规格',
              '__rowKind': 'PHYSICAL',
              '__billNo': '原单$i',
            },
        ],
        'documentMetadata': {
          'supplementalCells': [
            {
              'sourceCell': 'Q5',
              'value': '12345678901234.000000000000000000000001',
              'pending': false,
              'basis': '匿名实际已审GL来源',
            },
          ],
        },
      };
    }
    if (path == '/finance/template-imports/source-file') {
      return {
        'importId': 'source-file',
        'template': 'otherReceivableStatement',
        'sourceName': '匿名原表.xlsx',
        'sha256': 'sha',
        'headers': headers,
        'issues': <Object?>[],
        'rows': [
          for (int i = 0; i < originalRows; i++)
            {
              'sourceRow': i + 4,
              'cells': [
                for (int col = 1; col <= 10; col++)
                  {
                    'column': col,
                    'text': col == 2 ? 'PRIVATE_ORIGINAL_BODY$i' : '原文',
                    'number': col == 10
                        ? '12345678901234.000000000000000000000001'
                        : null,
                  },
              ],
            },
        ],
        'supplementalCells': [
          {
            'sourceCell': 'Q5',
            'number': '12345678901234.000000000000000000000001',
            'kind': 'NUMBER',
          },
        ],
      };
    }
    if (path == '/finance/material-statements/evidence') {
      historyQueries.add(Map.of(query ?? {}));
      final page = query?['page'] as int? ?? 1,
          size = query?['size'] as int? ?? 100;
      if (denyHistoryTail && page == 2) {
        throw ApiException(
          'FORBIDDEN',
          'history tail forbidden',
          httpStatus: 403,
        );
      }
      final start = (page - 1) * size;
      return {
        'items': [
          for (var i = start; i < start + size && i < historyRows; i++)
            {
              'id': 'history-$i',
              'context_id': _ctx,
              'kind': 'OPENING',
              'status': 'APPROVED',
              'created_at': '2026-09-01',
              'version': i + 1,
            },
        ],
        'page': page,
        'size': size,
        'total': historyRows,
        'totalPages': (historyRows + size - 1) ~/ size,
        'readScopeVersion': 'material-owner',
      };
    }
    if (path == '/finance/material-statements') {
      return {
        'items': <Object?>[],
        'page': query?['page'] ?? 1,
        'size': query?['size'] ?? 100,
        'total': 0,
        'totalPages': 0,
      };
    }
    if (path == '/finance/material-statements/$_ctx') {
      return {
        'id': _ctx,
        'row_version': 7,
        'auxiliary_id': 'aux',
        'accounting_currency_id': 'CNY',
        'account_code': '1221',
        'approved': <Object?>[],
        'evidence': <Object?>[],
      };
    }
    if (path == '/finance/material-statements/evidence/$_evidence') {
      return {
        'id': _evidence,
        'context_id': _ctx,
        'kind': 'OPENING',
        'status': 'DRAFT',
        'version': 2,
        'created_by': 'material-maker',
        'input': {
          'contextId': _ctx,
          'effectiveFrom': '2026-09-01',
          'balanceWeightKg': '10.000000000000000000000001',
          'sourceReference': '匿名原期初重量依据',
        },
      };
    }
    if (path.startsWith('/finance/material-statements/operations/')) {
      throw ApiException(
        'NOT_FOUND',
        '尚无当前原请求回执',
        httpStatus: 404,
        hasResponseCode: true,
      );
    }
    throw StateError('unexpected GET $path');
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/reference-labels')) return {};
    posts.add({'path': path, 'body': jsonDecode(jsonEncode(body))});
    if (path.endsWith('/cancel-unwritten')) {
      return {
        'receiptState': 'CANCELLED_NOT_WRITTEN',
        'requestId': ((body as Map)['body'] as Map)['requestId'],
        'actorId': cancelActor,
        'requestFingerprint': 'anonymous-verified-fp',
      };
    }
    if (path.endsWith('/compare')) {
      return {
        'results': [
          for (final row in (body as Map)['rows'] as List)
            {...row as Map, 'issues': <Object?>[], 'differences': <Object?>[]},
        ],
        'unmappedSourceRows': [for (int i = 5; i < 2003; i++) i],
      };
    }
    if (timeout && posts.length == 1) return first.future;
    throw ApiException(
      'CONFLICT',
      '其他操作已推进，原请求待核',
      httpStatus: 409,
      hasResponseCode: true,
    );
  }
}
