import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/finance/pages/finance_hub_page.dart';
import 'package:uten_imp/features/finance/widgets/finance_chart_command_dialog.dart';
import 'package:uten_imp/features/finance/widgets/finance_durable_command_dialog.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/drafts/form_draft.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import '../../shared/drafts/memory_form_draft_storage.dart';
import '../../support/finance_command_test_support.dart';
import '../../support/native_detail_reader_overrides.dart';

const _currency = '00000000-0000-0000-0000-000000000301';
const _style = '00000000-0000-0000-0000-000000000501';
const _activeForeign = '00000000-0000-0000-0000-000000000302';
const _otherStopped = '00000000-0000-0000-0000-000000000303';
const _chartOperations = [
  FinanceDurableOperation.chartAccountCreate,
  FinanceDurableOperation.chartMappingReplace,
  FinanceDurableOperation.chartTargetCreate,
];
final _grants = StateProvider<Set<String>>((_) => {});
final _identity = StateProvider<AuthenticatedScope?>(
  (_) => const AuthenticatedScope(userId: financeCommandTestActor),
);

class _Session extends SessionNotifier {
  @override
  SessionState build() => SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: ref.watch(_identity)?.userId ?? financeCommandTestActor,
      code: 'fixture',
      name: '匿名测试人员',
    ),
  );
}

class _Wire {
  _Wire(this.method, this.path, this.body);
  final String method, path;
  final Map<String, dynamic> body;
}

