import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';
import 'package:uten_imp/components/layout/uten_action_overflow.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/finance/config/finance_requirement_names.dart';
import 'package:uten_imp/features/finance/widgets/finance_asset_opening_group_dialog.dart';
import 'package:uten_imp/features/finance/widgets/finance_entry_file_picker.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_navigation.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

import '../../shared/drafts/memory_form_draft_storage.dart';

const _source = '10000000-0000-4000-8000-000000000001',
    _asset = '10000000-0000-4000-8000-000000000002',
    _voucher = '10000000-0000-4000-8000-000000000003',
    _entry = '10000000-0000-4000-8000-000000000004',
    _group = '10000000-0000-4000-8000-000000000005';
const _exact = '12345678901234.123456789012345678901234';
final _scope = StateProvider<AuthenticatedScope?>(
  (ref) => const AuthenticatedScope(userId: 'asset-user'),
);
final _captureKey = GlobalKey();
bool get _captureEnabled =>
    Platform.environment['UTEN_CAPTURE_FINANCE_ASSET_UI'] == '1';
List<String> _headers(String template) {
  final contract =
      jsonDecode(
            File(
              'server/src/main/resources/finance/template-contract-v1.json',
            ).readAsStringSync(),
          )
          as Map;
  return (((contract['templates'] as Map)[template] as Map)['headers'] as List)
      .cast<String>();
}

