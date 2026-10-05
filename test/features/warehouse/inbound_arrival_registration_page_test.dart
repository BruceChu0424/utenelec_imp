import 'dart:convert';

// 登记实际到货页(ADR-151 §5 单批合一)：双击 = 1 个来源、多选 = N 个来源，进同一个页面。
//  ① 来源身份走 ?expectationIds=，页面按 id 从服务端读预计到货(与任务中心同一投影)，
//     不再依赖跳转时的内存对象；本机草稿恢复同样按这个地址重开。
//  ② 本次实收默认=批准剩余，入库仓库行级必填(建议仓预填)；**勾选多行后改其中任意一行 =
//     整批落值**。
//  ③ 提交是一个批量命令 POST /warehouse/inbound/arrivals/batch：一个事务，服务端按
//     「订货单 x 入库仓库」分组建收货单，逐组回执(含超量隔离)。
//  ④ 多选时任务中心选定的路线(?preStock=1|0)只显示这一条提交按钮；双击进来两条并排。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/warehouse/models/inbound_registration_line.dart';
import 'package:uten_imp/features/warehouse/pages/inbound_arrival_registration_page.dart';
import 'package:uten_imp/shared/drafts/form_draft_mixin.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_inbound_expectations_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/procurement_inbound.dart';

import '../../shared/drafts/memory_form_draft_storage.dart';
import 'inbound_arrival_test_support.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

const _ids = ['expectation-batch-1', 'expectation-batch-2'];