class _Transport implements HttpClientAdapter {
  _Transport(this.operation);
  final FinanceDurableOperation operation;
  final writes = <_Wire>[], reads = <String>[], cancels = <_Wire>[];
  final receipts = <String, Map<String, dynamic>>{};
  bool loseReply = true,
      reject = false,
      loseCancel = false,
      wrongSuccess = false,
      forbidReads = false,
      legacy = false;
  int commits = 0, currentVersion = 5;
  String currencyStatus = '使用';
  bool missingCurrency = false;
  final allRequests = <_Wire>[];
  Completer<void>? holdWrite;
  void Function(_Wire request)? beforeWrite;
  String get target =>
      operation == FinanceDurableOperation.chartAccountCreate ? '' : '310410';
  Map<String, dynamic> get account => {
    'code': '310410',
    'name': '原权益科目',
    'version': currentVersion,
    'currencyName': '',
    'currencyId': missingCurrency ? null : _currency,
    'classification': 'EQUITY',
    'targets': operation == FinanceDurableOperation.chartMappingReplace
        ? [
            {
              'id': _style,
              'code': '310410',
              'name': '原权益核算',
              'category': 'EQUITY',
            },
          ]
        : <Map<String, dynamic>>[],
    'lineKeys': <String>[],
  };
  ResponseBody _json(Object? value, [int status = 200]) =>
      ResponseBody.fromString(
        jsonEncode(value),
        status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
  Map<String, dynamic> _proof(_Wire request, {bool cancelled = false}) => {
    'found': true,
    'requestId': request.body['requestId'],
    'actorId': financeCommandTestActor,
    'operation': operation.key,
    'method': request.method,
    'path': request.path,
    'requestBody': request.body,
    'outcome': cancelled ? 'CANCELLED_UNWRITTEN' : 'SUCCEEDED',
    'result': cancelled
        ? {'cancelled': true}
        : {
            'requestId': request.body['requestId'],
            'code': wrongSuccess ? '999999' : request.body['code'] ?? target,
            'status': operation == FinanceDurableOperation.chartAccountCreate
                ? 'CREATED'
                : 'APPLIED',
            if (operation != FinanceDurableOperation.chartAccountCreate) ...{
              'version': currentVersion,
              'styleIds': [_style],
              'classification': request.body['classification'],
              'currencyId': request.body['currencyId'],
              'lineKeys': [
                request.body['balanceLineKey'],
                request.body['profitLineKey'],
              ].whereType<String>().toList(),
            },
          },
  };
  @override
  Future<ResponseBody> fetch(
    RequestOptions o,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    final bytes = stream == null
        ? <int>[]
        : await stream.expand((chunk) => chunk).toList();
    final body = bytes.isEmpty
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes)) as Map);
    final request = _Wire(o.method, o.path, body);
    allRequests.add(request);
    if (o.method == 'GET') {
      if (o.path.startsWith('/finance/chart/operations/')) {
        reads.add(o.path);
        if (forbidReads) {
          return _json({'code': 'FORBIDDEN', 'message': '读取权限已撤销'}, 403);
        }
        final proof = receipts[o.path.split('/').last];
        if (legacy && proof != null && proof['outcome'] == 'SUCCEEDED') {
          return _json(
            {
              ...proof,
              'requiresOriginalRequestProof': true,
              'proofScope': 'LEGACY_TYPED_BODY',
            }..remove('requestBody'),
          );
        }
        return _json(proof ?? {'found': false});
      }
      if (o.path == '/finance/chart/310410') return _json(account);
      if (o.path == '/finance/chart/options') {
        return _json({
          'currencies': [
            {
              'id': _currency,
              'name': '人民币',
              'code': 'CNY',
              'baseCurrency': true,
              'status': currencyStatus,
            },
            {
              'id': _activeForeign,
              'name': '美元',
              'code': 'USD',
              'baseCurrency': false,
              'status': '使用',
            },
            {
              'id': _otherStopped,
              'name': '原停用币别',
              'code': 'OLD',
              'baseCurrency': false,
              'status': '停用',
            },
          ],
        });
      }
      if (o.path == '/finance/chart/00560301') {
        return _json({'code': 'NOT_FOUND', 'message': '当前尚未建立'}, 404);
      }
      if (o.path == '/finance/reports/gl/line-bindings') {
        return _json([
          {'lineKey': 'BS_51', 'label': '未分配利润', 'sheet': 'BALANCE'},
          {
            'lineKey': 'PL_PRIOR_ADJUSTMENT',
            'label': '以前年度损益调整',
            'sheet': 'PROFIT',
          },
        ]);
      }
      return _json({
        'items': <Object>[],
        'total': 0,
        'page': 1,
        'size': 100,
        'totalPages': 0,
      });
    }
    if (o.path.startsWith('/finance/chart/operations/') &&
        o.path.endsWith('/cancel')) {
      cancels.add(request);
      final original = Map<String, dynamic>.from(body['requestBody'] as Map);
      final id = original['requestId'] as String;
      expect(body['requestId'], id);
      expect(body['actorId'], financeCommandTestActor);
      expect(body['operation'], operation.key);
      expect(body['method'], operation.method);
      expect(body['path'], operation.path(target));
      final proof = receipts.putIfAbsent(
        id,
        () => _proof(
          _Wire(operation.method, operation.path(target), original),
          cancelled: true,
        ),
      );
      expect(proof['requestBody'], original);
      if (loseCancel) {
        throw DioException(
          requestOptions: o,
          type: DioExceptionType.receiveTimeout,
        );
      }
      return _json(proof);
    }
    if (o.path == operation.path(target) && o.method == operation.method) {
      writes.add(request);
      beforeWrite?.call(request);
      final gate = holdWrite;
      if (gate != null) await gate.future;
      final id = body['requestId'] as String;
      final old = receipts[id];
      if (old != null) {
        expect(old['requestBody'], body);
        return _json(old);
      }
      if (reject) {
        return _json({'code': 'CONFLICT', 'message': '所查看版本已变化'}, 409);
      }
      commits++;
      currentVersion++;
      final proof = _proof(request);
      receipts[id] = proof;
      if (loseReply) {
        throw DioException(
          requestOptions: o,
          type: DioExceptionType.receiveTimeout,
        );
      }
      return _json(proof);
    }
    return _json({});
  }

  @override
  void close({bool force = false}) {}
}

