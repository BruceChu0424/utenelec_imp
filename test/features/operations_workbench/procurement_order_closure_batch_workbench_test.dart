import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/layout/uten_floating_action_group.dart';
import 'package:uten_imp/components/data_display/uten_selection_summary_pill.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/operations_workbench/models/operations_workbench.dart';
import 'package:uten_imp/features/operations_workbench/pages/operations_workbench_page.dart';
import 'package:uten_imp/features/operations_workbench/repositories/operations_workbench_repository.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_decomposition_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/widgets/procurement_order_closure_selection_action.dart';
import 'package:uten_imp/core/theme/light_theme.dart';

import '../../helpers/badge_summary_fixture.dart';
import '../subcontract/fake_subcontract_draw_gateway.dart';
import '../../support/audit_screenshot_support.dart';

final _identity = StateProvider<AuthenticatedScope?>(
  (_) => const AuthenticatedScope(userId: 'reader-a'),
);

class _Gateway implements OperationsWorkbenchGateway {
  _Gateway(
    this.subcontract, {
    this.application = false,
    this.mixedApplication = false,
    this.legacyClosure = false,
  });
  final bool subcontract, application, mixedApplication, legacyClosure;
  int reads = 0;
  @override
  Future<OperationsWorkbenchData> load({
    required OperationsWorkbenchDepartment department,
    int page = 1,
    int size = 20,
    String? keyword,
    String? status,
    String? exception,
    String? dateFrom,
    String? dateTo,
    String? sort,
    String? order,
    Map<String, String?> columnFilters = const {},
    String? issuedFrom,
    String? issuedTo,
    String? needFrom,
    String? needTo,
  }) async {
    reads++;
    return OperationsWorkbenchData(
      department: department,
      summary: const OperationsWorkbenchSummary(
        totalTasks: 3,
        overdueTasks: 0,
        openTasks: 3,
        openQty: 9,
        statusCounts: {'IN_PROGRESS': 3, 'WAITING_ORDER': 1},
      ),
      items: [
        for (var i = 0; i < (application ? 1 : 3); i++)
          OperationsWorkbenchTask.fromJson({
            'taskId': 'row-$i',
            'planNo': 'PLAN-$i',
            'goodsName': '货品$i',
            'requiredQty': 3,
            'openQty': 3,
            'taskStatus': application ? 'WAITING_ORDER' : 'FINANCE_APPROVED',
            if (legacyClosure) 'displayStage': 'ORDER_CLOSE_PENDING',
            'supplyRoute': subcontract ? 'SUBCONTRACT' : 'PURCHASE',
            'actionDocType': application || (mixedApplication && i == 2)
                ? (subcontract ? 'SUBCONTRACT_APPLICATION' : 'PURCHASE_REQUEST')
                : (subcontract ? 'SUBCONTRACT_ORDER' : 'PURCHASE_ORDER'),
            'actionDocId': i < 2 ? 'order-1' : 'order-2',
            'actionDocNo': i < 2 ? 'ORDER-1' : 'ORDER-2',
            'actionDocStatus': '1',
            'actionDocCanView': true,
          }, department),
      ],
      page: page,
      size: size,
      total: application ? 1 : 3,
      totalPages: 1,
      capabilities: const OperationsWorkbenchCapabilities(),
    );
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Api extends ApiClient {
  _Api() : super(Dio(BaseOptions(baseUrl: 'https://example.invalid/api')));
  final previews = <Map<String, dynamic>>[];
  final submissions = <Map<String, dynamic>>[];
  bool blockSecond = false;
  bool blockAll = false;
  Completer<Map<String, dynamic>>? previewGate;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => {};
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
  }) async {
    final payload = (body as Map).cast<String, dynamic>();
    if (path.endsWith('/batch-preview')) {
      previews.add(payload);
      return previewGate?.future ??
          {
            'canSubmit': !blockSecond && !blockAll,
            'items': [
              for (final order in payload['orders'] as List)
                {
                  ...(order as Map<String, dynamic>),
                  'billNo': 'ORDER-${order['orderId']}',
                  'fingerprint': 'fp-${order['orderId']}',
                  'canSubmit':
                      !blockAll &&
                      (!blockSecond || order['orderId'] != 'order-2'),
                  'canReorder': true,
                  if (blockAll ||
                      (blockSecond && order['orderId'] == 'order-2'))
                    'blockReason': '还有未完成的收货草稿，请先在仓库处理',
                  'items': [
                    {
                      'orderItemId': 'line-${order['orderId']}',
                      'goodsName': '对应整单全部明细',
                      'remainingQty': '3',
                      'remainingGiftQty': '0',
                    },
                  ],
                },
            ],
          };
    }
    submissions.add(payload);
    return {
      'submittedCount': (payload['items'] as List).length,
      'approvals': [
        for (final _ in payload['items'] as List) {'status': 'APPROVED'},
      ],
    };
  }
}

