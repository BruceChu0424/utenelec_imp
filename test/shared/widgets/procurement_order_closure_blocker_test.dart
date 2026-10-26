import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/procurement_order_closure.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/widgets/procurement_order_closure_blocker_action.dart';
import 'package:uten_imp/shared/widgets/procurement_order_closure_dialog.dart';
import 'package:uten_imp/shared/widgets/procurement_order_closure_batch_dialog.dart';

import '../../helpers/badge_summary_fixture.dart';

final _identity = StateProvider<AuthenticatedScope?>(
  (_) => const AuthenticatedScope(userId: 'reader-a'),
);
final _server = StateProvider<String>((_) => 'https://example.invalid/api');
final _permissions = StateProvider<Set<String>>(
  (_) => {Perm.procurementInspectionView},
);

class _Api extends ApiClient {
  _Api(this.orderType)
    : super(Dio(BaseOptions(baseUrl: 'https://example.invalid/api')));
  final String orderType;
  int previewReads = 0;
  bool resolved = false;
  Map<String, dynamic>? submitted;
  Completer<Map<String, dynamic>>? heldRead;
  Map<String, dynamic> get response => {
    'billNo': 'PRIVATE-ORDER-1',
    'fingerprint': resolved ? 'after-quality' : 'pending-quality',
    'canSubmit': resolved,
    'blockReason': resolved ? null : '还有未完成的到货质检，请先完成质检和不合格品实物处置',
    if (!resolved)
      'blocker': {
        'kind': 'QUALITY_INSPECTION',
        'orderType': orderType,
        'orderId': 'order-1',
        'documentId': 'receipt-1',
      },
    'items': [
      {
        'orderItemId': 'line-1',
        'goodsName': 'PRIVATE-GOODS',
        'remainingQty': '60',
        'remainingGiftQty': '0',
      },
    ],
  };
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    previewReads++;
    return heldRead?.future ?? response;
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/batch-preview')) {
      previewReads++;
      return {
        'items': [
          {'orderType': orderType, 'orderId': 'order-1', ...response},
        ],
      };
    }
    submitted = (body as Map).cast<String, dynamic>();
    return path.endsWith('/batch-requests')
        ? {
            'submittedCount': 1,
            'approvals': [
              {'status': 'APPROVED'},
            ],
          }
        : {'status': 'APPROVED'};
  }
}

Future<({ProviderContainer container, GoRouter router})> _mount(
  WidgetTester tester,
  _Api api, {
  Set<String> permissions = const {Perm.procurementInspectionView},
  bool settle = true,
  bool batch = false,
}) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, _) => Scaffold(
          body: TextButton(
            onPressed: () => batch
                ? showProcurementOrderClosureBatchDialog(
                    context,
                    orders: [
                      ProcurementOrderClosureTarget(
                        orderType: api.orderType,
                        orderId: 'order-1',
                      ),
                    ],
                    stillCurrent: () => true,
                  )
                : showProcurementOrderClosureDialog(
                    context,
                    orderType: api.orderType,
                    orderId: 'order-1',
                    stillCurrent: () => true,
                  ),
            child: const Text('申请结束'),
          ),
        ),
      ),
      GoRoute(
        path: '/replacement',
        builder: (_, _) => const Scaffold(body: Text('替换后的阻断单据')),
      ),
      GoRoute(
        path: '/warehouse/inspections/:type/:receiptId',
        builder: (context, state) => Scaffold(
          body: Column(
            children: [
              Text(
                '真实质检办理 ${state.pathParameters['type']}/${state.pathParameters['receiptId']}',
              ),
              TextButton(
                onPressed: () {
                  api.resolved = true;
                  context.pop();
                },
                child: const Text('完成质检后返回申请'),
              ),
            ],
          ),
        ),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        authenticatedScopeProvider.overrideWith((ref) => ref.watch(_identity)),
        apiBaseUrlProvider.overrideWith((ref) => ref.watch(_server)),
        _permissions.overrideWith((_) => permissions),
        currentPermissionsProvider.overrideWith(
          (ref) => ref.watch(_permissions),
        ),
        isSuperAdminProvider.overrideWithValue(false),
        fixedBadgeSummaryOverride(),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  final container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp)),
  );
  await tester.tap(find.text('申请结束'));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }
  return (container: container, router: router);
}

