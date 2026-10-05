import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/inputs/uten_input_decoration.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/warehouse/models/inbound_registration_line.dart';
import 'package:uten_imp/features/warehouse/pages/production_finished_arrival_registration_page.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_place_suggestion_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/measurement/weight_unit.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/badge_summary_fixture.dart';
import 'arrival_weight_test_support.dart';
import 'package:uten_imp/shared/providers/uten_page_prefs_notifier.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

const _reportId = '20000000-0000-0000-0000-000000000001';
const _row1 = '30000000-0000-0000-0000-000000000001';
const _row2 = '30000000-0000-0000-0000-000000000002';
const _goods1 = 'a0000000-0000-0000-0000-000000000001';
const _goods2 = 'a0000000-0000-0000-0000-000000000002';
// ADR-151 §5：单张 = 1 个来源的同一个登记页；读写都走批量端点(一个事务)。
const _registrationPath =
    '/warehouse/production-finished-in/arrival-registrations/batch';
const _placeSuggestionPath = '/warehouse/place-suggestions';

void main() {
  testWidgets('实称重量: 随登记行提交千克并进幂等键，按报工数量核对 (ADR-135)', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1800, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _ArrivalRegistrationApi(
      warehouseId: 'warehouse-1',
      placeHint: 'CP-01',
    );
    final weights = FakeWeightRepository(
      api,
      byGoods: const {_goods1: learnedTwoGramParams},
    );
    await _openPage(
      tester,
      api: api,
      canRegister: true,
      clearSelection: false,
      overrides: warehouseWeightTestOverrides(api, repository: weights),
    );
    // 车间产出没有供应商：单重参数只按货品取。
    expect(weights.requests.first.single.goodsId, _goods1);
    expect(weights.requests.first.single.supplierId, isNull);
    // 本页只核对不回填数量：重量格里没有称重计数按钮。
    final grid = find.byKey(const Key('production-finished-arrival-grid'));
    expect(
      find.descendant(
        of: grid,
        matching: find.byKey(const ValueKey('weight-cell-weigh')),
      ),
      findsNothing,
    );

    // 报工 10 只 × 约 2 g = 约 20 g；称了 30 g → 比报工多约 5 只。
    await tester.enterText(
      find.descendant(
        of: grid,
        matching: find.byKey(const ValueKey('weight-cell-input')),
      ),
      '30g',
    );
    await tester.pump();
    final chip = find.byKey(
      const ValueKey('production-finished-arrival-weight-check-$_row1'),
    );
    expect(
      find.descendant(of: chip, matching: find.textContaining('比报工多约')),
      findsOneWidget,
    );

    await _submit(tester);
    final body = api.postBodies.single;
    final item = (body['lots'] as List).single as Map;
    expect(item['lotId'], _row1);
    expect(item['weight'], 0.03);
    // 幂等键带重量指纹：改了重量是另一个请求。
    expect(
      body['idempotencyKey'] as String,
      matches(RegExp(r':w-[0-9a-f]{16}$')),
    );
  });

  testWidgets('实称重量按 报工数量 x unitRate 的基本数量核对 (报工单位不是基本单位)', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1800, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // 报工 10 × 12 (unitRate) = 120 个基本单位 × 约 2 g = 约 240 g。
    final api = _ArrivalRegistrationApi(
      warehouseId: 'warehouse-1',
      placeHint: 'CP-01',
      unitRate: 12,
    );
    final weights = FakeWeightRepository(
      api,
      byGoods: const {_goods1: learnedTwoGramParams},
    );
    await _openPage(
      tester,
      api: api,
      canRegister: true,
      clearSelection: false,
      overrides: warehouseWeightTestOverrides(api, repository: weights),
    );
    final grid = find.byKey(const Key('production-finished-arrival-grid'));
    final input = find.descendant(
      of: grid,
      matching: find.byKey(const ValueKey('weight-cell-input')),
    );
    final chip = find.byKey(
      const ValueKey('production-finished-arrival-weight-check-$_row1'),
    );
    await tester.enterText(input, '240g');
    await tester.pump();
    expect(
      find.descendant(of: grid, matching: find.textContaining('比报工')),
      findsNothing,
      reason: '240 g 正好是 120 个基本单位, 不该当成 10 个报偏差',
    );

    await tester.enterText(input, '200g');
    await tester.pump();
    expect(
      find.descendant(of: chip, matching: find.textContaining('比报工少约')),
      findsOneWidget,
    );
    // 报工单位(本例名「只」, 1 个 = 12 基本单位)不是基本单位：偏差件数不借用它的名字。
    expect(
      find.descendant(of: chip, matching: find.textContaining('只')),
      findsNothing,
    );
  });

  testWidgets('报工单位本身按重量计时只读精确换算, 提交不带重量', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1800, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _ArrivalRegistrationApi(
      warehouseId: 'warehouse-1',
      placeHint: 'CP-01',
    );
    await _openPage(
      tester,
      api: api,
      canRegister: true,
      clearSelection: false,
      overrides: warehouseWeightTestOverrides(
        api,
        massUnits: const {
          'b0000000-0000-0000-0000-000000000001': WeightUnit.kg,
        },
      ),
    );
    final grid = find.byKey(const Key('production-finished-arrival-grid'));
    expect(
      find.descendant(
        of: grid,
        matching: find.byKey(const ValueKey('weight-cell-exact')),
      ),
      findsOneWidget,
    );
    await _submit(tester);
    final item = (api.postBodies.single['lots'] as List).single as Map;
    expect(item.containsKey('weight'), isFalse);
  });

  testWidgets('已登记批次只读显示登记时的实称重量', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1800, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _ArrivalRegistrationApi(
      registered: true,
      warehouseId: 'warehouse-1',
      place: 'CP-A-01',
      registeredWeightKg: 0.03,
    );
    await _openPage(
      tester,
      api: api,
      canRegister: true,
      overrides: warehouseWeightTestOverrides(api),
    );
    final field = tester.widget<TextField>(
      find.descendant(
        of: find.byKey(const Key('production-finished-arrival-grid')),
        matching: find.byKey(const ValueKey('weight-cell-input')),
      ),
    );
    expect(field.controller?.text, '0.03');
    expect(field.enabled, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('先入库后质检按钮：需独立权限，提交带上架标记与独立幂等键', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _ArrivalRegistrationApi();

    Future<void> pump(Set<String> permissions) => _openPage(
      tester,
      api: api,
      clearSelection: false,
      overrides: [
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
      ],
    );

    // 没有独立权限：只有「先质检后入库」，本次实收列也不出现。
    await pump(const {Perm.stockDocView, Perm.stockDocApprove});
    expect(find.byKey(InboundRoute.stockInFirst.submitKey), findsNothing);
    expect(find.byKey(InboundRoute.inspectFirst.submitKey), findsOneWidget);
    final qtyField = find.byKey(
      const ValueKey('production-finished-arrival-qty-$_row1'),
    );
    expect(qtyField, findsNothing);

    // 有独立权限：两条路线按钮并排。
    await pump(const {
      Perm.stockDocView,
      Perm.stockDocApprove,
      Perm.productionFinishedInBeforeInspection,
    });
    expect(find.byKey(InboundRoute.stockInFirst.submitKey), findsOneWidget);
    expect(find.byKey(InboundRoute.inspectFirst.submitKey), findsOneWidget);

    await _selectWarehouse(tester, '成品仓', settle: true);
    await _revealGrid(tester);
    await tester.enterText(_placeField(_row1), 'CP-A-09');
    await tester.pumpAndSettle();

    // 本次实收默认=报工数量 10；先填一个不一致的数验证拦截 (只走 toast、不弹确认框)。
    expect(_headerLabel('本次实收'), findsWidgets);
    expect(tester.widget<TextField>(qtyField).controller?.text, '10');
    await tester.enterText(qtyField, '9');
    await tester.pumpAndSettle();
    await _pressRoute(tester, InboundRoute.stockInFirst);
    expect(find.text('确认登记并先入库'), findsNothing);
    expect(api.lastPostBody, isNull, reason: '与报工量不一致必须先行拦截');
    expect(_toasts(tester).last, contains('本次实收与报工数量不一致'));

    await tester.enterText(qtyField, '10');
    await tester.pumpAndSettle();
    await _submit(tester, route: InboundRoute.stockInFirst);
    expect(api.lastPostPath, _registrationPath);
    expect(api.lastPostBody?['stockInBeforeInspection'], isTrue);
    // 幂等键含路线：改用另一个按钮重提交是另一个请求，不是重放。
    expect(
      api.lastPostBody?['idempotencyKey'] as String,
      endsWith(':prestock'),
    );
    final lots = (api.lastPostBody?['lots'] as List)
        .cast<Map<String, dynamic>>();
    expect(lots.single['lotId'], _row1);
    expect(lots.single['warehouseId'], 'warehouse-1');
    expect(lots.single['countedQty'], 10);
    expect(lots.single['place'], 'CP-A-09');
    expect(find.byKey(const Key('open-arrival-registration')), findsOneWidget);
  });

  testWidgets('自制单张登记右键移出一行后仅送检剩余行', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _ArrivalRegistrationApi(duplicateGoodsRows: true);
    await _openPage(tester, api: api, canRegister: true);

    await _selectWarehouse(tester, '成品仓', settle: true);
    await _revealGrid(tester);

    await _rightClick(tester, find.text('三极插套').last);
    await tester.tap(find.text('移出本次登记 (1)').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('返回任务中心后仍保持待登记'), findsOneWidget);
    await tester.tap(find.text('确认移出'));
    await tester.pumpAndSettle();
    expect(_placeCell(_row2), findsNothing);
    expect(find.textContaining('已移出 1 行'), findsOneWidget);
    expect(_toasts(tester).last, contains('已从本次登记移出 1 行'));

    await tester.enterText(_placeField(_row1), 'CP-A-01');
    await tester.pump();
    await _submit(tester);
    final lots = (api.lastPostBody?['lots'] as List)
        .cast<Map<String, dynamic>>();
    expect(lots, hasLength(1));
    expect(lots.single['lotId'], _row1);
  });

  testWidgets(
    'arrival registration is operable at 375px and posts exact warehouse places',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(375, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _ArrivalRegistrationApi();
      await _openPage(tester, api: api, canRegister: true);

      expect(find.text('登记实际入库'), findsOneWidget);
      expect(find.text('RB202608300001'), findsOneWidget);
      await _revealGrid(tester);
      expect(_headerLabel('入库仓库'), findsWidgets);
      expect(_headerLabel('实际成品仓'), findsNothing);
      expect(_headerLabel('行号'), findsNothing);
      expect(tester.takeException(), isNull);

      // 没选仓：校验只走 toast，不弹确认框、不发请求。
      await _pressRoute(tester, InboundRoute.inspectFirst);
      expect(find.text('确认登记送检'), findsNothing);
      expect(api.lastPostBody, isNull);
      expect(_toasts(tester).last, contains('未选择入库仓库'));

      await _selectWarehouse(tester, '成品仓', settle: true);
      expect(api.suggestionWarehouses, ['warehouse-1']);
      await _revealGrid(tester);
      expect(find.text('10'), findsOneWidget);
      _expectPlace(tester, _row1, '');

      // 2026-09-14：行级校验「整批扫完、同类一次点名全部违规行」。
      await _pressRoute(tester, InboundRoute.inspectFirst);
      expect(api.lastPostBody, isNull);
      expect(
        _toasts(tester).last,
        allOf(
          contains('未填写库位号'),
          contains('第 1 行'),
          isNot(contains('未选择入库仓库')),
        ),
      );

      await tester.enterText(_placeField(_row1), ' CP-A-01 ');
      await tester.pump();
      await _submit(tester);

      expect(
        find.byKey(const Key('open-arrival-registration')),
        findsOneWidget,
      );
      expect(api.lastPostPath, _registrationPath);
      // 一行一批实物：仓库、库位跟着批走，服务端按「报工 x 实际仓」分组。
      expect(api.lastPostBody?['lots'], const [
        {'lotId': _row1, 'warehouseId': 'warehouse-1', 'place': 'CP-A-01'},
      ]);
      expect(api.lastPostBody?.containsKey('stockInBeforeInspection'), isFalse);
      final idempotencyKey = api.lastPostBody?['idempotencyKey'] as String;
      expect(idempotencyKey.length, greaterThanOrEqualTo(8));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('view-only arrival task exposes no editable promise', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(375, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _ArrivalRegistrationApi(
      registered: true,
      warehouseId: 'warehouse-1',
      place: 'CP-A-01',
    );
    await _openPage(tester, api: api, canRegister: false);
    await _revealGrid(tester);

    for (final route in InboundRoute.values) {
      expect(find.byKey(route.submitKey), findsNothing);
    }
    expect(find.text('返回任务'), findsOneWidget);
    // 已登记：备注只读回显，行内仓库只读文字、没有选仓入口。
    expect(
      find.byKey(const Key('production-finished-arrival-remark')),
      findsNothing,
    );
    expect(_warehouseCell(_row1), findsNothing);
    // 已登记批只读显示登记仓与所属品质检查单。
    expect(
      find.descendant(
        of: _grid,
        matching: find.text('成品仓 · FQC20260830000001'),
      ),
      findsOneWidget,
    );
    expect(tester.widget<TextField>(_placeField(_row1)).enabled, isFalse);
    _expectPlace(tester, _row1, 'CP-A-01');
    expect(find.byType(RequiredCellFrame), findsNothing);
    expect(api.suggestionRequests, isEmpty);
    const footer = '当前账号只有查看权限，不能修改仓库或库位。';
    await tester.scrollUntilVisible(
      find.text(footer),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text(footer), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'formal route derives permission and refreshes pending count after save',
    (tester) async {
      final api = _ArrivalRegistrationApi();
      // 待点收数随徽章汇总带回(ADR-108): 保存成功后汇总重拉一次, 不再单独请求计数端点。
      final badges = FixedBadgeSummaryNotifier(
        badgeSummaryFixture(facts: {BadgeFact.finishedInbound: 1}),
      );
      final router = GoRouter(
        initialLocation: RouteName.warehouseProductionFinishedInboundTasks,
        routes: [
          GoRoute(
            path: RouteName.warehouseProductionFinishedInboundTasks,
            builder: (_, _) => const _ArrivalRouteQueue(),
          ),
          GoRoute(
            path: RouteName.warehouseProductionFinishedArrivalRegistration,
            builder: (_, state) => ProductionFinishedArrivalRegistrationPage(
              reportIds: (state.uri.queryParameters['reportIds'] ?? '')
                  .split(',')
                  .where((id) => id.isNotEmpty)
                  .toList(),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      SharedPreferences.setMockInitialValues({});

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            currentPermissionsProvider.overrideWithValue(const {
              Perm.stockDocView,
              Perm.stockDocApprove,
            }),
            isSuperAdminProvider.overrideWithValue(false),
            badgeSummaryProvider.overrideWith(() => badges),
          ],
          child: MaterialApp.router(
            routerConfig: router,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(badges.refreshCalls, 0);

      await tester.tap(find.byKey(const Key('open-formal-arrival-route')));
      await tester.pumpAndSettle();
      expect(find.byKey(InboundRoute.inspectFirst.submitKey), findsOneWidget);
      expect(find.byKey(InboundRoute.stockInFirst.submitKey), findsNothing);

      await _selectWarehouse(tester, '成品仓', settle: true);
      await _revealGrid(tester);
      await tester.enterText(_placeField(_row1), 'CP-A-01');
      await tester.pump();
      await _submit(tester);

      expect(
        find.byKey(const Key('open-formal-arrival-route')),
        findsOneWidget,
      );
      expect(badges.refreshCalls, greaterThanOrEqualTo(1));
      expect(
        ((api.lastPostBody?['lots'] as List).single as Map)['warehouseId'],
        'warehouse-1',
      );
    },
  );

  testWidgets(
    'place is editable before a warehouse is chosen; submit waits for suggestions',
    (tester) async {
      final api = _DeferredSuggestionApi(placeHint: 'GLOBAL-A-01');
      await _openPage(tester, api: api, canRegister: true);
      await _setAllRowsChecked(tester, true);

      // 没选仓也能填库位：货品资料通用库位先黄框带出，空值才描红。
      expect(tester.widget<TextField>(_placeField(_row1)).enabled, isTrue);
      _expectPlace(
        tester,
        _row1,
        'GLOBAL-A-01',
        autofilledFrom: InboundPlaceSource.goodsMaster,
      );
      expect(
        find.descendant(of: _grid, matching: find.text('库位号 *')),
        findsWidgets,
      );
      expect(find.byType(RequiredCellFrame), findsOneWidget);
      expect(api.suggestionRequests, isEmpty);
      expect(_submitButton(tester).onPressed, isNotNull);

      // 读取所选仓默认库位期间：提交置灰 (点灰按钮给提示)，库位仍可手填。
      await _selectWarehouse(tester, '成品仓');
      expect(api.suggestionWarehouses, ['warehouse-1']);
      expect(_submitButton(tester).onPressed, isNull);
      expect(_submitButton(tester).onDisabledTap, isNotNull);
      await _revealGrid(tester);
      expect(tester.widget<TextField>(_placeField(_row1)).enabled, isTrue);

      api.completeSuggestion(
        'warehouse-1',
        place: 'GLOBAL-A-01',
        source: 'GOODS_MASTER',
      );
      await tester.pumpAndSettle();
      await _revealGrid(tester);
      expect(_submitButton(tester).onPressed, isNotNull);
      _expectPlace(
        tester,
        _row1,
        'GLOBAL-A-01',
        autofilledFrom: InboundPlaceSource.goodsMaster,
      );
    },
  );

  testWidgets('global default stays editable and manual input changes source', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(375, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _ArrivalRegistrationApi(placeHint: 'GLOBAL-A-01');
    await _openPage(tester, api: api, canRegister: true);
    await _selectWarehouse(tester, '成品仓', settle: true);
    await _revealGrid(tester);

    expect(tester.widget<TextField>(_placeField(_row1)).enabled, isTrue);
    _expectPlace(
      tester,
      _row1,
      'GLOBAL-A-01',
      autofilledFrom: InboundPlaceSource.goodsMaster,
    );

    await tester.enterText(_placeField(_row1), 'MANUAL-A-02');
    await tester.pump();
    _expectPlace(tester, _row1, 'MANUAL-A-02');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'warehouse change posts shared place suggestions and fills a yellow place',
    (tester) async {
      final api = _ArrivalRegistrationApi(
        placeHint: 'GLOBAL-A-01',
        rememberedPlaces: const {'warehouse-2': 'WH-B-02'},
      );
      await _openPage(tester, api: api, canRegister: true);
      expect(api.suggestionRequests, isEmpty, reason: '没选仓不请求库位建议');

      await _selectWarehouse(tester, '备用成品仓', settle: true);

      // 共用端点：一个仓一次 POST，按「货品 × 颜色」请求。
      expect(api.suggestionPaths, [_placeSuggestionPath]);
      expect(api.suggestionRequests.single, {
        'warehouseId': 'warehouse-2',
        'items': [
          {'goodsId': _goods1, 'colorId': null},
        ],
      });
      await _revealGrid(tester);
      _expectPlace(
        tester,
        _row1,
        'WH-B-02',
        autofilledFrom: InboundPlaceSource.warehousePreference,
      );
      // 用户显式选的仓不是预填，不留黄框。
      expect(_warehouseDecoration(tester, _row1).autofilled, isFalse);
      expect(
        find.descendant(
          of: _warehouseCell(_row1),
          matching: find.text('备用成品仓'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('入库仓库预填：货品主档归属仓优先，没有时回落账号上次所选仓 (黄框待核对)', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // 账号记忆 (偏好键 production.finishedArrivalFill 不变) 记着上次选的备用成品仓。
    // 记忆缓存键按 账号/服务器 作用域哈希（v2）：先用空 mock 算出同款键
    // （服务器解析走 apiBaseUrlProvider 真实链、本地模式；无登录会话 scope=null），
    // 再带着种好的键重新取 prefs 给页面。
    SharedPreferences.setMockInitialValues({});
    final probePrefs = await SharedPreferences.getInstance();
    final probe = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(probePrefs)],
    );
    late final String scopedKey;
    try {
      scopedKey = scopedPagePreferenceCacheKey(
        'page_prefs_cache_production.finishedArrivalFill',
        probe.read(apiBaseUrlProvider),
        probe.read(authenticatedScopeProvider),
      );
    } finally {
      probe.dispose();
    }
    SharedPreferences.setMockInitialValues({
      scopedKey: '{"warehouseId":"warehouse-2"}',
    });
    final prefs = await SharedPreferences.getInstance();
    final api = _ArrivalRegistrationApi(
      duplicateGoodsRows: true,
      masterWarehouseByItem: const {_row1: 'warehouse-1'},
    );
    await _openPage(
      tester,
      api: api,
      canRegister: true,
      resetPrefs: false,
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );

    expect(
      api.suggestionWarehouses,
      unorderedEquals(['warehouse-1', 'warehouse-2']),
    );
    expect(api.suggestionPaths, everyElement(_placeSuggestionPath));
    expect(
      find.descendant(of: _warehouseCell(_row1), matching: find.text('成品仓')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: _warehouseCell(_row2), matching: find.text('备用成品仓')),
      findsOneWidget,
    );
    expect(_warehouseDecoration(tester, _row1).autofilled, isTrue);
    expect(_warehouseDecoration(tester, _row2).autofilled, isTrue);
  });

  testWidgets('warehouse preference replaces untouched global suggestion', (
    tester,
  ) async {
    final api = _ArrivalRegistrationApi(
      warehouseId: 'warehouse-1',
      placeHint: 'GLOBAL-A-01',
      rememberedPlaces: const {'warehouse-1': 'WH-A-09'},
    );
    await _openPage(tester, api: api, canRegister: true);
    await _revealGrid(tester);

    final placeField = _placeField(_row1);
    _expectPlace(
      tester,
      _row1,
      'WH-A-09',
      autofilledFrom: InboundPlaceSource.warehousePreference,
    );
    // 聚焦、挪光标不算核对：黄框保留。
    await tester.showKeyboard(placeField);
    expect(
      tester
          .widget<EditableText>(
            find.descendant(
              of: placeField,
              matching: find.byType(EditableText),
            ),
          )
          .focusNode
          .hasFocus,
      isTrue,
    );
    tester.widget<TextField>(placeField).controller!.selection =
        const TextSelection.collapsed(offset: 0);
    await tester.pump();
    _expectPlace(
      tester,
      _row1,
      'WH-A-09',
      autofilledFrom: InboundPlaceSource.warehousePreference,
    );
  });

  testWidgets('late warehouse response cannot overwrite newer warehouse', (
    tester,
  ) async {
    final api = _DeferredSuggestionApi();
    await _openPage(tester, api: api, canRegister: true);

    await _selectWarehouse(tester, '成品仓');
    await _selectWarehouse(tester, '备用成品仓');
    api.completeSuggestion('warehouse-2', place: 'WH-B-02');
    await tester.pump();
    api.completeSuggestion('warehouse-1', place: 'WH-A-01');
    await tester.pump();
    await _revealGrid(tester);

    _expectPlace(
      tester,
      _row1,
      'WH-B-02',
      autofilledFrom: InboundPlaceSource.warehousePreference,
    );
  });

  testWidgets('manual input survives retry for the same warehouse', (
    tester,
  ) async {
    final api = _DeferredSuggestionApi();
    await _openPage(tester, api: api, canRegister: true);

    await _selectWarehouse(tester, '成品仓');
    api.failSuggestion('warehouse-1');
    await tester.pumpAndSettle();
    await _revealGrid(tester);
    expect(tester.widget<TextField>(_placeField(_row1)).enabled, isTrue);
    _expectPlace(tester, _row1, '');
    await tester.enterText(_placeField(_row1), 'MANUAL-A-07');
    await tester.pump();

    final requestsBeforeRetry = api.suggestionRequests.length;
    await _revealSuggestionStatus(tester);
    await tester.tap(_suggestionRetryButton);
    await tester.pump();
    // 手填过的行重试也不再拉建议，失败提示随之收起。
    expect(api.suggestionRequests, hasLength(requestsBeforeRetry));
    expect(_suggestionStatus, findsNothing);

    await _revealPlace(tester, _row1);
    _expectPlace(tester, _row1, 'MANUAL-A-07');
  });

  testWidgets('switching warehouse discards the previous manual place', (
    tester,
  ) async {
    final api = _ArrivalRegistrationApi(
      rememberedPlaces: const {
        'warehouse-1': 'WH-A-01',
        'warehouse-2': 'WH-B-02',
      },
    );
    await _openPage(tester, api: api, canRegister: true);
    await _selectWarehouse(tester, '成品仓', settle: true);
    await _revealGrid(tester);
    _expectPlace(
      tester,
      _row1,
      'WH-A-01',
      autofilledFrom: InboundPlaceSource.warehousePreference,
    );
    await tester.enterText(_placeField(_row1), 'MANUAL-A-07');
    await tester.pump();

    await _selectWarehouse(tester, '备用成品仓', settle: true);
    await _revealGrid(tester);

    expect(api.suggestionWarehouses, ['warehouse-1', 'warehouse-2']);
    _expectPlace(
      tester,
      _row1,
      'WH-B-02',
      autofilledFrom: InboundPlaceSource.warehousePreference,
    );
  });

  testWidgets(
    'new warehouse drops the old auto place and takes the server goods-master fallback',
    (tester) async {
      final api = _DeferredSuggestionApi(placeHint: 'GLOBAL-A-01');
      await _openPage(tester, api: api, canRegister: true);

      await _selectWarehouse(tester, '成品仓');
      api.completeSuggestion('warehouse-1', place: 'WH-A-01');
      await tester.pump();
      await _selectWarehouse(tester, '备用成品仓');
      await _revealGrid(tester);

      // 新仓还没回话：旧仓的库位已清掉，不冒充新仓默认；库位仍可手填。
      expect(tester.widget<TextField>(_placeField(_row1)).enabled, isTrue);
      _expectPlace(tester, _row1, '');

      // 新仓没记住库位：服务端按货品资料通用库位回落 (GOODS_MASTER)。
      api.completeSuggestion(
        'warehouse-2',
        place: 'GLOBAL-A-01',
        source: 'GOODS_MASTER',
      );
      await tester.pump();
      _expectPlace(
        tester,
        _row1,
        'GLOBAL-A-01',
        autofilledFrom: InboundPlaceSource.goodsMaster,
      );
    },
  );

  testWidgets('failed next-warehouse lookup cannot retain prior auto place', (
    tester,
  ) async {
    final api = _DeferredSuggestionApi();
    await _openPage(tester, api: api, canRegister: true);

    await _selectWarehouse(tester, '成品仓');
    api.completeSuggestion('warehouse-1', place: 'WH-A-01');
    await tester.pump();
    await _selectWarehouse(tester, '备用成品仓');
    api.failSuggestion('warehouse-2');
    await tester.pumpAndSettle();
    await _revealGrid(tester);

    expect(tester.widget<TextField>(_placeField(_row1)).enabled, isTrue);
    _expectPlace(tester, _row1, '');

    // 失败提示条带「重试」：重拉新仓，回来后照常黄框回填。
    await _revealSuggestionStatus(tester);
    expect(
      find.descendant(
        of: _suggestionStatus,
        matching: find.textContaining('库位建议加载失败'),
      ),
      findsOneWidget,
    );
    await tester.tap(_suggestionRetryButton);
    await tester.pump();
    expect(api.suggestionWarehouses.last, 'warehouse-2');
    api.completeSuggestion('warehouse-2', place: 'WH-B-02');
    await tester.pumpAndSettle();
    expect(_suggestionStatus, findsNothing);

    await _revealPlace(tester, _row1);
    _expectPlace(
      tester,
      _row1,
      'WH-B-02',
      autofilledFrom: InboundPlaceSource.warehousePreference,
    );
  });

  testWidgets('missing row suggestion cannot retain prior warehouse value', (
    tester,
  ) async {
    final api = _DeferredSuggestionApi(secondRowOtherGoods: true);
    await _openPage(tester, api: api, canRegister: true);
    // 两行一起改仓：勾选多行后在任一行改仓 = 整批落值。
    await _setAllRowsChecked(tester, true);

    await _selectWarehouse(tester, '成品仓');
    expect(
      (api.suggestionRequests.single['items'] as List).length,
      2,
      reason: '同仓两种货品合并成一次请求',
    );
    api.completeSuggestion('warehouse-1', place: 'WH-A-01');
    await tester.pump();
    await _selectWarehouse(tester, '备用成品仓');
    api.completeSuggestionItems('warehouse-2', const [
      {
        'goodsId': _goods1,
        'colorId': null,
        'place': 'WH-B-02',
        'source': 'WAREHOUSE_PREFERENCE',
      },
    ]);
    await tester.pump();
    await _revealGrid(tester);

    _expectPlace(
      tester,
      _row1,
      'WH-B-02',
      autofilledFrom: InboundPlaceSource.warehousePreference,
    );
    _expectPlace(tester, _row2, '');
  });

  testWidgets('一张报工的两批实物进两个仓：一次提交一个命令，各批带各自的仓', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _ArrivalRegistrationApi(
      duplicateGoodsRows: true,
      warehouseId: 'warehouse-1',
    );
    await _openPage(tester, api: api, canRegister: true);

    // 货品主档归属仓 (黄框待核对) 预填到两行，进页即按该仓拉库位建议。
    expect(api.suggestionWarehouses, ['warehouse-1']);
    await _revealGrid(tester);
    expect(_warehouseDecoration(tester, _row1).autofilled, isTrue);

    // 第二行改成备用成品仓：行内仓格 → 共享仓库选择面板。
    await _tapGridCell(tester, _warehouseCell(_row2));
    await tester.tap(
      find.byKey(const Key('warehouse-picker-entry-warehouse-2')),
    );
    await tester.pumpAndSettle();
    expect(api.suggestionWarehouses, ['warehouse-1', 'warehouse-2']);
    expect(_warehouseDecoration(tester, _row1).autofilled, isTrue);
    expect(_warehouseDecoration(tester, _row2).autofilled, isFalse);

    await tester.enterText(_placeField(_row1), 'CP-A-01');
    await tester.enterText(_placeField(_row2), 'CP-B-01');
    await tester.pump();
    await _submit(tester);

    // ADR-151 §5：同一报工按实际仓分组由服务端做，页面只发一个命令。
    expect(api.postBodies, hasLength(1));
    final lots = (api.postBodies.single['lots'] as List)
        .cast<Map<String, dynamic>>();
    expect(lots.map((lot) => lot['lotId']), [_row1, _row2]);
    expect(lots.map((lot) => lot['warehouseId']), [
      'warehouse-1',
      'warehouse-2',
    ]);
    expect(lots.last['place'], 'CP-B-01');
    expect(find.byKey(const Key('open-arrival-registration')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('登记失败整批不落：停在原页，重试原样提交同一个命令', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _ArrivalRegistrationApi(
      duplicateGoodsRows: true,
      warehouseId: 'warehouse-1',
      failWarehouses: {'warehouse-2'},
    );
    await _openPage(tester, api: api, canRegister: true);
    await _revealGrid(tester);
    await _tapGridCell(tester, _warehouseCell(_row2));
    await tester.tap(
      find.byKey(const Key('warehouse-picker-entry-warehouse-2')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(_placeField(_row1), 'CP-A-01');
    await tester.enterText(_placeField(_row2), 'CP-B-01');
    await tester.pump();
    await _submit(tester);

    // 一个事务：失败时一批都不落，两行都仍可编辑。
    expect(api.postBodies, isEmpty);
    expect(api.failedBodies, hasLength(1));
    expect(_toasts(tester).last, contains('暂时不可登记'));
    expect(find.byKey(InboundRoute.inspectFirst.submitKey), findsOneWidget);
    expect(find.byKey(const Key('open-arrival-registration')), findsNothing);
    await _revealGrid(tester);
    expect(tester.widget<TextField>(_placeField(_row1)).enabled, isTrue);
    expect(tester.widget<TextField>(_placeField(_row2)).enabled, isTrue);

    // 原样重试：同一个提交键(丢响应重放安全)，两批一起登记。
    api.failWarehouses.clear();
    await _submit(tester);
    expect(api.postBodies, hasLength(1));
    expect(
      api.postBodies.single['idempotencyKey'],
      api.failedBodies.single['idempotencyKey'],
    );
    expect(
      (api.postBodies.single['lots'] as List).map(
        (lot) => (lot as Map)['lotId'],
      ),
      [_row1, _row2],
    );
    expect(find.byKey(const Key('open-arrival-registration')), findsOneWidget);
  });

  testWidgets('勾选多行后右键批量设置库位号应用到全部选中行', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _ArrivalRegistrationApi(
      duplicateGoodsRows: true,
      warehouseId: 'warehouse-1',
    );
    await _openPage(tester, api: api, canRegister: true);
    await _revealGrid(tester);

    // 2026-09-12 表头上方「全选/统一填写库位」按钮全撤：全选走表头复选框，
    // 批量填库位走右键菜单。
    expect(find.text('全选'), findsNothing);
    expect(find.text('统一填写库位(0)'), findsNothing);
    await _setAllRowsChecked(tester, true);
    await _rightClick(tester, find.text('三极插套').first);
    await tester.tap(find.text('批量设置库位号 (2)'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('production-finished-arrival-batch-place-input')),
      ' RACK-7 ',
    );
    await tester.tap(
      find.byKey(const Key('production-finished-arrival-batch-place-apply')),
    );
    await tester.pumpAndSettle();
    // 批量写库位视同已核对：不留黄框。
    for (final id in const [_row1, _row2]) {
      _expectPlace(tester, id, 'RACK-7');
    }
  });

  testWidgets('已登记批次在品质未处理前可撤回登记，撤回后回到待登记', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _ArrivalRegistrationApi(
      registered: true,
      warehouseId: 'warehouse-1',
      place: 'CP-A-01',
      reversible: true,
    );
    await _openPage(tester, api: api, canRegister: true);

    expect(find.textContaining('FQC20260830000001'), findsWidgets);
    for (final route in InboundRoute.values) {
      expect(find.byKey(route.submitKey), findsNothing);
    }
    final reverseButton = find.byKey(
      const ValueKey(
        'production-finished-arrival-reverse-40000000-0000-0000-0000-000000000001',
      ),
    );
    expect(reverseButton, findsOneWidget);
    await tester.tap(reverseButton);
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('撤回登记(仅品质未处理)'),
      ),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const Key('production-finished-arrival-reverse-confirm')),
    );
    await tester.pump();
    expect(
      find.byKey(const Key('production-finished-arrival-reverse-error')),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const Key('production-finished-arrival-reverse-reason')),
      '  仓库选错  ',
    );
    await tester.tap(
      find.byKey(const Key('production-finished-arrival-reverse-confirm')),
    );
    await tester.pumpAndSettle();

    expect(api.reversedRegistrationIds, [
      '40000000-0000-0000-0000-000000000001',
    ]);
    expect(api.lastReverseBody?['reason'], '仓库选错');
    expect(
      (api.lastReverseBody?['idempotencyKey'] as String?)?.length,
      greaterThanOrEqualTo(8),
    );
    // 撤回后页面重拉：回到待登记态 (可再次登记)。
    expect(find.byKey(InboundRoute.inspectFirst.submitKey), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _ArrivalRouteQueue extends ConsumerWidget {
  const _ArrivalRouteQueue();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(badgeFactProvider(BadgeFact.finishedInbound));
    return Scaffold(
      body: Center(
        child: FilledButton(
          key: const Key('open-formal-arrival-route'),
          onPressed: () => context.push(
            RoutePath.warehouseProductionFinishedArrivalRegistration([
              _reportId,
            ], returnTo: RouteName.warehouseProductionFinishedInboundTasks),
          ),
          child: const Text('打开登记'),
        ),
      ),
    );
  }
}

final _grid = find.byKey(const Key('production-finished-arrival-grid'));

final _suggestionStatus = find.byKey(
  const Key('inbound-place-suggestion-status'),
);

final _suggestionRetryButton = find.descendant(
  of: _suggestionStatus,
  matching: find.text('重试'),
);

/// 库位格：键挂在 WarehouseAutofillTextField 上，里面才是 TextField。
Finder _placeCell(String reportItemId) =>
    find.byKey(ValueKey('production-finished-arrival-place-$reportItemId'));

Finder _placeField(String reportItemId) => find.descendant(
  of: _placeCell(reportItemId),
  matching: find.byType(TextField),
);

Finder _warehouseCell(String reportItemId) =>
    find.byKey(ValueKey('production-finished-arrival-wh-$reportItemId'));

UtenInputDecoration _warehouseDecoration(
  WidgetTester tester,
  String reportItemId,
) =>
    tester
            .widget<InputDecorator>(
              find.descendant(
                of: _warehouseCell(reportItemId),
                matching: find.byType(InputDecorator),
              ),
            )
            .decoration
        as UtenInputDecoration;

/// 库位格的值与黄框状态：[autofilledFrom] 非空 = 预填/建议值待核对，ⓘ 说明来源；
/// 为空 = 手填或空值，不留黄框。
void _expectPlace(
  WidgetTester tester,
  String reportItemId,
  String text, {
  InboundPlaceSource? autofilledFrom,
}) {
  final field = tester.widget<TextField>(_placeField(reportItemId));
  expect(field.controller?.text, text);
  final decoration = field.decoration! as UtenInputDecoration;
  expect(
    decoration.autofilled,
    autofilledFrom != null,
    reason: '库位 "$text" 的黄框状态不对',
  );
  expect(decoration.info, autofilledFrom?.reviewHint);
}

/// 表头文案 (必填列带「 *」，两种写法都认)。
Finder _headerLabel(String label) => find.descendant(
  of: _grid,
  matching: find.byWidgetPredicate((widget) {
    if (widget is! Text) return false;
    final text = widget.data ?? widget.textSpan?.toPlainText();
    return text == label || text == '$label *';
  }),
);

Finder _selectAllHeader() => find.descendant(
  of: _grid,
  matching: find.byWidgetPredicate(
    (widget) => widget is Checkbox && widget.tristate,
  ),
);

UtenButton _submitButton(
  WidgetTester tester, [
  InboundRoute route = InboundRoute.inspectFirst,
]) => tester.widget<UtenButton>(find.byKey(route.submitKey));

/// 顶部 toast (context.appError / appInfo) 走全局通知队列，测试宿主不挂通知层，
/// 直接读队列文案。
List<String> _toasts(WidgetTester tester) => ProviderScope.containerOf(
  tester.element(find.byType(MaterialApp)),
  listen: false,
).read(appNotificationProvider).map((notice) => notice.message).toList();

Future<void> _revealGrid(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    _grid,
    320,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pump();
}

Future<void> _revealPlace(WidgetTester tester, String reportItemId) async {
  await tester.scrollUntilVisible(
    _placeCell(reportItemId),
    320,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pump();
}

/// 库位建议提示条在明细表上方：编辑表带表头设置操作条后常停在视口外、被 ListView
/// 拆卸，向上滚到它出现为止 (不能用 pumpAndSettle，加载中转圈永不停)。
Future<void> _revealSuggestionStatus(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    _suggestionStatus,
    -320,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pump();
}

/// 点明细行里的格子。表格自带 sticky 表头覆盖层，行刚好停在视口顶端时会被它压住
/// （命中落到表头上）。先把目标滚到视口中部再点，不依赖页面其它元素的高度——
/// 2026-09-11 撤掉「成品明细 (N)」标题行后，固定步长滚动的老写法就是这么失手的。
Future<void> _tapGridCell(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    120,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
  // alignment 0.5 = 滚到视口中部，避开表格自带的 sticky 表头覆盖层。
  await Scrollable.ensureVisible(tester.element(finder), alignment: 0.5);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// 鼠标右键点行 (行菜单)：先滚到视口中部避开 sticky 表头。
Future<void> _rightClick(WidgetTester tester, Finder finder) async {
  await Scrollable.ensureVisible(tester.element(finder), alignment: 0.5);
  await tester.pumpAndSettle();
  final gesture = await tester.startGesture(
    tester.getCenter(finder),
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryButton,
  );
  await gesture.up();
  await tester.pumpAndSettle();
}

Future<void> _selectWarehouse(
  WidgetTester tester,
  String label, {
  bool settle = false,
  int row = 1,
}) async {
  // 选仓 = 点行内仓格弹共享仓库面板。
  // 注意不能用 pumpAndSettle——延迟建议类用例里库位建议请求挂起时提示条一直转圈。
  final cell = _warehouseCell(row == 1 ? _row1 : _row2);
  await tester.scrollUntilVisible(
    cell,
    120,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pump();
  // alignment 0.5 = 滚到视口中部，避开表格自带的 sticky 表头覆盖层。
  await Scrollable.ensureVisible(tester.element(cell), alignment: 0.5);
  await tester.pump();
  await tester.tap(cell);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  final entry = {'成品仓': 'warehouse-1', '备用成品仓': 'warehouse-2'}[label]!;
  await tester.tap(find.byKey(ValueKey('warehouse-picker-entry-$entry')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
  if (settle) await tester.pumpAndSettle();
}

/// 用表头三态全选格把可勾选行整体切到 [checked] (只读页没有勾选列时不动)。
Future<void> _setAllRowsChecked(WidgetTester tester, bool checked) async {
  await _revealGrid(tester);
  final header = _selectAllHeader();
  if (header.evaluate().isEmpty) return;
  for (var i = 0; i < 3; i++) {
    final box = tester.widget<Checkbox>(header.first);
    if (box.value == checked || box.onChanged == null) return;
    box.onChanged!(null);
    await tester.pump();
  }
  fail('表头全选格没能切到 $checked');
}

/// 点路线提交按钮 (两条路线并排，按 InboundRoute.submitKey 取)。提交集=勾选集：
/// 一行都没勾时先经表头全选勾回全部行。只点按钮，不处理确认框。
Future<void> _pressRoute(WidgetTester tester, InboundRoute route) async {
  await _revealGrid(tester);
  final header = _selectAllHeader();
  if (header.evaluate().isNotEmpty &&
      tester.widget<Checkbox>(header.first).value == false) {
    await _setAllRowsChecked(tester, true);
  }
  final button = _submitButton(tester, route);
  expect(button.onPressed, isNotNull, reason: '「${route.label}」不应置灰');
  button.onPressed!();
  await tester.pumpAndSettle();
}

/// 每次提交都先弹确认框 (UtenDialog)，点确认才真正登记。
Future<void> _confirm(WidgetTester tester, InboundRoute route) async {
  final label = route.isStockInFirst ? '确认登记并先入库' : '确认登记送检';
  expect(find.text(label), findsOneWidget, reason: '提交前必须弹确认框');
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

Future<void> _submit(
  WidgetTester tester, {
  InboundRoute route = InboundRoute.inspectFirst,
}) async {
  await _pressRoute(tester, route);
  await _confirm(tester, route);
}

/// 打开登记页 (宿主页 push 进去，登记成功后 pop 回宿主)。[clearSelection] 为真时
/// 清空进页默认全选，本文件多数用例按「逐行操作」编写；提交前由 [_pressRoute]
/// 统一回选全部行。已打开时再调用只刷新 ProviderScope 覆盖 (如换权限快照)。
Future<void> _openPage(
  WidgetTester tester, {
  required _ArrivalRegistrationApi api,
  bool? canRegister,
  bool clearSelection = true,
  bool resetPrefs = true,
  List<Override> overrides = const [],
}) async {
  // 选仓记忆 (inboundWarehouseFillMemoryProvider) 本地走 shared_preferences 缓存，
  // 测试宿主必须给 mock 初值。
  if (resetPrefs) SharedPreferences.setMockInitialValues({});
  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api), ...overrides],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                key: const Key('open-arrival-registration'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ProductionFinishedArrivalRegistrationPage(
                      reportIds: const [_reportId],
                      canRegister: canRegister,
                    ),
                  ),
                ),
                child: const Text('打开登记'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  if (find
      .byType(ProductionFinishedArrivalRegistrationPage)
      .evaluate()
      .isEmpty) {
    await tester.tap(find.byKey(const Key('open-arrival-registration')));
  }
  await tester.pumpAndSettle();
  if (clearSelection) await _setAllRowsChecked(tester, false);
}

class _ArrivalRegistrationApi extends ApiClient {
  _ArrivalRegistrationApi({
    this.registered = false,
    this.warehouseId,
    this.place,
    this.placeHint,
    this.duplicateGoodsRows = false,
    this.secondRowOtherGoods = false,
    this.masterWarehouseByItem = const {},
    this.rememberedPlaces = const {},
    Set<String>? failWarehouses,
    this.reversible = false,
    this.unitRate,
    this.registeredWeightKg,
  }) : failWarehouses = failWarehouses ?? <String>{},
       super(Dio());

  /// 报工行换算率 (1 个报工单位 = 多少基本单位)；null = 不下发 (按 1)。
  final double? unitRate;

  /// 已登记行登记时的实称重量 (千克)；待登记行恒为空。
  final double? registeredWeightKg;

  bool registered;

  /// 未登记时 = 各行货品主档归属仓 (item.lastWarehouseId，进页预填)；
  /// 已登记时 = 登记头的入库仓库。
  final String? warehouseId;

  /// 逐行覆盖货品主档归属仓 (reportItemId → 仓)。
  final Map<String, String> masterWarehouseByItem;

  /// 仓 → 该仓记住的库位 (服务端 WAREHOUSE_PREFERENCE)；没配的仓由服务端按货品资料
  /// 通用库位 (placeHint，GOODS_MASTER) 回落，都没有 = NONE。
  final Map<String, String> rememberedPlaces;

  /// 登记这些仓时返回失败（部分仓失败场景）；用例可中途清空后重试。
  final Set<String> failWarehouses;
  final bool reversible;
  final String? place;
  final String? placeHint;

  /// 第二行同货品同颜色。
  final bool duplicateGoodsRows;

  /// 第二行换一种货品 (库位建议按「货品 × 颜色」回填，同货品两行拿到的是同一条)。
  final bool secondRowOtherGoods;

  final List<Map<String, dynamic>> postBodies = [];

  /// 整批失败的提交(一个事务，什么都没落)。
  final List<Map<String, dynamic>> failedBodies = [];
  final List<String> reversedRegistrationIds = [];
  Map<String, dynamic>? lastReverseBody;
  String? lastPostPath;
  Map<String, dynamic>? lastPostBody;

  /// 库位建议请求 (路径与请求体)。
  final List<String> suggestionPaths = [];
  final List<Map<String, dynamic>> suggestionRequests = [];
  List<String> get suggestionWarehouses => [
    for (final request in suggestionRequests) request['warehouseId'] as String,
  ];

  bool _saved = false;
  String? _savedWarehouseId;
  final Map<String, String> _savedPlaces = {};

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/master/warehouses/dict') {
      return const [
        {'id': 'warehouse-1', 'name': '成品仓', 'selectableForNew': true},
        {'id': 'warehouse-2', 'name': '备用成品仓', 'selectableForNew': true},
      ];
    }
    // 登记页按来源报工一次拉取(单张 = 1 个来源)。
    if (path == _registrationPath) {
      expect(query?['reportIds'], _reportId);
      return [_detailJson()];
    }
    return const [];
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    throw StateError('Unexpected GET $path');
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    if (path == _placeSuggestionPath) {
      final request = Map<String, dynamic>.from(body! as Map);
      suggestionPaths.add(path);
      suggestionRequests.add(request);
      return answerSuggestions(request);
    }
    if (path.startsWith(
          '/warehouse/production-finished-in/arrival-registrations/',
        ) &&
        path.endsWith('/reverse')) {
      reversedRegistrationIds.add(
        path.split('/arrival-registrations/').last.split('/').first,
      );
      lastReverseBody = Map<String, dynamic>.from(body! as Map);
      _saved = false;
      registered = false;
      _savedWarehouseId = null;
      _savedPlaces.clear();
      return _detailJson();
    }
    // 单重参数取参失败不再静默 (ADR-151): 这些用例不关心单重, 回一个「都没学过」的真实形状。
    if (path == '/stock/weight/params') {
      return {'items': <Object>[], 'stockBalances': <Object>[]};
    }
    if (path != _registrationPath) throw StateError('Unexpected POST $path');
    lastPostPath = path;
    lastPostBody = Map<String, dynamic>.from(body! as Map);
    final lots = [
      for (final lot in (lastPostBody?['lots'] as List? ?? const []))
        Map<String, dynamic>.from(lot as Map),
    ];
    final failed = lots
        .map((lot) => lot['warehouseId'] as String?)
        .where(failWarehouses.contains)
        .toList();
    if (failed.isNotEmpty) {
      failedBodies.add(lastPostBody!);
      throw NetworkException('仓库「${failed.first}」暂时不可登记');
    }
    postBodies.add(lastPostBody!);
    _saved = true;
    _savedWarehouseId = lots.isEmpty
        ? null
        : lots.first['warehouseId'] as String?;
    for (final lot in lots) {
      _savedPlaces[lot['lotId'] as String] = lot['place'] as String;
    }
    final groups = <String>{
      for (final lot in lots) lot['warehouseId'] as String,
    };
    return {
      'registeredCount': 1,
      'reports': [
        for (final warehouse in groups)
          {
            'registrationId': '40000000-0000-0000-0000-000000000001',
            'reportId': _reportId,
            'reportNo': 'RB202608300001',
            'warehouseId': warehouse,
            'warehouseName': '成品仓',
          },
      ],
      'sheets': const <Object>[],
    };
  }

  /// 共用库位建议端点的服务端口径：该仓记住的库位 → 货品资料通用库位 → 无。
  Future<Map<String, dynamic>> answerSuggestions(
    Map<String, dynamic> request,
  ) async {
    final remembered = rememberedPlaces[request['warehouseId']];
    final fallback = placeHint?.isNotEmpty == true ? placeHint : null;
    return {
      'items': [
        for (final goods in _requestedGoods(request))
          {
            ...goods,
            'place': remembered ?? fallback,
            'source': remembered != null
                ? 'WAREHOUSE_PREFERENCE'
                : fallback != null
                ? 'GOODS_MASTER'
                : 'NONE',
          },
      ],
    };
  }

  static List<Map<String, dynamic>> _requestedGoods(
    Map<String, dynamic> request,
  ) => [
    for (final item in request['items'] as List)
      Map<String, dynamic>.from(item as Map),
  ];

  Map<String, dynamic> _detailJson() {
    final registeredValue = registered || _saved;
    final selectedWarehouse = _savedWarehouseId ?? warehouseId;
    final registrationId = registeredValue
        ? '40000000-0000-0000-0000-00000000000${postBodies.isEmpty ? 1 : postBodies.length}'
        : null;
    return {
      'registrationId': registrationId,
      'registered': registeredValue,
      'reportId': _reportId,
      'reportNo': 'RB202608300001',
      'reportDate': '2026-08-30',
      'departmentId': '50000000-0000-0000-0000-000000000001',
      'workshopName': '注塑车间',
      'warehouseId': selectedWarehouse,
      'warehouseCode': selectedWarehouse == null ? null : 'CP',
      'warehouseName': selectedWarehouse == null ? null : '成品仓',
      'receiverEmployeeId': '60000000-0000-0000-0000-000000000001',
      'receiverName': '仓库管理员',
      'registeredAt': registeredValue ? '2026-08-30T08:30:00Z' : null,
      'sheetNo': registeredValue ? 'FQC20260830000001' : null,
      'reversible': registeredValue && reversible,
      'batches': registeredValue
          ? [
              {
                'registrationId': registrationId,
                'warehouseId': selectedWarehouse,
                'warehouseName': '成品仓',
                'receiverName': '仓库管理员',
                'registeredAt': '2026-08-30T08:30:00Z',
                'itemCount': _itemsJson().length,
                'sheetNo': 'FQC20260830000001',
                'reversible': reversible,
              },
            ]
          : const <Map<String, dynamic>>[],
      'lots': _itemsJson(),
    };
  }

  List<Map<String, dynamic>> _itemsJson() => [
    _itemJson(reportItemId: _row1, lineNo: 1),
    if (duplicateGoodsRows || secondRowOtherGoods)
      _itemJson(
        reportItemId: _row2,
        lineNo: 2,
        otherGoods: secondRowOtherGoods,
      ),
  ];

  Map<String, dynamic> _itemJson({
    required String reportItemId,
    required int lineNo,
    bool otherGoods = false,
  }) {
    final pending = !(registered || _saved);
    final master = masterWarehouseByItem[reportItemId] ?? warehouseId;
    // 一批实物一行：测试里一批只有一份(需求份)，批号沿用报工行号便于定位格子。
    return {
      'lotId': reportItemId,
      'members': [
        {
          'reportItemId': reportItemId,
          'lineNo': lineNo,
          'qty': 10,
          'kind': 'DEMAND',
        },
      ],
      'lineNo': lineNo,
      'planItemId': '70000000-0000-0000-0000-000000000001',
      'executionSegmentId': '80000000-0000-0000-0000-000000000001',
      'planId': '90000000-0000-0000-0000-000000000001',
      'planNo': 'SJ202608300001',
      'goodsId': otherGoods ? _goods2 : _goods1,
      'goodsCode': otherGoods ? 'V51044' : 'V51043',
      'goodsName': otherGoods ? '两极插头' : '三极插套',
      'colorId': null,
      'colorName': '—',
      'unitId': 'b0000000-0000-0000-0000-000000000001',
      'unitName': '只',
      'reportedQty': 10,
      'place': _savedPlaces[reportItemId] ?? place,
      'placeHint': placeHint,
      // 货品主档归属仓：只在待登记时作为预填来源带回。
      'lastWarehouseId': pending ? master : null,
      'weight': pending ? null : registeredWeightKg,
      'unitRate': ?unitRate,
    };
  }
}

/// 库位建议挂起，由用例决定何时、以什么结果返回 (乱序 / 失败)。
class _DeferredSuggestionApi extends _ArrivalRegistrationApi {
  _DeferredSuggestionApi({super.placeHint, super.secondRowOtherGoods});

  final Map<String, Completer<Map<String, dynamic>>> _pending = {};
  final Map<String, Map<String, dynamic>> _pendingRequests = {};

  @override
  Future<Map<String, dynamic>> answerSuggestions(Map<String, dynamic> request) {
    final warehouseId = request['warehouseId'] as String;
    final current = _pending[warehouseId];
    if (current != null && !current.isCompleted) return current.future;
    final next = Completer<Map<String, dynamic>>();
    _pending[warehouseId] = next;
    _pendingRequests[warehouseId] = request;
    return next.future;
  }

  Completer<Map<String, dynamic>> _pendingFor(String warehouseId) {
    final pending = _pending[warehouseId];
    if (pending == null || pending.isCompleted) {
      throw StateError('No pending suggestion request for $warehouseId');
    }
    return pending;
  }

  /// 按该仓请求里的每种货品回同一个库位。
  void completeSuggestion(
    String warehouseId, {
    required String? place,
    String source = 'WAREHOUSE_PREFERENCE',
  }) {
    _pendingFor(warehouseId);
    completeSuggestionItems(warehouseId, [
      for (final goods in _ArrivalRegistrationApi._requestedGoods(
        _pendingRequests[warehouseId]!,
      ))
        {...goods, 'place': place, 'source': source},
    ]);
  }

  void completeSuggestionItems(
    String warehouseId,
    List<Map<String, dynamic>> items,
  ) => _pendingFor(warehouseId).complete({'items': items});

  void failSuggestion(String warehouseId) =>
      _pendingFor(warehouseId).completeError(NetworkException('成品仓默认库位加载失败'));
}
