import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/feedback/uten_empty.dart';
import 'package:uten_imp/components/feedback/uten_skeleton.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_selection.dart';
import 'package:uten_imp/core/router/page_resume_provider.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/finance/pages/finance_doc_detail_page.dart';
import 'package:uten_imp/features/production/pages/production_plan_detail_page.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/pages/purchase_doc_detail_page.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/pages/sales_doc_detail_page.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_doc_detail_page.dart';
import 'package:uten_imp/shared/auth/document_scope_capability.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../support/audit_screenshot_support.dart';
import '../support/document_scope_capability_overrides.dart';

const _id = 'e65a0a91-4302-430b-adc6-f8277a947893';
const _owner = '88c21312-0a3e-4e03-a872-9acbff33cf37';

enum _Family { sales, purchase, subcontract, finance, plan }

extension on _Family {
  String get detailPath => switch (this) {
    _Family.sales => '/sales/orders/$_id',
    _Family.purchase => '/purchase/orders/$_id',
    _Family.subcontract => '/subcontract/orders/$_id',
    _Family.finance => '/finance/receipts/$_id',
    _Family.plan => '/production/plans/$_id',
  };

  Widget get page => switch (this) {
    _Family.sales => const SalesDocDetailPage(
      docType: SalesDocType.order,
      id: _id,
    ),
    _Family.purchase => const PurchaseDocDetailPage(
      docType: PurchaseDocType.order,
      id: _id,
    ),
    _Family.subcontract => const SubcontractDocDetailPage(
      docType: SubcontractDocType.order,
      id: _id,
    ),
    _Family.finance => const FinanceDocDetailPage(
      docType: FinanceDocType.receipt,
      id: _id,
    ),
    _Family.plan => const ProductionPlanDetailPage(id: _id),
  };

  DocumentDataScope get scope => switch (this) {
    _Family.sales => DocumentDataScope.sales,
    _Family.purchase => DocumentDataScope.purchase,
    _Family.subcontract => DocumentDataScope.subcontract,
    _Family.finance => DocumentDataScope.finance,
    _Family.plan => DocumentDataScope.productionPlan,
  };
}

class _DetailApi extends ApiClient {
  _DetailApi(this.family) : super(Dio());
  final _Family family;
  Completer<void>? readGate;
  Object? readError;
  int reads = 0;
  int writes = 0;
  int status = 0;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path != family.detailPath) {
      return {'items': <Object>[], 'total': 0, 'page': 1, 'size': 20};
    }
    reads++;
    await readGate?.future;
    if (readError case final error?) throw error;
    return _snapshot;
  }

  Map<String, dynamic> get _snapshot => {
    'id': _id,
    'billNo': 'DOC-${family.name}',
    'billDate': '2026-09-30',
    'makerId': _owner,
    'ownerEmployeeId': _owner,
    'makerName': '制单员',
    'createdAt': '2026-09-30T01:00:00Z',
    'status': status,
    'rowVersion': 1,
    'closed': false,
    'canEdit': true,
    'canDelete': true,
    'receiptKind': 'RECEIVABLE',
    'allowedActions': ['VIEW', 'EDIT', 'DELETE', 'APPROVE'],
    'financeApproval': {
      'status': 'DRAFT',
      'allowedActions': ['SUBMIT_FINANCE'],
    },
    'items': <Object>[],
  };

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
    if (path == '${family.detailPath}/approve') {
      writes++;
      status = 1;
      return _snapshot;
    }
    return {};
  }
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _DetailApi api, {
  Size size = const Size(1440, 1000),
  bool dark = false,
  double textScale = 1,
  GlobalKey? capture,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({'performancePreference': 'lite'});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      apiClientProvider.overrideWithValue(api),
      localServerReachableProvider.overrideWith(
        (ref) => LocalServerReachabilityNotifier(prefs, web: true),
      ),
      writeAllDocumentScope(api.family.scope),
      currentPermissionsProvider.overrideWithValue({
        Perm.salesOrderView,
        Perm.salesOrderEdit,
        Perm.salesOrderDelete,
        Perm.salesOrderApprove,
        Perm.salesOrderReverse,
        Perm.purchaseOrderView,
        Perm.purchaseOrderEdit,
        Perm.purchaseOrderDelete,
        Perm.purchaseOrderSubmitFinance,
        Perm.subcontractOrderView,
        Perm.subcontractOrderEdit,
        Perm.subcontractOrderDelete,
        Perm.subcontractOrderSubmitFinance,
        Perm.financeReceiptView,
        Perm.financeReceiptEdit,
        Perm.financeReceiptDelete,
        Perm.financeReceiptApprove,
        Perm.financeReceiptReverse,
        Perm.productionPlanView,
        Perm.productionPlanEdit,
        Perm.productionPlanDelete,
        Perm.productionPlanApprove,
      }),
      isSuperAdminProvider.overrideWithValue(false),
    ],
  );
  addTearDown(container.dispose);
  final theme = dark ? buildDarkTheme() : buildLightTheme();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: capture == null ? theme : auditScreenshotTheme(theme),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        builder: (context, child) {
          final content = MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(textScale),
              disableAnimations: true,
            ),
            child: child!,
          );
          return capture == null
              ? content
              : RepaintBoundary(key: capture, child: content);
        },
        home: api.family.page,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Finder get _scaffold => find.byType(Scaffold).first;

