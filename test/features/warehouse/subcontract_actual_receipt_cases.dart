import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/components/feedback/uten_confirmation_summary.dart';
import 'package:uten_imp/shared/formatters/exact_decimal.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/warehouse/pages/inbound_arrival_registration_page.dart';
import 'package:uten_imp/features/warehouse/models/inbound_registration_line.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_inbound_allocation_view.dart';
import 'package:uten_imp/shared/drafts/form_draft_mixin.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/models/procurement_inbound.dart';
import 'package:uten_imp/shared/models/procurement_quantity.dart';
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
    _registerSubcontractActualReceiptCase(
      vector,
      precisionProbe: false,
      screenshot: screenshot,
      prepareScreenshot: prepareScreenshot,
      screenshotTheme: screenshotTheme,
    );
  }
  // This is a separate transport/display precision probe. It consumes the
  // allowance fixture's recorded text; it does not extend ordinary business vectors.
  if (contract['normalAllowanceVectors'] case final List<Object?> precision) {
    final source = precision.cast<Map<String, dynamic>>().singleWhere(
      (item) => item['id'] == 'recorded-target-zero-loss',
    );
    final actual = (contract['actualMaterialVectors'] as List)
        .cast<Map<String, dynamic>>()
        .singleWhere((item) => item['id'] == 'actual-source-base-one');
    for (final layout in [
      (name: 'wide', narrow: false, scale: 1.0),
      (name: 'narrow', narrow: true, scale: 1.0),
      (name: 'wide-large', narrow: false, scale: 1.5),
      (name: 'narrow-large', narrow: true, scale: 1.5),
    ]) {
      _registerSubcontractActualReceiptCase({
        'id': '${actual['id']}-${layout.name}',
        'target': source['target'],
        // Actual output is a separate source fact. The derived normal maximum
        // remains a readonly limit, never an actual-input default.
        'actualReceipt': actual['outputQty'],
        'materialReceivableQty': actual['physicalOutputQty'],
        'normalMaxReceivableQty': source['normalMaximum'],
        'quantitySemantics': procurementLegacyQuantity,
        'narrow': layout.narrow,
        'textScale': layout.scale,
      }, precisionProbe: true);
    }
    _registerSharedConfirmationPrecision(actual['outputQty'] as String);
  }
}

void _registerSubcontractActualReceiptCase(
  Map<String, dynamic> vector, {
  required bool precisionProbe,
  Future<void> Function(RenderRepaintBoundary boundary, bool narrow)?
  screenshot,
  Future<void> Function(WidgetTester tester)? prepareScreenshot,
  ThemeData? screenshotTheme,
}) {
  testWidgets(
    '${precisionProbe ? '委外实收独立精度' : '委外实收共享样例'} ${vector['id']} 保持实际输入与恢复命令',
    (tester) async {
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
                approvedRemainingQtyText: precisionProbe
                    ? vector['materialReceivableQty'] as String
                    : null,
                quantitySemantics: vector['quantitySemantics'] as String?,
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
              builder: precisionProbe
                  ? (context, child) => MediaQuery(
                      data: MediaQuery.of(context).copyWith(
                        textScaler: TextScaler.linear(
                          vector['textScale'] as double,
                        ),
                      ),
                      child: child!,
                    )
                  : null,
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
      if (precisionProbe) {
        expect(
          tester.widget<TextField>(qty).controller!.text,
          vector['actualReceipt'],
          reason: '实际输入不经过double或四位物料格式器回写',
        );
        for (final field in [
          ('orderedQty', 'orderedQtyText', vector['target']),
          ('pendingReturnQty', 'pendingReturnQtyText', vector['target']),
          (
            'normalMaxReceivableQty',
            'normalMaxReceivableQtyText',
            vector['normalMaxReceivableQty'],
          ),
        ]) {
          final reference = find.byKey(
            ValueKey('warehouse-arrival-${field.$1}-actual-item'),
          );
          await tester.ensureVisible(reference);
          expect(tester.widget<Text>(reference).data, '${field.$3} 个');
          expect((row(entered)['item'] as Map)[field.$2], field.$3);
        }
        expect(
          (row(entered)['item'] as Map)['materialReceivableQtyText'],
          vector['materialReceivableQty'],
        );
        expect(
          find.byWidgetPredicate(
            (widget) =>
                widget is Tooltip &&
                (widget.message?.contains(
                      '已发物料理论上还能回厂 ${vector['materialReceivableQty']} 个',
                    ) ??
                    false),
          ),
          findsWidgets,
        );
      }
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
      expect(
        (row(snapshot())['item'] as Map)['normalMaxReceivableQtyText'],
        vector['normalMaxReceivableQty'],
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
      if (precisionProbe) {
        expect(
          jsonEncode(sent),
          contains('"qty":"${vector['actualReceipt']}"'),
        );
        expect(
          jsonEncode(entered),
          contains('"qty":"${vector['actualReceipt']}"'),
        );
      }
      if (vector['outcome'] == 'EXCEPTION') {
        expect(
          row(snapshot())['qty'],
          vector['actualReceipt'],
          reason: '服务端异常不改写实际数量',
        );
      }
      expect(tester.takeException(), isNull);
    },
  );
}

void _registerSharedConfirmationPrecision(String quantity) {
  testWidgets('委外实收独立精度 公共确认保留登记与IQC原量并在390大字换行', (tester) async {
    tester.view.physicalSize = const Size(390, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var accepted = false;
    final api = _ActualReceiptApi(customPrefills: const []);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          sessionProvider.overrideWith(_ActualReceiptSession.new),
          masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  accepted = await showWarehouseInboundAllocationConfirmDialog(
                    context,
                    title: '确认原始实收',
                    summary: UtenConfirmationSummary(
                      facts: [
                        UtenConfirmationFact(
                          label: '原始实收合计',
                          value:
                              '${financeExactSumTexts(List.filled(3, quantity))} 个',
                        ),
                      ],
                    ),
                    actionLabel: '登记实收',
                    sections: [
                      for (final source in ['采购登记', '委外登记', 'IQC合格品'])
                        WarehouseInboundAllocationSection(
                          id: source,
                          goodsLabel: '$source 原量',
                          quantity: quantity,
                          unitName: '个',
                          allocations: const [],
                        ),
                    ],
                  );
                },
                child: const Text('打开公共确认'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开公共确认'));
    await tester.pumpAndSettle();
    final expected = financeExactSumTexts(List.filled(3, quantity));
    expect(
      find.textContaining('原始实收合计 $expected 个', findRichText: true),
      findsOneWidget,
    );
    expect(find.textContaining('原量'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('确认入库'));
    await tester.pumpAndSettle();
    expect(accepted, isTrue);
    expect(tester.takeException(), isNull);
  });
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
