import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/subcontract/config/subcontract_doc_config.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_business_list_pages.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_page_factory.dart';
import 'package:uten_imp/features/subcontract/services/subcontract_save_workflow.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  test(
    'factory routes remaining document families to explicit business pages',
    () {
      expect(
        SubcontractPageFactory.list(SubcontractDocType.order),
        isA<SubcontractOrderWorkspacePage>(),
      );
      expect(
        SubcontractPageFactory.list(SubcontractDocType.materialIssue),
        isA<SubcontractLegacyMaterialIssueHistoryPage>(),
      );
      expect(
        SubcontractPageFactory.list(SubcontractDocType.returnDoc),
        isA<SubcontractFinishedReturnHistoryPage>(),
      );
      expect(
        SubcontractPageFactory.list(SubcontractDocType.materialReturn),
        isA<SubcontractMaterialReturnHistoryPage>(),
      );
      expect(
        SubcontractPageFactory.list(SubcontractDocType.waste),
        isA<SubcontractWasteResponsibilityPage>(),
      );
      expect(
        SubcontractPageFactory.list(SubcontractDocType.inquiry),
        isA<SubcontractInquiryArchivePage>(),
      );
    },
  );

  test('retired list pages fail closed（申请并入任务中心、回厂跟踪下线）', () {
    // 2026-09-06：列表路由在 app_router 层重定向，工厂分派防御性兜底。
    expect(
      () => SubcontractPageFactory.list(SubcontractDocType.application),
      throwsUnsupportedError,
    );
    expect(
      () => SubcontractPageFactory.list(SubcontractDocType.receipt),
      throwsUnsupportedError,
    );
  });

  test(
    'new execution entry points fail closed only where an authoritative task is required',
    () {
      expect(
        SubcontractPageFactory.editor(type: SubcontractDocType.materialIssue),
        isA<SubcontractExecutionCreateBlockedPage>(),
      );
      expect(
        SubcontractPageFactory.editor(type: SubcontractDocType.receipt),
        isA<SubcontractExecutionCreateBlockedPage>(),
      );
      expect(
        SubcontractPageFactory.editor(type: SubcontractDocType.application),
        isA<SubcontractExecutionCreateBlockedPage>(),
      );
      expect(
        SubcontractPageFactory.editor(type: SubcontractDocType.inquiry),
        isA<SubcontractExecutionCreateBlockedPage>(),
      );
      expect(
        SubcontractPageFactory.editor(type: SubcontractDocType.returnDoc),
        isA<SubcontractFinishedReturnEditorPage>(),
      );
      expect(
        SubcontractPageFactory.editor(type: SubcontractDocType.materialReturn),
        isA<SubcontractMaterialReturnEditorPage>(),
      );
      expect(
        SubcontractPageFactory.editor(type: SubcontractDocType.waste),
        isA<SubcontractWasteResponsibilityEditorPage>(),
      );
    },
  );

  test('commercial permissions are exact per business page', () {
    expect(
      SubcontractDocConfig.inquiry.commercialViewPerm,
      Perm.subcontractInquiryPriceView,
    );
    expect(
      SubcontractDocConfig.order.commercialViewPerm,
      Perm.subcontractOrderPriceView,
    );
    expect(
      SubcontractDocConfig.receipt.commercialViewPerm,
      Perm.subcontractReceiptPriceView,
    );
    expect(
      SubcontractDocConfig.returnDoc.commercialViewPerm,
      Perm.subcontractReturnPriceView,
    );
    expect(
      SubcontractDocConfig.waste.commercialViewPerm,
      Perm.subcontractWasteSuggestionView,
    );
    expect(SubcontractDocConfig.application.commercialViewPerm, isNull);
    expect(SubcontractDocConfig.materialIssue.commercialViewPerm, isNull);
    expect(SubcontractDocConfig.materialReturn.commercialViewPerm, isNull);
  });

  test('order tax rate is explicit and bounded before finance submission', () {
    expect(validateSubcontractTaxRate('', required: true), isNotNull);
    expect(validateSubcontractTaxRate('0', required: true), isNull);
    expect(validateSubcontractTaxRate('13', required: true), isNull);
    expect(validateSubcontractTaxRate('-0.1', required: true), isNotNull);
    expect(validateSubcontractTaxRate('100.1', required: true), isNotNull);
    expect(
      validateSubcontractTaxRate('not-a-number', required: true),
      isNotNull,
    );
  });

  testWidgets(
    'order page hides create action without exact view/create permissions',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final router = GoRouter(
        initialLocation: '/subcontract/orders',
        routes: [
          GoRoute(
            path: '/subcontract/orders',
            builder: (_, _) => const SubcontractOrderWorkspacePage(),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentPermissionsProvider.overrideWithValue(const {}),
            apiClientProvider.overrideWithValue(_api()),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      // 2026-09-06 收口：订货页只保留「创建新委外单」（view+create 门控），
      // 从任务中心下单的入口不再重复放页头。
      expect(find.text('创建新委外单'), findsNothing);
      expect(find.byType(SubcontractOrderWorkspacePage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('order page exposes 创建新委外单 with exact view/create permissions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final router = GoRouter(
      initialLocation: '/subcontract/orders',
      routes: [
        GoRoute(
          path: '/subcontract/orders',
          builder: (_, _) => const SubcontractOrderWorkspacePage(),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentPermissionsProvider.overrideWithValue(const {
            Perm.subcontractOrderView,
            Perm.subcontractOrderCreate,
          }),
          apiClientProvider.overrideWithValue(_api()),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('创建新委外单'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('waste page headers send supplier and warehouse filters to API', (
    tester,
  ) async {
    // 损耗页两列都有（supplier + warehouse）：选桶后 repository.list 的既有
    // 参数 supplierId / warehouseId 收到字典项 id，筛选后重拉回第 1 页。
    tester.view.physicalSize = const Size(1500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _RecordingApi();
    final router = GoRouter(
      initialLocation: '/subcontract/wastes',
      routes: [
        GoRoute(
          path: '/subcontract/wastes',
          builder: (_, _) => const SubcontractWasteResponsibilityPage(),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(api)],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    // 默认不选阶段（引导占位不发请求）；点「草稿」段加载表格。
    await tester.tap(find.text('草稿'));
    await tester.pumpAndSettle();

    final table = tester.widget<MasterDataTableView<SubcontractDocListItem>>(
      find.byWidgetPredicate(
        (widget) => widget is MasterDataTableView<SubcontractDocListItem>,
      ),
    );
    expect(table.facets.keys, containsAll(<String>['supplier', 'warehouse']));
    expect(table.facets['supplier']?.single.value, 'supplier-1');
    expect(table.facets['warehouse']?.single.value, 'warehouse-1');

    api.lastQuery = null;
    table.onFilterChanged('supplier', 'supplier-1');
    await tester.pumpAndSettle();
    expect(api.lastQuery?['supplierId'], 'supplier-1');
    expect(api.lastQuery?['page'], 1);

    final refreshed = tester
        .widget<MasterDataTableView<SubcontractDocListItem>>(
          find.byWidgetPredicate(
            (widget) => widget is MasterDataTableView<SubcontractDocListItem>,
          ),
        );
    refreshed.onFilterChanged('warehouse', 'warehouse-1');
    await tester.pumpAndSettle();
    expect(api.lastQuery?['warehouseId'], 'warehouse-1');
    expect(api.lastQuery?['supplierId'], 'supplier-1');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'order page keeps single create entry regardless of decompose permission',
    (tester) async {
      // 分解权限只影响任务中心的多选下单，不再在订货页头出现第二个入口。
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final router = GoRouter(
        initialLocation: '/subcontract/orders',
        routes: [
          GoRoute(
            path: '/subcontract/orders',
            builder: (_, _) => const SubcontractOrderWorkspacePage(),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentPermissionsProvider.overrideWithValue(const {
              Perm.subcontractOrderView,
              Perm.subcontractOrderCreate,
              Perm.subcontractApplicationView,
              Perm.subcontractOrderDecompose,
            }),
            apiClientProvider.overrideWithValue(_api()),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('创建新委外单'), findsOneWidget);
      expect(find.text('从申请分解下单'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

ApiClient _api() {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        final data = request.path == '/subcontract/orders'
            ? <String, dynamic>{
                'items': const <dynamic>[],
                'page': 1,
                'size': 20,
                'total': 0,
                'totalPages': 1,
              }
            : <dynamic>[];
        handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: data,
          ),
        );
      },
    ),
  );
  return ApiClient(dio);
}

/// 记录列表请求 query 的 ApiClient（表头筛选冒烟断言用）。
class _RecordingApi extends ApiClient {
  _RecordingApi() : super(Dio());

  Map<String, dynamic>? lastQuery;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    lastQuery = query == null ? null : Map<String, dynamic>.from(query);
    return const <String, dynamic>{
      'items': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'waste-1',
          'billNo': 'WH26080001',
          'billDate': '2026-08-31',
          'supplierId': 'supplier-1',
          'warehouseId': 'warehouse-1',
          'status': 0,
        },
      ],
      'page': 1,
      'size': 20,
      'total': 1,
      'totalPages': 1,
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('suppliers')) {
      return const [
        {'id': 'supplier-1', 'name': '委外商甲'},
      ];
    }
    if (path.contains('warehouses')) {
      return const [
        {'id': 'warehouse-1', 'name': '一号仓'},
      ];
    }
    return const [];
  }
}