void main() {
  for (final single in [true, false]) {
    testWidgets(
      'arrival draft restores ${single ? 'single' : 'multi'} source after restart from the source-id route',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1400, 1800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final api = _BatchApi();
        final ids = single ? [_ids.first] : _ids;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              apiClientProvider.overrideWithValue(api),
              sessionProvider.overrideWith(_TestSessionNotifier.new),
              masterNameServiceProvider.overrideWithValue(
                MasterNameService(api),
              ),
            ],
            child: MaterialApp(
              home: InboundArrivalRegistrationPage(
                expectationIds: ids,
                canRegister: true,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final Map<String, dynamic> snapshot =
            (tester.state(find.byType(InboundArrivalRegistrationPage))
                    as FormDraftMixin<InboundArrivalRegistrationPage>)
                .captureFormDraft();
        final rows = (snapshot['rows'] as List).cast<Map<String, dynamic>>();
        expect(rows, hasLength(single ? 1 : 3));
        rows.first['qty'] = '1.';
        rows.first['selected'] = false;
        rows.first['stockPlace'] = 'A-12';
        rows.first['stockPlaceAutofilled'] = false;
        snapshot['remark'] = '恢复尚未填完的到货';
        final route = RoutePath.warehouseArrivalRegistration(ids);
        final saved = FormDraft(
          id: 'arrival-draft',
          title: '登记实际到货',
          module: BadgeModule.warehouse,
          route: route,
          permission: Perm.warehouseInboundStockIn,
          updatedAt: DateTime.now(),
          data: snapshot,
          revision: 'version-1',
        );
        await tester.pumpWidget(const SizedBox.shrink());
        final router = GoRouter(
          initialLocation: saved.resumeLocation,
          routes: [
            GoRoute(
              path: RouteName.warehouseArrivalRegistration,
              builder: (_, state) => InboundArrivalRegistrationPage(
                key: state.pageKey,
                expectationIds:
                    (state.uri.queryParameters['expectationIds'] ?? '')
                        .split(',')
                        .where((id) => id.isNotEmpty)
                        .toList(),
                canRegister: true,
              ),
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authenticatedScopeProvider.overrideWithValue(
                const AuthenticatedScope(userId: 'user-1'),
              ),
              apiBaseUrlProvider.overrideWithValue(
                'https://draft-test.example/api',
              ),
              currentPermissionsProvider.overrideWithValue({
                Perm.warehouseInboundView,
                Perm.warehouseInboundStockIn,
              }),
              apiClientProvider.overrideWithValue(api),
              sessionProvider.overrideWith(_TestSessionNotifier.new),
              masterNameServiceProvider.overrideWithValue(
                MasterNameService(api),
              ),
              formDraftsProvider.overrideWith(
                () => _RecoveredArrivalDrafts(saved),
              ),
            ],
            child: MaterialApp.router(routerConfig: router),
          ),
        );
        await tester.pumpAndSettle();
        final recovered =
            (tester.state(find.byType(InboundArrivalRegistrationPage))
                    as FormDraftMixin<InboundArrivalRegistrationPage>)
                .captureFormDraft();
        final recoveredRows = (recovered['rows'] as List)
            .cast<Map<String, dynamic>>();
        expect(recovered['registrationId'], snapshot['registrationId']);
        expect(recovered['remark'], '恢复尚未填完的到货');
        expect(recoveredRows.first['qty'], '1.');
        expect(recoveredRows.first['selected'], false);
        expect(recoveredRows.first['stockPlaceAutofilled'], false);
        expect(recoveredRows.first['item'], rows.first['item']);
        expect(find.text('已恢复本机草稿'), findsOneWidget);
        expect(api.arrivalPostBodies, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'disabled remembered warehouse is cleared before a new arrival and hidden in the picker',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _BatchApi(disabledFirst: true);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            sessionProvider.overrideWith(_TestSessionNotifier.new),
            masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
          ],
          child: const MaterialApp(
            home: InboundArrivalRegistrationPage(
              expectationIds: _ids,
              canRegister: true,
              route: InboundRoute.inspectFirst,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('成品仓'), findsNothing);
      expect(find.text('必选 · 点击选择'), findsNWidgets(3));
      await tester.ensureVisible(
        find.byKey(const Key('warehouse-arrival-wh-batch-item-1')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('warehouse-arrival-wh-batch-item-1')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('warehouse-picker-entry-warehouse-1')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('warehouse-picker-entry-warehouse-2')),
        findsOneWidget,
      );
      expect(api.arrivalPostBodies, isEmpty);
    },
  );

  testWidgets('预计到货：待登记行可勾选，先质检后入库按钮随选择计数', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final api = _ExpectationsApi();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.warehouseInboundView,
            Perm.warehouseInboundStockIn,
          }),
        ],
        child: const MaterialApp(
          home: Scaffold(body: WarehouseInboundExpectationsView()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final table = tester.widget<MasterDataTableView<InboundExpectation>>(
      find.byKey(const Key('inbound-expectation-task-table')),
    );
    expect(table.selectable, isTrue);
    expect(find.byType(Checkbox), findsWidgets);
    expect(find.text('先质检后入库'), findsOneWidget);

    await tester.tap(find.byType(Checkbox).at(1));
    await tester.pump();
    expect(find.text('已选 1 项'), findsOneWidget);
    expect(find.text('先质检后入库(1)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('多选 N 个来源：行级仓库必填+勾选行整批落仓+一个命令登记送检', (tester) async {
    tester.view.physicalSize = const Size(1600, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final api = _BatchApi();
    final router = _router(route: InboundRoute.inspectFirst);
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          sessionProvider.overrideWith(_TestSessionNotifier.new),
          masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    // 来源按 id 从服务端读：一次 by-ids 请求带全部所选任务。
    expect(api.byIdsQueries.single, {'ids': _ids.join(',')});
    // 行级仓库：建议仓订单的行预填「成品仓」，无建议订单的行留空必选。
    expect(find.text('成品仓'), findsOneWidget);
    expect(find.text('必选 · 点击选择'), findsNWidgets(2));
    expect(
      tester.widget<Checkbox>(find.byType(Checkbox).at(0)).value,
      isTrue,
      reason: '明细行进页默认全选',
    );

    // 点其中任意一行的仓库格选「原料仓」，全部勾选行一起落仓。
    await tester.ensureVisible(
      find.byKey(const Key('warehouse-arrival-wh-batch-item-1')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('warehouse-arrival-wh-batch-item-1')),
    );
    await tester.pumpAndSettle();
    expect(find.text('先选主仓，再选子仓'), findsOneWidget);
    await tester.tap(
      find.byKey(const Key('warehouse-picker-entry-warehouse-2')),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('原料仓'),
      findsNWidgets(3),
      reason: '勾了 3 行就该 3 行一起落仓，而不是只改点到的那一行',
    );
    expect(find.text('必选 · 点击选择'), findsNothing);

    // 同一批里可以有正常到货与先补退货。
    await tester.ensureVisible(
      find.byKey(const Key('warehouse-arrival-source-batch-item-1')),
    );
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('warehouse-arrival-source-batch-item-1')),
        matching: find.text('自动识别'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('正常到货').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const Key('warehouse-arrival-source-batch-item-2')),
    );
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('warehouse-arrival-source-batch-item-2')),
        matching: find.text('自动识别'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('先补退货').last);
    await tester.pumpAndSettle();

    // 提交：两张订货单 x 同一仓库 = 两张收货单，但只发一个命令(一个事务)。
    await tester.tap(
      find.byKey(const Key('inbound-route-submit-inspectFirst')),
    );
    await tester.pumpAndSettle();
    expect(find.text('先质检后入库(2 张收货单)'), findsOneWidget);
    await tester.tap(find.text('确认登记送检'));
    await tester.pump();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(api.arrivalPostBodies, hasLength(1));
    final body = api.arrivalPostBodies.single;
    expect(
      body['idempotencyKey'] as String?,
      matches(r'^warehouse-arrival-batch-[0-9a-f]{16}$'),
    );
    expect(body['receiverEmployeeId'], 'emp-me');
    expect(body.containsKey('stockInBeforeInspection'), isFalse);
    final lines = (body['lines'] as List).cast<Map<String, dynamic>>();
    expect(lines.map((line) => line['orderItemId']), [
      'batch-item-1',
      'batch-item-2',
      'batch-item-3',
    ]);
    expect(lines.map((line) => line['warehouseId']).toSet(), {'warehouse-2'});
    // 采购员按各自订货单带出；来源单号随行。
    expect(lines.map((line) => line['purchaserId']), [
      'purchaser-1',
      'purchaser-2',
      'purchaser-2',
    ]);
    expect(lines.map((line) => line['sourceDocNo']), [
      'PO-BATCH-001',
      'PO-BATCH-002',
      'PO-BATCH-002',
    ]);
    expect(
      {
        for (final line in lines)
          line['orderItemId']: line['replacementIntent'],
      },
      {
        'batch-item-1': 'NORMAL',
        'batch-item-2': 'RETURN_REPLACEMENT',
        'batch-item-3': null,
      },
    );
    // 登记完成回任务中心。
    expect(find.text('预计到货任务中心'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('双击 1 个来源：两条路线按钮并排，点哪条走哪条', (tester) async {
    tester.view.physicalSize = const Size(1600, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _BatchApi();
    final router = _router(ids: [_ids.first]);
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          sessionProvider.overrideWith(_TestSessionNotifier.new),
          masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.warehouseInboundView,
            Perm.warehouseInboundStockIn,
            Perm.warehouseIqcStockInBeforeInspection,
          }),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(api.byIdsQueries.single, {'ids': _ids.first});
    expect(find.text('路线：先质检后入库'), findsNothing);
    expect(
      find.byKey(const Key('inbound-route-submit-stockInFirst')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('inbound-route-submit-inspectFirst')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const Key('inbound-route-submit-inspectFirst')),
    );
    await tester.pumpAndSettle();
    expect(find.text('先质检后入库(1 张收货单)'), findsOneWidget);
    await tester.tap(find.text('确认登记送检'));
    await tester.pump();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final lines = (api.arrivalPostBodies.single['lines'] as List)
        .cast<Map<String, dynamic>>();
    expect(lines.single['orderItemId'], 'batch-item-1');
    expect(lines.single['warehouseId'], 'warehouse-1');
    expect(lines.single['qty'], 5);
    expect(find.text('预计到货任务中心'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('明细默认全选，没勾行时提交置灰，只提交勾选行', (tester) async {
    tester.view.physicalSize = const Size(1600, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final api = _BatchApi();
    final router = _router(route: InboundRoute.inspectFirst);
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          sessionProvider.overrideWith(_TestSessionNotifier.new),
          masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
          // 持有「先入库后质检」独立权限，但多选时选的是「先质检后入库」路线。
          currentPermissionsProvider.overrideWithValue(const {
            Perm.warehouseIqcStockInBeforeInspection,
          }),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          builder: (context, child) => Column(
            children: [
              const AppNotificationHost(),
              Expanded(child: child ?? const SizedBox()),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final submit = find.byKey(const Key('inbound-route-submit-inspectFirst'));
    UtenButton submitButton() => tester.widget<UtenButton>(submit);
    expect(submitButton().onPressed, isNotNull);

    final headerSelectAll = find.byWidgetPredicate(
      (widget) => widget is Checkbox && widget.tristate,
    );
    await tester.tap(headerSelectAll.first);
    await tester.pumpAndSettle();
    expect(submitButton().onPressed, isNull);
    // 多选选定了路线：只显示这一条提交按钮；标题下标明本页路线。
    expect(
      find.byKey(const Key('inbound-route-submit-stockInFirst')),
      findsNothing,
    );
    expect(find.widgetWithText(UtenButton, '先质检后入库'), findsOneWidget);
    expect(find.text('路线：先质检后入库'), findsOneWidget);
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pump();
    expect(find.textContaining('请先勾选要登记送检的明细行'), findsOneWidget);

    // 只勾第一行(订货单 A，建议仓已预填) → 可提交；确认弹窗写明未勾选行去向。
    await tester.tap(find.byType(Checkbox).at(0));
    await tester.pump();
    expect(submitButton().onPressed, isNotNull);
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(find.textContaining('有 2 行未勾选'), findsOneWidget);
    expect(find.text('确认登记送检'), findsOneWidget);
    await tester.tap(find.text('确认登记送检'));
    await tester.pump();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(api.arrivalPostBodies, hasLength(1));
    final lines = (api.arrivalPostBodies.single['lines'] as List)
        .cast<Map<String, dynamic>>();
    expect(lines.map((line) => line['orderItemId']), ['batch-item-1']);
    expect(tester.takeException(), isNull);
  });

  // ADR-151 §1 回归 (2026-10-04 用户「多选就报错」): 开着本机草稿保护, 取消勾选再勾回
  // (快照回到初始值) 后提交必须照常发出到货登记, 失败也要说出真实原因。
  testWidgets('草稿保护开启时取消勾选再勾回后提交仍发出登记', (tester) async {
    tester.view.physicalSize = const Size(1600, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final api = _BatchApi();
    final drafts = MemoryFormDraftStorage();
    final router = _router(route: InboundRoute.inspectFirst);
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          sessionProvider.overrideWith(_TestSessionNotifier.new),
          masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
          authenticatedScopeProvider.overrideWithValue(
            const AuthenticatedScope(userId: 'warehouse-user'),
          ),
          apiBaseUrlProvider.overrideWithValue(
            'https://draft-test.example/api',
          ),
          formDraftStorageProvider.overrideWithValue(drafts),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.warehouseInboundView,
            Perm.warehouseInboundStockIn,
          }),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          builder: (context, child) => Column(
            children: [
              const AppNotificationHost(),
              Expanded(child: child ?? const SizedBox()),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final headerSelectAll = find.byWidgetPredicate(
      (widget) => widget is Checkbox && widget.tristate,
    );
    await tester.tap(headerSelectAll.first);
    await tester.pumpAndSettle();
    expect(drafts.records, isNotEmpty, reason: '取消勾选后已自动保存本机草稿');
    await tester.tap(headerSelectAll.first);
    await tester.pumpAndSettle();
    expect(
      (jsonDecode(drafts.records.values.single) as Map)['completed'],
      isNot(true),
      reason: '回到初始值不写删除墓碑',
    );

    // 回到初始值之后再改(只留订货单 A 那一行, 它有建议仓): 旧逻辑这里每次保存都撞墓碑。
    await tester.tap(headerSelectAll.first);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox).at(0));
    await tester.pumpAndSettle();
    expect(find.textContaining('草稿尚未保存'), findsNothing);

    final submit = find.byKey(const Key('inbound-route-submit-inspectFirst'));
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认登记送检'));
    await tester.pump();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(api.arrivalPostBodies, hasLength(1));
    expect(find.textContaining('登记失败'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('预计到货：多选「先入库后质检」直达登记页并带来源 id 与 preStock=1', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    String? registrationLocation;
    Object? registrationExtra;
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) =>
              const Scaffold(body: WarehouseInboundExpectationsView()),
        ),
        GoRoute(
          path: RouteName.warehouseArrivalRegistration,
          builder: (_, state) {
            registrationLocation = state.uri.toString();
            registrationExtra = state.extra;
            return const Scaffold(body: Text('登记页落点'));
          },
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(_ExpectationsApi()),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.warehouseInboundView,
            Perm.warehouseInboundStockIn,
            Perm.warehouseIqcStockInBeforeInspection,
          }),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('先入库后质检'), findsOneWidget);
    await tester.tap(find.byType(Checkbox).at(1));
    await tester.pump();
    expect(find.text('先入库后质检(1)'), findsOneWidget);
    await tester.tap(find.text('先入库后质检(1)'));
    await tester.pumpAndSettle();
    expect(find.text('登记页落点'), findsOneWidget);
    expect(
      registrationLocation,
      RoutePath.warehouseArrivalRegistration([
        'expectation-1',
      ], stockInBeforeInspection: true),
    );
    expect(Uri.parse(registrationLocation!).queryParameters['preStock'], '1');
    // 来源身份只走地址，不再靠跳转时的内存对象。
    expect(registrationExtra, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('预计到货：无先入库后质检权限时不显示批量按钮', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(_ExpectationsApi()),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.warehouseInboundView,
            Perm.warehouseInboundStockIn,
          }),
        ],
        child: const MaterialApp(
          home: Scaffold(body: WarehouseInboundExpectationsView()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('先质检后入库'), findsOneWidget);
    expect(find.text('先入库后质检'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('preStock 进页即库位号必填，只显示该路线按钮，提交带上架库位', (tester) async {
    tester.view.physicalSize = const Size(1600, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _BatchApi();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          sessionProvider.overrideWith(_TestSessionNotifier.new),
          masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.warehouseIqcStockInBeforeInspection,
          }),
        ],
        child: const MaterialApp(
          home: InboundArrivalRegistrationPage(
            expectationIds: _ids,
            canRegister: true,
            route: InboundRoute.stockInFirst,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final grid = tester.widget<UtenEditableGrid<dynamic>>(
      find.byWidgetPredicate((widget) => widget is UtenEditableGrid),
    );
    final stockPlaceColumn = grid.columns
        .where((column) => column.key == 'place')
        .single;
    expect(stockPlaceColumn.label, '库位号');
    expect(stockPlaceColumn.required, isTrue);
    // 合并自单张登记页：预计去向(基本量)列。
    expect(
      grid.columns.where((column) => column.key == 'expectedAllocation'),
      hasLength(1),
    );
    expect(find.widgetWithText(UtenButton, '先入库后质检'), findsOneWidget);
    expect(find.text('路线：先入库后质检'), findsOneWidget);
    expect(find.text('先质检后入库'), findsNothing);
    expect(
      find.byKey(const Key('inbound-route-submit-inspectFirst')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}

GoRouter _router({List<String> ids = _ids, InboundRoute? route}) => GoRouter(
  initialLocation: RoutePath.warehouseArrivalRegistration(
    ids,
    stockInBeforeInspection: route?.isStockInFirst,
  ),
  routes: [
    GoRoute(
      path: RouteName.warehouseArrivalRegistration,
      builder: (_, state) => InboundArrivalRegistrationPage(
        expectationIds: (state.uri.queryParameters['expectationIds'] ?? '')
            .split(',')
            .where((id) => id.isNotEmpty)
            .toList(),
        canRegister: true,
        route: InboundRoute.fromQuery(state.uri.queryParameters),
      ),
    ),
    GoRoute(
      path: RouteName.warehouseInboundExpectations,
      builder: (_, _) => const Scaffold(body: Text('预计到货任务中心')),
    ),
  ],
);

List<ProcurementReceiptPrefill> _prefills() => const [
  // 订货单 A：带建议仓(成品仓)——行预填。
  ProcurementReceiptPrefill(
    expectationId: 'expectation-batch-1',
    orderType: ProcurementInboundOrderType.purchase,
    orderBillNo: 'PO-BATCH-001',
    orderId: 'order-batch-1',
    supplierId: 'supplier-1',
    supplierName: '测试供应商',
    warehouseId: null,
    suggestedWarehouseId: 'warehouse-1',
    suggestedWarehouseName: '成品仓',
    purchaserId: 'purchaser-1',
    items: [
      ProcurementReceiptPrefillItem(
        orderItemId: 'batch-item-1',
        goodsId: 'goods-1',
        goodsCode: 'G-001',
        goodsName: '轴套',
        unitRate: 1,
        unitName: '个',
        approvedRemainingQty: 5,
      ),
    ],
  ),
  // 订货单 B：无建议仓——行必选待填。
  ProcurementReceiptPrefill(
    expectationId: 'expectation-batch-2',
    orderType: ProcurementInboundOrderType.purchase,
    orderBillNo: 'PO-BATCH-002',
    orderId: 'order-batch-2',
    supplierId: 'supplier-2',
    supplierName: '测试供应商二',
    warehouseId: null,
    purchaserId: 'purchaser-2',
    items: [
      ProcurementReceiptPrefillItem(
        orderItemId: 'batch-item-2',
        goodsId: 'goods-2',
        goodsCode: 'G-002',
        goodsName: '端盖',
        unitRate: 1,
        unitName: '个',
        approvedRemainingQty: 8,
      ),
      ProcurementReceiptPrefillItem(
        orderItemId: 'batch-item-3',
        goodsId: 'goods-3',
        goodsCode: 'G-003',
        goodsName: '垫片',
        unitRate: 1,
        unitName: '个',
        approvedRemainingQty: 20,
      ),
    ],
  ),
];

class _RecoveredArrivalDrafts extends FormDraftsNotifier {
  _RecoveredArrivalDrafts(this.draft);
  final FormDraft draft;
  @override
  List<FormDraft> build() => [draft];
}

class _TestSessionNotifier extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    user: AppUser(
      id: 'user-me',
      code: 'USR-ME',
      name: '仓管员',
      employeeId: 'emp-me',
    ),
  );
}

/// 预计到货列表桩：一条「待登记」采购任务(无草稿收货单)。
class _ExpectationsApi extends ApiClient {
  _ExpectationsApi() : super(Dio());

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/warehouse/inbound/expectations') {
      return {
        'items': [
          {
            'id': 'expectation-1',
            'orderType': 'PURCHASE',
            'orderId': 'order-1',
            'billNo': 'PO-001',
            'supplierId': 'supplier-1',
            'supplierName': '测试供应商',
            'status': 'OPEN',
            'remainingQty': 5,
            'registeredQty': 0,
            'allowedActions': ['CREATE_PURCHASE_RECEIPT'],
            'draftReceiptIds': const <dynamic>[],
            'pendingInspectionReceipts': 0,
            'openArrivalExceptions': 0,
            'items': [
              {
                'id': 'expectation-item-1',
                'orderItemId': 'order-item-1',
                'goodsId': 'goods-1',
                'goodsCode': 'G-001',
                'goodsName': '轴套',
                'unitRate': 1,
                'orderedQty': 5,
                'acceptedQty': 0,
                'remainingQty': 5,
                'registeredQty': 0,
              },
            ],
          },
        ],
        'page': 1,
        'size': 20,
        'total': 1,
      };
    }
    if (path.contains('/count')) return const {'count': 0};
    throw ApiException('TEST_UNEXPECTED_GET', path);
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [];
}

/// 登记页桩：主档字典 + 按 id 读预计到货 + 批量登记命令回执。
class _BatchApi extends ApiClient {
  _BatchApi({this.disabledFirst = false}) : super(Dio());
  final bool disabledFirst;

  final List<Map<String, dynamic>> arrivalPostBodies = [];
  final List<Map<String, dynamic>?> byIdsQueries = [];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('/count')) return const {'count': 0};
    throw ApiException('TEST_UNEXPECTED_GET', path);
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/master/warehouses/dict') {
      return [
        {
          'id': 'warehouse-1',
          'name': '成品仓',
          'status': disabledFirst ? '禁用' : '使用',
          'accountable': true,
          'selectableForNew': !disabledFirst,
        },
        {'id': 'warehouse-2', 'name': '原料仓', 'selectableForNew': true},
      ];
    }
    if (path == arrivalExpectationsByIdsPath) {
      byIdsQueries.add(query);
      return expectationsByIdsAnswer(query, _prefills());
    }
    return const [];
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    if (path == arrivalBatchPath) {
      final request = Map<String, dynamic>.from(body! as Map);
      arrivalPostBodies.add(request);
      return arrivalBatchAnswer(request);
    }
    if (path == '/warehouse/inbound/goods-profile-hints') {
      return const {'updated': 0};
    }
    throw ApiException('TEST_UNEXPECTED_POST', path);
  }
}