class _Environment {
  _Environment(this.container, this.dio, this.router);
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

class _HeldStorage extends MemoryFormDraftStorage {
  bool holdNext = false;
  final release = Completer<void>();
  @override
  Future<bool> compareAndSet(
    String key, {
    required String? expectedValue,
    required String? value,
  }) async {
    if (holdNext) {
      holdNext = false;
      await release.future;
    }
    return super.compareAndSet(key, expectedValue: expectedValue, value: value);
  }
}

Future<_Environment> _open(
  WidgetTester t,
  _Transport transport,
  MemoryFormDraftStorage storage, {
  FormDraft? resume,
  bool hub = false,
  bool write = true,
  bool read = true,
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
      sessionProvider.overrideWith(_Session.new),
      authenticatedScopeProvider.overrideWith((ref) => ref.watch(_identity)),
      apiBaseUrlProvider.overrideWithValue('https://finance-command.test/api'),
      apiClientProvider.overrideWithValue(ApiClient(dio)),
      currentPermissionsProvider.overrideWith((ref) => ref.watch(_grants)),
      _grants.overrideWith(
        (_) => {
          if (read) ...{Perm.financeReportView, Perm.financeViewAll},
          if (write) ...{Perm.paymentStyleEdit, Perm.paymentStyleCreate},
        },
      ),
      sharedPreferencesProvider.overrideWithValue(
        await SharedPreferences.getInstance(),
      ),
      formDraftStorageProvider.overrideWithValue(storage),
    ],
  );
  GoRouter? router;
  const locale = AppLocalizations.localizationsDelegates;
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
      localizationsDelegates: locale,
      supportedLocales: AppLocalizations.supportedLocales,
    );
  } else {
    app = MaterialApp(
      theme: buildLightTheme(),
      locale: const Locale('zh'),
      localizationsDelegates: locale,
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
            onPressed: () => showFinanceChartCommand(
              context,
              operation: transport.operation,
              code: transport.target,
              account: transport.target.isEmpty ? null : transport.account,
              currencies: const [
                {
                  'id': _currency,
                  'name': '人民币',
                  'code': 'CNY',
                  'baseCurrency': true,
                  'status': '使用',
                },
              ],
              resumeDraftId: resume?.id,
            ),
            child: const Text('打开科目操作'),
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
    await t.tap(find.text('打开科目操作'));
    await t.pumpAndSettle();
  }
  return _Environment(container, dio, router);
}

Finder _button(String label) =>
    find.widgetWithText(UtenButton, label).hitTestable();
Finder _input(String label) => find.descendant(
  of: find.byWidgetPredicate((w) => w is UtenInput && w.label == label),
  matching: find.byType(TextFormField),
);
Future<void> _choose(WidgetTester t, String label, String value) async {
  final field = find.byWidgetPredicate(
    (w) => w is UtenDropdownField && w.label == label,
  );
  await t.ensureVisible(field);
  await t.pumpAndSettle();
  await t.tap(field);
  await t.pumpAndSettle();
  await t.tap(find.text(value).last);
  await t.pumpAndSettle();
}

String _saveLabel(FinanceDurableOperation operation) => switch (operation) {
  FinanceDurableOperation.chartAccountCreate => '新增科目',
  FinanceDurableOperation.chartTargetCreate => '补建并对应此科目',
  _ => '保存对应',
};
Future<void> _fill(WidgetTester t, FinanceDurableOperation operation) async {
  if (operation == FinanceDurableOperation.chartAccountCreate) {
    await t.enterText(_input('科目编码'), '00560301');
    await t.enterText(_input('科目名称'), '原损益科目');
    await t.enterText(_input('新增依据'), '原科目资料完整保留');
    await _choose(t, '财务类别', '损益');
    await _choose(t, '同时补建核算类别', '收入');
  } else {
    if (operation == FinanceDurableOperation.chartTargetCreate) {
      await _choose(t, '补建核算类别', '权益');
    }
    await _choose(t, '资产负债表项目', '未分配利润');
    await _choose(t, '利润表项目', '以前年度损益调整');
  }
  await t.ensureVisible(_button(_saveLabel(operation)));
  await t.pumpAndSettle();
}

Future<void> _action(WidgetTester t, String label) async {
  await tapFinanceOriginalAction(t, label);
  await t.pumpAndSettle();
}