Future<({ProviderContainer container, _Gateway gateway, _Api api})> _mount(
  WidgetTester tester,
  bool subcontract, {
  bool application = false,
  bool mixedApplication = false,
  bool draw = false,
  bool permission = true,
  bool legacyClosure = false,
  double width = 1400,
  _Api? api,
  GlobalKey? capture,
  double textScale = 1,
}) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final gateway = _Gateway(
    subcontract,
    application: application,
    mixedApplication: mixedApplication,
    legacyClosure: legacyClosure,
  );
  final client = api ?? _Api();
  final drawGateway = FakeSubcontractDrawGateway(
    canSubmitDraw: false,
    rows: draw
        ? [drawRow('draw-a', canDraw: false), drawRow('draw-b', canDraw: false)]
        : [],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(client),
        apiBaseUrlProvider.overrideWithValue('https://example.invalid/api'),
        authenticatedScopeProvider.overrideWith((ref) => ref.watch(_identity)),
        currentPermissionsProvider.overrideWithValue({
          Perm.purchaseOrderView,
          Perm.purchaseRequestView,
          Perm.subcontractApplicationView,
          Perm.subcontractOrderView,
          if (permission) Perm.purchaseOrderSubmitFinance,
          if (permission) Perm.subcontractOrderSubmitFinance,
        }),
        isSuperAdminProvider.overrideWithValue(false),
        fixedBadgeSummaryOverride(),
      ],
      child: MaterialApp(
        theme: capture == null ? null : auditScreenshotTheme(buildLightTheme()),
        builder: (context, child) {
          final scaled = MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          );
          return capture == null
              ? scaled
              : RepaintBoundary(key: capture, child: scaled);
        },
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: subcontract
            ? SubcontractDecompositionPage(
                repository: gateway,
                drawRepository: drawGateway,
              )
            : OperationsWorkbenchPage(
                department: OperationsWorkbenchDepartment.purchase,
                repository: gateway,
              ),
      ),
    ),
  );
  final container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp)),
  );
  await tester.pumpAndSettle();
  final stage = find.text(
    draw || application ? (subcontract ? '待处理' : '申请待分解') : '进行中',
  );
  if (stage.evaluate().isEmpty) {
    await tester.tap(find.text('选择分类'));
    await tester.pumpAndSettle();
  }
  await tester.ensureVisible(stage);
  await tester.tap(stage);
  await tester.pumpAndSettle();
  return (container: container, gateway: gateway, api: client);
}

Finder get _action =>
    find.byKey(const Key('procurement-order-closure-selection-action'));
void _selectOrders(WidgetTester tester, Set<String> ids) {
  final table = tester.widget<MasterDataTableView<OperationsWorkbenchTask>>(
    find.byType(MasterDataTableView<OperationsWorkbenchTask>),
  );
  table.onSelectedIdsChanged!(ids);
}

