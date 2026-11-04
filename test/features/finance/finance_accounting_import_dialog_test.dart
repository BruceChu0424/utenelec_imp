import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';
import 'package:uten_imp/components/layout/uten_action_overflow.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/finance/widgets/finance_accounting_import_dialog.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_navigation.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import '../../shared/drafts/memory_form_draft_storage.dart';

const _v = '10000000-0000-0000-0000-000000000001',
    _b = '10000000-0000-0000-0000-000000000002';
const _currency = '10000000-0000-0000-0000-000000000003';
const _fxCurrency = '10000000-0000-0000-0000-000000000004',
    _otherFx = '10000000-0000-0000-0000-000000000005',
    _aux = '10000000-0000-0000-0000-000000000006';
const _key = 'BOOK|2026|9|记|0001';
final _scopeSignal = StateProvider<AuthenticatedScope?>(
  (ref) => const AuthenticatedScope(userId: 'accounting-user'),
);
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
    'original F10 currency mappings and separate opening original unit survive draft and immutable retry',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1500, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _Api(fx: true), storage = MemoryFormDraftStorage();
      var env = await _pump(tester, api, storage);
      await _balance(tester);
      await tester.tap(find.text('原凭证币别'));
      await tester.pumpAndSettle();
      final currency = find.byKey(
        const ValueKey('accounting-source-currency-原USD标签'),
      );
      expect(tester.widget<UtenDropdownField>(currency).value, isNull);
      await _select(tester, 'accounting-source-currency-原USD标签', _fxCurrency);
      await tester.tap(find.text('科目对应'));
      await tester.pumpAndSettle();
      for (final code in ['1001', '3101']) {
        await _select(tester, 'accounting-style-$code', 'STYLE-$code');
        await _select(tester, 'accounting-currency-$code', _currency);
      }
      await tester.tap(find.text('凭证性质'));
      await tester.pumpAndSettle();
      await _select(tester, 'accounting-purpose-$_key', 'OPERATING');
      await tester.tap(find.text('期初分配'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('添加行'));
      await tester.tap(find.text('添加行'));
      await tester.pumpAndSettle();
      Finder opening(String field) => find.byWidgetPredicate(
        (widget) =>
            widget is UtenDropdownField &&
            widget.key is ValueKey &&
            (widget.key! as ValueKey).value.toString().startsWith(
              'accounting-opening-$field-',
            ),
      );
      tester
          .widget<UtenDropdownField>(opening('accountCode'))
          .onChanged('1001');
      await tester.pumpAndSettle();
      tester
          .widget<UtenDropdownField>(opening('currencyId'))
          .onChanged(_currency);
      await tester.pumpAndSettle();
      tester
          .widget<UtenDropdownField>(opening('originalCurrencyId'))
          .onChanged(_fxCurrency);
      await tester.pumpAndSettle();
      await tester.tap(find.text('明确选择原辅助项目').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('原辅助项目').first);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('原辅助项目').first);
      await tester.pumpAndSettle();
      UtenInput input(String field) => tester.widget<UtenInput>(
        find.byWidgetPredicate(
          (widget) =>
              widget is UtenInput &&
              widget.key is ValueKey &&
              (widget.key! as ValueKey).value.toString().startsWith(
                'accounting-opening-$field-',
              ),
        ),
      );
      input('openingDebit').controller!.text =
          '1234567890123456789012345678901234567890.123456789012345678901234567890';
      input('openingCredit').controller!.text = '0';
      input('originalNet').controller!.text = '10.000000000000000000000001';
      input('exchangeRate').controller!.text = '10.00001';
      input('sourceReference').controller!.text = '原本币及原币分别核对依据';
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      final draft = env.container.read(formDraftsProvider).single;
      expect(
        (draft.data['sourceCurrencyMappings'] as Map)['原USD标签'],
        _fxCurrency,
      );
      expect(
        _map(
          (draft.data['openingAllocations'] as List).single,
        )['originalCurrencyId'],
        _fxCurrency,
      );
      await tester.pumpWidget(const SizedBox());
      env.router.dispose();
      env.container.dispose();
      env = await _pump(tester, api, storage, resumeDraftId: draft.id);
      expect(
        input('originalNet').controller!.text,
        '10.000000000000000000000001',
      );
      expect(
        tester.widget<UtenDropdownField>(opening('originalCurrencyId')).value,
        _fxCurrency,
      );
      await tester.tap(find.text('核对与提交'));
      await tester.pumpAndSettle();
      _input(tester, '核对依据／退回或撤回原因').text = '明确本币会计属性与实际原币单位';
      tester
          .widget<CheckboxListTile>(
            find.widgetWithText(
              CheckboxListTile,
              '已核对本期原始凭证完整、原余额与辅助明细完整，并逐张确认凭证性质',
            ),
          )
          .onChanged!(true);
      await tester.pumpAndSettle();
      final submit = tester.widget<UtenButton>(
        find.widgetWithText(UtenButton, '提交另一人复核'),
      );
      final request = Future<void>.sync(submit.onPressed!);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(api.posts, hasLength(1));
      final body = api.posts.single;
      expect((body['sourceCurrencyMappings'] as Map)['原USD标签'], _fxCurrency);
      final openingBody = _map((body['openingAllocations'] as List).single);
      expect(openingBody['currencyId'], _currency);
      expect(openingBody['originalCurrencyId'], _fxCurrency);
      expect(
        openingBody['openingDebit'],
        '1234567890123456789012345678901234567890.123456789012345678901234567890',
      );
      expect(openingBody['originalNet'], '10.000000000000000000000001');
      final before = jsonEncode(body);
      api.first.completeError(NetworkTimeoutException());
      await request;
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(UtenButton, '使用原请求核对并重试'));
      await tester.pumpAndSettle();
      expect(jsonEncode(api.posts.last), before);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      env.router.dispose();
      env.container.dispose();
    },
  );
  testWidgets(
    'manual opening allocation keeps incomplete exact text through interruption',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1500, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _Api(), storage = MemoryFormDraftStorage();
      var env = await _pump(tester, api, storage);
      await _balance(tester);
      await tester.tap(find.text('期初分配'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('添加行'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加行'));
      await tester.pumpAndSettle();
      UtenInput input(String field) => tester.widget<UtenInput>(
        find.byWidgetPredicate(
          (w) =>
              w is UtenInput &&
              w.key is ValueKey &&
              ((w.key! as ValueKey).value.toString().startsWith(
                'accounting-opening-$field-',
              )),
        ),
      );
      expect(input('openingDebit').controller!.text, isEmpty);
      expect(input('openingCredit').controller!.text, isEmpty);
      input('openingDebit').controller!.text = '1.';
      input('openingCredit').controller!.text = '0';
      input('sourceReference').controller!.text = '财务原始期初分配依据';
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      final draft = env.container.read(formDraftsProvider).single;
      expect(
        _map((draft.data['openingAllocations'] as List).single)['openingDebit'],
        '1.',
      );
      expect(
        _map(
          (draft.data['openingAllocations'] as List).single,
        )['sourceReference'],
        '财务原始期初分配依据',
      );
      await tester.pumpWidget(const SizedBox());
      env.router.dispose();
      env.container.dispose();
      env = await _pump(tester, api, storage, resumeDraftId: draft.id);
      expect(input('openingDebit').controller!.text, '1.');
      expect(input('sourceReference').controller!.text, '财务原始期初分配依据');
      expect(api.posts, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      env.router.dispose();
      env.container.dispose();
    },
  );
  testWidgets(
    'unknown reviewer return remains replayable after the preview becomes private',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1500, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _Api(submitted: true), storage = MemoryFormDraftStorage();
      var env = await _pump(tester, api, storage);
      await tester.tap(find.text('核对与提交'));
      await tester.pumpAndSettle();
      _input(tester, '核对依据／退回或撤回原因').text = '需要原提交人更正';
      final button = tester.widget<UtenButton>(
        find.widgetWithText(UtenButton, '退回核对'),
      );
      final request = Future<void>.sync(button.onPressed!);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(api.posts, hasLength(1));
      api.privatePreview = true;
      api.first.completeError(NetworkTimeoutException());
      await request;
      await tester.pumpAndSettle();
      final draft = env.container.read(formDraftsProvider).single,
          original = jsonEncode(api.posts.single);
      await tester.pumpWidget(const SizedBox());
      env.router.dispose();
      env.container.dispose();
      env = await _pump(tester, api, storage, resumeDraftId: draft.id);
      expect(find.text('使用原请求核对并重试'), findsWidgets);
      await tester.tap(find.widgetWithText(UtenButton, '使用原请求核对并重试'));
      await tester.pumpAndSettle();
      expect(api.posts, hasLength(2));
      expect(jsonEncode(api.posts.last), original);
      expect(env.container.read(formDraftsProvider), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      env.router.dispose();
      env.container.dispose();
    },
  );
  testWidgets('narrow view retains Uten action panel without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(392, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.binding.setSurfaceSize(const Size(392, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final env = await _pump(tester, _Api(), MemoryFormDraftStorage());
    expect(find.byType(UtenActionOverflow), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    env.router.dispose();
    env.container.dispose();
  });
  testWidgets(
    '5000 source entries use bounded projection and keep full original membership',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1500, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final slices = <Duration>[];
      debugUiWorkSliceObserver = (label, time) {
        if (label == 'finance.accounting.original-projection') slices.add(time);
      };
      addTearDown(() => debugUiWorkSliceObserver = null);
      final env = await _pump(
        tester,
        _Api(entryCount: 5000),
        MemoryFormDraftStorage(),
      );
      final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
        find.byWidgetPredicate(
          (w) => w is MasterDataTableView<Map<String, dynamic>>,
        ),
      );
      expect(table.items, hasLength(5000));
      expect(table.virtualized, isTrue);
      expect(slices, isNotEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      env.router.dispose();
      env.container.dispose();
    },
  );
  testWidgets(
    'late original response cannot revive an old owner after A-B-A scope change',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1500, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final gate = Completer<void>(), api = _Api(gate: gate);
      final env = await _pump(
        tester,
        api,
        MemoryFormDraftStorage(),
        settle: false,
      );
      env.container.read(_scopeSignal.notifier).state =
          const AuthenticatedScope(userId: 'other-user');
      await tester.pump();
      env.container.read(_scopeSignal.notifier).state =
          const AuthenticatedScope(userId: 'accounting-user');
      await tester.pump();
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.textContaining('登录身份或服务器已变化'), findsOneWidget);
      expect(api.posts, isEmpty);
      expect(
        find.byWidgetPredicate(
          (w) => w is MasterDataTableView<Map<String, dynamic>>,
        ),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox());
      env.router.dispose();
      env.container.dispose();
    },
  );
  testWidgets(
    'original 83 headers stay ordered, allocation uses the shared grid, drafts omit source body',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1500, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _Api(), storage = MemoryFormDraftStorage();
      final env = await _pump(tester, api, storage);
      final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
        find.byWidgetPredicate(
          (w) => w is MasterDataTableView<Map<String, dynamic>>,
        ),
      );
      expect(table.columns, hasLength(83));
      expect(table.columns.first.label, 'F1 原列1');
      expect(table.columns.last.label, 'F83 原列83');
      expect(api.posts, isEmpty);
      await _balance(tester);
      await tester.tap(find.text('科目对应'));
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate((w) => w is UtenEditableGrid),
        findsOneWidget,
      );
      await _select(tester, 'accounting-style-1001', 'STYLE-1001');
      await _select(tester, 'accounting-currency-1001', _currency);
      await tester.tap(find.text('核对与提交'));
      await tester.pumpAndSettle();
      _input(tester, '核对依据／退回或撤回原因').text = '尚未提交的核对依据';
      await tester.pumpAndSettle();
      final draft = env.container.read(formDraftsProvider).single;
      expect(draft.data['voucherId'], _v);
      expect(draft.data['balanceId'], _b);
      expect(
        jsonEncode(draft.data),
        isNot(contains('DO_NOT_EXECUTE_SOURCE_FLAGS')),
      );
      expect(jsonEncode(draft.data), isNot(contains('F83 原列83')));
      expect(
        _map(_map(draft.data['accounts'])['1001'])['styleId'],
        'STYLE-1001',
      );
      await tester.pumpWidget(const SizedBox());
      env.router.dispose();
      env.container.dispose();
    },
  );
  testWidgets(
    'rapid submit coalesces and timeout retries the identical frozen request',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1500, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _Api(), storage = MemoryFormDraftStorage();
      final env = await _pump(tester, api, storage);
      await _balance(tester);
      await tester.tap(find.text('科目对应'));
      await tester.pumpAndSettle();
      for (final code in ['1001', '3101']) {
        await _select(tester, 'accounting-style-$code', 'STYLE-$code');
        await _select(tester, 'accounting-currency-$code', _currency);
      }
      await tester.tap(find.text('凭证性质'));
      await tester.pumpAndSettle();
      await _select(tester, 'accounting-purpose-$_key', 'OPERATING');
      await tester.tap(find.text('核对与提交'));
      await tester.pumpAndSettle();
      _input(tester, '核对依据／退回或撤回原因').text = '已核对匿名原件';
      final check = tester.widget<CheckboxListTile>(
        find.widgetWithText(
          CheckboxListTile,
          '已核对本期原始凭证完整、原余额与辅助明细完整，并逐张确认凭证性质',
        ),
      );
      check.onChanged!(true);
      await tester.pumpAndSettle();
      final button = tester.widget<UtenButton>(
        find.widgetWithText(UtenButton, '提交另一人复核'),
      );
      final first = button.onPressed!();
      button.onPressed!();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(api.posts, hasLength(1));
      final frozen = jsonEncode(api.posts.single);
      api.first.completeError(NetworkTimeoutException());
      await first;
      await tester.pumpAndSettle();
      expect(find.text('使用原请求核对并重试'), findsWidgets);
      await tester.tap(find.widgetWithText(UtenButton, '使用原请求核对并重试'));
      await tester.pumpAndSettle();
      expect(api.posts, hasLength(2));
      expect(jsonEncode(api.posts.last), frozen);
      expect(env.container.read(formDraftsProvider), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      env.router.dispose();
      env.container.dispose();
    },
  );
}