void main() {
  setUp(prepareFinanceCommandTest);
  testWidgets(
    'one wait covers original chart persistence before dispatch and rapid stale save calls cannot duplicate it',
    (t) async {
      final transport = _Transport(FinanceDurableOperation.chartMappingReplace),
          storage = _HeldStorage();
      final env = await _open(t, transport, storage);
      await _fill(t, transport.operation);
      Map<String, dynamic>? sentAtDispatch;
      bool? unknownAtDispatch;
      transport.beforeWrite = (request) {
        final draft = env.container.read(formDraftsProvider).singleOrNull;
        if (draft != null) {
          sentAtDispatch = Map<String, dynamic>.from(
            jsonDecode(jsonEncode(draft.data['sent'])) as Map,
          );
          unknownAtDispatch = draft.hasUnknownSubmission;
        }
      };
      final submit = t.widget<UtenButton>(_button('保存对应')).onPressed!;
      storage.holdNext = true;
      submit();
      submit();
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(find.byType(UtenBusyOverlayCard), findsOneWidget);
      expect(transport.writes, isEmpty);
      storage.release.complete();
      await t.pumpAndSettle();
      expect(transport.writes, hasLength(1));
      expect(sentAtDispatch, transport.writes.single.body);
      expect(unknownAtDispatch, isTrue);
      expect(transport.commits, 1);
      expect(t.takeException(), isNull);
      await env.close(t);
    },
  );
  for (final operation in _chartOperations) {
    testWidgets(
      '${operation.key} real ApiClient lost reply survives hard close and actual Hub GET without another write',
      (t) async {
        final transport = _Transport(operation),
            storage = MemoryFormDraftStorage();
        var env = await _open(t, transport, storage);
        await _fill(t, operation);
        await t.tap(_button(_saveLabel(operation)));
        await t.pumpAndSettle();
        expect(transport.commits, 1);
        expect(transport.writes, hasLength(1));
        final original = transport.writes.single;
        expect(original.method, operation.method);
        expect(original.path, operation.path(transport.target));
        if (operation == FinanceDurableOperation.chartAccountCreate) {
          expect(original.body.keys.toSet(), {
            'requestId',
            'code',
            'name',
            'currencyName',
            'category',
            'sourceReference',
            'classification',
            'currencyId',
          });
          expect(original.body['code'], '00560301');
          expect(original.body['currencyId'], _currency);
        } else {
          expect(original.body['expectedVersion'], 5);
          expect(original.body['balanceLineKey'], 'BS_51');
          expect(original.body['profitLineKey'], 'PL_PRIOR_ADJUSTMENT');
        }
        final draft = env.container.read(formDraftsProvider).single;
        expect(draft.data['sent'], original.body);
        await t.tap(_button('稍后核对'));
        await t.pumpAndSettle();
        expect(env.container.read(formDraftsProvider).single.id, draft.id);
        await env.close(t);
        transport.currencyStatus = '停用';
        env = await _open(
          t,
          transport,
          storage,
          resume: draft,
          hub: true,
          write: false,
        );
        await _action(t, '核对原操作结果');
        expect(transport.reads, hasLength(1));
        expect(
          transport.reads.single,
          endsWith('/${original.body['requestId']}'),
        );
        expect(transport.writes, hasLength(1));
        expect(transport.commits, 1);
        expect(transport.cancels, isEmpty);
        expect(env.container.read(formDraftsProvider), isEmpty);
        expect(t.takeException(), isNull);
        await env.close(t);
      },
    );
    testWidgets(
      '${operation.key} GET false and CAS conflict stay frozen, cancel loss restores proof and explicit review alone permits new UUID',
      (t) async {
        final transport = _Transport(operation)..reject = true;
        final storage = MemoryFormDraftStorage();
        var env = await _open(t, transport, storage);
        await _fill(t, operation);
        await t.tap(_button(_saveLabel(operation)));
        await t.pumpAndSettle();
        final original = Map<String, dynamic>.from(
          transport.writes.single.body,
        );
        await _action(t, '核对原操作结果');
        expect(_button('重试原请求'), findsOneWidget);
        transport.currentVersion = 9;
        transport.loseCancel = true;
        await _action(t, '核实未写并保留输入');
        expect(_button('重试原请求'), findsOneWidget);
        final draft = env.container.read(formDraftsProvider).single;
        await env.close(t);
        transport.loseCancel = false;
        env = await _open(t, transport, storage, resume: draft);
        await _action(t, '核对原操作结果');
        expect(_button('核对当前设置'), findsOneWidget);
        expect(transport.writes, hasLength(1));
        await t.tap(_button('核对当前设置'));
        await t.pumpAndSettle();
        expect(transport.writes, hasLength(1));
        await t.tap(_button('采用当前版本，保留输入'));
        await t.pumpAndSettle();
        expect(transport.writes, hasLength(1));
        transport.reject = false;
        transport.loseReply = false;
        await t.tap(_button(_saveLabel(operation)));
        await t.pumpAndSettle();
        final next = transport.writes.last.body;
        expect(next['requestId'], isNot(original['requestId']));
        final oldBusiness = {...original}
          ..remove('requestId')
          ..remove('expectedVersion');
        final newBusiness = {...next}
          ..remove('requestId')
          ..remove('expectedVersion');
        expect(newBusiness, oldBusiness);
        if (operation != FinanceDurableOperation.chartAccountCreate) {
          expect(next['expectedVersion'], 9);
        }
        expect(transport.commits, 1);
        expect(env.container.read(formDraftsProvider), isEmpty);
        expect(t.takeException(), isNull);
        await env.close(t);
      },
    );
    testWidgets(
      '${operation.key} wrong success code and lost read authority never complete or replay original input',
      (t) async {
        final transport = _Transport(operation)
          ..loseReply = false
          ..wrongSuccess = true;
        final storage = MemoryFormDraftStorage();
        var env = await _open(t, transport, storage);
        await _fill(t, operation);
        await t.tap(_button(_saveLabel(operation)));
        await t.pumpAndSettle();
        expect(_button('重试原请求'), findsOneWidget);
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
        expect(transport.reads, isEmpty);
        expect(transport.writes, hasLength(1));
        expect(storage.records, isNotEmpty);
        expect(t.takeException(), isNull);
        await env.close(t);
      },
    );
  }
  testWidgets(
    'legacy chart create GET uses the original body to strengthen the old success without creating again',
    (t) async {
      final transport = _Transport(FinanceDurableOperation.chartAccountCreate)
        ..legacy = true;
      final env = await _open(t, transport, MemoryFormDraftStorage());
      await _fill(t, transport.operation);
      await t.tap(_button('新增科目'));
      await t.pumpAndSettle();
      final original = transport.writes.single.body;
      await _action(t, '核对原操作结果');
      expect(transport.reads, hasLength(1));
      expect(transport.cancels, hasLength(1));
      expect(transport.cancels.single.body['requestBody'], original);
      expect(transport.writes, hasLength(1));
      expect(transport.commits, 1);
      expect(env.container.read(formDraftsProvider), isEmpty);
      await env.close(t);
    },
  );
  testWidgets(
    'scope ABA hides chart data and stale save callback cannot create under a replacement owner',
    (t) async {
      final transport = _Transport(FinanceDurableOperation.chartAccountCreate);
      final env = await _open(t, transport, MemoryFormDraftStorage());
      await _fill(t, transport.operation);
      final save = t.widget<UtenButton>(_button('新增科目')).onPressed!;
      env.container.read(_identity.notifier).state = const AuthenticatedScope(
        userId: 'different-reader',
      );
      await t.pump();
      env.container.read(_identity.notifier).state = const AuthenticatedScope(
        userId: financeCommandTestActor,
      );
      await t.pumpAndSettle();
      save();
      await t.pumpAndSettle();
      expect(find.text('访问范围已变化'), findsOneWidget);
      expect(transport.writes, isEmpty);
      expect(find.text('原损益科目'), findsNothing);
      await env.close(t);
    },
  );
  testWidgets(
    'chart metadata explicitly selects a nondeleted stopped UUID for history without enabling currency or creating financial documents',
    (t) async {
      final transport = _Transport(FinanceDurableOperation.chartAccountCreate)
        ..currencyStatus = '停用'
        ..loseReply = false;
      final env = await _open(t, transport, MemoryFormDraftStorage());
      await _fill(t, transport.operation);
      final dropdown = t.widget<UtenDropdownField>(
        find.byWidgetPredicate(
          (w) => w is UtenDropdownField && w.label == '核算币别',
        ),
      );
      expect(dropdown.value, _currency);
      expect(
        dropdown.items.singleWhere((item) => item.value == _currency).enabled,
        isTrue,
      );
      expect(
        dropdown.items
            .singleWhere((item) => item.value == _otherStopped)
            .enabled,
        isTrue,
      );
      await _choose(t, '核算币别', '原停用币别（OLD） · 已停用（历史核算）');
      await t.tap(_button('新增科目'));
      await t.pumpAndSettle();
      expect(transport.writes.single.body['currencyId'], _otherStopped);
      expect(
        transport.allRequests
            .where((request) => request.method != 'GET')
            .map((request) => request.path),
        ['/finance/chart'],
      );
      expect(transport.commits, 1);
      expect(t.takeException(), isNull);
      await env.close(t);
    },
  );
  testWidgets(
    'existing stopped UUID remains exact while all nondeleted historical choices stay available',
    (t) async {
      final transport = _Transport(FinanceDurableOperation.chartMappingReplace)
        ..currencyStatus = '停用'
        ..loseReply = false;
      final env = await _open(t, transport, MemoryFormDraftStorage());
      await _fill(t, transport.operation);
      final field = t.widget<UtenDropdownField>(
        find.byWidgetPredicate(
          (w) => w is UtenDropdownField && w.label == '核算币别',
        ),
      );
      expect(field.value, _currency);
      expect(
        field.items.singleWhere((item) => item.value == _currency).enabled,
        isTrue,
      );
      expect(
        field.items.singleWhere((item) => item.value == _otherStopped).enabled,
        isTrue,
      );
      await t.tap(_button('保存对应'));
      await t.pumpAndSettle();
      expect(transport.writes.single.body['currencyId'], _currency);
      expect(transport.commits, 1);
      expect(t.takeException(), isNull);
      await env.close(t);
    },
  );
  testWidgets(
    'a legacy code without currency identity can explicitly bind a stopped UUID before historical GL continuation',
    (t) async {
      final transport = _Transport(FinanceDurableOperation.chartMappingReplace)
        ..currencyStatus = '停用'
        ..missingCurrency = true
        ..loseReply = false;
      final env = await _open(t, transport, MemoryFormDraftStorage());
      await _fill(t, transport.operation);
      final field = find.byWidgetPredicate(
        (w) => w is UtenDropdownField && w.label == '核算币别',
      );
      expect(t.widget<UtenDropdownField>(field).value, isNull);
      await _choose(t, '核算币别', '人民币（CNY） · 本位币 · 已停用（历史核算）');
      await t.tap(_button('保存对应'));
      await t.pumpAndSettle();
      expect(transport.writes.single.body['currencyId'], _currency);
      expect(
        transport.allRequests
            .where((request) => request.method != 'GET')
            .map((request) => request.path),
        ['/finance/chart/310410'],
      );
      expect(transport.commits, 1);
      expect(t.takeException(), isNull);
      await env.close(t);
    },
  );
  for (final operation in _chartOperations) {
    testWidgets(
      '${operation.key} narrow enlarged form preserves controls and exact report choices',
      (t) async {
        final transport = _Transport(operation),
            env = await _open(
              t,
              transport,
              MemoryFormDraftStorage(),
              width: 390,
              scale: 1.5,
            );
        await _fill(t, operation);
        expect(t.takeException(), isNull);
        await t.tap(_button(_saveLabel(operation)));
        await t.pumpAndSettle();
        expect(transport.writes, hasLength(1));
        expect(t.takeException(), isNull);
        await env.close(t);
      },
    );
  }
}
