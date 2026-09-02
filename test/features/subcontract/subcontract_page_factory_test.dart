import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/subcontract/config/subcontract_doc_config.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_business_list_pages.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_page_factory.dart';
import 'package:uten_imp/features/subcontract/services/subcontract_save_workflow.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  test(
    'factory routes all eight document families to explicit business pages',
    () {
      expect(
        SubcontractPageFactory.list(SubcontractDocType.application),
        isA<SubcontractApplicationRegisterPage>(),
      );
      expect(
        SubcontractPageFactory.list(SubcontractDocType.order),
        isA<SubcontractOrderWorkspacePage>(),
      );
      expect(
        SubcontractPageFactory.list(SubcontractDocType.receipt),
        isA<SubcontractReceiptQualityTrackingPage>(),
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

  test('new execution entry points fail closed only where an authoritative task is required', () {
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
  });

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
    'order page hides direct and decomposition actions without exact permissions',
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

      expect(find.text('直接委外下单'), findsNothing);
      expect(find.text('从申请分解下单'), findsNothing);
      expect(find.textContaining('订货不是采购收货'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'order page exposes actions only after exact view/create permissions',
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

      expect(find.text('直接委外下单'), findsOneWidget);
      expect(find.text('从申请分解下单'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'missing decompose hides only the application-source write action',
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
            currentPermissionsProvider.overrideWithValue(const {
              Perm.subcontractOrderView,
              Perm.subcontractOrderCreate,
              Perm.subcontractApplicationView,
            }),
            apiClientProvider.overrideWithValue(_api()),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('直接委外下单'), findsOneWidget);
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