Map<String, dynamic> _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};
TextEditingController _input(WidgetTester t, String label) => t
    .widget<UtenInput>(
      find.byWidgetPredicate((w) => w is UtenInput && w.label == label),
    )
    .controller!;
Future<void> _select(WidgetTester t, String key, String value) async {
  t.widget<UtenDropdownField>(find.byKey(ValueKey(key))).onChanged(value);
  await t.pumpAndSettle();
}

Future<void> _balance(WidgetTester t) async {
  t
      .widget<UtenDropdownField>(
        find.byWidgetPredicate(
          (w) => w is UtenDropdownField && w.label == '成对原科目余额',
        ),
      )
      .onChanged(_b);
  await t.pumpAndSettle();
}

Future<({ProviderContainer container, GoRouter router})> _pump(
  WidgetTester tester,
  _Api api,
  MemoryFormDraftStorage storage, {
  bool settle = true,
  String? resumeDraftId,
}) async {
  final c = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      authenticatedScopeProvider.overrideWith((ref) => ref.watch(_scopeSignal)),
      currentPermissionsProvider.overrideWithValue({
        Perm.financePostExecute,
        'finance_report:view',
        'finance:view:all',
      }),
      apiBaseUrlProvider.overrideWithValue('https://test.example/api'),
      formDraftStorageProvider.overrideWithValue(storage),
    ],
  );
  final router = GoRouter(
    routes: [
      DraftAwareGoRoute(
        path: '/finance',
        builder: (context, state) => Scaffold(
          body: Center(
            child: UtenButton(
              onPressed: () => showFinanceAccountingImportDialog(
                context,
                initialImportId: _v,
                resumeDraftId: resumeDraftId,
              ),
              child: const Text('打开接续'),
            ),
          ),
        ),
      ),
    ],
    initialLocation: '/finance',
  );
  await tester.pumpWidget(
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
  await tester.pumpAndSettle();
  await tester.tap(find.text('打开接续'));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }
  return (container: c, router: router);
}

