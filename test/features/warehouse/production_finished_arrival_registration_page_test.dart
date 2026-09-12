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
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/warehouse/pages/production_finished_arrival_registration_page.dart';
import 'package:uten_imp/features/warehouse/providers/production_finished_inbound_task_count_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

const _reportId = '20000000-0000-0000-0000-000000000001';

void _expectSourceInsideField(WidgetTester tester, String source) {
  final field = tester.widget<TextField>(
    _placeField('30000000-0000-0000-0000-000000000001'),
  );
  expect(field.decoration, isA<UtenInputDecoration>());
  final decoration = field.decoration! as UtenInputDecoration;
  // 2026-09-12 起库位来源说明 ⓘ 收进列头，格内不再逐行挂图标；
  // 来源语义只剩黄框（预填待核对）一种可见状态。
  expect(decoration.info, isNull);
  expect(
    decoration.autofilled,
    {'货品主档通用建议', '最近登记：同仓同货品', '该仓默认'}.contains(source),
  );
}

void main() {
  testWidgets('自制单张登记右键移出一行后仅送检剩余行', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _ArrivalRegistrationApi(duplicateGoodsRows: true);
    await _openPage(tester, api: api, canRegister: true);

    await _selectWarehouse(tester, '成品仓', settle: true);
    await _revealGrid(tester);

    final removedPlace = _placeField('30000000-0000-0000-0000-000000000002');
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('2').last),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await gesture.up();
    await tester.pump();
    await tester.tap(find.text('移出本批送检 (1)').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('仍保持待登记送检'), findsOneWidget);
    await tester.tap(find.text('确认移出'));
    await tester.pumpAndSettle();
    expect(removedPlace, findsNothing);
    expect(find.textContaining('未选行仍在待登记送检'), findsOneWidget);

    await tester.enterText(
      _placeField('30000000-0000-0000-0000-000000000001'),
      'CP-A-01',
    );
    _pressSubmit(tester);
    await tester.pumpAndSettle();
    final items = (api.lastPostBody?['items'] as List)
        .cast<Map<String, dynamic>>();
    expect(items, hasLength(1));
    expect(
      items.single['reportItemId'],
      '30000000-0000-0000-0000-000000000001',
    );
  });

  testWidgets(
    'arrival registration is operable at 375px and posts exact warehouse places',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(375, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _ArrivalRegistrationApi();
      await _openPage(tester, api: api, canRegister: true);

      expect(find.text('登记成品仓与库位'), findsOneWidget);
      expect(find.text('第 1 步：仓库登记到货位置'), findsOneWidget);
      expect(find.text('RB202608300001'), findsOneWidget);
      expect(tester.takeException(), isNull);

      _pressSubmit(tester);
      await tester.pump();
      await _revealValidationError(tester);
      expect(find.text('请选择实际存放的成品仓库'), findsWidgets);

      await _selectWarehouse(tester, '成品仓', settle: true);
      expect(api.suggestionWarehouses, contains('warehouse-1'));
      await _revealGrid(tester);
      expect(find.text('10'), findsOneWidget);
      final placeField = find.byKey(
        const ValueKey(
          'production-finished-arrival-place-'
          '30000000-0000-0000-0000-000000000001',
        ),
      );
      expect(tester.widget<TextField>(placeField).controller?.text, isEmpty);

      _pressSubmit(tester);
      await tester.pump();
      expect(api.lastPostBody, isNull);
      expect(find.text('登记成品仓与库位'), findsOneWidget);
      await _revealValidationError(tester);
      final validation = find.byKey(
        const Key('production-finished-arrival-validation-error'),
      );
      expect(validation, findsOneWidget);
      expect(tester.widget<Text>(validation).data, '第 1 行必须填写库位号');

      await tester.enterText(placeField, ' CP-A-01 ');
      _pressSubmit(tester);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('open-arrival-registration')),
        findsOneWidget,
      );
      expect(
        api.lastPostPath,
        '/warehouse/production-finished-in/arrival-registrations/$_reportId',
      );
      expect(api.lastPostBody?['warehouseId'], 'warehouse-1');
      expect(api.lastPostBody?['items'], const [
        {
          'reportItemId': '30000000-0000-0000-0000-000000000001',
          'place': 'CP-A-01',
        },
      ]);
      expect(
        (api.lastPostBody?['idempotencyKey'] as String?)?.length,
        greaterThanOrEqualTo(8),
      );
      expect(api.rememberRequests, 1);
      expect(
        api.lastRememberRegistrationId,
        '40000000-0000-0000-0000-000000000001',
      );
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

    expect(
      find.byKey(const Key('production-finished-arrival-submit')),
      findsNothing,
    );
    expect(find.text('该到货登记已提交，仓库和库位仅供核对。'), findsOneWidget);
    // 已登记后整个登记工具区不渲染：不留可编辑的仓/备注/批量库位入口。
    expect(
      find.byKey(const Key('production-finished-arrival-warehouse')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('production-finished-arrival-remark')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('production-finished-arrival-batch-place')),
      findsNothing,
    );
    // 实际成品仓改为头部卡只读回显（值来自已登记明细）。
    expect(find.widgetWithText(TextFormField, '成品仓'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(
            find.byKey(
              const ValueKey(
                'production-finished-arrival-place-'
                '30000000-0000-0000-0000-000000000001',
              ),
            ),
          )
          .enabled,
      isFalse,
    );
    _expectSourceInsideField(tester, '本次登记快照');
    expect(
      find.byKey(const Key('production-finished-arrival-remember-places')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'formal route derives permission and refreshes pending count after save',
    (tester) async {
      final api = _ArrivalRegistrationApi();
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
              reportId: state.pathParameters['reportId'] ?? '',
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
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      expect(api.countRequests, 1);

      await tester.tap(find.byKey(const Key('open-formal-arrival-route')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('production-finished-arrival-submit')),
        findsOneWidget,
      );

      await _selectWarehouse(tester, '成品仓', settle: true);
      await _revealGrid(tester);
      await tester.enterText(
        find.byKey(
          const ValueKey(
            'production-finished-arrival-place-'
            '30000000-0000-0000-0000-000000000001',
          ),
        ),
        'CP-A-01',
      );
      await tester.tap(
        find.byKey(const Key('production-finished-arrival-submit')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('open-formal-arrival-route')),
        findsOneWidget,
      );
      expect(api.countRequests, 2);
      expect(api.lastPostBody?['warehouseId'], 'warehouse-1');
    },
  );

  testWidgets('place stays disabled until warehouse suggestions are ready', (
    tester,
  ) async {
    final api = _ArrivalRegistrationApi(placeHint: 'GLOBAL-A-01');
    await _openPage(tester, api: api, canRegister: true);
    await _revealGrid(tester);

    final placeField = _placeField('30000000-0000-0000-0000-000000000001');
    final beforeSelection = tester.widget<TextField>(placeField);
    expect(beforeSelection.enabled, isFalse);
    expect(beforeSelection.controller?.text, isEmpty);
    expect(beforeSelection.decoration?.hintText, '请先选择成品仓');
    expect(find.text('请先选择成品仓'), findsWidgets);
    expect(_requiredPlaceHeader(), findsNothing);
    expect(find.byType(RequiredCellFrame), findsNothing);

    await _selectWarehouse(tester, '成品仓', settle: true);
    await _revealGrid(tester);

    final afterSelection = tester.widget<TextField>(placeField);
    expect(afterSelection.enabled, isTrue);
    expect(afterSelection.controller?.text, 'GLOBAL-A-01');
    _expectSourceInsideField(tester, '货品主档通用建议');
    expect(_requiredPlaceHeader(), findsWidgets);
    expect(find.byType(RequiredCellFrame), findsOneWidget);
  });

  testWidgets('global default stays editable and manual input changes source', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(375, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _ArrivalRegistrationApi(placeHint: 'GLOBAL-A-01');
    await _openPage(tester, api: api, canRegister: true);
    await _selectWarehouse(tester, '成品仓', settle: true);
    await _revealGrid(tester);

    final placeField = _placeField('30000000-0000-0000-0000-000000000001');
    expect(
      tester.widget<TextField>(placeField).controller?.text,
      'GLOBAL-A-01',
    );
    _expectSourceInsideField(tester, '货品主档通用建议');
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(
              const Key('production-finished-arrival-remember-places'),
            ),
          )
          .value,
      isTrue,
    );

    await tester.enterText(placeField, 'MANUAL-A-02');
    await tester.pump();
    _expectSourceInsideField(tester, '手工输入');
    expect(tester.takeException(), isNull);
  });

  testWidgets('registration history suggestion is visible and editable', (
    tester,
  ) async {
    final api = _ArrivalRegistrationApi(
      warehouseId: 'warehouse-1',
      suggestionsByWarehouse: const {
        'warehouse-1': [
          {
            'reportItemId': '30000000-0000-0000-0000-000000000001',
            'place': 'HISTORY-A-08',
            'source': 'REGISTRATION_HISTORY',
          },
        ],
      },
    );
    await _openPage(tester, api: api, canRegister: true);
    await _revealGrid(tester);

    final placeField = _placeField('30000000-0000-0000-0000-000000000001');
    expect(
      tester.widget<TextField>(placeField).controller?.text,
      'HISTORY-A-08',
    );
    _expectSourceInsideField(tester, '最近登记：同仓同货品');

    await tester.enterText(placeField, 'MANUAL-A-09');
    await tester.pump();
    _expectSourceInsideField(tester, '手工输入');
  });

  testWidgets('warehouse preference replaces untouched global suggestion', (
    tester,
  ) async {
    final api = _ArrivalRegistrationApi(
      warehouseId: 'warehouse-1',
      placeHint: 'GLOBAL-A-01',
      suggestionsByWarehouse: const {
        'warehouse-1': [
          {
            'reportItemId': '30000000-0000-0000-0000-000000000001',
            'place': 'WH-A-09',
            'source': 'WAREHOUSE_PREFERENCE',
          },
        ],
      },
    );
    await _openPage(tester, api: api, canRegister: true);
    await _revealGrid(tester);

    final placeField = _placeField('30000000-0000-0000-0000-000000000001');
    expect(tester.widget<TextField>(placeField).controller?.text, 'WH-A-09');
    _expectSourceInsideField(tester, '该仓默认');
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
    _expectSourceInsideField(tester, '该仓默认');
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

    final placeField = _placeField('30000000-0000-0000-0000-000000000001');
    expect(tester.widget<TextField>(placeField).controller?.text, 'WH-B-02');
    _expectSourceInsideField(tester, '该仓默认');
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
    final placeField = _placeField('30000000-0000-0000-0000-000000000001');
    expect(tester.widget<TextField>(placeField).enabled, isTrue);
    await tester.enterText(placeField, 'MANUAL-A-07');
    await tester.pump();
    await tester.ensureVisible(
      find.byKey(const Key('production-finished-arrival-retry-suggestions')),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const Key('production-finished-arrival-retry-suggestions')),
    );
    await tester.pump();
    expect(tester.widget<TextField>(placeField).enabled, isFalse);
    expect(
      tester.widget<TextField>(placeField).controller?.text,
      'MANUAL-A-07',
    );

    api.completeSuggestion('warehouse-1', place: 'WH-A-01');
    await tester.pump();
    await _revealGrid(tester);

    expect(
      tester.widget<TextField>(placeField).controller?.text,
      'MANUAL-A-07',
    );
    _expectSourceInsideField(tester, '手工输入');
  });

  testWidgets('switching warehouse discards the previous manual place', (
    tester,
  ) async {
    final api = _ArrivalRegistrationApi(
      suggestionsByWarehouse: const {
        'warehouse-1': [
          {
            'reportItemId': '30000000-0000-0000-0000-000000000001',
            'place': 'WH-A-01',
            'source': 'WAREHOUSE_PREFERENCE',
          },
        ],
        'warehouse-2': [
          {
            'reportItemId': '30000000-0000-0000-0000-000000000001',
            'place': 'WH-B-02',
            'source': 'WAREHOUSE_PREFERENCE',
          },
        ],
      },
    );
    await _openPage(tester, api: api, canRegister: true);
    await _selectWarehouse(tester, '成品仓', settle: true);
    await _revealGrid(tester);
    final placeField = _placeField('30000000-0000-0000-0000-000000000001');
    await tester.enterText(placeField, 'MANUAL-A-07');
    await tester.pump();

    await _selectWarehouse(tester, '备用成品仓', settle: true);
    await _revealGrid(tester);

    expect(tester.widget<TextField>(placeField).controller?.text, 'WH-B-02');
    _expectSourceInsideField(tester, '该仓默认');
  });

  testWidgets('switching to none restores the goods master fallback', (
    tester,
  ) async {
    final api = _DeferredSuggestionApi(placeHint: 'GLOBAL-A-01');
    await _openPage(tester, api: api, canRegister: true);

    await _selectWarehouse(tester, '成品仓');
    api.completeSuggestion('warehouse-1', place: 'WH-A-01');
    await tester.pump();
    await _selectWarehouse(tester, '备用成品仓');
    await _revealGrid(tester);

    final placeField = _placeField('30000000-0000-0000-0000-000000000001');
    expect(tester.widget<TextField>(placeField).enabled, isFalse);
    expect(
      tester.widget<TextField>(placeField).controller?.text,
      'GLOBAL-A-01',
    );
    api.completeSuggestion('warehouse-2', place: null, source: 'NONE');
    await tester.pump();

    expect(tester.widget<TextField>(placeField).enabled, isTrue);
    expect(
      tester.widget<TextField>(placeField).controller?.text,
      'GLOBAL-A-01',
    );
    _expectSourceInsideField(tester, '货品主档通用建议');
  });

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

    final placeField = _placeField('30000000-0000-0000-0000-000000000001');
    expect(tester.widget<TextField>(placeField).enabled, isTrue);
    expect(tester.widget<TextField>(placeField).controller?.text, isEmpty);
    _expectSourceInsideField(tester, '暂无默认');
  });

  testWidgets('missing row suggestion cannot retain prior warehouse value', (
    tester,
  ) async {
    final api = _DeferredSuggestionApi(duplicateGoodsRows: true);
    await _openPage(tester, api: api, canRegister: true);

    await _selectWarehouse(tester, '成品仓');
    api.completeSuggestion('warehouse-1', place: 'WH-A-01');
    await tester.pump();
    await _selectWarehouse(tester, '备用成品仓');
    api.completeSuggestionItems('warehouse-2', const [
      {
        'reportItemId': '30000000-0000-0000-0000-000000000001',
        'place': 'WH-B-02',
        'source': 'WAREHOUSE_PREFERENCE',
      },
    ]);
    await tester.pump();
    await _revealGrid(tester);

    expect(
      tester
          .widget<TextField>(
            _placeField('30000000-0000-0000-0000-000000000001'),
          )
          .controller
          ?.text,
      'WH-B-02',
    );
    expect(
      tester
          .widget<TextField>(
            _placeField('30000000-0000-0000-0000-000000000002'),
          )
          .controller
          ?.text,
      isEmpty,
    );
  });

  testWidgets('行级成品仓：两行分别选不同仓，按仓两次 POST（不同幂等键）并逐批记忆', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _ArrivalRegistrationApi(
      duplicateGoodsRows: true,
      lastWarehouseId: 'warehouse-1',
    );
    await _openPage(tester, api: api, canRegister: true);

    // 上次登记仓（黄框待核对）落到未手工改过的两行：不再有表头默认仓下拉
    //（2026-09-12 撤），预填直接体现在行内仓格与建议请求上。
    expect(api.suggestionWarehouses, contains('warehouse-1'));
    await _revealGrid(tester);
    expect(find.text('成品仓'), findsWidgets);

    // 第二行改成备用成品仓：行内仓格 → 共享仓库选择面板。
    await _tapGridCell(
      tester,
      find.byKey(
        const ValueKey(
          'production-finished-arrival-wh-30000000-0000-0000-0000-000000000002',
        ),
      ),
    );
    await tester.tap(
      find.byKey(const Key('warehouse-picker-entry-warehouse-2')),
    );
    await tester.pumpAndSettle();
    expect(api.suggestionWarehouses, contains('warehouse-2'));

    await tester.enterText(
      _placeField('30000000-0000-0000-0000-000000000001'),
      'CP-A-01',
    );
    await tester.enterText(
      _placeField('30000000-0000-0000-0000-000000000002'),
      'CP-B-01',
    );
    _pressSubmit(tester);
    await tester.pumpAndSettle();

    expect(api.postBodies, hasLength(2));
    expect(api.postBodies[0]['warehouseId'], 'warehouse-1');
    expect(api.postBodies[1]['warehouseId'], 'warehouse-2');
    expect(
      ((api.postBodies[0]['items'] as List).single as Map)['reportItemId'],
      '30000000-0000-0000-0000-000000000001',
    );
    expect(
      ((api.postBodies[1]['items'] as List).single as Map)['place'],
      'CP-B-01',
    );
    final keys = api.postBodies
        .map((body) => body['idempotencyKey'] as String)
        .toList();
    expect(keys.toSet(), hasLength(2));
    expect(keys[0], endsWith(':warehouse-1'));
    expect(keys[1], endsWith(':warehouse-2'));
    expect(keys.map((key) => key.split(':').first).toSet(), hasLength(1));
    expect(api.rememberRequests, 2, reason: '每个登记批次按 registrationId 记忆一次');
    expect(find.byKey(const Key('open-arrival-registration')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('部分仓登记失败停在原页；重试只补提交失败仓', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _ArrivalRegistrationApi(
      duplicateGoodsRows: true,
      lastWarehouseId: 'warehouse-1',
      failWarehouses: {'warehouse-2'},
    );
    await _openPage(tester, api: api, canRegister: true);
    await _revealGrid(tester);
    await _tapGridCell(
      tester,
      find.byKey(
        const ValueKey(
          'production-finished-arrival-wh-30000000-0000-0000-0000-000000000002',
        ),
      ),
    );
    await tester.tap(
      find.byKey(const Key('warehouse-picker-entry-warehouse-2')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      _placeField('30000000-0000-0000-0000-000000000001'),
      'CP-A-01',
    );
    await tester.enterText(
      _placeField('30000000-0000-0000-0000-000000000002'),
      'CP-B-01',
    );
    _pressSubmit(tester);
    await tester.pumpAndSettle();

    expect(api.postBodies, hasLength(1));
    expect(api.postBodies.single['warehouseId'], 'warehouse-1');
    expect(
      find.byKey(const Key('production-finished-arrival-submit')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('open-arrival-registration')), findsNothing);
    // 已成功仓的行锁定只读；失败仓的行仍可编辑。
    expect(
      tester
          .widget<TextField>(
            _placeField('30000000-0000-0000-0000-000000000001'),
          )
          .enabled,
      isFalse,
    );
    expect(
      tester
          .widget<TextField>(
            _placeField('30000000-0000-0000-0000-000000000002'),
          )
          .enabled,
      isTrue,
    );

    api.failWarehouses.clear();
    _pressSubmit(tester);
    await tester.pumpAndSettle();
    expect(api.postBodies, hasLength(2));
    expect(api.postBodies.last['warehouseId'], 'warehouse-2');
    expect(
      ((api.postBodies.last['items'] as List).single as Map)['reportItemId'],
      '30000000-0000-0000-0000-000000000002',
    );
    expect(find.byKey(const Key('open-arrival-registration')), findsOneWidget);
  });

  testWidgets('勾选多行后右键批量设置库位号应用到全部选中行', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _ArrivalRegistrationApi(
      duplicateGoodsRows: true,
      lastWarehouseId: 'warehouse-1',
    );
    await _openPage(tester, api: api, canRegister: true);
    await _revealGrid(tester);

    // 2026-09-12 表头上方「全选/统一填写库位」按钮全撤：全选走表头复选框，
    // 批量填库位走右键菜单。
    expect(find.text('全选'), findsNothing);
    expect(find.text('统一填写库位(0)'), findsNothing);
    await tester.tap(
      find.byWidgetPredicate((widget) => widget is Checkbox && widget.tristate),
    );
    await tester.pump();
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('三极插套').first),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await gesture.up();
    await tester.pump();
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
    for (final id in const [
      '30000000-0000-0000-0000-000000000001',
      '30000000-0000-0000-0000-000000000002',
    ]) {
      expect(
        tester.widget<TextField>(_placeField(id)).controller?.text,
        'RACK-7',
      );
    }
    _expectSourceInsideField(tester, '手工输入');
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

    expect(find.text('FQC20260830000001'), findsWidgets);
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
    // 撤回后页面重拉：回到待登记态（可再次登记）。
    expect(
      find.byKey(const Key('production-finished-arrival-submit')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('remember switch off skips remember endpoint', (tester) async {
    final api = _ArrivalRegistrationApi();
    await _openPage(tester, api: api, canRegister: true);
    await _selectWarehouse(tester, '成品仓', settle: true);
    await tester.tap(
      find.byKey(const Key('production-finished-arrival-remember-places')),
    );
    await tester.pump();
    await _revealGrid(tester);
    await tester.enterText(
      _placeField('30000000-0000-0000-0000-000000000001'),
      'CP-A-01',
    );
    _pressSubmit(tester);
    await tester.pumpAndSettle();

    expect(api.rememberRequests, 0);
    expect(find.byKey(const Key('open-arrival-registration')), findsOneWidget);
  });

  testWidgets(
    'remember conflict blocks registration for same goods and color',
    (tester) async {
      final api = _ArrivalRegistrationApi(duplicateGoodsRows: true);
      await _openPage(tester, api: api, canRegister: true);
      await _selectWarehouse(tester, '成品仓', settle: true);
      await _selectWarehouse(tester, '成品仓', settle: true, row: 2);
      await _revealGrid(tester);
      await tester.enterText(
        _placeField('30000000-0000-0000-0000-000000000001'),
        'CP-A-01',
      );
      await tester.enterText(
        _placeField('30000000-0000-0000-0000-000000000002'),
        'CP-B-02',
      );
      _pressSubmit(tester);
      await tester.pump();

      expect(find.textContaining('同一颜色维度填写了不同库位'), findsOneWidget);
      expect(find.textContaining('关闭“同时记住”'), findsOneWidget);
      expect(api.lastPostBody, isNull);
    },
  );

  testWidgets(
    'remember failure keeps read-only retry state until retry succeeds',
    (tester) async {
      final api = _ArrivalRegistrationApi(failFirstRemember: true);
      await _openPage(tester, api: api, canRegister: true);
      await _selectWarehouse(tester, '成品仓', settle: true);
      await _revealGrid(tester);
      final placeField = _placeField('30000000-0000-0000-0000-000000000001');
      await tester.enterText(placeField, 'CP-A-01');
      _pressSubmit(tester);
      await tester.pump();
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(api.rememberRequests, 1);
      expect(
        find.byKey(const Key('production-finished-arrival-remember-failure')),
        findsOneWidget,
      );
      expect(tester.widget<TextField>(placeField).enabled, isFalse);
      expect(
        tester
            .widget<UtenButton>(
              find.byKey(const Key('production-finished-arrival-refresh')),
            )
            .onPressed,
        isNull,
      );
      expect(
        find.byKey(const Key('production-finished-arrival-retry-remember')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const Key('production-finished-arrival-retry-remember')),
      );
      await tester.pumpAndSettle();
      expect(api.rememberRequests, 2);
      expect(
        find.byKey(const Key('open-arrival-registration')),
        findsOneWidget,
      );
    },
  );
}

class _ArrivalRouteQueue extends ConsumerWidget {
  const _ArrivalRouteQueue();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(warehouseProductionFinishedInboundPendingCountProvider);
    return Scaffold(
      body: Center(
        child: FilledButton(
          key: const Key('open-formal-arrival-route'),
          onPressed: () => context.push(
            RoutePath.warehouseProductionFinishedArrivalRegistration(
              _reportId,
              returnTo: RouteName.warehouseProductionFinishedInboundTasks,
            ),
          ),
          child: const Text('打开登记'),
        ),
      ),
    );
  }
}

Finder _placeField(String reportItemId) =>
    find.byKey(ValueKey('production-finished-arrival-place-$reportItemId'));

Finder _requiredPlaceHeader() => find.byWidgetPredicate(
  (widget) => widget is Text && widget.textSpan?.toPlainText() == '库位号 *',
);

Future<void> _revealGrid(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.byKey(const Key('production-finished-arrival-registration-grid')),
    320,
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

/// 校验错误文案位于 ListView 惰性视口外时，先滚动到可见再断言。
Future<void> _revealValidationError(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.byKey(const Key('production-finished-arrival-validation-error')),
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pump();
}

Future<void> _selectWarehouse(
  WidgetTester tester,
  String label, {
  bool settle = false,
  int row = 1,
}) async {
  // 2026-09-12 表头「默认成品仓」下拉已撤：选仓 = 点行内仓格弹共享仓库面板。
  // 注意不能用 pumpAndSettle——延迟建议类用例里 place-suggestions 永远挂起。
  final cell = find.byKey(
    ValueKey(
      'production-finished-arrival-wh-30000000-0000-0000-0000-00000000000$row',
    ),
  );
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

void _pressSubmit(WidgetTester tester) {
  tester
      .widget<UtenButton>(
        find.byKey(const Key('production-finished-arrival-submit')),
      )
      .onPressed!
      .call();
}

Future<void> _openPage(
  WidgetTester tester, {
  required _ArrivalRegistrationApi api,
  required bool canRegister,
}) async {
  // 选仓记忆（productionFinishedArrivalFillMemoryProvider）本地走
  // shared_preferences 缓存，测试宿主必须给 mock 初值。
  SharedPreferences.setMockInitialValues({});
  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                key: const Key('open-arrival-registration'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ProductionFinishedArrivalRegistrationPage(
                      reportId: _reportId,
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
  await tester.tap(find.byKey(const Key('open-arrival-registration')));
  await tester.pumpAndSettle();
}

class _ArrivalRegistrationApi extends ApiClient {
  _ArrivalRegistrationApi({
    this.registered = false,
    this.warehouseId,
    this.place,
    this.placeHint,
    this.duplicateGoodsRows = false,
    this.failFirstRemember = false,
    this.suggestionsByWarehouse = const {},
    this.lastWarehouseId,
    this.failWarehouses = const {},
    this.reversible = false,
  }) : super(Dio());

  bool registered;

  /// 未登记时作为逐行「同货品最近登记仓」建议（lastWarehouseId）带回；
  /// 已登记时是登记头的实际成品仓。
  final String? warehouseId;

  /// 当前用户上次登记仓（GET last-warehouse）；null = 无历史。
  final String? lastWarehouseId;

  /// 登记这些仓时返回失败（部分仓失败场景）；用例可中途清空后重试。
  Set<String> failWarehouses;
  final bool reversible;
  final List<Map<String, dynamic>> postBodies = [];
  final List<String> reversedRegistrationIds = [];
  Map<String, dynamic>? lastReverseBody;
  final String? place;
  final String? placeHint;
  final bool duplicateGoodsRows;
  final bool failFirstRemember;
  final Map<String, List<Map<String, dynamic>>> suggestionsByWarehouse;
  String? lastPostPath;
  Map<String, dynamic>? lastPostBody;
  int countRequests = 0;
  int rememberRequests = 0;
  String? lastRememberRegistrationId;
  final List<String> suggestionWarehouses = [];
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
        {'id': 'warehouse-1', 'name': '成品仓'},
        {'id': 'warehouse-2', 'name': '备用成品仓'},
      ];
    }
    return const [];
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/tasks/count')) {
      countRequests++;
      return const {'count': 1};
    }
    if (path.endsWith('/place-suggestions')) {
      final selectedWarehouse = query?['warehouseId']?.toString() ?? '';
      suggestionWarehouses.add(selectedWarehouse);
      return {
        'items':
            suggestionsByWarehouse[selectedWarehouse] ??
            [
              for (final item in _itemsJson())
                {
                  'reportItemId': item['reportItemId'],
                  'place': placeHint,
                  'source': placeHint?.isNotEmpty == true
                      ? 'GOODS_MASTER'
                      : 'NONE',
                },
            ],
      };
    }
    if (path ==
        '/warehouse/production-finished-in/arrival-registrations/$_reportId') {
      return _detailJson();
    }
    if (path.endsWith('/last-warehouse')) {
      return lastWarehouseId == null
          ? const <String, dynamic>{}
          : {'warehouseId': lastWarehouseId, 'warehouseName': '成品仓'};
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
    if (path.endsWith('/remember-places')) {
      rememberRequests++;
      lastRememberRegistrationId = query?['registrationId']?.toString();
      if (failFirstRemember && rememberRequests == 1) {
        throw NetworkException('默认库位服务暂时不可用');
      }
      return const {
        'remembered': 1,
        'unchanged': 0,
        'ambiguous': 0,
        'warnings': <String>[],
      };
    }
    if (path.endsWith('/reverse')) {
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
    lastPostPath = path;
    lastPostBody = Map<String, dynamic>.from(body! as Map);
    final requestedWarehouse = lastPostBody?['warehouseId'] as String?;
    if (failWarehouses.contains(requestedWarehouse)) {
      throw NetworkException('仓库「$requestedWarehouse」暂时不可登记');
    }
    postBodies.add(lastPostBody!);
    _saved = true;
    _savedWarehouseId = requestedWarehouse;
    for (final item in (lastPostBody?['items'] as List? ?? const [])) {
      final row = Map<String, dynamic>.from(item as Map);
      _savedPlaces[row['reportItemId'] as String] = row['place'] as String;
    }
    return _detailJson();
  }

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
      'items': _itemsJson(),
    };
  }

  List<Map<String, dynamic>> _itemsJson() => [
    _itemJson(reportItemId: '30000000-0000-0000-0000-000000000001', lineNo: 1),
    if (duplicateGoodsRows)
      _itemJson(
        reportItemId: '30000000-0000-0000-0000-000000000002',
        lineNo: 2,
      ),
  ];

  Map<String, dynamic> _itemJson({
    required String reportItemId,
    required int lineNo,
  }) => {
    'reportItemId': reportItemId,
    'lineNo': lineNo,
    'planItemId': '70000000-0000-0000-0000-000000000001',
    'executionSegmentId': '80000000-0000-0000-0000-000000000001',
    'planId': '90000000-0000-0000-0000-000000000001',
    'planNo': 'SJ202608300001',
    'goodsId': 'a0000000-0000-0000-0000-000000000001',
    'goodsCode': 'V51043',
    'goodsName': '三极插套',
    'colorId': null,
    'colorName': '—',
    'unitId': 'b0000000-0000-0000-0000-000000000001',
    'unitName': '只',
    'reportedQty': 10,
    'place': _savedPlaces[reportItemId] ?? place,
    'placeHint': placeHint,
    'lastWarehouseId': registered || _saved ? null : warehouseId,
    'lastWarehouseName': registered || _saved || warehouseId == null
        ? null
        : '成品仓',
  };
}

class _DeferredSuggestionApi extends _ArrivalRegistrationApi {
  _DeferredSuggestionApi({super.placeHint, super.duplicateGoodsRows});

  final Map<String, Completer<Map<String, dynamic>>> _pendingSuggestions = {};

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/place-suggestions')) {
      final warehouseId = query?['warehouseId']?.toString() ?? '';
      suggestionWarehouses.add(warehouseId);
      final current = _pendingSuggestions[warehouseId];
      if (current != null && !current.isCompleted) return current.future;
      final next = Completer<Map<String, dynamic>>();
      _pendingSuggestions[warehouseId] = next;
      return next.future;
    }
    return super.get(path, query: query);
  }

  void completeSuggestion(
    String warehouseId, {
    required String? place,
    String source = 'WAREHOUSE_PREFERENCE',
  }) {
    completeSuggestionItems(warehouseId, [
      for (final item in _itemsJson())
        {
          'reportItemId': item['reportItemId'],
          'place': place,
          'source': source,
        },
    ]);
  }

  void completeSuggestionItems(
    String warehouseId,
    List<Map<String, dynamic>> items,
  ) {
    final pending = _pendingSuggestions[warehouseId];
    if (pending == null) {
      throw StateError('No pending suggestion request for $warehouseId');
    }
    pending.complete({'items': items});
  }

  void failSuggestion(String warehouseId) {
    final pending = _pendingSuggestions[warehouseId];
    if (pending == null) {
      throw StateError('No pending suggestion request for $warehouseId');
    }
    pending.completeError(NetworkException('成品仓默认库位加载失败'));
  }
}