void main() {
  for (final family in _Family.values) {
    testWidgets(
      '${family.name} loading error and retry use shared feedback without issuing business writes',
      (tester) async {
        final api = _DetailApi(family)..readGate = Completer<void>();
        await _pump(tester, api);
        expect(find.byType(UtenSkeletonList), findsOneWidget);
        expect(tester.widget<Scaffold>(_scaffold).floatingActionButton, isNull);
        api.readError = ApiException('NETWORK', '暂时无法读取详情');
        api.readGate!.complete();
        await tester.pumpAndSettle();
        expect(find.byType(UtenEmpty), findsOneWidget);
        expect(tester.widget<Scaffold>(_scaffold).floatingActionButton, isNull);
        api.readError = null;
        api.readGate = null;
        await tester.tap(find.widgetWithText(OutlinedButton, '重试'));
        await tester.pumpAndSettle();
        expect(find.textContaining('DOC-${family.name}'), findsWidgets);
        expect(api.reads, 2);
        expect(api.writes, 0);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${family.name} failed refresh hides old actions until the new detail arrives',
      (tester) async {
        final api = _DetailApi(family);
        final container = await _pump(tester, api);
        expect(
          tester.widget<Scaffold>(_scaffold).floatingActionButton,
          isNotNull,
        );
        api.readError = ApiException('NETWORK', '暂时无法读取详情');
        if (family == _Family.finance) {
          await tester.tap(find.widgetWithText(UtenButton, '审核'));
          await tester.pumpAndSettle();
          await tester.tap(find.widgetWithText(FilledButton, '确认审核'));
        } else {
          container.read(pageRefreshRequestProvider.notifier).state++;
        }
        await tester.pumpAndSettle();
        expect(find.byType(UtenEmpty), findsOneWidget);
        expect(tester.widget<Scaffold>(_scaffold).floatingActionButton, isNull);
        api.readError = null;
        api.readGate = Completer<void>();
        await tester.tap(find.widgetWithText(OutlinedButton, '重试'));
        await tester.pump();
        expect(find.byType(UtenSkeletonList), findsOneWidget);
        expect(tester.widget<Scaffold>(_scaffold).floatingActionButton, isNull);
        api.readGate!.complete();
        await tester.pumpAndSettle();
        expect(
          tester.widget<Scaffold>(_scaffold).floatingActionButton,
          isNotNull,
        );
        expect(api.reads, 3);
        expect(api.writes, family == _Family.finance ? 1 : 0);
        expect(tester.takeException(), isNull);
      },
    );

    for (final narrow in [true, false]) {
      testWidgets(
        '${family.name} recovery action remains reachable with large text narrow=$narrow',
        (tester) async {
          final capture =
              Platform.environment['UTEN_CAPTURE_DETAIL_RECOVERY_UI'] == 'true';
          final key = capture ? GlobalKey() : null;
          if (capture) await loadAuditScreenshotFonts(tester);
          final size = narrow ? const Size(375, 844) : const Size(1440, 1000);
          final api = _DetailApi(family)
            ..readError = ApiException('NETWORK', '暂时无法读取详情');
          await _pump(
            tester,
            api,
            size: size,
            dark: !narrow,
            textScale: 1.5,
            capture: key,
          );
          final retry = find.widgetWithText(OutlinedButton, '重试');
          await tester.ensureVisible(retry);
          await tester.pumpAndSettle();
          expect(tester.getRect(retry).bottom, lessThanOrEqualTo(size.height));
          expect(
            tester.widget<Scaffold>(_scaffold).floatingActionButton,
            isNull,
          );
          expect(tester.takeException(), isNull);
          if (key != null) {
            await saveAuditScreenshot(
              tester,
              key,
              'detail-load-${family.name}-${narrow ? '375-light' : '1440-dark'}',
            );
          }
        },
      );
    }
  }
}