Future<void> _capture(WidgetTester t, String name) async {
  if (!_captureEnabled) return;
  await t.pumpAndSettle();
  final boundary =
      _captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await t.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('output/finance-cost-assets/ui/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  setUpAll(() async {
    if (_captureEnabled) {
      final font = FontLoader('NotoSansSC')
        ..addFont(rootBundle.load('assets/fonts/NotoSansSCFull.ttf'));
      await font.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    }
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    '2000 source rows retain exact original headers and bounded work',
    (t) async {
      await _size(t);
      final slices = <Duration>[];
      debugUiWorkSliceObserver = (label, time) {
        if (label == 'finance.asset-opening.original-projection') {
          slices.add(time);
        }
      };
      addTearDown(() => debugUiWorkSliceObserver = null);
      final env = await _pump(t, _Api(rows: 2000), MemoryFormDraftStorage());
      final table = _table(t);
      expect(table.virtualized, isTrue);
      expect(table.items, hasLength(2000));
      expect(
        table.columns.skip(1).take(55).map((c) => c.label).toList(),
        _headers('depreciation'),
      );
      expect(table.items.first['9'], _exact);
      expect(slices, isNotEmpty);
      await _capture(t, '01-fixed-asset-original-55-columns-anonymous');
      expect(find.textContaining('已选1行'), findsNothing);
      expect(t.takeException(), isNull);
      await _dispose(t, env);
    },
  );

  testWidgets(
    'explicit asset choice and unfinished month text survive interruption without source body',
    (t) async {
      await _size(t);
      final api = _Api(), storage = MemoryFormDraftStorage();
      var env = await _pump(t, api, storage);
      await _mapMember(t);
      await _capture(t, '02-explicit-asset-mapping-anonymous');
      _input(t, 'asset-opening-remaining-4').text = '1.';
      _label(t, '本次核对／撤销依据').text = '原表第四行与明确资产编号核对';
      await t.pump(const Duration(milliseconds: 500));
      await t.pumpAndSettle();
      final draft = env.container.read(formDraftsProvider).single;
      final member = Map<String, dynamic>.from(
        (draft.data['members'] as List).single as Map,
      );
      expect(member['remainingMonths'], '1.');
      expect((member['asset'] as Map)['id'], _asset);
      expect(
        jsonEncode(draft.data),
        isNot(contains('RAW_SOURCE_DO_NOT_EXECUTE')),
      );
      expect(jsonEncode(draft.data), isNot(contains('原列55')));
      await _dispose(t, env);
      env = await _pump(t, api, storage, resumeDraftId: draft.id);
      expect(_input(t, 'asset-opening-remaining-4').text, '1.');
      expect(_label(t, '本次核对／撤销依据').text, '原表第四行与明确资产编号核对');
      expect(api.posts, isEmpty);
      expect(t.takeException(), isNull);
      await _dispose(t, env);
    },
  );

  testWidgets(
    'unknown create is frozen and replays the identical request after restoring draft and original voucher references',
    (t) async {
      await _size(t);
      final api = _Api(timeout: true), storage = MemoryFormDraftStorage();
      var env = await _pump(t, api, storage);
      await _prepare(t);
      final send = Future<void>.sync(_button(t, '提交接续核对').onPressed!);
      // A previously captured button callback cannot bypass the live busy gate.
      await Future<void>.sync(_button(t, '提交接续核对').onPressed ?? () {});
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(api.posts, hasLength(1));
      api.first.completeError(NetworkTimeoutException());
      await send;
      await t.pumpAndSettle();
      await _capture(t, '03-unknown-create-retains-command-anonymous');
      final draft = env.container.read(formDraftsProvider).single;
      final before = jsonEncode(api.posts.single);
      expect(_label(t, '本次核对／撤销依据').text, '按原表及已记账凭证核对');
      expect(
        t
            .widget<UtenInput>(
              find.byWidgetPredicate(
                (w) => w is UtenInput && w.label == '本次核对／撤销依据',
              ),
            )
            .enabled,
        isFalse,
      );
      await _dispose(t, env);
      env = await _pump(t, api, storage, resumeDraftId: draft.id);
      await t.tap(find.widgetWithText(UtenButton, '使用原请求核对并重试'));
      await t.pumpAndSettle();
      expect(api.posts, hasLength(2));
      expect(jsonEncode(api.posts.last), before);
      expect(env.container.read(formDraftsProvider), isEmpty);
      expect(t.takeException(), isNull);
      await _dispose(t, env);
    },
  );

  testWidgets(
    'unknown CAS approval does not accept another actor or issue a newer-version retry',
    (t) async {
      await _size(t);
      final api = _Api(timeout: true, group: true),
          storage = MemoryFormDraftStorage();
      var env = await _pump(t, api, storage, group: true);
      _label(t, '本次核对／撤销依据').text = '复核该组原始证据';
      final send = Future<void>.sync(_button(t, '复核接续').onPressed!);
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      api.first.completeError(NetworkTimeoutException());
      await send;
      await t.pumpAndSettle();
      final draft = env.container.read(formDraftsProvider).single;
      api.status = 'APPROVED';
      api.version = 1;
      api.approver = 'someone-else';
      await _dispose(t, env);
      env = await _pump(t, api, storage, group: true, resumeDraftId: draft.id);
      await t.tap(find.widgetWithText(UtenButton, '使用原请求核对并重试'));
      await t.pumpAndSettle();
      expect(api.posts, hasLength(1));
      expect(
        env.container.read(formDraftsProvider).single.hasUnknownSubmission,
        isTrue,
      );
      api.approver = 'asset-user';
      await t.tap(find.widgetWithText(UtenButton, '核对原操作结果'));
      await t.pumpAndSettle();
      expect(api.posts, hasLength(1));
      expect(env.container.read(formDraftsProvider), isEmpty);
      expect(t.takeException(), isNull);
      await _dispose(t, env);
    },
  );

  testWidgets(
    'same actor cannot approve own group; another reviewer can approve revocation with exact CAS version',
    (t) async {
      await _size(t);
      final api = _Api(group: true)..submitter = 'asset-user';
      var env = await _pump(t, api, MemoryFormDraftStorage(), group: true);
      expect(_button(t, '复核接续').onPressed, isNull);
      await _dispose(t, env);
      api.status = 'REVOKE_PENDING';
      api.version = 2;
      env = await _pump(t, api, MemoryFormDraftStorage(), group: true);
      _label(t, '本次核对／撤销依据').text = '已倒序红冲本系统计提，撤销本次认领';
      await t.tap(find.widgetWithText(UtenButton, '复核撤销本次接续'));
      await t.pumpAndSettle();
      expect(
        api.posts.single['path'],
        '/finance/asset-opening-groups/$_group/approve-revoke',
      );
      expect(api.posts.single['body'], {
        'expectedVersion': 2,
        'reason': '已倒序红冲本系统计提，撤销本次认领',
      });
      expect(t.takeException(), isNull);
      await _dispose(t, env);
    },
  );

  testWidgets('late source cannot return after owner A-B-A', (t) async {
    await _size(t);
    final gate = Completer<void>(), api = _Api(gate: gate);
    final env = await _pump(t, api, MemoryFormDraftStorage(), settle: false);
    env.container.read(_scope.notifier).state = const AuthenticatedScope(
      userId: 'other',
    );
    await t.pump();
    env.container.read(_scope.notifier).state = const AuthenticatedScope(
      userId: 'asset-user',
    );
    await t.pump();
    gate.complete();
    await t.pumpAndSettle();
    expect(find.textContaining('登录身份或服务器已变化'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (w) => w is MasterDataTableView<Map<String, dynamic>>,
      ),
      findsNothing,
    );
    expect(api.posts, isEmpty);
    await _dispose(t, env);
  });

  testWidgets(
    'cancelling file selection preserves period and never submits a group',
    (t) async {
      await _size(t);
      final api = _Api(), storage = MemoryFormDraftStorage();
      final env = await _pump(t, api, storage, initialSource: false);
      _label(t, '原表会计月份（YYYY-MM）').text = '2026-09';
      await t.tap(find.widgetWithText(UtenButton, '导入财务原表'));
      await t.pumpAndSettle();
      expect(_label(t, '原表会计月份（YYYY-MM）').text, '2026-09');
      expect(api.posts, isEmpty);
      expect(
        env.container.read(formDraftsProvider).single.data['period'],
        '2026-09',
      );
      expect(t.takeException(), isNull);
      await _dispose(t, env);
    },
  );

  testWidgets(
    'completed archive retains original 39 headers and fixed original dates',
    (t) async {
      await _size(t);
      final env = await _pump(
        t,
        _Api(template: 'depreciationCompleted'),
        MemoryFormDraftStorage(),
      );
      expect(
        find.text('${FinanceRequirementNames.depreciationCompleted}原表接续'),
        findsOneWidget,
      );
      expect(
        _table(t).columns.skip(1).take(39).map((c) => c.label),
        _headers('depreciationCompleted'),
      );
      expect(
        _headers('depreciationCompleted').any((h) => h.contains('2025/7/29')),
        isTrue,
      );
      await _capture(t, '05-completed-archive-original-dates-anonymous');
      expect(t.takeException(), isNull);
      await _dispose(t, env);
    },
  );

  testWidgets(
    '392px layout uses Uten actions and original entry names without overflow',
    (t) async {
      t.view.physicalSize = const Size(392, 760);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await t.binding.setSurfaceSize(const Size(392, 760));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final env = await _pump(
        t,
        _Api(template: 'amortization'),
        MemoryFormDraftStorage(),
      );
      expect(
        find.text('${FinanceRequirementNames.amortization}原表接续'),
        findsOneWidget,
      );
      expect(find.byType(UtenActionOverflow), findsWidgets);
      await _capture(t, '04-amortization-narrow-anonymous');
      expect(t.takeException(), isNull);
      await _dispose(t, env);
    },
  );
}