void main() {
  for (final subcontract in [false, true]) {
    testWidgets(
      '${subcontract ? 'subcontract' : 'purchase'} historical closure stays selectable for direct execution',
      (tester) async {
        final fixture = await _mount(tester, subcontract, legacyClosure: true);
          expect(find.text('历史结束申请待业务确认'), findsWidgets);
        _selectOrders(tester, {'row-0'});
        await tester.pumpAndSettle();
        expect(tester.widget<UtenButton>(_action).onPressed, isNotNull);
        await tester.tap(_action);
        await tester.pumpAndSettle();
        expect(find.textContaining('无需财务批准'), findsWidgets);
        expect(fixture.api.previews.last['orders'], [
          {
            'orderType': subcontract ? 'SUBCONTRACT' : 'PURCHASE',
            'orderId': 'order-1',
          },
        ]);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('shared table keeps summary-first order: 已选胶囊最左、业务动作在右', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MasterDataTableView<String>(
            columns: [
              MasterColumnDef(
                key: 'name',
                label: '名称',
                width: 160,
                value: (item) => item,
              ),
            ],
            items: const ['one'],
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
            selectable: true,
            idOf: (item) => item,
            onSelectedIdsChanged: (_) {},
            batchActionsBuilder: (_, _) => [const Text('普通批量动作')],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final group = tester.widget<UtenFloatingActionGroup>(
      find.byType(UtenFloatingActionGroup),
    );
    expect(group.children.first, isA<UtenSelectionSummaryPill>());
    expect(group.children.last, isA<Text>());
  });
  for (final subcontract in [false, true]) {
    testWidgets(
      '${subcontract ? 'subcontract' : 'purchase'} bottom-right action survives zero selection and deduplicates whole orders',
      (tester) async {
        const captureUi = bool.fromEnvironment('UTEN_CAPTURE_UI');
        final capture = captureUi ? GlobalKey() : null;
        if (captureUi) await loadAuditScreenshotFonts(tester);
        final fixture = await _mount(tester, subcontract, capture: capture);
        expect(
          find.ancestor(
            of: _action,
            matching: find.byType(UtenFloatingActionGroup),
          ),
          findsOneWidget,
        );
        expect(tester.widget<UtenButton>(_action).onPressed, isNull);
        expect(find.text('取消/结束订单 (0)'), findsOneWidget);
        _selectOrders(tester, {'row-0', 'row-1', 'row-2'});
        await tester.pumpAndSettle();
        expect(find.text('批量取消/结束 (2)'), findsOneWidget);
        final rect = tester.getRect(_action);
        expect(rect.bottom, greaterThan(600));
        expect(rect.right, greaterThan(700));
        if (capture != null) {
          await saveAuditScreenshot(
            tester,
            capture,
            '${subcontract ? 'subcontract' : 'purchase'}-cancel-end-batch-wide',
          );
        }
        await tester.tap(_action);
        await tester.pumpAndSettle();
        expect(fixture.api.previews.last['orders'], [
          {
            'orderType': subcontract ? 'SUBCONTRACT' : 'PURCHASE',
            'orderId': 'order-1',
          },
          {
            'orderType': subcontract ? 'SUBCONTRACT' : 'PURCHASE',
            'orderId': 'order-2',
          },
        ]);
        expect(find.textContaining('包含全部明细'), findsOneWidget);
        await tester.enterText(
          find.byKey(const Key('procurement-order-closure-batch-reason')),
          '供应商停止供货',
        );
        final reads = fixture.gateway.reads;
        await tester.tap(
          find.byKey(const Key('procurement-order-closure-batch-submit')),
        );
        await tester.pumpAndSettle();
        expect(fixture.api.submissions.single['items'], hasLength(2));
        expect(fixture.gateway.reads, greaterThan(reads));
        expect(tester.widget<UtenButton>(_action).onPressed, isNull);
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      '${subcontract ? 'subcontract' : 'purchase'} absent finance-submit authority leaves a visible disabled action',
      (tester) async {
        final fixture = await _mount(tester, subcontract, permission: false);
        _selectOrders(tester, {'row-0'});
        await tester.pumpAndSettle();
        expect(_action, findsOneWidget);
        expect(tester.widget<UtenButton>(_action).onPressed, isNull);
        expect(find.byTooltip('缺少采购或委外订单办理权限，请联系管理员授权。'), findsOneWidget);
        expect(fixture.api.previews, isEmpty);
      },
    );
  }
  testWidgets(
    'subcontract pending draw rows can end their order even when drawing is unavailable',
    (tester) async {
      final fixture = await _mount(tester, true, draw: true);
      final table = tester.widget<MasterDataTableView<SubcontractPendingRow>>(
        find.byType(MasterDataTableView<SubcontractPendingRow>),
      );
      expect(table.selectable, isTrue);
      table.onSelectedIdsChanged!({'draw-draw-a', 'draw-draw-b'});
      await tester.pumpAndSettle();
      expect(tester.widget<UtenButton>(_action).onPressed, isNotNull);
      await tester.tap(_action);
      await tester.pumpAndSettle();
      expect(fixture.api.previews.last['orders'], [
        {'orderType': 'SUBCONTRACT', 'orderId': 'order-1'},
      ]);
    },
  );
  testWidgets(
    'selected request rows explain why they cannot end a purchase order',
    (tester) async {
      final fixture = await _mount(tester, false, application: true);
      _selectOrders(tester, {'row-0'});
      await tester.pumpAndSettle();
      expect(tester.widget<UtenButton>(_action).onPressed, isNull);
      expect(find.byTooltip('所选内容包含申请单或其它记录，请仅选择要结束的订货单。'), findsOneWidget);
      expect(fixture.api.previews, isEmpty);
    },
  );
  testWidgets(
    'mixed eligibility counts only actionable orders and requires explicit confirmation to omit blocked orders',
    (tester) async {
      final api = _Api()..blockSecond = true;
      await _mount(tester, false, api: api);
      _selectOrders(tester, {'row-0', 'row-2'});
      await tester.pumpAndSettle();
      expect(find.text('取消/结束订单 (1)'), findsOneWidget);
      await tester.tap(_action);
      await tester.pumpAndSettle();
      expect(find.text('还有未完成的收货草稿，请先在仓库处理'), findsOneWidget);
      expect(
        tester
            .widget<UtenButton>(
              find.byKey(const Key('procurement-order-closure-batch-submit')),
            )
            .onPressed,
        isNull,
      );
      expect(api.submissions, isEmpty);
      await tester.enterText(
        find.byKey(const Key('procurement-order-closure-batch-reason')),
        '只结束可办理订单',
      );
      await tester.tap(
        find.byKey(const Key('procurement-order-closure-confirm-eligible')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('procurement-order-closure-batch-submit')),
      );
      await tester.pumpAndSettle();
      expect(api.submissions.single['items'], [
        {
          'orderType': 'PURCHASE',
          'orderId': 'order-1',
          'expectedFingerprint': 'fp-order-1',
        },
      ]);
    },
  );

  testWidgets(
    'batch remaining reorder submits every reviewed order with its own fingerprint',
    (tester) async {
      final fixture = await _mount(tester, false);
      _selectOrders(tester, {'row-0', 'row-2'});
      await tester.pumpAndSettle();
      await tester.tap(_action);
      await tester.pumpAndSettle();
      await tester.tap(find.text('结束并重新生成剩余订单'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('procurement-order-closure-batch-reason')),
        '更换供应商',
      );
      await tester.tap(
        find.byKey(const Key('procurement-order-closure-batch-submit')),
      );
      await tester.pumpAndSettle();
      expect(fixture.api.submissions.single['mode'], 'CLOSE_AND_REORDER');
      expect(fixture.api.submissions.single['items'], [
        {
          'orderType': 'PURCHASE',
          'orderId': 'order-1',
          'expectedFingerprint': 'fp-order-1',
        },
        {
          'orderType': 'PURCHASE',
          'orderId': 'order-2',
          'expectedFingerprint': 'fp-order-2',
        },
      ]);
    },
  );

  testWidgets(
    'all ineligible orders show zero and never enable the floating action',
    (tester) async {
      final api = _Api()..blockAll = true;
      await _mount(tester, false, api: api);
      _selectOrders(tester, {'row-0', 'row-1', 'row-2'});
      await tester.pumpAndSettle();
      expect(find.text('取消/结束订单 (0)'), findsOneWidget);
      expect(tester.widget<UtenButton>(_action).onPressed, isNull);
      expect(api.previews.single['orders'], hasLength(2));
      expect(api.submissions, isEmpty);
    },
  );

  testWidgets(
    'mixed order and application rows count only the eligible order and require an explicit skip confirmation',
    (tester) async {
      final fixture = await _mount(tester, false, mixedApplication: true);
      _selectOrders(tester, {'row-0', 'row-1', 'row-2'});
      await tester.pumpAndSettle();
      expect(find.text('取消/结束订单 (1)'), findsOneWidget);
      await tester.tap(_action);
      await tester.pumpAndSettle();
      expect(find.text('可办理订单: 1 · 暂不可办理: 1'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('procurement-order-closure-batch-reason')),
        '只提交有效订货单',
      );
      expect(
        tester
            .widget<UtenButton>(
              find.byKey(const Key('procurement-order-closure-batch-submit')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(
        find.byKey(const Key('procurement-order-closure-confirm-eligible')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('procurement-order-closure-batch-submit')),
      );
      await tester.pumpAndSettle();
      expect(fixture.api.submissions.single['items'], hasLength(1));
      expect(
        ((fixture.api.submissions.single['items'] as List).single
            as Map<String, dynamic>)['orderId'],
        'order-1',
      );
    },
  );

  testWidgets(
    'eligibility is queried again after reselection and cannot rely on a previous positive result',
    (tester) async {
      final fixture = await _mount(tester, false);
      _selectOrders(tester, {'row-0'});
      await tester.pumpAndSettle();
      expect(find.text('取消/结束订单 (1)'), findsOneWidget);
      fixture.api.blockAll = true;
      _selectOrders(tester, {});
      await tester.pumpAndSettle();
      _selectOrders(tester, {'row-0'});
      await tester.pumpAndSettle();
      expect(fixture.api.previews, hasLength(2));
      expect(find.text('取消/结束订单 (0)'), findsOneWidget);
      expect(tester.widget<UtenButton>(_action).onPressed, isNull);
    },
  );

  testWidgets(
    'a late eligibility reply cannot overwrite the newer selected order',
    (tester) async {
      final api = _Api();
      await _mount(tester, false, api: api);
      final old = Completer<Map<String, dynamic>>();
      api.previewGate = old;
      _selectOrders(tester, {'row-0'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.widget<UtenButton>(_action).onPressed, isNull);
      api.previewGate = null;
      _selectOrders(tester, {'row-2'});
      await tester.pumpAndSettle();
      expect(find.text('取消/结束订单 (1)'), findsOneWidget);
      old.complete({
        'canSubmit': false,
        'items': [
          {
            'orderType': 'PURCHASE',
            'orderId': 'order-1',
            'canSubmit': false,
            'blockReason': '旧请求已不可办',
            'items': <Map<String, dynamic>>[],
          },
        ],
      });
      await tester.pumpAndSettle();
      expect(find.text('取消/结束订单 (1)'), findsOneWidget);
      expect(tester.widget<UtenButton>(_action).onPressed, isNotNull);
      expect(api.previews.last['orders'], [
        {'orderType': 'PURCHASE', 'orderId': 'order-2'},
      ]);
    },
  );

  testWidgets('rapid selection changes debounce into one eligibility request', (
    tester,
  ) async {
    final fixture = await _mount(tester, false);
    _selectOrders(tester, {'row-0'});
    await tester.pump(const Duration(milliseconds: 50));
    _selectOrders(tester, {'row-2'});
    await tester.pumpAndSettle();
    expect(fixture.api.previews, hasLength(1));
    expect(fixture.api.previews.single['orders'], [
      {'orderType': 'PURCHASE', 'orderId': 'order-2'},
    ]);
  });

  testWidgets(
    'returning from a cancelled preview still revalidates the current workbench',
    (tester) async {
      final fixture = await _mount(tester, false);
      _selectOrders(tester, {'row-0'});
      await tester.pumpAndSettle();
      await tester.tap(_action);
      await tester.pumpAndSettle();
      final before = fixture.gateway.reads;
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(fixture.gateway.reads, greaterThan(before));
      expect(fixture.api.submissions, isEmpty);
    },
  );
  testWidgets(
    'account change retires an in-flight batch preview without showing its late quantities',
    (tester) async {
      final api = _Api();
      final fixture = await _mount(tester, false, api: api);
      _selectOrders(tester, {'row-0'});
      await tester.pumpAndSettle();
      api.previewGate = Completer<Map<String, dynamic>>();
      await tester.tap(_action);
      await tester.pump();
      fixture.container.read(_identity.notifier).state =
          const AuthenticatedScope(userId: 'reader-b');
      await tester.pumpAndSettle();
      api.previewGate!.complete({
        'canSubmit': true,
        'items': [
          {
            'orderType': 'PURCHASE',
            'orderId': 'order-1',
            'billNo': 'PRIVATE-LATE',
            'fingerprint': 'old',
            'canSubmit': true,
            'items': <Map<String, dynamic>>[],
          },
        ],
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('PRIVATE-LATE'), findsNothing);
      expect(
        find.byKey(const Key('procurement-order-closure-batch-dialog')),
        findsNothing,
      );
      expect(api.submissions, isEmpty);
    },
  );
  for (final subcontract in [false, true]) {
    for (final textScale in [1.0, 2.0]) {
      testWidgets(
        '${subcontract ? 'subcontract' : 'purchase'} 375px scale $textScale keeps the summary pill first with the action after it',
        (tester) async {
          const captureUi = bool.fromEnvironment('UTEN_CAPTURE_UI');
          final capture = captureUi ? GlobalKey() : null;
          if (captureUi) await loadAuditScreenshotFonts(tester);
          await _mount(
            tester,
            subcontract,
            width: 375,
            capture: capture,
            textScale: textScale,
          );
          _selectOrders(tester, {'row-0', 'row-2'});
          await tester.pumpAndSettle();
          expect(_action, findsOneWidget);
          expect(
            find.ancestor(
              of: _action,
              matching: find.byType(UtenFloatingActionGroup),
            ),
            findsOneWidget,
          );
          // 2026-10-24 用户口径：已选 N 项胶囊恒在悬浮组最左，取消/结束订单
          // 按钮排在其右——窄屏换行也不例外，胶囊永远第一行首位。
          final group = tester.widget<UtenFloatingActionGroup>(
            find.byType(UtenFloatingActionGroup),
          );
          expect(group.children.first, isA<UtenSelectionSummaryPill>());
          final actionChild = group.children
              .whereType<ProcurementOrderClosureSelectionAction>()
              .single;
          expect(group.children.indexOf(actionChild), 1);
          expect(tester.getRect(_action).bottom, greaterThan(600));
          expect(tester.getRect(_action).top, greaterThanOrEqualTo(0));
          expect(tester.getRect(_action).left, greaterThanOrEqualTo(0));
          expect(tester.getRect(_action).right, lessThanOrEqualTo(375));
          expect(tester.takeException(), isNull);
          if (capture != null) {
            await saveAuditScreenshot(
              tester,
              capture,
              !subcontract && textScale == 1
                  ? 'purchase-cancel-end-narrow'
                  : '${subcontract ? 'subcontract' : 'purchase'}-cancel-end-narrow-$textScale',
            );
          }
        },
      );
    }
  }
}
