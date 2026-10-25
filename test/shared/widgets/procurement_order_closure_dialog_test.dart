import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/shared/models/procurement_order_closure.dart';
import 'package:uten_imp/shared/widgets/procurement_order_closure_dialog.dart';
import 'package:uten_imp/shared/widgets/procurement_order_closure_status.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';

import '../../helpers/badge_summary_fixture.dart';
import '../../support/audit_screenshot_support.dart';

class _Api extends ApiClient {
  _Api({
    this.canSubmit = true,
    this.canReorder = true,
    this.unverifiedQuantity = false,
  }) : super(Dio());
  final bool canSubmit;
  final bool canReorder;
  final bool unverifiedQuantity;
  String? submittedPath;
  Map<String, dynamic>? submittedBody;
  Completer<void>? pending;
  int postCalls = 0;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => {
    'billNo': 'PO-OLD-1',
    'fingerprint': 'frozen-fulfillment',
    'canSubmit': canSubmit,
    'canReorder': canReorder,
    'unverifiedQuantity': unverifiedQuantity,
    'blockReorderReason': canReorder ? null : '旧库计量未核验，不能重建',
    'blockReason': canSubmit ? null : '财务审批处理中',
    'items': [
      {
        'orderItemId': 'line-1',
        'lineNo': 1,
        'goodsCode': 'G-001',
        'goodsName': '电机支架',
        'unitName': '件',
        'orderedQty': '100.0001',
        'receivedQty': '40',
        'remainingQty': unverifiedQuantity ? null : '60.0001',
        'remainingGiftQty': unverifiedQuantity ? null : '2.0001',
      },
    ],
  };

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    submittedPath = path;
    postCalls++;
    submittedBody = (body as Map).cast<String, dynamic>();
    await pending?.future;
    return {};
  }
}