Future<void> _size(WidgetTester t) async {
  t.view.physicalSize = const Size(1500, 1100);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  await t.binding.setSurfaceSize(const Size(1500, 1100));
  addTearDown(() => t.binding.setSurfaceSize(null));
}

MasterDataTableView<Map<String, dynamic>> _table(WidgetTester t) => t.widget(
  find.byWidgetPredicate((w) => w is MasterDataTableView<Map<String, dynamic>>),
);
UtenButton _button(WidgetTester t, String text) =>
    t.widget(find.widgetWithText(UtenButton, text));
TextEditingController _label(WidgetTester t, String label) => t
    .widget<UtenInput>(
      find.byWidgetPredicate((w) => w is UtenInput && w.label == label),
    )
    .controller!;
TextEditingController _input(WidgetTester t, String key) =>
    t.widget<UtenInput>(find.byKey(ValueKey(key))).controller!;
Future<void> _mapMember(WidgetTester t) async {
  final table = _table(t),
      context = t.element(find.byType(FinanceAssetOpeningGroupSurface));
  final button =
      table.columns.firstWhere((c) => c.key == 'map').cellBuilder!(
            context,
            table.items.first,
          )
          as UtenButton;
  button.onPressed!();
  await t.pumpAndSettle();
  await t.tap(find.text('成员对应'));
  await t.pumpAndSettle();
  expect(find.byWidgetPredicate((w) => w is UtenEditableGrid), findsOneWidget);
  await t.ensureVisible(find.widgetWithText(UtenButton, '选择草稿'));
  await t.pumpAndSettle();
  await t.tap(find.widgetWithText(UtenButton, '选择草稿'));
  await t.pumpAndSettle();
  final pick = _table(t), row = pick.items.last;
  final select =
      pick.columns.firstWhere((c) => c.key == 'select').cellBuilder!(
            t.element(find.byType(FinanceAssetOpeningGroupSurface)),
            row,
          )
          as UtenButton;
  select.onPressed!();
  await t.pumpAndSettle();
}