void main() {
  for (final batch in [false, true]) {
    for (final navigation in ['go', 'platform', 'replace']) {
      testWidgets('$navigation return releases closure blocker batch=$batch', (
        tester,
      ) async {
        final api = _Api('PURCHASE');
        final fixture = await _mount(tester, api, batch: batch);
        final blocker = find.byKey(
          const Key('procurement-order-closure-blocker-open'),
        );
        expect(api.previewReads, 1);
        for (var visit = 0; visit < 2; visit++) {
          expect(tester.widget<UtenButton>(blocker).onPressed, isNotNull);
          await tester.tap(blocker);
          await tester.pumpAndSettle();
          expect(find.text('真实质检办理 PURCHASE/receipt-1'), findsOneWidget);
          if (navigation == 'replace') {
            fixture.router.replace<void>('/replacement');
            await tester.pumpAndSettle();
            expect(find.text('替换后的阻断单据'), findsOneWidget);
            expect(api.previewReads, visit + 1);
            fixture.router.pop();
          } else if (navigation == 'go') {
            fixture.router.go('/');
          } else {
            await fixture.router.routeInformationProvider
                .didPushRouteInformation(RouteInformation(uri: Uri.parse('/')));
          }
          await tester.pumpAndSettle(
            const Duration(milliseconds: 100),
            EnginePhase.sendSemanticsUpdate,
            const Duration(seconds: 3),
          );
          expect(tester.widget<UtenButton>(blocker).onPressed, isNotNull);
          expect(api.previewReads, visit + 2);
        }
        expect(
          api.submitted,
          isNull,
          reason: 'Navigation never submits closure.',
        );
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final type in ['PURCHASE', 'SUBCONTRACT']) {
    testWidgets(
      '$type quality blocker preserves physical inspection and refreshes on real return',
      (tester) async {
        final api = _Api(type);
        await _mount(tester, api);
        expect(find.textContaining('质检中的实物和检验任务继续保留'), findsOneWidget);
        expect(
          tester
              .widget<UtenButton>(
                find.byKey(const Key('procurement-order-closure-submit')),
              )
              .onPressed,
          isNull,
        );
        await tester.enterText(
          find.byKey(const Key('procurement-order-closure-reason')),
          '供应商停止供货',
        );
        await tester.tap(
          find.byKey(const Key('procurement-order-closure-blocker-open')),
        );
        await tester.pumpAndSettle();
        expect(find.text('真实质检办理 $type/receipt-1'), findsOneWidget);
        await tester.tap(find.text('完成质检后返回申请'));
        await tester.pumpAndSettle();
        expect(api.previewReads, 2);
        expect(
          find.byKey(const Key('procurement-order-closure-blocker-open')),
          findsNothing,
        );
        expect(
          tester
              .widget<TextFormField>(
                find.byKey(const Key('procurement-order-closure-reason')),
              )
              .controller!
              .text,
          '供应商停止供货',
        );
        await tester.tap(
          find.byKey(const Key('procurement-order-closure-submit')),
        );
        await tester.pumpAndSettle();
        expect(api.submitted, {
          'mode': 'CLOSE',
          'reason': '供应商停止供货',
          'expectedFingerprint': 'after-quality',
        });
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'a procurement user without quality view gets an explanation without a fake department entry',
    (tester) async {
      final api = _Api('PURCHASE');
      await _mount(tester, api, permissions: {Perm.purchaseOrderView});
      expect(find.textContaining('请由有权限的品质人员'), findsOneWidget);
      expect(
        find.byKey(const Key('procurement-order-closure-blocker-open')),
        findsNothing,
      );
      expect(api.submitted, isNull);
    },
  );

  for (final boundary in ['identity', 'server', 'permission']) {
    testWidgets(
      '$boundary change removes the old private preview and rejects a late GET',
      (tester) async {
        final api = _Api('PURCHASE')
          ..heldRead = Completer<Map<String, dynamic>>();
        final fixture = await _mount(tester, api, settle: false);
        switch (boundary) {
          case 'identity':
            fixture.container.read(_identity.notifier).state =
                const AuthenticatedScope(userId: 'reader-b');
          case 'server':
            fixture.container.read(_server.notifier).state =
                'https://another.invalid/api';
          case 'permission':
            fixture.container.read(_permissions.notifier).state = {
              Perm.purchaseOrderView,
            };
        }
        await tester.pumpAndSettle();
        api.heldRead!.complete(api.response);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('procurement-order-closure-dialog')),
          findsNothing,
        );
        expect(find.textContaining('PRIVATE-ORDER-1'), findsNothing);
        expect(find.textContaining('PRIVATE-GOODS'), findsNothing);
        expect(api.submitted, isNull);
        expect(tester.takeException(), isNull);
      },
    );
  }

  test(
    'structured blockers map only to real routes and their exact view permissions',
    () {
      const cases = [
        (
          'QUALITY_INSPECTION',
          'PURCHASE',
          '/warehouse/inspections/PURCHASE/doc-1',
          Perm.procurementInspectionView,
        ),
        (
          'WAREHOUSE_IQC_RETURN',
          'SUBCONTRACT',
          '/warehouse/quality-results/SUBCONTRACT/doc-1',
          Perm.warehouseIqcReturnView,
        ),
        (
          'WAREHOUSE_RECEIPT',
          'PURCHASE',
          '/purchase/receipts/doc-1',
          Perm.purchaseReceiptView,
        ),
        (
          'WAREHOUSE_RETURN',
          'SUBCONTRACT',
          '/subcontract/returns/doc-1',
          Perm.subcontractReturnView,
        ),
        (
          'ARRIVAL_EXCEPTION',
          'PURCHASE',
          '/procurement/arrival-exceptions/doc-1',
          Perm.supplierReturnTaskView,
        ),
        (
          'FINANCE',
          'PURCHASE',
          '/finance/procurement-approvals/doc-1',
          Perm.financeOrderApprovalView,
        ),
      ];
      for (final entry in cases) {
        final blocker = ProcurementOrderClosureBlocker(
          kind: entry.$1,
          orderType: entry.$2,
          orderId: 'order-1',
          documentId: 'doc-1',
        );
        expect(procurementClosureBlockerRoute(blocker), entry.$3);
        expect(procurementClosureBlockerPermission(blocker), entry.$4);
      }
      final draw = procurementClosureBlockerRoute(
        const ProcurementOrderClosureBlocker(
          kind: 'SUBCONTRACT_DRAW',
          orderType: 'SUBCONTRACT',
          orderId: 'order-1',
        ),
      )!;
      expect(Uri.parse(draw).queryParameters, {
        'segment': 'draw',
        'orderId': 'order-1',
      });
      expect(
        procurementClosureBlockerRoute(
          const ProcurementOrderClosureBlocker(
            kind: 'UNKNOWN',
            orderType: 'PURCHASE',
            orderId: 'order-1',
          ),
        ),
        isNull,
      );
    },
  );
}