Future<void> _open(
  WidgetTester tester,
  _Api api, {
  Brightness brightness = Brightness.light,
  double scale = 1,
  bool Function()? stillCurrent,
  GlobalKey? capture,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        fixedBadgeSummaryOverride(),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: brightness == Brightness.dark
            ? buildDarkTheme()
            : buildLightTheme(),
        builder: (context, child) {
          final content = MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          );
          return capture == null
              ? content
              : RepaintBoundary(key: capture, child: content);
        },
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showProcurementOrderClosureDialog(
                context,
                orderType: 'PURCHASE',
                orderId: 'order-1',
                stillCurrent: stillCurrent ?? () => true,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  for (final orderType in ['PURCHASE', 'SUBCONTRACT']) {
    for (final canEdit in [true, false]) {
      testWidgets(
        '$orderType replacement opens ${canEdit ? 'editor' : 'read-only detail'}',
        (tester) async {
          final prefix = orderType == 'PURCHASE' ? 'purchase' : 'subcontract';
          final target = '/$prefix/orders/new-order${canEdit ? '/edit' : ''}';
          String? openedPath;
          final router = GoRouter(
            routes: [
              GoRoute(
                path: '/',
                builder: (_, _) => Scaffold(
                  body: ProcurementOrderClosureStatus(
                    request: const ProcurementOrderClosureRequest(
                      caseId: 'closure-1',
                      status: 'APPROVED',
                      mode: 'CLOSE_AND_REORDER',
                      replacementOrderId: 'new-order',
                      replacementBillNo: 'PO-NEW-1',
                    ),
                    orderType: orderType,
                    canOpenReplacement: true,
                    canEditReplacement: canEdit,
                  ),
                ),
              ),
              GoRoute(
                path: target,
                builder: (_, state) {
                  openedPath = state.uri.path;
                  return const Scaffold(body: Text('replacement target'));
                },
              ),
            ],
          );
          addTearDown(router.dispose);
          await tester.pumpWidget(
            MaterialApp.router(
              routerConfig: router,
              locale: const Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.textContaining('PO-NEW-1'));
          await tester.pumpAndSettle();
          expect(openedPath, target);
          expect(find.text('replacement target'), findsOneWidget);
        },
      );
    }
  }

  test(
    'closure quantities preserve exact digits and missing fingerprint fails closed',
    () {
      final preview = ProcurementOrderClosurePreview.fromJson({
        'canSubmit': true,
        'items': [
          {'remainingQty': '999999999999.9999'},
        ],
      });
      expect(preview.canSubmit, isFalse);
      expect(preview.items.single.remainingQty, '999999999999.9999');
    },
  );

  test(
    'ending projection stays separate from effective commercial approval',
    () {
      final json = <String, dynamic>{
        'id': 'old-order',
        'status': 1,
        'closed': false,
        'financeApproval': {'status': 'APPROVED', 'attempt': 1, 'version': 2},
        'closureRequest': {
          'caseId': 'closure-1',
          'status': 'PENDING',
          'mode': 'CLOSE',
          'reason': '停止供货',
        },
      };
      final purchase = PurchaseDocDetail.fromJson(json);
      final subcontract = SubcontractDocDetail.fromJson(json);
      expect(purchase.financeApproval!.isApproved, isTrue);
      expect(purchase.closureRequest!.isPending, isTrue);
      expect(subcontract.financeApproval!.isApproved, isTrue);
      expect(subcontract.closureRequest!.isPending, isTrue);
      expect(purchase.closed, isFalse);
      expect(subcontract.closed, isFalse);
    },
  );

  testWidgets(
    'requires reason and submits remaining reorder request with reviewed fingerprint',
    (tester) async {
      final api = _Api();
      await _open(tester, api);
      final submit = find.byKey(const Key('procurement-order-closure-submit'));
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(api.submittedBody, isNull);
      expect(
        tester
            .state<FormFieldState<String>>(
              find.byKey(const Key('procurement-order-closure-reason')),
            )
            .errorText,
        '请填写结束原因',
      );
      await tester.ensureVisible(find.text('结束并重新生成剩余订单'));
      await tester.tap(find.text('结束并重新生成剩余订单'));
      await tester.enterText(
        find.byKey(const Key('procurement-order-closure-reason')),
        '  供应商停止供货  ',
      );
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(
        api.submittedPath,
        '/finance/procurement-approvals/orders/PURCHASE/order-1/closure-requests',
      );
      expect(api.submittedBody, {
        'mode': 'CLOSE_AND_REORDER',
        'reason': '供应商停止供货',
        'expectedFingerprint': 'frozen-fulfillment',
      });
      expect(
        find.byKey(const Key('procurement-order-closure-dialog')),
        findsNothing,
      );
    },
  );

  testWidgets('server block prevents submission', (tester) async {
    final api = _Api(canSubmit: false);
    await _open(tester, api);
    expect(find.text('财务审批处理中'), findsOneWidget);
    final button = tester.widget<UtenButton>(
      find.byKey(const Key('procurement-order-closure-submit')),
    );
    expect(button.onPressed, isNull);
    expect(api.submittedBody, isNull);
  });

  testWidgets(
    'closure request explains receipt and quality finality before submission',
    (tester) async {
      await _open(tester, _Api());
      expect(find.text('结束前请办清收退货和质检处置；批准后不能直接更改原单已核定实收。'), findsOneWidget);
      expect(
        find.byKey(const Key('procurement-order-closure-submit')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'unverified legacy quantities allow only direct end and stay unknown',
    (tester) async {
      final api = _Api(canReorder: false, unverifiedQuantity: true);
      await _open(tester, api);
      expect(find.textContaining('本单旧库计量未核验'), findsOneWidget);
      expect(find.text('旧库计量未核验，不能重建'), findsOneWidget);
      final reorder = tester.widget<RadioListTile<String>>(
        find.byWidgetPredicate(
          (widget) =>
              widget is RadioListTile<String> &&
              widget.value == 'CLOSE_AND_REORDER',
        ),
      );
      expect(reorder.enabled, isFalse);
      expect(find.textContaining('剩余订货量: —'), findsOneWidget);
      await tester.ensureVisible(find.text('结束并重新生成剩余订单'));
      await tester.tap(find.text('结束并重新生成剩余订单'));
      await tester.enterText(
        find.byKey(const Key('procurement-order-closure-reason')),
        '历史迁移单停止履约',
      );
      await tester.tap(
        find.byKey(const Key('procurement-order-closure-submit')),
      );
      await tester.pumpAndSettle();
      expect(api.submittedBody!['mode'], 'CLOSE');
    },
  );

  testWidgets(
    'direct end stays busy until receipt and does not dispatch twice',
    (tester) async {
      final api = _Api()..pending = Completer<void>();
      await _open(tester, api);
      await tester.enterText(
        find.byKey(const Key('procurement-order-closure-reason')),
        '历史单不再执行',
      );
      final submit = find.byKey(const Key('procurement-order-closure-submit'));
      await tester.tap(submit);
      await tester.pump();
      await tester.tap(submit);
      await tester.pump();
      expect(api.postCalls, 1);
      expect(api.submittedBody!['mode'], 'CLOSE');
      expect(tester.widget<UtenButton>(submit).isLoading, isTrue);
      api.pending!.complete();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('procurement-order-closure-dialog')),
        findsNothing,
      );
    },
  );

  testWidgets('identity change during confirmation prevents command dispatch', (
    tester,
  ) async {
    final api = _Api();
    var current = true;
    await _open(tester, api, stillCurrent: () => current);
    await tester.enterText(
      find.byKey(const Key('procurement-order-closure-reason')),
      '停止供货',
    );
    current = false;
    await tester.tap(find.byKey(const Key('procurement-order-closure-submit')));
    await tester.pumpAndSettle();
    expect(api.submittedBody, isNull);
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('narrow closure dialog fits $brightness at $scale', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(320, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        const captureUi = bool.fromEnvironment('UTEN_CAPTURE_UI');
        final capture = captureUi ? GlobalKey() : null;
        if (captureUi) await loadAuditScreenshotFonts(tester);
        await _open(
          tester,
          _Api(),
          brightness: brightness,
          scale: scale,
          capture: capture,
        );
        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const Key('procurement-order-closure-dialog')),
          findsOneWidget,
        );
        expect(find.textContaining('60.0001'), findsOneWidget);
        if (capture != null) {
          await saveAuditScreenshot(
            tester,
            capture,
            'procurement-closure-${brightness.name}-$scale',
          );
        }
      });
      testWidgets(
        'closure progress and replacement action fit $brightness at $scale',
        (tester) async {
          tester.view.physicalSize = const Size(320, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(
            MaterialApp(
              theme: brightness == Brightness.dark
                  ? buildDarkTheme()
                  : buildLightTheme(),
              locale: const Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: MediaQuery(
                  data: MediaQueryData(
                    size: const Size(320, 900),
                    textScaler: TextScaler.linear(scale),
                  ),
                  child: const SingleChildScrollView(
                    child: ProcurementOrderClosureStatus(
                      request: ProcurementOrderClosureRequest(
                        caseId: 'closure-1',
                        status: 'APPROVED',
                        mode: 'CLOSE_AND_REORDER',
                        reason: '供应商停止供货',
                        replacementOrderId: 'new-order',
                        replacementBillNo: 'PO-20261025-001',
                      ),
                      orderType: 'PURCHASE',
                      canOpenReplacement: true,
                      canOpenReview: true,
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text('结束已批准'), findsOneWidget);
          expect(find.textContaining('PO-20261025-001'), findsOneWidget);
        },
      );
    }
  }
}
