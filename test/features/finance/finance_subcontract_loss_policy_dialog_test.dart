import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/data_display/uten_detail_summary_card.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/finance/widgets/finance_subcontract_loss_policy_dialog.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import '../../shared/drafts/memory_form_draft_storage.dart';

const _seed = <String, dynamic>{
  '__goodsId': 'goods-1',
  '__unitId': 'unit-pcs',
  '__colorId': 'color-real',
  'goodsCode': 'G-1',
  'goodsName': '原发料货品',
  'color': '实际颜色',
};
const _exact = '5.000000000000000000000001';
Finder _field(String label) =>
    find.byWidgetPredicate((w) => w is UtenInput && w.label == label);
Future<void> _fill(WidgetTester tester) async {
  await tester.enterText(_field('允许损耗率（%）'), _exact);
  await tester.enterText(_field('生效日期'), '2026-10-01');
  await tester.enterText(_field('实际来源依据'), '实际原发料及原件确认百分率');
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    if (Platform.environment['UTEN_FIN02_SCREENSHOTS'] != null) {
      await (FontLoader(
        'NotoSansSC',
      )..addFont(rootBundle.load('assets/fonts/NotoSansSCFull.ttf'))).load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    }
  });
  testWidgets(
    'exact input and real UUID dimensions survive a hard reopen and unknown submits retry only the original body',
    (tester) async {
      final api = _Api()..unknown = true, storage = MemoryFormDraftStorage();
      var container = await _mount(tester, api, storage);
      await _fill(tester);
      await _screenshot(tester, 'fin02-loss-policy-wide.png');
      await tester.tap(find.text('提交审核'));
      await tester.pumpAndSettle();
      expect(api.commands, hasLength(1));
      final first = api.commands.single;
      final body = Map<String, dynamic>.from(first['body'] as Map);
      expect(body['ratePercent'], _exact);
      expect(body['goodsId'], 'goods-1');
      expect(body['colorId'], 'color-real');
      expect(body['unitId'], 'unit-pcs');
      expect(tester.widget<UtenInput>(_field('允许损耗率（%）')).enabled, isFalse);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      final draft = container.read(formDraftsProvider).single;
      expect(draft.hasUnknownSubmission, isTrue);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      container = await _mount(tester, api, storage, resume: draft.id);
      expect(
        tester.widget<UtenInput>(_field('允许损耗率（%）')).controller!.text,
        _exact,
      );
      api.unknown = false;
      await tester.tap(find.text('重试原请求'));
      await tester.pumpAndSettle();
      expect(api.commands, hasLength(2));
      expect(api.commands.last, first);
      expect(container.read(formDraftsProvider), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
  testWidgets(
    'a pending request can resolve by its original receipt without sending a new mutation',
    (tester) async {
      final api = _Api()..unknown = true;
      final container = await _mount(tester, api, MemoryFormDraftStorage());
      await _fill(tester);
      await tester.tap(find.text('提交审核'));
      await tester.pumpAndSettle();
      api.receipt = true;
      await tester.tap(find.text('核对原请求回执'));
      await tester.pumpAndSettle();
      expect(api.commands, hasLength(1));
      expect(container.read(formDraftsProvider), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
  testWidgets(
    'waiting overlay blocks rapid duplicate save and leaves exact fields intact',
    (tester) async {
      final api = _Api()..gate = Completer<Map<String, dynamic>>();
      final container = await _mount(tester, api, MemoryFormDraftStorage());
      await _fill(tester);
      await tester.tap(find.text('提交审核'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(UtenBusyOverlay), findsOneWidget);
      expect(api.commands, hasLength(1));
      final save = tester.widget<UtenButton>(
        find.widgetWithText(UtenButton, '重试原请求'),
      );
      expect(save.onPressed, isNull);
      api.gate!.complete({'id': 'server-policy'});
      await tester.pumpAndSettle();
      expect(api.commands, hasLength(1));
      expect(find.byType(UtenBusyOverlay), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
  testWidgets(
    'hard interruption keeps the original in-flight request and a late completion cannot close the restored editor',
    (tester) async {
      final api = _Api()..gate = Completer<Map<String, dynamic>>(),
          storage = MemoryFormDraftStorage();
      var container = await _mount(tester, api, storage);
      await _fill(tester);
      await tester.tap(find.text('提交审核'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(api.commands, hasLength(1));
      final draft = container.read(formDraftsProvider).single;
      expect(draft.hasUnknownSubmission, isTrue);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      container = await _mount(tester, api, storage, resume: draft.id);
      api.gate!.complete({'id': 'server-policy'});
      await tester.pumpAndSettle();
      expect(find.text('核对原请求回执'), findsOneWidget);
      expect(api.commands, hasLength(1));
      expect(
        tester.widget<UtenInput>(_field('允许损耗率（%）')).controller!.text,
        _exact,
      );
      api.receipt = true;
      await tester.tap(find.text('核对原请求回执'));
      await tester.pumpAndSettle();
      expect(api.commands, hasLength(1));
      expect(container.read(formDraftsProvider), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
  testWidgets(
    'matching request id alone cannot confirm a receipt with changed original values',
    (tester) async {
      final api = _Api()..unknown = true;
      final container = await _mount(tester, api, MemoryFormDraftStorage());
      await _fill(tester);
      await tester.tap(find.text('提交审核'));
      await tester.pumpAndSettle();
      api.receipt = true;
      api.wrongReceipt = true;
      await tester.tap(find.text('核对原请求回执'));
      await tester.pumpAndSettle();
      expect(find.text('重试原请求'), findsOneWidget);
      expect(
        container.read(formDraftsProvider).single.hasUnknownSubmission,
        isTrue,
      );
      expect(api.commands, hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
  testWidgets(
    'source picker pages actual records and retires private values after permission ABA',
    (tester) async {
      final grants = StateProvider<Set<String>>(
        (ref) => {
          Perm.financeReportView,
          Perm.financeViewAll,
          Perm.paymentStyleEdit,
        },
      );
      final api = _Api();
      final container = await _mount(
        tester,
        api,
        MemoryFormDraftStorage(),
        directory: true,
        grants: grants,
      );
      await tester.tap(find.text('新增规则'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择实际商品'));
      await tester.pumpAndSettle();
      final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
        find.byType(MasterDataTableView<Map<String, dynamic>>).last,
      );
      expect(table.items, hasLength(50));
      expect(table.totalPages, 400);
      table.onRowTap!(table.items.last);
      await tester.pumpAndSettle();
      expect(find.textContaining('真实商品49'), findsOneWidget);
      final prior = container.read(grants);
      container.read(grants.notifier).state = {};
      await tester.pumpAndSettle();
      expect(find.textContaining('真实商品49'), findsNothing);
      container.read(grants.notifier).state = prior;
      await tester.pumpAndSettle();
      expect(find.textContaining('真实商品49'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
  testWidgets(
    'review shows the original percent separately from the explicitly adopted rate',
    (tester) async {
      final api = _Api()..records = true;
      final container = await _mount(
        tester,
        api,
        MemoryFormDraftStorage(),
        directory: true,
      );
      final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
        find.byType(MasterDataTableView<Map<String, dynamic>>),
      );
      expect(
        table.columns.map((c) => c.label),
        containsAll(['原输入（%）', '实际采用值（%）']),
      );
      table.onRowTap!(table.items.single);
      await tester.pumpAndSettle();
      expect(
        tester.widget<UtenInput>(_field('允许损耗率（%）')).controller!.text,
        _exact,
      );
      final adopted = tester.widget<UtenSummaryField>(
        find.byWidgetPredicate(
          (w) => w is UtenSummaryField && w.label == '实际采用损耗率（%）',
        ),
      );
      expect(adopted.value, '5');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
  testWidgets(
    'narrow editor keeps original fields and actions without layout overflow',
    (tester) async {
      final container = await _mount(
        tester,
        _Api(),
        MemoryFormDraftStorage(),
        narrow: true,
      );
      await _fill(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('提交审核'), findsOneWidget);
      await _screenshot(tester, 'fin02-loss-policy-narrow.png');
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
}

Future<ProviderContainer> _mount(
  WidgetTester tester,
  _Api api,
  MemoryFormDraftStorage storage, {
  String? resume,
  bool directory = false,
  bool narrow = false,
  StateProvider<Set<String>>? grants,
}) async {
  await tester.binding.setSurfaceSize(
    narrow ? const Size(390, 844) : const Size(1200, 1000),
  );
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      apiBaseUrlProvider.overrideWithValue('https://finance-draft.test/api'),
      sessionProvider.overrideWith(_Session.new),
      authenticatedScopeProvider.overrideWithValue(
        const AuthenticatedScope(userId: 'finance-operator'),
      ),
      if (grants != null)
        currentPermissionsProvider.overrideWith((ref) => ref.watch(grants))
      else
        currentPermissionsProvider.overrideWithValue({
          Perm.financeReportView,
          Perm.financeViewAll,
          Perm.paymentStyleEdit,
          Perm.financePostExecute,
        }),
      sharedPreferencesProvider.overrideWithValue(prefs),
      formDraftStorageProvider.overrideWithValue(storage),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: const ValueKey('fin02-screen'),
        child: MaterialApp(
          theme: buildLightTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showFinanceSubcontractLossPolicyDialog(
                  context,
                  supplierId: 'supplier-real',
                  sourceRow: directory ? null : _seed,
                  resumeDraftId: resume,
                ),
                child: const Text('打开'),
              ),
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
  bool unknown = false, receipt = false, records = false, wrongReceipt = false;
  Completer<Map<String, dynamic>>? gate;
  final commands = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    commands.add({
      'path': path,
      'body': jsonDecode(jsonEncode(body)),
      'headers': headers ?? {},
    });
    if (gate != null) return gate!.future;
    if (unknown) throw NetworkTimeoutException();
    return {'id': 'server-policy'};
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('/operations/')) {
      if (!receipt) {
        throw ApiException(
          'NOT_FOUND',
          '尚未取得本人成功回执',
          hasResponseCode: true,
          httpStatus: 404,
        );
      }
      final body = Map<String, dynamic>.from(commands.single['body'] as Map);
      return {
        'id': 'server-policy',
        'request_id': path.split('/').last,
        'submitted_by': 'finance-operator',
        'revision': 0,
        'rate_percent_original': wrongReceipt ? '99' : body['ratePercent'],
        for (final entry in const {
          'supplierId': 'supplier_id',
          'goodsId': 'goods_id',
          'colorId': 'color_id',
          'unitId': 'unit_id',
          'effectiveFrom': 'effective_from',
          'effectiveTo': 'effective_to',
          'enabled': 'enabled',
          'sourceReference': 'source_reference',
        }.entries)
          entry.value: body[entry.key],
      };
    }
    if (path.endsWith('/source-choices')) {
      return {
        'items': [
          for (int i = 0; i < 50; i++)
            {
              'goodsId': 'goods-$i',
              'colorId': null,
              'unitId': 'unit-real',
              'goodsCode': 'G-$i',
              'goodsName': '真实商品$i',
              'unitCode': 'PCS',
              'unitName': '件',
              'actualSource': true,
            },
        ],
        'totalPages': 400,
      };
    }
    if (records) {
      final row = <String, dynamic>{
        'id': 'policy-real',
        'supplier_id': 'supplier-real',
        'goods_id': 'goods-1',
        'unit_id': 'unit-pcs',
        'color_id': 'color-real',
        'goodsCode': 'G-1',
        'goodsName': '原发料货品',
        'rate_percent_originalExact': _exact,
        'ratePercentExact': '5',
        'effective_from': '2026-10-01',
        'enabled': true,
        'status': 'SUBMITTED',
        'revision': 0,
        'source_reference': '原输入和明确采用比例都保留',
        'submitted_by': 'independent-maker',
      };
      if (path.endsWith('/policy-real')) return row;
      return {
        'items': [row],
        'totalPages': 1,
      };
    }
    return {'items': <Object>[], 'totalPages': 0};
  }
}

Future<void> _screenshot(WidgetTester tester, String name) async {
  final folder = Platform.environment['UTEN_FIN02_SCREENSHOTS'];
  if (folder == null) return;
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  await tester.drag(
    find.byType(SingleChildScrollView).first,
    const Offset(0, 2000),
  );
  await tester.pumpAndSettle();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('fin02-screen')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(folder).create(recursive: true);
      await File('$folder/$name').writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}