Future<void> _prepare(WidgetTester t) async {
  await _mapMember(t);
  _input(t, 'asset-opening-remaining-4').text = '12';
  _label(t, '本次核对／撤销依据').text = '按原表及已记账凭证核对';
  await t.tap(find.text('凭证条目'));
  await t.pumpAndSettle();
  _label(t, '完整原凭证号').text = '记-2026-09-0001';
  await t.tap(find.widgetWithText(UtenButton, '查找并加入凭证'));
  await t.pumpAndSettle();
  t
      .widget<UtenDropdownField>(
        find.byWidgetPredicate(
          (w) => w is UtenDropdownField && w.label == '主要来源凭证',
        ),
      )
      .onChanged(_voucher);
  await t.pumpAndSettle();
  final table = _table(t);
  final box =
      table.columns.firstWhere((c) => c.key == 'selected').cellBuilder!(
            t.element(find.byType(FinanceAssetOpeningGroupSurface)),
            table.items.first,
          )
          as Checkbox;
  box.onChanged!(true);
  await t.pumpAndSettle();
  await t.tap(find.text('成员对应'));
  await t.pumpAndSettle();
  await t.tap(find.widgetWithText(UtenButton, '读取最新成员并核对'));
  await t.pumpAndSettle();
}

typedef _Env = ({ProviderContainer container, GoRouter router});
Future<_Env> _pump(
  WidgetTester t,
  _Api api,
  MemoryFormDraftStorage storage, {
  bool group = false,
  bool initialSource = true,
  bool settle = true,
  String? resumeDraftId,
}) async {
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      authenticatedScopeProvider.overrideWith((ref) => ref.watch(_scope)),
      currentPermissionsProvider.overrideWithValue({
        Perm.financeAssetView,
        Perm.financeAssetEdit,
        Perm.financeAssetApprove,
        Perm.financeReportView,
        Perm.financeViewAll,
      }),
      apiBaseUrlProvider.overrideWithValue('https://test.example/api'),
      formDraftStorageProvider.overrideWithValue(storage),
      financeEntryFilePickerProvider.overrideWithValue(() async => null),
    ],
  );
  final router = GoRouter(
    initialLocation: '/finance',
    routes: [
      DraftAwareGoRoute(
        path: '/finance',
        builder: (context, state) => Scaffold(
          body: Center(
            child: UtenButton(
              onPressed: () => showFinanceAssetOpeningGroupDialog(
                context,
                template: api.template,
                initialSourceImportId: group || !initialSource ? null : _source,
                initialGroupId: group ? _group : null,
                resumeDraftId: resumeDraftId,
              ),
              child: const Text('打开接续'),
            ),
          ),
        ),
      ),
    ],
  );
  await t.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: _captureKey,
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          routerConfig: router,
          theme: _captureEnabled ? buildLightTheme() : null,
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
  await t.tap(find.text('打开接续'));
  if (settle) {
    await t.pumpAndSettle();
  } else {
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
  }
  return (container: container, router: router);
}

Future<void> _dispose(WidgetTester t, _Env env) async {
  await t.pumpWidget(const SizedBox());
  env.router.dispose();
  env.container.dispose();
}

