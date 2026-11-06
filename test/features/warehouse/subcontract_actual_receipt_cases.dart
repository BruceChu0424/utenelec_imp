import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/warehouse/pages/inbound_arrival_registration_page.dart';
import 'package:uten_imp/features/warehouse/models/inbound_registration_line.dart';
import 'package:uten_imp/shared/drafts/form_draft_mixin.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/models/procurement_inbound.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'inbound_arrival_test_support.dart';
import 'arrival_weight_test_support.dart';

void registerSubcontractActualReceiptCases(
  Map<String, dynamic> contract, {
  Future<void> Function(RenderRepaintBoundary boundary, bool narrow)?
  screenshot,
  Future<void> Function(WidgetTester tester)? prepareScreenshot,
  ThemeData? screenshotTheme,
}) {
  final vectors = (contract['vectors'] as List).cast<Map<String, dynamic>>();
  for (final vector in [
    ...vectors,
    {
      ...vectors.firstWhere((item) => item['id'] == 'variable-loss'),
      'id': 'variable-loss-narrow',
      'narrow': true,
    },
  ]) {
    testWidgets('委外实收共享样例 ${vector['id']} 保持实际输入与恢复命令', (tester) async {
      final narrow = vector['narrow'] == true;
      tester.view.physicalSize = Size(narrow ? 390 : 1800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      if (prepareScreenshot != null) await prepareScreenshot(tester);
      final preferences = await SharedPreferences.getInstance();
      final api = _ActualReceiptApi(
        customPrefills: [
          ProcurementReceiptPrefill(
            expectationId: 'actual-subcontract',
            orderType: ProcurementInboundOrderType.subcontract,
            orderBillNo: 'EO-ACTUAL-001',
            supplierId: 'supplier-1',
            warehouseId: 'warehouse-1',
            items: [
              ProcurementReceiptPrefillItem(
                orderItemId: 'actual-item',
                goodsId: 'goods-1',
                goodsCode: 'Q7BJ-ZJ0340',
                goodsName: '委外成品',
                unitRate: 1,
                unitName: '个',
                approvedRemainingQty: num.parse(
                  vector['materialReceivableQty'] as String,
                ),
                orderedQty: num.parse(vector['target'] as String),
                orderedQtyText: vector['target'] as String,
                pendingReturnQty: num.parse(vector['target'] as String),
                pendingReturnQtyText: vector['target'] as String,
                materialReceivableQty: num.parse(
                  vector['materialReceivableQty'] as String,
                ),
                materialReceivableQtyText:
                    vector['materialReceivableQty'] as String,
                normalMaxReceivableQty: num.parse(
                  vector['normalMaxReceivableQty'] as String,
                ),
                normalMaxReceivableQtyText:
                    vector['normalMaxReceivableQty'] as String,
              ),
            ],
          ),
        ],
        arrivalError: vector['outcome'] == 'EXCEPTION'
            ? ApiException('CONFLICT', '实际回厂超过正常上限，请按到货异常办理', httpStatus: 409)
            : null,
      );
      final router = _actualReceiptRouter(
        ids: ['actual-subcontract'],
        route: InboundRoute.inspectFirst,
      );
      addTearDown(router.dispose);
      const screenshotKey = ValueKey('subcontract-actual-receipt-screen');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            sharedPreferencesProvider.overrideWithValue(preferences),
            sessionProvider.overrideWith(_ActualReceiptSession.new),
            masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
            ...warehouseWeightTestOverrides(api),
            currentPermissionsProvider.overrideWithValue(const {
              Perm.warehouseInboundView,
              Perm.warehouseInboundStockIn,
            }),
          ],
          child: RepaintBoundary(
            key: screenshotKey,
            child: MaterialApp.router(
              routerConfig: router,
              theme: screenshotTheme,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final editor =
          tester.state(find.byType(InboundArrivalRegistrationPage))
              as FormDraftMixin<InboundArrivalRegistrationPage>;
      Map<String, dynamic> snapshot() => editor.captureFormDraft();
      Map<String, dynamic> row(Map<String, dynamic> draft) =>
          (draft['rows'] as List).single as Map<String, dynamic>;
      final before = snapshot();
      expect(row(before)['qty'], '', reason: '理论供料容量不能冒充实收');
      expect(
        (row(before)['item'] as Map)['normalMaxReceivableQtyText'],
        vector['normalMaxReceivableQty'],
      );
      await tester.tap(find.byKey(InboundRoute.inspectFirst.submitKey));
      await tester.pumpAndSettle();
      expect(api.arrivalPostBodies, isEmpty, reason: '未清点实际数量不能发送登记');
      final qty = find.byKey(
        const ValueKey('warehouse-arrival-qty-actual-item'),
      );
      await tester.ensureVisible(qty);
      await tester.enterText(qty, vector['actualReceipt'] as String);
      await tester.pumpAndSettle();
      final entered = snapshot();
      final submitPoint = tester.getCenter(
        find.byKey(InboundRoute.inspectFirst.submitKey),
      );
      await tester.tap(find.byKey(InboundRoute.inspectFirst.submitKey));
      // A real repeated click can land on the modal barrier after the first
      // click opens confirmation; it must not start another mutation.
      await tester.tapAt(submitPoint);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('warehouse-inbound-allocation-confirm-dialog')),
        findsOneWidget,
      );
      await tester.tap(find.text('返回修改'));
      await tester.pumpAndSettle();
      expect(api.arrivalPostBodies, isEmpty, reason: '取消确认不得写入');
      expect(row(snapshot())['qty'], vector['actualReceipt']);
      await tester.enterText(qty, '');
      await editor.restoreFormDraft(
        jsonDecode(jsonEncode(entered)) as Map<String, dynamic>,
      );
      await tester.pumpAndSettle();
      expect(row(snapshot())['qty'], vector['actualReceipt']);
      expect(snapshot()['registrationId'], entered['registrationId']);
      expect(
        (row(snapshot())['item'] as Map)['orderedQtyText'],
        vector['target'],
      );
      expect(
        (row(snapshot())['item'] as Map)['pendingReturnQtyText'],
        vector['target'],
      );
      expect(
        (row(snapshot())['item'] as Map)['materialReceivableQtyText'],
        vector['materialReceivableQty'],
      );
      if (screenshot != null && (vector['id'] == 'minimum' || narrow)) {
        await tester.ensureVisible(
          find.byKey(
            const ValueKey('warehouse-arrival-orderedQty-actual-item'),
          ),
        );
        await tester.pumpAndSettle();
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(screenshotKey),
        );
        await screenshot(boundary, narrow);
      }
      await tester.tap(find.byKey(InboundRoute.inspectFirst.submitKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认登记送检'));
      await tester.pumpAndSettle();
      expect(api.arrivalPostBodies, hasLength(1));
      final sent = api.arrivalPostBodies.single;
      expect(
        ((sent['lines'] as List).single as Map)['qty'],
        vector['actualReceipt'],
      );
      if (vector['outcome'] == 'EXCEPTION') {
        expect(
          row(snapshot())['qty'],
          vector['actualReceipt'],
          reason: '服务端异常不改写实际数量',
        );
      }
      expect(tester.takeException(), isNull);
    });
  }
}

GoRouter _actualReceiptRouter({
  required List<String> ids,
  required InboundRoute route,
}) => GoRouter(
  initialLocation: RoutePath.warehouseArrivalRegistration(
    ids,
    stockInBeforeInspection: route.isStockInFirst,
  ),
  routes: [
    GoRoute(
      path: RouteName.warehouseArrivalRegistration,
      builder: (_, state) => InboundArrivalRegistrationPage(
        expectationIds: (state.uri.queryParameters['expectationIds'] ?? '')
            .split(',')
            .where((id) => id.isNotEmpty)
            .toList(),
        route: route,
      ),
    ),
    GoRoute(
      path: RouteName.warehouseInboundExpectations,
      builder: (_, _) => const Scaffold(body: Text('预计到货任务中心')),
    ),
  ],
);

class _ActualReceiptSession extends SessionNotifier {
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

class _ActualReceiptApi extends ApiClient {
  _ActualReceiptApi({required this.customPrefills, this.arrivalError})
    : super(Dio());
  final List<ProcurementReceiptPrefill> customPrefills;
  final Object? arrivalError;
  final List<Map<String, dynamic>> arrivalPostBodies = [];
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/org/employee-references') {
      return {
        'items': [_receiver],
        'page': 1,
        'size': 100,
        'total': 1,
        'totalPages': 1,
      };
    }
    if (path.contains('/count')) return const {'count': 0};
    throw ApiException('TEST_UNEXPECTED_GET', path);
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/org/employee-references/by-ids') return [_receiver];
    if (path == '/org/employee-references/departments' ||
        path == '/business-references/departments') {
      return [
        {
          'id': 'warehouse-department',
          'code': 'WH',
          'name': '仓储部',
          'level': '二级班组',
          'children': <Object>[],
        },
      ];
    }
    if (path == '/business-references/warehouses') {
      return [
        {
          'id': 'warehouse-1',
          'name': '成品仓',
          'status': '使用',
          'accountable': true,
          'selectableForNew': true,
        },
      ];
    }
    if (path == arrivalExpectationsByIdsPath) {
      return expectationsByIdsAnswer(query, customPrefills);
    }
    return const [];
  }

  Map<String, Object> get _receiver => {
    'id': 'emp-me',
    'code': '000067',
    'fullName': '仓管员',
    'departmentId': 'warehouse-department',
    'departmentName': '仓储部',
    'positionName': '仓管员',
    'status': 'active',
  };

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    if (path == '/warehouse/place-suggestions') {
      return const {'items': <Object>[]};
    }
    if (path == arrivalBatchPath) {
      final request = Map<String, dynamic>.from(body! as Map);
      arrivalPostBodies.add(request);
      final error = arrivalError;
      if (error != null) throw error;
      return arrivalBatchAnswer(request);
    }
    throw ApiException('TEST_UNEXPECTED_POST', path);
  }
}