class _Api extends ApiClient {
  _Api({
    this.entryCount = 2,
    this.gate,
    this.submitted = false,
    this.fx = false,
  }) : super(Dio(BaseOptions(baseUrl: 'https://test.example/api')));
  final int entryCount;
  final Completer<void>? gate;
  final bool submitted, fx;
  bool privatePreview = false;
  final posts = <Map<String, dynamic>>[];
  final first = Completer<Map<String, dynamic>>();
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/finance/accounting-imports/$_v' && gate != null) {
      await gate!.future;
    }
    if (path == '/finance/accounting-imports/$_v' && privatePreview) {
      throw ApiException(
        'FORBIDDEN',
        '原预览仅原提交人可读',
        httpStatus: 403,
        hasResponseCode: true,
      );
    }
    if (path == '/finance/auxiliary-items') {
      return {
        'items': [
          {
            'id': _aux,
            'sourceCode': 'AUX-1',
            'sourceName': '原辅助项目',
            'sourceSystem': 'BOOK',
            'status': 'ACTIVE',
            'role': 'OTHER',
            'partyId': 'original-party',
            'partyName': '原往来对象',
          },
        ],
        'page': 1,
        'totalPages': 1,
      };
    }
    if (path == '/finance/accounting-imports') {
      return {
        'items': [
          {
            'id': _v,
            'kind': 'VOUCHERS',
            'sourceName': '匿名原凭证',
            'sourceSystem': 'BOOK',
            'status': 'PREVIEW',
          },
          {
            'id': _b,
            'kind': 'BALANCE',
            'sourceName': '匿名原余额',
            'sourceSystem': 'BOOK',
            'status': 'PREVIEW',
          },
        ],
      };
    }
    if (path == '/finance/chart') {
      return {
        'items': [
          for (final code in ['1001', '3101'])
            {
              'code': code,
              'name': '匿名科目$code',
              'version': 1,
              'targets': [
                {
                  'id': 'STYLE-$code',
                  'code': code,
                  'name': '核算$code',
                  'category': code == '1001' ? 'ACCOUNT' : 'EQUITY',
                },
              ],
            },
        ],
      };
    }
    if (path == '/finance/accounting-imports/options') {
      return {
        'currencies': [
          {'id': _currency, 'code': 'RMB', 'name': '人民币', 'status': '使用'},
          if (fx) ...[
            {'id': _fxCurrency, 'code': 'USD', 'name': '美元', 'status': '使用'},
            {'id': _otherFx, 'code': 'USD-OTHER', 'name': '美元', 'status': '使用'},
          ],
        ],
      };
    }
    if (path == '/finance/accounting-imports/$_v') {
      return {
        'importId': _v,
        'kind': 'VOUCHERS',
        'sourceName': '匿名原凭证',
        'sourceSystem': 'BOOK',
        'status': submitted ? 'SUBMITTED' : 'PREVIEW',
        'version': submitted ? 1 : 0,
        'submittedBy': submitted ? 'original-submitter' : null,
        'review': submitted
            ? {
                'request': {
                  'balanceImportId': _b,
                  'accounts': <Map<String, dynamic>>[],
                  'voucherPurposes': <String, String>{},
                  'entryAuxiliaries': <String, String>{},
                  'auxiliarySourceIds': <String>[],
                  'omittedZeroBalanceProfitCodes': <String>[],
                  'completeOriginalPeriod': true,
                  'reason': '原提交核对说明',
                },
              }
            : null,
        'source': {
          'headers': [for (int i = 1; i <= 83; i++) 'F$i 原列$i'],
          'issues': <Map<String, dynamic>>[],
          'vouchers': [
            {
              'key': _key,
              'date': '2026-09-01',
              'number': '0001',
              'type': '记',
              'closingCandidate': false,
              'debit': '100.0001',
              'credit': '100.0001',
              'entries': [
                for (int i = 0; i < entryCount; i++)
                  {
                    'sourceRow': i + 2,
                    'sourceEntryId': 'ENTRY-$i',
                    'number': '0001',
                    'accountCode': i.isEven ? '1001' : '3101',
                    'accountName': '匿名科目',
                    'customerCode': '',
                    'supplierCode': '',
                    'employeeCode': '',
                    'projectCode': '',
                    'currencyName': fx ? '原USD标签' : '',
                    'source': {
                      for (int field = 1; field <= 83; field++)
                        'F$field': 'SOURCE-$i-$field',
                      'F1': '2026-09-01',
                      'F3': '0001',
                      'F6': i.isEven ? '1001' : '3101',
                      'F7': i.isEven ? '100.0001' : '0',
                      'F8': i.isEven ? '0' : '100.0001',
                      if (fx) 'F10': '原USD标签',
                      'F83': 'DO_NOT_EXECUTE_SOURCE_FLAGS',
                    },
                  },
              ],
            },
          ],
        },
      };
    }
    if (path == '/finance/accounting-imports/$_b') {
      return {
        'importId': _b,
        'kind': 'BALANCE',
        'sourceName': '匿名原余额',
        'sourceSystem': 'BOOK',
        'status': 'PREVIEW',
        'version': 0,
        'source': {
          'headers': [
            '会计年度',
            '会计期间',
            '科目编码',
            '科目名称',
            '外币名称',
            '期初借方',
            '期初贷方',
            '本期发生借方',
            '本期发生贷方',
            '期末借方',
            '期末贷方',
          ],
          'issues': <Map<String, dynamic>>[],
          'balances': [
            for (final code in ['1001', '3101'])
              {
                'year': 2026,
                'month': 9,
                'accountCode': code,
                'accountName': '匿名科目$code',
                'currencyName': '',
                'openingDebit': '0',
                'openingCredit': '0',
                'debit': '100.0001',
                'credit': '100.0001',
                'closingDebit': '0',
                'closingCredit': '0',
              },
          ],
        },
      };
    }
    return {};
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) {
    posts.add(_map(jsonDecode(jsonEncode(body))));
    if (posts.length == 1) return first.future;
    return Future.value({'importId': _v, 'status': 'SUBMITTED'});
  }
}