class _Api extends ApiClient {
  _Api({
    this.rows = 1,
    this.timeout = false,
    this.group = false,
    this.gate,
    this.template = 'depreciation',
  }) : super(Dio(BaseOptions(baseUrl: 'https://test.example/api')));
  final int rows;
  final bool timeout, group;
  final String template;
  final Completer<void>? gate;
  final posts = <Map<String, dynamic>>[];
  final first = Completer<Map<String, dynamic>>();
  String status = 'SUBMITTED', submitter = 'original-owner';
  String? approver;
  int version = 0;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/finance/asset-opening-groups') return {'items': <Object>[]};
    if (group && path == '/finance/template-imports/$_source') {
      throw ApiException(
        'NOT_FOUND',
        '通用原件只供上传人读取',
        httpStatus: 404,
        hasResponseCode: true,
      );
    }
    if (path == '/finance/template-imports/$_source' ||
        path == '/finance/asset-opening-groups/$_group/source') {
      if (gate != null) await gate!.future;
      return {
        'importId': _source,
        'template': template,
        'period': '2026-09',
        'sourceName': '匿名资产原表.xlsx',
        'sourceSheet': '原表',
        'sha256': 'a' * 64,
        'hiddenIncluded': true,
        'issues': <String>[],
        'headers': _headers(template),
        'rows': [
          for (int r = 0; r < rows; r++)
            {
              'sourceRow': r + 4,
              'issues': <String>[],
              'cells': [
                {
                  'column': template == 'amortization' ? 3 : 6,
                  'text': '匿名资产',
                  'kind': 'TEXT',
                },
                {
                  'column': template == 'amortization' ? 7 : 9,
                  'number': _exact,
                  'text': _exact,
                  'kind': 'NUMBER',
                },
                {
                  'column': template == 'amortization' ? 9 : 11,
                  'number': '100.000000001',
                  'text': '100.000000001',
                  'kind': 'NUMBER',
                },
                {
                  'column': 55,
                  'text': 'RAW_SOURCE_DO_NOT_EXECUTE',
                  'kind': 'TEXT',
                },
              ],
            },
        ],
      };
    }
    Map<String, dynamic> asset(String id) => {
      'id': id,
      'code': 'FA-01',
      'name': '匿名资产',
      'status': 'DRAFT',
      'version': 7,
      'originalValue': _exact,
      'totalAmount': _exact,
      'categoryName': '原财务已核对政策',
    };
    if (path == '/finance/fixed-assets' ||
        path == '/finance/deferred-expenses') {
      return {
        'items': [asset('different-id'), asset(_asset)],
        'total': 2,
      };
    }
    if (path == '/finance/fixed-assets/$_asset' ||
        path == '/finance/deferred-expenses/$_asset') {
      return {'summary': asset(_asset)};
    }
    if (path == '/finance/asset-opening-groups/vouchers') {
      return {
        'items': [
          {
            'id': _voucher,
            'voucherNo': '记-2026-09-0001',
            'voucherDate': '2026-09-01',
            'entries': [
              {
                'id': _entry,
                'styleId': 'style',
                'code': '1601',
                'name': '固定资产',
                'direction': 1,
                'amount': _exact,
              },
            ],
          },
        ],
      };
    }
    if (path == '/finance/asset-opening-groups/$_group') {
      return {
        'id': _group,
        'source_import_id': _source,
        'fingerprint': 'b' * 64,
        'status': status,
        'version': version,
        'actor_id': submitter,
        'approved_by': approver,
        'revoke_actor_id': 'revocation-owner',
        'revoke_reason': '原撤销依据',
        'reason': '原接续依据',
        'as_of': '2026-09-30',
        'sourceVoucherIds': [_voucher],
        'source_entry_snapshot': [
          {
            'id': _entry,
            'voucherId': _voucher,
            'voucherNo': '记-2026-09-0001',
            'direction': 1,
            'amount': _exact,
          },
        ],
        'member_snapshot': [
          {
            'objectType': 'FIXED_ASSET',
            'objectId': _asset,
            'sourceRow': 4,
            'remainingMonths': 12,
            'name': '匿名资产',
            'code': 'FA-01',
            'row_version': 7,
            'lifecycle_status': 'DRAFT',
            'original': _exact,
          },
        ],
      };
    }
    throw StateError('Unexpected GET $path');
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    posts.add({'path': path, 'body': jsonDecode(jsonEncode(body))});
    if (timeout && posts.length == 1) return first.future;
    return {
      'id': path == '/finance/asset-opening-groups'
          ? (body as Map)['requestId']
          : _group,
      'status': 'APPROVED',
    };
  }
}
