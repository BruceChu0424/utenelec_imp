import 'dart:ui' show PointerDeviceKind, SemanticsAction;
import '../../support/finance_command_test_support.dart'
    show tapFinanceOriginalAction;
import '../../support/finance_document_command_fixture.dart';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/components/layout/uten_collapsible_section.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/router/app_router.dart';
import 'package:uten_imp/core/router/permission_by_path.dart';
import 'package:uten_imp/core/performance/json_value_snapshot.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/features/finance/config/finance_doc_config.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/finance/models/finance_entry_request.dart';
import 'package:uten_imp/features/finance/widgets/finance_batch_recovery_panel.dart';
import 'package:uten_imp/features/finance/providers/finance_name_provider.dart';
import 'package:uten_imp/features/finance/pages/finance_doc_edit_page.dart';
import 'package:uten_imp/features/finance/widgets/finance_grid_columns.dart';
import 'package:uten_imp/shared/drafts/form_draft_mixin.dart';
import 'package:uten_imp/shared/drafts/form_draft_navigation.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/formatters/exact_decimal.dart';
import '../../support/native_detail_reader_overrides.dart';
import '../../support/document_scope_capability_overrides.dart';
import '../../shared/drafts/memory_form_draft_storage.dart';
import '../../support/audit_screenshot_support.dart';
import '../../support/uten_test_actions.dart';
import '../../support/finance_dropdown_dom_stub.dart'
    if (dart.library.js_interop) '../../support/finance_dropdown_dom_web.dart'
    as dropdown_dom;

final _batchPermissions = StateProvider<Set<String>>(
  (_) => {
    for (final type in FinanceDocType.values) ...{
      FinanceDocConfig.by(type).createPerm!,
      FinanceDocConfig.by(type).listPerm,
    },
  },
);

const _captureReceiptFlows = bool.fromEnvironment('UTEN_CAPTURE_RECEIPT_FLOW');

void main() {
  for (final selectionMode in [
    'touch',
    'mouse-hover',
    'semantics',
    'width-during-menu',
    'browser-dom',
  ]) {
    testWidgets(
      'actual expense batch account then exact amount then currency and method retain selected source values ($selectionMode)',
      (tester) async {
        final semantics = ['semantics', 'browser-dom'].contains(selectionMode)
            ? tester.ensureSemantics()
            : null;
        try {
          final backend = _Api()..financialMethods = true;
          final env = await _open(
            tester,
            FinanceDocType.expense,
            backend: backend,
            size: const Size(1280, 900),
          );
          await tester.tap(find.widgetWithText(UtenButton, '选择费用账户'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('人民币账户').first);
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const Key('finance-account-picker-confirm')),
          );
          await tester.pumpAndSettle();
          final row = _table(tester).controller.rows.single;
          expect(row.entry.accountId, 'account-cny');
          const amount = '2.000000000000000000000001';
          final amountField = find.byWidgetPredicate(
            (widget) =>
                widget is TextField && identical(widget.controller, row.amount),
          );
          await tester.ensureVisible(amountField);
          await tester.enterText(
            amountField,
            selectionMode == 'width-during-menu' ? '2' : amount,
          );
          await tester.pumpAndSettle();
          Finder field(String hint) => find.byWidgetPredicate(
            (widget) => widget is UtenDropdownField && widget.hintText == hint,
          );
          Future<void> select(String hint, String label) async {
            await tester.ensureVisible(field(hint));
            await tester.pumpAndSettle();
            await tester.tap(field(hint));
            await tester.pumpAndSettle();
            if (selectionMode == 'width-during-menu' && hint == '选择币种') {
              row.amount.text = amount;
              await tester.pumpAndSettle();
            }
            final owner = tester.widget<UtenDropdownField>(field(hint));
            final item = owner.items.singleWhere(
              (item) => item.label == label && item.enabled && item.visible,
            );
            final choice = find.byKey(
              ValueKey(('uten-dropdown-option', owner.key, item.value)),
            );
            expect(choice, findsOneWidget);
            if (selectionMode == 'browser-dom') {
              await tester.runAsync(() async {
                dropdown_dom.clickFinanceDropdownDomOption(label);
                await Future<void>.delayed(const Duration(milliseconds: 20));
              });
            } else if (selectionMode == 'semantics') {
              final node = tester.getSemantics(choice);
              expect(
                node.getSemanticsData().hasAction(SemanticsAction.tap),
                isTrue,
              );
              node.owner!.performAction(node.id, SemanticsAction.tap);
            } else if (selectionMode == 'mouse-hover') {
              final mouse = await tester.createGesture(
                kind: PointerDeviceKind.mouse,
              );
              await mouse.addPointer(location: Offset.zero);
              await mouse.moveTo(tester.getCenter(choice));
              await tester.pump(const Duration(seconds: 1));
              await tester.tap(choice, kind: PointerDeviceKind.mouse);
              await mouse.removePointer();
            } else {
              await tester.tap(choice);
            }
            await tester.pumpAndSettle();
          }

          await select('选择币种', '人民币');
          expect(
            identical(row, _table(tester).controller.rows.single),
            isTrue,
            reason: 'selection must update the live source row',
          );
          expect(row.entry.currencyId, 'cny');
          expect(row.exchangeRate.text, '1');
          expect(tester.widget<UtenDropdownField>(field('选择币种')).value, 'cny');
          expect(row.amount.text, amount);
          expect(find.textContaining('未选币种'), findsNothing);
          await select('选择付款方式', '银行转账');
          expect(row.entry.methodId, 'method');
          expect(
            tester.widget<UtenDropdownField>(field('选择付款方式')).value,
            'method',
          );
          expect(backend.bodies, isEmpty);
          await env.close(tester);
        } finally {
          semantics?.dispose();
        }
      },
      skip:
          selectionMode == 'browser-dom' &&
          !dropdown_dom.financeDropdownDomAvailable,
    );
  }

  testWidgets(
    'rejected dispatched batch stays sealed through GET false and lost cancel, then explicit new review preserves every row and exact amount',
    (tester) async {
      final backend = _Api()
        ..reject = true
        ..loseCancel = true;
      final storage = MemoryFormDraftStorage();
      var env = await _open(
        tester,
        FinanceDocType.payment,
        backend: backend,
        storage: storage,
      );
      _payment(
        _table(tester).controller[0],
        'supplier-A',
        'ledger-1',
        '0.000000000000000000000001',
      );
      await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
      await tester.pumpAndSettle();
      final original = Map<String, dynamic>.from(backend.bodies.single);
      final draft = env.container.read(formDraftsProvider).single;
      expect(draft.hasUnknownSubmission, isTrue);
      expect(find.text('重试原批次'), findsOneWidget);
      await tapFinanceOriginalAction(tester, '核对原批次结果');
      await tester.pumpAndSettle();
      expect(
        env.container.read(formDraftsProvider).single.hasUnknownSubmission,
        isTrue,
      );
      await tapFinanceOriginalAction(tester, '核实未写并保留输入');
      await tester.pumpAndSettle();
      expect(
        env.container.read(formDraftsProvider).single.hasUnknownSubmission,
        isTrue,
      );
      expect(
        jsonValuesEqual(backend.cancellations.single['requestBody'], original),
        isTrue,
      );
      await env.close(tester);
      env = await _open(
        tester,
        FinanceDocType.payment,
        backend: backend,
        storage: storage,
        location: draft.resumeLocation,
      );
      await tapFinanceOriginalAction(tester, '核对原批次结果');
      await tester.pumpAndSettle();
      expect(
        _table(tester).controller.rows.single.amount.text,
        '0.000000000000000000000001',
      );
      expect(
        env.container.read(formDraftsProvider).single.hasUnknownSubmission,
        isFalse,
      );
      expect(
        env.container
            .read(formDraftsProvider)
            .single
            .data['createIdempotencyKey'],
        original['idempotencyKey'],
      );
      backend.reject = false;
      await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
      await tester.pumpAndSettle();
      expect(find.text('核对新批次'), findsOneWidget);
      expect(backend.bodies, hasLength(1));
      await tester.tap(find.text('确认保存新批次'));
      await tester.pumpAndSettle();
      expect(backend.bodies, hasLength(2));
      expect(
        backend.bodies.last['idempotencyKey'],
        isNot(original['idempotencyKey']),
      );
      final entry = (backend.bodies.last['documents'] as List).single as Map;
      expect(
        ((entry['items'] as List).single as Map)['amountOriginal'],
        '0.000000000000000000000001',
      );
      expect(backend.commits, 1);
      await expectLater(
        backend.post('/finance/payments/batch', body: original),
        throwsA(isA<ApiException>()),
      );
      expect(backend.commits, 1);
      expect(find.text('已完成'), findsOneWidget);
      await env.close(tester);
    },
  );

  testWidgets(
    'batch success lost reply is adopted from legacy original-body proof without another create',
    (tester) async {
      final backend = _Api()
        ..timeout = true
        ..commitBeforeTimeout = true
        ..legacyBody = true;
      final env = await _open(tester, FinanceDocType.payment, backend: backend);
      _payment(
        _table(tester).controller[0],
        'supplier-A',
        'ledger-1',
        '12.000000000000000000000001',
      );
      await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
      await tester.pumpAndSettle();
      expect(backend.commits, 1);
      await tapFinanceOriginalAction(tester, '核对原批次结果');
      await tester.pumpAndSettle();
      expect(backend.bodies, hasLength(1));
      expect(backend.cancellations, hasLength(1));
      expect(backend.commits, 1);
      expect(find.text('已完成'), findsOneWidget);
      await env.close(tester);
    },
  );

  testWidgets(
    'loss of create retains a private family-view recovery through the real application guard and builder',
    (tester) async {
      final backend = _Api()..reject = true;
      final storage = MemoryFormDraftStorage();
      var env = await _open(
        tester,
        FinanceDocType.payment,
        backend: backend,
        storage: storage,
      );
      _payment(
        _table(tester).controller[0],
        'supplier-A',
        'ledger-1',
        '91.000000000000000000000001',
      );
      await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
      await tester.pumpAndSettle();
      final original = Map<String, dynamic>.from(backend.bodies.single);
      await env.close(tester);
      env = await _open(
        tester,
        FinanceDocType.payment,
        backend: backend,
        storage: storage,
        permissions: {FinanceDocConfig.payment.listPerm},
        productionGuard: true,
      );
      await env.container.read(formDraftsProvider.notifier).ready;
      final projected = env.container.read(formDraftsProvider).single;
      expect(projected.data[financeBatchReadRecoveryOnlyKey], isTrue);
      expect(projected.data.containsKey('rows'), isFalse);
      expect(projected.data.containsKey('attachments'), isFalse);
      expect(projected.data.containsKey('batchCommand'), isFalse);
      expect(
        projected.resumeLocation,
        contains('/finance/payments/batch-recovery'),
      );
      expect(
        requiredAnyPermFor(projected.resumeLocation),
        contains(FinanceDocConfig.payment.listPerm),
      );
      env.router.go(projected.resumeLocation);
      await tester.pumpAndSettle();
      expect(find.byType(FinanceBatchRecoveryPage), findsOneWidget);
      expect(find.byType(FinanceDocEditPage), findsNothing);
      expect(find.text('91.000000000000000000000001'), findsNothing);
      expect(backend.bodies, hasLength(1));
      await tapFinanceOriginalAction(tester, '核实未写并保留输入');
      await tester.pumpAndSettle();
      final raw = await env.container
          .read(formDraftsProvider.notifier)
          .readFinanceBatchRecovery(projected.id);
      expect(raw!.data['batchCommand'], isNull);
      expect(raw.data['batchNeedsReview'], isTrue);
      expect(
        ((raw.data['rows'] as List).single as Map)['amount'],
        '91.000000000000000000000001',
      );
      expect(raw.data['createIdempotencyKey'], original['idempotencyKey']);
      expect(find.text('返回原输入核对新批次'), findsNothing);
      expect(backend.commits, 0);
      expect(backend.bodies, hasLength(1));
      expect(tester.takeException(), isNull);
      await env.close(tester);
    },
  );

  testWidgets(
    'legacy receipt editor selects a physical batch, preserves its old source and saves a partial receipt',
    (tester) async {
      final env = await _open(tester, FinanceDocType.receipt, legacy: true);
      expect(_table(tester).controller.rows.single.appliedLedgerId, 'old-ar');
      final action = find.byKey(const ValueKey('receipt-import-ar'));
      await tester.ensureVisible(action);
      await tester.tap(action);
      await tester.pumpAndSettle();
      await _chooseShipmentBatch(tester, 'shared-ar', '200');
      final rows = _table(tester).controller.rows;
      expect(rows, hasLength(2));
      expect(rows.first.appliedLedgerId, 'old-ar');
      expect(rows.last.appliedLedgerId, 'shared-ar');
      expect(rows.last.requestedSalesOrderId, isNull);
      expect(
        financeAmountUnits(rows.last.amount.text),
        financeAmountUnits('200'),
      );
      final section = find.byKey(
        const ValueKey('finance-receipt-settlement-fees'),
      );
      await tester.ensureVisible(section);
      await tester.pumpAndSettle();
      final value = tester.widget<UtenCollapsibleSection>(section);
      if (!(value.expanded ?? value.initiallyExpanded)) {
        await tester.tap(
          find.descendant(of: section, matching: find.text(value.title)),
        );
        await tester.pumpAndSettle();
      }
      final actual = find.byKey(
        const ValueKey('finance-receipt-account-amount'),
      );
      await tester.ensureVisible(actual);
      await tester.pumpAndSettle();
      await tester.enterText(actual, '300');
      await tester.tap(find.text('保存').hitTestable());
      await tester.pumpAndSettle();
      expect(env.api.putBodies, hasLength(1));
      final payload = env.api.putBodies.single;
      final frozen = env.api.putCommands.single;
      expect(frozen['expectedVersion'], 0);
      expect(
        frozen['expectedSnapshot'],
        env.api.legacyReceipt['approvalSnapshot'],
      );
      expect(frozen['requestId'], isA<String>());
      expect(frozen['document'], payload);
      expect(payload['bankReference'], 'LEGACY-BANK');
      expect(payload['expectedVersion'], 0);
      expect(
        ((payload['items'] as List).last as Map)['appliedLedgerId'],
        'shared-ar',
      );
      expect(
        ((payload['items'] as List).last as Map).containsKey(
          'requestedSalesOrderId',
        ),
        isFalse,
      );
      expect(find.text('已完成'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await env.close(tester);
    },
  );
  testWidgets(
    'ordinary receipt explicitly chooses one shipment batch and amount400 without consuming the same orders other batch',
    (tester) async {
      final capture = _captureReceiptFlows ? GlobalKey() : null;
      final env = await _open(
        tester,
        FinanceDocType.receipt,
        overlayCapture: capture,
      );
      expect(
        _table(
          tester,
        ).columns.singleWhere((c) => c.key == 'entryMethod').required,
        _captureReceiptFlows,
      );
      final row = _table(tester).controller.rows.single;
      row.entry.accountId = 'account-cny';
      row.entry.methodId = 'method';
      await env.container.read(financeNameServiceProvider).loadClientNames([
        '00000000-0000-0000-0000-0000000000aa',
      ]);
      row.entry.touch();
      await tester.pumpAndSettle();
      await tester.tap(find.text('按出货单收款').first);
      await tester.pumpAndSettle();
      await _chooseShipmentBatch(tester, 'shared-ar', '', capture: capture);
      final imported = _table(tester).controller.rows.single;
      expect(imported.appliedLedgerId, 'shared-ar');
      expect(imported.entry.partyId, '00000000-0000-0000-0000-0000000000aa');
      expect(imported.entry.partyName, '客户甲');
      expect(imported.requestedSalesOrderId, isNull);
      expect(imported.amount.text, isEmpty);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(env.api.bodies, isEmpty);
      final amountField = find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            identical(widget.controller, imported.amount),
      );
      final revealing = _table(
        tester,
      ).controller.revealError(imported, columnKey: 'amount');
      await tester.pumpAndSettle();
      await revealing;
      await tester.enterText(amountField, '400');
      await tester.pumpAndSettle();
      expect(
        financeAmountUnits(imported.amount.text),
        financeAmountUnits('400'),
      );
      if (capture != null) {
        await _secondCaptureRow(tester, deposit: false);
        await _blurReceiptCapture(tester);
        await saveAuditScreenshot(tester, capture, 'receipt-flow-partial-400');
      }
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      final doc = Map<String, dynamic>.from(
        (env.api.bodies.single['documents'] as List).first as Map,
      );
      final line = Map<String, dynamic>.from(
        (doc['items'] as List).single as Map,
      );
      expect(line['appliedLedgerId'], 'shared-ar');
      expect(
        financeAmountUnits(line['amountOriginal']?.toString()),
        financeAmountUnits('400'),
      );
      expect(line.containsKey('requestedSalesOrderId'), isFalse);
      expect(
        financeAmountUnits(doc['accountAmount']?.toString()),
        financeAmountUnits('400'),
      );
      expect(env.api.collectionReads, isEmpty);
      expect(tester.takeException(), isNull);
      await env.close(tester);
    },
  );
  testWidgets(
    'explicit order deposit accepts real1000 for order735 without silently routing through ordinary AR auto allocation',
    (tester) async {
      final capture = _captureReceiptFlows ? GlobalKey() : null;
      final env = await _open(
        tester,
        FinanceDocType.receipt,
        overlayCapture: capture,
        extraPermissions: const {
          Perm.financeViewAll,
          Perm.customerPrepaymentView,
        },
      );
      final row = _table(tester).controller.rows.single;
      row.entry.accountId = 'account-cny';
      row.entry.methodId = 'method';
      row.amount.text = '1000';
      row.entry.bankReference.text = 'BANK-DEPOSIT-1000';
      row.entry.touch();
      await tester.pumpAndSettle();
      final revealing = _table(
        tester,
      ).controller.revealError(row, columnKey: 'entryKind');
      await tester.pumpAndSettle();
      await revealing;
      await tester.tap(find.text('出货收款').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('订单预收（定金/多付）').last);
      await tester.pumpAndSettle();
      final source = _table(
        tester,
      ).controller.revealError(row, columnKey: 'entrySource');
      await tester.pumpAndSettle();
      await source;
      await tester.tap(find.text('选订货单').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('XD-B').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定').last);
      await tester.pumpAndSettle();
      expect(row.entry.salesOrderId, 'order-B');
      expect(row.amount.text, '1000');
      expect(row.appliedLedgerId, isNull);
      expect(env.api.collectionReads, isEmpty);
      if (capture != null) {
        await _secondCaptureRow(tester, deposit: true);
        final kindVisible = _table(
          tester,
        ).controller.revealError(row, columnKey: 'entryKind');
        await tester.pumpAndSettle();
        await kindVisible;
        await _blurReceiptCapture(tester);
        await saveAuditScreenshot(
          tester,
          capture,
          'receipt-flow-order-prepayment-mode-full',
        );
        final visible = _table(
          tester,
        ).controller.revealError(row, columnKey: 'amount');
        await tester.pumpAndSettle();
        await visible;
        await _blurReceiptCapture(tester);
        await saveAuditScreenshot(
          tester,
          capture,
          'receipt-flow-order-prepayment-1000',
        );
      }
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      final doc = Map<String, dynamic>.from(
        (env.api.bodies.single['documents'] as List).first as Map,
      );
      expect(doc['receiptKind'], 'CUSTOMER_PREPAYMENT');
      expect(doc['salesOrderId'], 'order-B');
      expect(doc['amountOriginal'], '1000');
      expect(doc['items'], isEmpty);
      expect(tester.takeException(), isNull);
      await env.close(tester);
    },
  );
  testWidgets('shipment receipt fee200-10-190 preserves actual bank facts', (
    tester,
  ) async {
    final capture = _captureReceiptFlows ? GlobalKey() : null;
    final env = await _open(
      tester,
      FinanceDocType.receipt,
      overlayCapture: capture,
    );
    final row = _table(tester).controller.rows.single;
    row.entry.accountId = 'account-cny';
    row.entry.methodId = 'method';
    row.entry.bankReference.text = 'BANK-200-10-190';
    row.entry.touch();
    await tester.pumpAndSettle();
    await tester.tap(find.text('按出货单收款').first);
    await tester.pumpAndSettle();
    await _chooseShipmentBatch(tester, 'shared-ar', '200');
    final imported = _table(tester).controller.rows.single;
    if (capture != null) {
      await _secondCaptureRow(tester, deposit: false);
    }
    final revealing = _table(
      tester,
    ).controller.revealError(imported, columnKey: 'entrySettings');
    await tester.pumpAndSettle();
    await revealing;
    await tester.tap(find.text('设置').first);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('finance-entry-settlement-fee')),
      '10',
    );
    await tester.enterText(
      find.byKey(const ValueKey('finance-entry-settlement-account-amount')),
      '190',
    );
    await tester.pumpAndSettle();
    if (capture != null) {
      await saveAuditScreenshot(
        tester,
        capture,
        'receipt-flow-bank-fee-200-10-190',
      );
    }
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final doc = Map<String, dynamic>.from(
      (env.api.bodies.single['documents'] as List).first as Map,
    );
    expect(
      financeAmountUnits(doc['accountAmount']?.toString()),
      financeAmountUnits('190'),
    );
    expect(
      financeAmountUnits(doc['bankFeeAccountAmount']?.toString()),
      financeAmountUnits('10'),
    );
    final item = (doc['items'] as List).single as Map;
    expect(item['appliedLedgerId'], 'shared-ar');
    expect(
      financeAmountUnits(item['amountOriginal']?.toString()),
      financeAmountUnits('200'),
    );
    expect(item.containsKey('requestedSalesOrderId'), isFalse);
    expect(tester.takeException(), isNull);
    await env.close(tester);
  });
  testWidgets(
    'ordinary receipts keep two chosen batches in one document and preserve a verified independent opening source',
    (tester) async {
      final env = await _open(tester, FinanceDocType.receipt);
      env.api.independentSource = true;
      final row = _table(tester).controller.rows.single;
      row.entry.accountId = 'account-cny';
      row.entry.methodId = 'method';
      row.entry.touch();
      await tester.pumpAndSettle();
      await tester.tap(find.text('按出货单收款').first);
      await tester.pumpAndSettle();
      await _chooseShipmentBatch(tester, 'shared-ar', '400');
      await tester.tap(find.text('按出货单收款').first);
      await tester.pumpAndSettle();
      await _chooseShipmentBatch(tester, 'opening-ar', '125');
      final rows = _table(tester).controller.rows;
      expect(rows, hasLength(2));
      expect(rows.map((r) => r.requestedSalesOrderId), everyElement(isNull));
      final opening = rows.singleWhere(
        (r) => r.appliedLedgerId == 'opening-ar',
      );
      expect(opening.sourceDocType, 'OPENING');
      expect(opening.sourceDocNo, '期初-已核验');
      opening.entry.accountId = 'account-cny';
      opening.entry.methodId = 'method';
      opening.entry.touch();
      await tester.pumpAndSettle();
      final draft =
          (tester.state(find.byType(FinanceDocEditPage))
                  as FormDraftMixin<FinanceDocEditPage>)
              .captureFormDraftSnapshot();
      expect(jsonEncode(draft), contains('期初-已核验'));
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      final docs = env.api.bodies.single['documents'] as List;
      final groups = docs
          .cast<Map<String, dynamic>>()
          .map(financeEntryGroupKey)
          .toSet();
      expect(groups, hasLength(1));
      final items = docs
          .expand((d) => (d as Map)['items'] as List)
          .cast<Map<String, dynamic>>();
      expect(
        items.map((i) => i['appliedLedgerId']),
        unorderedEquals(['shared-ar', 'opening-ar']),
      );
      expect(
        items.every((i) => !i.containsKey('requestedSalesOrderId')),
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await env.close(tester);
    },
  );
  for (final width in [375.0, 1440.0]) {
    testWidgets(
      'receipt settlement compact panel keeps amount and cancel accessible at width$width',
      (tester) async {
        final capture = _captureReceiptFlows && width == 375
            ? GlobalKey()
            : null;
        final env = await _open(
          tester,
          FinanceDocType.receipt,
          size: Size(width, 960),
          overlayCapture: capture,
        );
        final row = _table(tester).controller.rows.single;
        _payment(
          row,
          '00000000-0000-0000-0000-0000000000aa',
          'shared-ar',
          '200',
        );
        row.sourceDocNo = 'XC-1000-A';
        row.entry.fee.text = '10';
        await tester.pumpAndSettle();
        final revealing = _table(
          tester,
        ).controller.revealError(row, columnKey: 'entrySettings');
        await tester.pumpAndSettle();
        await revealing;
        await tester.tap(find.text('设置').first);
        await tester.pumpAndSettle();
        final actual = find.byKey(
          const ValueKey('finance-entry-settlement-account-amount'),
        );
        final fee = find.byKey(const ValueKey('finance-entry-settlement-fee'));
        final a = tester.getRect(actual), f = tester.getRect(fee);
        if (width == 375) {
          expect(a.left, f.left);
          expect(a.bottom, lessThan(f.top));
        } else {
          expect(a.top, f.top);
          expect(a.left, greaterThan(width - 840));
        }
        expect(a.right, lessThanOrEqualTo(width));
        expect(find.text('保存设置').hitTestable(), findsOneWidget);
        await tester.enterText(actual, '190');
        await tester.pumpAndSettle();
        if (capture != null) {
          await saveAuditScreenshot(
            tester,
            capture,
            'receipt-flow-settings-375',
          );
        }
        await tester.tap(find.text('取消').last);
        await tester.pumpAndSettle();
        expect(row.entry.accountAmount.text, isEmpty);
        expect(row.entry.fee.text, '10');
        expect(tester.takeException(), isNull);
        await env.close(tester);
      },
    );
  }
  for (final width in [375.0, 1440.0]) {
    testWidgets(
      'shipment source full-width footer preserves cancel and explicit multi-selection at width$width',
      (tester) async {
        final env = await _open(
          tester,
          FinanceDocType.receipt,
          size: Size(width, 960),
        );
        final original = _table(tester).controller.rows.single;
        original.amount.text = '77';
        original.entry.accountAmount.text = '70';
        await tester.pumpAndSettle();
        await tester.tap(find.text('按出货单收款').first);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('ar-ap-select-shared-ar')));
        await tester.pumpAndSettle();
        final footer = tester.getRect(
          find.byKey(const ValueKey('ar-ap-footer')),
        );
        final summary = tester.getRect(
          find.byKey(const ValueKey('ar-ap-selection-summary')),
        );
        final confirm = tester.getRect(
          find.byKey(const ValueKey('ar-ap-confirm')),
        );
        expect(footer.right, closeTo(width, 1));
        expect(footer.width, greaterThan(width == 375 ? 370 : 1000));
        expect(confirm.right, lessThanOrEqualTo(footer.right));
        if (width == 1440) {
          expect(confirm.left, greaterThan(summary.left));
        }
        expect(find.text('已选 1 行'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('ar-ap-cancel')));
        await tester.pumpAndSettle();
        expect(original.appliedLedgerId, isNull);
        expect(original.amount.text, '77');
        expect(original.entry.accountAmount.text, '70');
        original.amount.clear();
        original.entry.accountAmount.clear();
        original.entry.touch();
        await tester.pumpAndSettle();
        await tester.tap(find.text('按出货单收款').first);
        await tester.pumpAndSettle();
        for (final id in ['shared-ar', 'second-ar']) {
          final select = find.byKey(ValueKey('ar-ap-select-$id'));
          await tester.ensureVisible(select);
          await tester.pumpAndSettle();
          await tester.tap(select);
          await tester.pumpAndSettle();
        }
        expect(find.text('已选 2 行'), findsOneWidget);
        for (final entry in {'shared-ar': '400', 'second-ar': '200'}.entries) {
          final field = find.byKey(ValueKey('ar-ap-amount-${entry.key}'));
          await tester.ensureVisible(field);
          await tester.pumpAndSettle();
          await tester.enterText(field, entry.value);
        }
        await tester.tap(find.byKey(const ValueKey('ar-ap-confirm')));
        await tester.pumpAndSettle();
        final rows = _table(tester).controller.rows;
        expect(
          rows.map((r) => r.appliedLedgerId),
          unorderedEquals(['shared-ar', 'second-ar']),
        );
        expect(rows.map((r) => r.requestedSalesOrderId), everyElement(isNull));
        expect(tester.takeException(), isNull);
        await env.close(tester);
      },
    );
  }

  testWidgets(
    'the published limit leaves all 501 unsent rows intact and dispatches no batch',
    (tester) async {
      final backend = _Api();
      final env = await _open(tester, FinanceDocType.payment, backend: backend);
      final table = _table(tester);
      for (var index = 0; index < 501; index++) {
        final row = index == 0 ? table.controller[0] : table.createBlankRow!();
        _payment(
          row,
          'supplier-A',
          'ledger-$index',
          '$index.000000000000000000000001',
        );
        if (index != 0) table.controller.addRows([row]);
      }
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
      await tester.pumpAndSettle();
      expect(table.controller.length, 501);
      expect(table.controller[500].amount.text, '500.000000000000000000000001');
      expect(backend.bodies, isEmpty);
      expect(tester.takeException(), isNull);
      await env.close(tester);
    },
  );
  test('client grouping preview uses the shared server contract', () {
    final contract =
        jsonDecode(
              File(
                'contracts/finance-entry-grouping-v1.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    expect(contract['maxDocuments'], financeBatchMaxDocuments);
    for (final scenario
        in (contract['cases'] as List).cast<Map<String, dynamic>>()) {
      final keys = (scenario['entries'] as List)
          .cast<Map<String, dynamic>>()
          .map(
            (entry) => financeEntryGroupKey(Map<String, dynamic>.from(entry)),
          )
          .toSet();
      expect(
        keys.length,
        scenario['groups'],
        reason: scenario['name'] as String,
      );
    }
  });

  test(
    'two-of-three pricing works in all orders and keeps explicit amount',
    () {
      for (final inputs in [
        ['qty', 'price'],
        ['price', 'qty'],
        ['qty', 'amount'],
        ['amount', 'qty'],
        ['price', 'amount'],
        ['amount', 'price'],
      ]) {
        final row = FinanceGridRow(mode: ItemMode.allocate)
          ..enableEntryPricing();
        final fields = {
          'qty': row.qty,
          'price': row.price,
          'amount': row.amount,
        };
        final values = {'qty': '4', 'price': '2.5', 'amount': '10'};
        for (final input in inputs) {
          fields[input]!.text = values[input]!;
        }
        expect(double.parse(row.qty.text), 4, reason: inputs.toString());
        expect(double.parse(row.price.text), 2.5, reason: inputs.toString());
        expect(double.parse(row.amount.text), 10, reason: inputs.toString());
        row.dispose();
      }
      final row = FinanceGridRow(mode: ItemMode.allocate)..enableEntryPricing();
      row.amount.text = '0.000000000000000000000001';
      expect(row.amount.text, '0.000000000000000000000001');
      row.dispose();
    },
  );

  for (final type in FinanceDocType.values) {
    testWidgets(
      '${type.name} creation puts settlement terms in the common selectable grid',
      (tester) async {
        final env = await _open(tester, type, methodOptionsAvailable: true);
        final table = _table(tester);
        expect(table.selectable, isTrue);
        if (type != FinanceDocType.bankTransfer) {
          expect(
            table.columns.singleWhere((c) => c.key == 'entryMethod').required,
            isTrue,
          );
        } else {
          expect(table.columns.where((c) => c.key == 'entryMethod'), isEmpty);
        }
        if (type == FinanceDocType.expense ||
            type == FinanceDocType.otherIncome) {
          expect(
            table.columns.singleWhere((c) => c.key == 'style').required,
            isTrue,
          );
        }
        expect(
          table.columns.last.key,
          type == FinanceDocType.receipt ? 'entryBalance' : 'remark',
        );
        expect(
          table.columns.map((column) => column.key),
          containsAll([
            'entryAccount',
            'entryCurrency',
            'exchangeRate',
            'amount',
          ]),
        );
        if (type == FinanceDocType.payment || type == FinanceDocType.receipt) {
          expect(
            table.columns.map((column) => column.key),
            containsAll(['entryParty', 'entrySettings', 'entryBankReference']),
          );
          expect(
            table.columns.map((column) => column.key),
            isNot(contains('entryFee')),
          );
          expect(
            table.columns.map((column) => column.key),
            isNot(contains('entryAccountAmount')),
          );
          expect(
            table.columns
                .singleWhere((column) => column.key == 'entryBalance')
                .label,
            type == FinanceDocType.receipt ? '还欠' : '未结金额',
          );
          expect(
            table.columns.singleWhere((column) => column.key == 'amount').label,
            type == FinanceDocType.receipt ? '本次收款' : '本次付款(原币)',
          );
          expect(find.text('请先引用已入账的应付；暂不支持给供应商预付'), findsNothing);
        }
        await tester.tap(find.text('添加行').first);
        await tester.pumpAndSettle();
        expect(table.controller.rows, hasLength(2));
        expect(tester.takeException(), isNull);
        await env.close(tester);
      },
    );
  }

  for (final type in [FinanceDocType.receipt, FinanceDocType.payment]) {
    testWidgets(
      '${type.name} settlement settings preserve cancel and calculate same-currency bank facts',
      (tester) async {
        final env = await _open(tester, type);
        final row = _table(tester).controller.rows.single;
        _payment(row, 'party-A', 'ledger-1', '1000');
        row.entry.fee.text = '10';
        row.remark.text = '保留备注';
        await tester.pumpAndSettle();
        final revealing = _table(
          tester,
        ).controller.revealError(row, columnKey: 'entrySettings');
        await tester.pumpAndSettle();
        await revealing;
        await tester.tap(find.text('设置').first);
        await tester.pumpAndSettle();
        final feeField = find.byKey(
          const ValueKey('finance-entry-settlement-fee'),
        );
        final actualField = find.byKey(
          const ValueKey('finance-entry-settlement-account-amount'),
        );
        expect(tester.widget<TextField>(feeField).controller!.text, '10');
        expect(
          tester.getRect(actualField).left,
          lessThan(tester.getRect(feeField).left),
        );
        expect(tester.getRect(actualField).top, tester.getRect(feeField).top);
        expect(find.text('取消'), findsAtLeastNWidgets(1));
        await tester.enterText(feeField, '999');
        await tester.tap(find.byTooltip('关闭').last);
        await tester.pumpAndSettle();
        expect(row.entry.fee.text, '10');
        await tester.tap(find.text('设置').first);
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(feeField).controller!.text, '10');
        expect(tester.widget<TextField>(actualField).controller!.text, isEmpty);
        await tester.enterText(feeField, '10.000000000000000000000001');
        await tester.tap(find.text('保存设置'));
        await tester.pumpAndSettle();
        expect(row.entry.fee.text, '10.000000000000000000000001');
        expect(row.remark.text, '保留备注');
        await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
        await tester.pumpAndSettle();
        final doc = Map<String, dynamic>.from(
          (env.api.bodies.single['documents'] as List).single as Map,
        );
        expect(
          doc['accountAmount'],
          type == FinanceDocType.receipt
              ? '989.999999999999999999999999'
              : '1010.000000000000000000000001',
        );
        expect(doc['bankFeeAccountAmount'], '10.000000000000000000000001');
        expect(((doc['items'] as List).single as Map)['remark'], '保留备注');
        expect(tester.takeException(), isNull);
        await env.close(tester);
      },
    );
  }

  testWidgets(
    'project selected last refreshes grouping totals on the next frame',
    (tester) async {
      final env = await _open(tester, FinanceDocType.expense);
      final row = _table(tester).controller.rows.single;
      row.entry.accountId = 'account-cny';
      row.entry.currencyId = 'cny';
      row.exchangeRate.text = '1';
      row.amount.text = '100.000000000000000000000001';
      row.entry.touch();
      await tester.pumpAndSettle();
      expect(find.text('0 张单据'), findsOneWidget);
      row.styleId = 'style';
      await tester.pump();
      expect(find.text('1 张单据'), findsOneWidget);
      expect(find.text('待填写: '), findsNothing);
      expect(row.amount.text, '100.000000000000000000000001');
      expect(env.api.bodies, isEmpty);
      expect(tester.takeException(), isNull);
      await env.close(tester);
    },
  );

  testWidgets(
    'row reference imports its hidden supplier and preserves entered bank reference',
    (tester) async {
      final env = await _open(tester, FinanceDocType.payment);
      env.api.supplierSelectable = false;
      final row = _table(tester).controller[0];
      row.entry.partyId = 'supplier-A';
      row.entry.bankReference.text = 'OPTIONAL-REFERENCE';
      row.entry.touch();
      await tester.pumpAndSettle();
      await tester.tap(find.text('引用应付').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ar-ap-select-ap-cny')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ar-ap-confirm')));
      await tester.pumpAndSettle();
      final imported = _table(tester).controller.rows.single;
      expect(imported.appliedLedgerId, 'ap-cny');
      expect(imported.entry.partyId, 'supplier-A');
      expect(imported.entry.currencyId, 'cny');
      expect(imported.exchangeRate.text, '1');
      expect(imported.entry.bankReference.text, 'OPTIONAL-REFERENCE');
      expect(tester.takeException(), isNull);
      await env.close(tester);
    },
  );

  testWidgets('new row rejects a supplier hidden while its picker was open', (
    tester,
  ) async {
    final env = await _open(tester, FinanceDocType.payment);
    await tester.tap(find.text('选择供应商').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('供应商甲'));
    env.api.supplierSelectable = false;
    await tester.pump();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(_table(tester).controller.rows.single.entry.partyId, isNull);
    expect(env.api.paths, isEmpty);
    expect(tester.takeException(), isNull);
    await env.close(tester);
  });

  testWidgets(
    'batch fill applies only selected rows and cancel preserves input',
    (tester) async {
      final env = await _open(tester, FinanceDocType.expense);
      final table = _table(tester);
      await tester.tap(find.text('添加行').first);
      await tester.pumpAndSettle();
      table.controller.setSelected([table.controller[0]], true);
      await tester.tap(find.text('批量填写').first);
      await tester.pumpAndSettle();
      final field = find
          .byWidgetPredicate(
            (widget) =>
                widget is TextField && widget.decoration?.labelText == '金额',
          )
          .last;
      await tester.enterText(field, '12.500000000000000000000001');
      await tester.tap(find.text('填入所选行'));
      await tester.pumpAndSettle();
      expect(table.controller[0].amount.text, '12.500000000000000000000001');
      expect(table.controller[1].amount.text, isEmpty);
      await tester.tap(find.text('批量填写').first);
      await tester.pumpAndSettle();
      await tester.enterText(field, '999');
      await tester.tap(find.byTooltip('关闭').last);
      await tester.pumpAndSettle();
      expect(table.controller[0].amount.text, '12.500000000000000000000001');
      await env.close(tester);
    },
  );

  testWidgets(
    'mixed suppliers preview two documents and submit one atomic batch',
    (tester) async {
      final env = await _open(tester, FinanceDocType.payment);
      final table = _table(tester);
      final rows = table.controller;
      final first = rows[0];
      _payment(first, 'supplier-A', 'ledger-1', '10');
      final second = table.createBlankRow!();
      _payment(second, 'supplier-A', 'ledger-2', '20');
      final third = table.createBlankRow!();
      _payment(third, 'supplier-B', 'ledger-3', '30');
      rows.addRows([second, third]);
      await tester.pumpAndSettle();
      expect(find.text('预计生成: '), findsOneWidget);
      expect(find.text('2 张单据'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
      await tester.pumpAndSettle();
      expect(env.api.bodies, hasLength(1));
      expect(env.api.paths.single, '/finance/payments/batch');
      expect((env.api.bodies.single['documents'] as List), hasLength(3));
      expect(find.text('已完成'), findsOneWidget);
      await env.close(tester);
    },
  );

  for (final type in [FinanceDocType.payment, FinanceDocType.receipt]) {
    testWidgets(
      '${type.name} unknown result keeps original source command across hard close and replays exactly',
      (tester) async {
        final storage = MemoryFormDraftStorage();
        var env = await _open(tester, type, storage: storage);
        _payment(
          _table(tester).controller[0],
          'supplier-A',
          'ledger-1',
          '0.000000000000000000000001',
        );
        if (type == FinanceDocType.receipt) {
          final row = _table(tester).controller[0];
          row.requestedSalesOrderId = 'order-B';
          row.entry.salesOrderId = 'order-B';
          row.entry.salesOrderNo = 'XD-B';
          row.sourceDocType = 'SALES_SHIPMENT';
          row.sourceDocNo = 'XC-REAL-PARTIAL';
        }
        env.api.timeout = true;
        await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
        await tester.pumpAndSettle();
        final original = jsonEncode(env.api.bodies.single);
        final draft = env.container.read(formDraftsProvider).single;
        expect(draft.hasUnknownSubmission, isTrue);
        await env.close(tester);
        env = await _open(
          tester,
          type,
          storage: storage,
          location: draft.resumeLocation,
        );
        if (type == FinanceDocType.receipt) {
          final restored = _table(tester).controller.rows.single;
          expect(restored.sourceDocType, 'SALES_SHIPMENT');
          expect(restored.sourceDocNo, 'XC-REAL-PARTIAL');
        }
        await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
        await tester.pumpAndSettle();
        expect(jsonEncode(env.api.bodies.single), original);
        expect(find.text('已完成'), findsOneWidget);
        await env.close(tester);
      },
    );
  }

  testWidgets(
    '1000 rapid edits preserve distinct currencies, selection and draft values',
    (tester) async {
      final env = await _open(tester, FinanceDocType.payment);
      final table = _table(tester);
      final additions = List.generate(999, (_) => table.createBlankRow!());
      table.controller.addRows(additions);
      for (var index = 0; index < table.controller.length; index++) {
        final row = table.controller[index];
        _payment(
          row,
          'supplier-${index % 8}',
          'ledger-$index',
          '$index.000000000000000000000001',
        );
      }
      for (var index = 1; index < table.controller.length; index += 2) {
        final row = table.controller[index];
        row.entry.currencyId = 'usd';
        row.currencyId = 'usd';
        row.exchangeRate.text = '7.2';
        row.entry.accountAmount.text = row.amount.text;
        row.entry.touch();
      }
      table.controller.setSelected([
        table.controller[1],
        table.controller[999],
      ], true);
      await tester.pumpAndSettle();
      final state =
          tester.state(find.byType(FinanceDocEditPage))
              as FormDraftMixin<FinanceDocEditPage>;
      var saved = false;
      final saving = state.saveFormDraftNow().whenComplete(() => saved = true);
      for (var frame = 0; frame < 2000 && !saved; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1)),
        );
      }
      expect(saved, isTrue);
      await saving;
      final snapshot = state.captureFormDraft();
      expect(snapshot['rows'], hasLength(1000));
      expect(
        (snapshot['rows'] as List)
            .cast<Map<String, dynamic>>()
            .map((row) => (row['entry'] as Map<String, dynamic>)['currencyId'])
            .toSet(),
        {'cny', 'usd'},
      );
      expect(snapshot['selected'], [1, 999]);
      expect(
        ((snapshot['rows'] as List).last as Map)['amount'],
        '999.000000000000000000000001',
      );
      expect(env.api.bodies, isEmpty);
      expect(tester.takeException(), isNull);
      await env.close(tester);
    },
  );

  testWidgets('desktop and narrow layouts retain the row grid and save action', (
    tester,
  ) async {
    if (Platform.environment['UTEN_CAPTURE_FINANCE_ENTRY'] == 'true') {
      await loadAuditScreenshotFonts(tester);
    }
    for (final scenario in [
      for (final type in FinanceDocType.values)
        for (final layout in [
          (const Size(1600, 1000), 1.0),
          (const Size(390, 844), 1.0),
          (const Size(1600, 1000), 1.5),
        ])
          (type, layout.$1, layout.$2),
    ]) {
      final type = scenario.$1;
      final size = scenario.$2;
      final capture = GlobalKey();
      final env = await _open(
        tester,
        type,
        size: size,
        capture: capture,
        zoom: scenario.$3,
      );
      _payment(
        _table(tester).controller[0],
        'supplier-A',
        'ledger-1',
        '1200.50',
      );
      await env.container.read(financeNameServiceProvider).loadSupplierNames([
        'supplier-A',
      ]);
      final row = _table(tester).controller.rows.single;
      if (type == FinanceDocType.expense ||
          type == FinanceDocType.otherIncome) {
        row.entry.partyId = null;
        row.appliedLedgerId = null;
        row.styleId = 'style';
        row.qty.text = '100';
        row.price.text = '12.005';
      } else if (type == FinanceDocType.bankTransfer) {
        row.entry.partyId = null;
        row.appliedLedgerId = null;
        row.inAccountId = 'account-cny';
        row.occurDate = '2026-11-03';
      }
      row.entry.touch();
      await tester.pumpAndSettle();
      expect(find.text('保存').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (Platform.environment['UTEN_CAPTURE_FINANCE_ENTRY'] == 'true') {
        await saveAuditScreenshot(
          tester,
          capture,
          'finance-entry-${type.name}-${size.width.toInt()}${scenario.$3 == 1 ? '' : '-zoom150'}',
        );
      }
      await env.close(tester);
    }
  });
}

Future<void> _blurReceiptCapture(WidgetTester tester) async {
  final gesture = await tester.startGesture(
    tester.getCenter(find.text('新建销售收款单').first),
    kind: PointerDeviceKind.mouse,
  );
  await gesture.up();
  await tester.pumpAndSettle();
}

Future<void> _secondCaptureRow(
  WidgetTester tester, {
  required bool deposit,
}) async {
  final table = _table(tester);
  final row = table.createBlankRow!();
  row.entry.accountId = 'account-cny';
  row.entry.methodId = 'method';
  row.entry.bankReference.text = 'BANK-SECOND-BATCH';
  if (deposit) {
    row.entry.receiptKind = 'CUSTOMER_PREPAYMENT';
    row.amount.text = '150';
  }
  table.controller.addRow(row);
  await tester.pumpAndSettle();
  final revealing = table.controller.revealError(row, columnKey: 'entrySource');
  await tester.pumpAndSettle();
  await revealing;
  await tester.tap(find.text(deposit ? '选订货单' : '选出货单').last);
  await tester.pumpAndSettle();
  if (deposit) {
    await tester.tap(find.text('XD-A').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定').last);
    await tester.pumpAndSettle();
  } else {
    await _chooseShipmentBatch(tester, 'second-ar', '200');
  }
  final focus = table.controller.revealError(
    table.controller.rows.first,
    columnKey: 'amount',
  );
  await tester.pumpAndSettle();
  await focus;
}

Future<void> _chooseShipmentBatch(
  WidgetTester tester,
  String ledger,
  String amount, {
  GlobalKey? capture,
}) async {
  await tester.tap(find.byKey(ValueKey('ar-ap-select-$ledger')));
  await tester.pumpAndSettle();
  if (capture != null) {
    await saveAuditScreenshot(tester, capture, 'receipt-flow-select-batch');
  }
  final field = find.byKey(ValueKey('ar-ap-amount-$ledger'));
  await tester.ensureVisible(field);
  await tester.pumpAndSettle();
  await tester.enterText(field, amount);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('ar-ap-confirm')));
  await tester.pumpAndSettle();
}

void _payment(FinanceGridRow row, String party, String ledger, String amount) {
  row.entry.partyId = party;
  row.entry.accountId = 'account-cny';
  row.entry.currencyId = 'cny';
  row.entry.methodId = 'method';
  row.currencyId = 'cny';
  row.appliedLedgerId = ledger;
  row.appliedBillNo = ledger;
  row.balanceOriginalText = amount;
  row.amount.text = amount;
  row.exchangeRate.text = '1';
  row.entry.touch();
}

UtenEditableGrid<FinanceGridRow> _table(WidgetTester tester) =>
    tester.widget(find.byType(UtenEditableGrid<FinanceGridRow>));

class _Environment {
  _Environment(this.api, this.container, this.router);
  final _Api api;
  final ProviderContainer container;
  final GoRouter router;
  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    router.dispose();
    container.dispose();
  }
}

Future<_Environment> _open(
  WidgetTester tester,
  FinanceDocType type, {
  MemoryFormDraftStorage? storage,
  String? location,
  GlobalKey? capture,
  GlobalKey? overlayCapture,
  Size size = const Size(1800, 1100),
  double zoom = 1,
  bool legacy = false,
  bool methodOptionsAvailable = false,
  Set<String> extraPermissions = const {},
  _Api? backend,
  Set<String>? permissions,
  bool productionGuard = false,
}) async {
  if (overlayCapture != null) {
    await loadAuditScreenshotFonts(tester);
  }
  await setUtenTestSurfaceSize(
    tester,
    overlayCapture != null && size == const Size(1800, 1100)
        ? const Size(1440, 960)
        : size,
  );
  addTearDown(() => setUtenTestSurfaceSize(tester, null));
  SharedPreferences.setMockInitialValues({});
  final api =
      backend ??
      _Api(
        legacy: legacy,
        captureMethods: overlayCapture != null || methodOptionsAvailable,
      );
  final container = ProviderContainer(
    overrides: [
      if (legacy) financeWriteAllDocumentScope(),
      apiClientProvider.overrideWithValue(api),
      apiBaseUrlProvider.overrideWithValue('https://finance-batch.test/api'),
      sessionProvider.overrideWith(legacy ? _LegacySession.new : _Session.new),
      authenticatedScopeProvider.overrideWithValue(
        const AuthenticatedScope(userId: 'fixture'),
      ),
      currentPermissionsProvider.overrideWith(
        (ref) => ref.watch(_batchPermissions),
      ),
      ...nativeDetailReaderOverrides(
        includeSession: false,
        includeServer: false,
      ),
      sharedPreferencesProvider.overrideWithValue(
        await SharedPreferences.getInstance(),
      ),
      formDraftStorageProvider.overrideWithValue(
        storage ?? MemoryFormDraftStorage(),
      ),
    ],
  );
  container.read(_batchPermissions.notifier).state =
      permissions ??
      {
        Perm.salesOrderView,
        ...extraPermissions,
        for (final docType in FinanceDocType.values) ...{
          FinanceDocConfig.by(docType).createPerm!,
          FinanceDocConfig.by(docType).listPerm,
          ?FinanceDocConfig.by(docType).editPerm,
        },
      };
  final base = '/finance/${type.pathSegment}';
  final actual = productionGuard ? container.read(appRouterProvider) : null;
  GoRoute? route(String path) {
    GoRoute? find(List<RouteBase> routes) {
      for (final entry in routes) {
        if (entry is GoRoute && entry.path == path) return entry;
        final nested = find(entry.routes);
        if (nested != null) return nested;
      }
      return null;
    }

    return actual == null ? null : find(actual.configuration.routes);
  }

  final recovery = route('/finance/:seg/batch-recovery');
  final denied = route('/access-denied');
  final router = GoRouter(
    initialLocation: location ?? '$base/new',
    redirect: actual?.configuration.topRedirect,
    routes: [
      DraftAwareGoRoute(
        path: '$base/new',
        builder: (_, _) => RepaintBoundary(
          key: capture,
          child: UtenDisplayZoomBox(
            fontFactor: zoom,
            child: FinanceDocEditPage(
              docType: type,
              id: legacy ? 'legacy-receipt' : null,
            ),
          ),
        ),
      ),
      if (recovery != null)
        GoRoute(
          path: recovery.path,
          builder: recovery.builder,
          redirect: recovery.redirect,
        ),
      if (denied != null)
        GoRoute(
          path: denied.path,
          builder: denied.builder,
          redirect: denied.redirect,
        ),
      GoRoute(
        path: base,
        builder: (_, _) => const Scaffold(body: Text('已完成')),
      ),
      GoRoute(
        path: '$base/:id',
        builder: (_, _) => const Scaffold(body: Text('已完成')),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: overlayCapture,
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: auditScreenshotTheme(buildLightTheme()),
          routerConfig: router,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Environment(api, container, router);
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'fixture',
      code: 'fixture',
      name: '匿名测试人员',
      permissions: ref.watch(_batchPermissions).toList(),
    ),
  );
}

class _LegacySession extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(id: 'fixture', code: 'fixture', name: '测试财务'),
  );
}

class _Api extends ApiClient {
  _Api({this.legacy = false, this.captureMethods = false}) : super(Dio());
  final bool legacy;
  final bool captureMethods;
  final putBodies = <Map<String, dynamic>>[];
  final putCommands = <Map<String, dynamic>>[];
  Map<String, dynamic> get legacyReceipt => financeReviewedDetailFixture({
    'id': 'legacy-receipt',
    'makerId': 'fixture',
    'version': 0,
    'status': 0,
    'billNo': 'YS-LEGACY',
    'billDate': '2026-11-04',
    'receiptKind': 'AR_SETTLEMENT',
    'clientId': '00000000-0000-0000-0000-0000000000aa',
    'accountId': 'account-cny',
    'currencyId': 'cny',
    'exchangeRate': 1,
    'amountOriginal': 100,
    'amountLocal': 100,
    'accountAmount': 100,
    'accountAmountLocal': 100,
    'settlementAuthorityVersion': 2,
    'settlementChannel': 'DIRECT_ACCOUNT',
    'exchangeRateSource': 'BANK_STATEMENT',
    'exchangeRateEffectiveAt': '2026-11-04T01:00:00Z',
    'bankBookedAt': '2026-11-04T02:00:00Z',
    'bankReference': 'LEGACY-BANK',
    'accountCurrencyId': 'cny',
    'feeSettlementMode': 'NONE',
    'feeBearer': 'NONE',
    'items': [
      {
        'id': 'old-line',
        'lineNo': 1,
        'appliedLedgerId': 'old-ar',
        'appliedBillNo': 'AR-OLD',
        'clientId': '00000000-0000-0000-0000-0000000000aa',
        'currencyId': 'cny',
        'exchangeRate': 1,
        'amountOriginal': 100,
        'amountLocal': 100,
        'balanceBeforeOriginal': 100,
      },
    ],
  }, FinanceDocType.receipt);
  @override
  Future<Map<String, dynamic>> put(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
  }) async {
    final command = Map<String, dynamic>.from(body as Map);
    expect(command.keys.toSet(), {
      'requestId',
      'expectedVersion',
      'expectedSnapshot',
      'document',
    });
    expect(command['expectedVersion'], legacyReceipt['approvalVersion']);
    expect(command['expectedSnapshot'], legacyReceipt['approvalSnapshot']);
    final document = Map<String, dynamic>.from(command['document'] as Map);
    expect(document['expectedVersion'], command['expectedVersion']);
    putCommands.add(command);
    putBodies.add(document);
    // The request uses decimal text. The real typed response exposes exact
    // fields alongside numeric compatibility values; raw request strings are
    // never valid values for those numeric response properties.
    Map<String, dynamic> responseValues(Map<String, dynamic> values) {
      final result = Map<String, dynamic>.from(values);
      for (final key in [
        'exchangeRate',
        'amountOriginal',
        'amountLocal',
        'qty',
        'price',
        'bankFee',
        'otherFee',
        'writeOffAmount',
        'writeOffLocal',
        'appliedAmountLocal',
      ]) {
        if (result[key] is String) {
          result['${key}Exact'] = result.remove(key);
        }
      }
      return result;
    }

    final result = responseValues({
      ...legacyReceipt,
      ...document,
      'version': 1,
      'items': [
        for (final (index, item) in (document['items'] as List).indexed)
          responseValues({
            ...Map<String, dynamic>.from(item as Map),
            'id': 'saved-line-$index',
          }),
      ],
    })..remove('expectedVersion');
    for (final key in [
      'approvalVersion',
      'approvalSnapshot',
      'approvalPlatformFields',
    ]) {
      result.remove(key);
    }
    return financeReviewReceiptFixture(
      path: path,
      command: command,
      result: result,
      actorId: 'fixture',
    );
  }

  final bodies = <Map<String, dynamic>>[];
  final paths = <String>[];
  bool independentSource = false;
  bool timeout = false;
  bool financialMethods = false;
  bool reject = false,
      commitBeforeTimeout = false,
      loseCancel = false,
      legacyBody = false;
  int commits = 0;
  final cancellations = <Map<String, dynamic>>[];
  final receipts = <String, Map<String, dynamic>>{};
  bool supplierSelectable = true;
  int collectionParts = 1;
  final collectionReads = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> postCancellable(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    CancelToken? cancelToken,
  }) async {
    if (path != '/finance/receipts/order-collection-preview') {
      throw StateError('unexpected read $path');
    }
    final value = Map<String, dynamic>.from(body as Map);
    collectionReads.add(value);
    final amount = value['amountOriginal'].toString();
    final piece = collectionParts == 1 ? amount : '100';
    return {
      'salesOrderId': value['salesOrderId'],
      'orderBillNo': value['salesOrderId'] == 'order-A' ? 'XD-A' : 'XD-B',
      'clientId': '00000000-0000-0000-0000-0000000000aa',
      'currencyId': 'cny',
      'receiptKind': 'AR_SETTLEMENT',
      'amountOriginal': amount,
      'items': [
        for (var index = 0; index < collectionParts; index++)
          {
            'ledgerId': collectionParts == 1 ? 'shared-ar' : 'ar-$index',
            'billNo': 'AR-$index',
            'sourceDocNo': 'XC-$index',
            'amountOriginal': piece,
            'balanceOriginal': '1000',
          },
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (legacy && path == '/finance/receipts/legacy-receipt') {
      return legacyReceipt;
    }
    if (path == '/sales/orders' || path == '/finance/receipts/order-sources') {
      return {
        'items': [
          for (final id in ['A', 'B'])
            {
              'id': 'order-$id',
              'billNo': 'XD-$id',
              'billDate': '2026-11-04',
              'clientId': '00000000-0000-0000-0000-0000000000aa',
              'currencyId': 'cny',
              'status': 1,
              'totalOriginal': 735,
              'closed': id == 'B',
              'sellerName': '测试业务员',
            },
        ],
        'page': 1,
        'size': 20,
        'total': 2,
        'totalPages': 1,
      };
    }
    if (path.contains('/batch/operations/')) {
      final receipt = receipts[path.split('/').last];
      if (receipt == null) return {'found': false};
      return {
        ...receipt,
        if (legacyBody && receipt['outcome'] == 'SUCCEEDED')
          'requestBody': null,
      };
    }
    if (path.endsWith('/suppliers')) {
      return {
        'items': [
          {
            'id': 'supplier-A',
            'name': '供应商甲',
            'categoryId': 'supplier-category',
            'status': '使用',
          },
        ],
        'page': 1,
        'size': 100,
        'total': 1,
        'totalPages': 1,
      };
    }
    if (path == '/finance/receipts/shipment-sources') {
      return {
        'items': [
          for (final id in [
            'shared-ar',
            'second-ar',
            if (independentSource) 'opening-ar',
          ])
            {
              'id': id,
              'billNo': 'AR-$id',
              'billDate': '2026-11-04',
              'sourceDocType': id == 'opening-ar'
                  ? 'OPENING'
                  : 'SALES_SHIPMENT',
              'sourceDocId': 'shipment-$id',
              'sourceDocNo': id == 'opening-ar'
                  ? '期初-已核验'
                  : id == 'shared-ar'
                  ? 'XC-1000-A'
                  : 'XC-1000-B',
              'direction': 'AR',
              'openItemKind': 'RECEIVABLE',
              'clientId': '00000000-0000-0000-0000-0000000000aa',
              'clientName': '客户甲',
              'currencyId': 'cny',
              'currencyName': '人民币',
              'exchangeRate': 1,
              'exchangeRateExact': '1',
              'amountOriginal': 1000,
              'amountOriginalExact': '1000',
              'amountReceivedOriginal': 0,
              'amountReceivedOriginalExact': '0',
              'amountBalanceOriginal': 1000,
              'amountBalanceOriginalExact': '1000',
              'prepaymentAppliedOriginal': '0',
              'amountWriteOffOriginalExact': '0',
              'status': 1,
              'salesOrderIds': ['order-B'],
              'authoritativeSalesOrderId': 'order-B',
              'salesOrderNos': ['XD-B'],
            },
        ],
        'total': 2,
        'page': 1,
        'size': 50,
        'totalPages': 1,
      };
    }
    return path == '/finance/ar-ap'
        ? {
            'items': [
              {
                'id': 'ap-cny',
                'direction': 'AP',
                'billNo': 'AP-CNY-001',
                'supplierId': 'supplier-A',
                'currencyId': 'cny',
                'currencyCode': 'CNY',
                'currencyName': '人民币',
                'amountOriginal': 30,
                'amountSettled': 0,
                'amountBalanceOriginal': 30,
              },
            ],
            'total': 1,
            'page': 1,
            'size': 50,
          }
        : {'items': <dynamic>[], 'total': 0};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('/clients/') && path.contains('lookup')) {
      final ids = query?['ids']?.toString().split(',').toSet() ?? <String>{};
      return [
        for (final row in <Map<String, dynamic>>[
          {
            'id': '00000000-0000-0000-0000-0000000000aa',
            'name': '客户甲',
            'status': '使用',
            'selectable': true,
          },
          {
            'id': 'supplier-A',
            'name': '往来甲',
            'status': '使用',
            'selectable': true,
          },
        ])
          if (ids.contains(row['id'])) row,
      ];
    }
    if (path.contains('suppliers') && path.contains('lookup')) {
      return [
        {
          'id': 'supplier-A',
          'name': '供应商甲',
          'status': '使用',
          'selectable': supplierSelectable,
        },
      ];
    }
    if (path.contains('supplier-categories')) {
      return [
        {
          'id': 'supplier-category',
          'name': '供应商分类',
          'code': 'S',
          'level': 0,
          'children': <dynamic>[],
        },
      ];
    }
    if (path.endsWith('/accounts') || path.contains('/accounts/')) {
      return [
        {
          'id': 'account-cny',
          'name': '人民币账户',
          'currencyId': 'cny',
          'currencyCode': 'CNY',
          'currencyName': '人民币',
          'baseCurrency': true,
          'status': '使用',
        },
      ];
    }
    if (financialMethods && path == '/master/reference-methods/finance') {
      return [
        {
          'id': 'method',
          'code': 'BANK',
          'name': '银行转账',
          'legacyNameConfirmed': true,
        },
      ];
    }
    if (path.contains('currencies')) {
      return [
        {
          'id': 'cny',
          'code': 'CNY',
          'name': '人民币',
          'baseCurrency': true,
          'exchangeRate': '1',
        },
        {
          'id': 'usd',
          'code': 'USD',
          'name': '美元',
          'baseCurrency': false,
          'exchangeRate': '7.2',
        },
      ];
    }
    if (path == '/platform-columns/scopes') {
      return [
        {
          'scope': 'view_ar_ap_ledger',
          'priceVisible': true,
          'supportsValues': false,
        },
      ];
    }
    if (captureMethods && path == '/master/reference-methods/finance') {
      return [
        {'id': 'method', 'name': '银行转账', 'code': 'BANK', 'status': '使用'},
      ];
    }
    if (path.contains('payment-styles')) {
      return [
        {
          'id': 'style',
          'code': 'E001',
          'name': query?['category'] == 'INCOME' ? '其他收入' : '办公费用',
          'category': query?['category'] ?? 'EXPENSE',
          'status': '使用',
          'children': <dynamic>[],
        },
      ];
    }
    return [];
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
  }) async {
    if (path.endsWith('/cancel')) {
      final cancellation = Map<String, dynamic>.from(body as Map);
      cancellations.add(cancellation);
      final command = Map<String, dynamic>.from(
        cancellation['requestBody'] as Map,
      );
      final key = command['idempotencyKey'] as String;
      final receipt = receipts.putIfAbsent(
        key,
        () => _receipt(
          path.split('/batch/').first,
          command,
          'CANCELLED_UNWRITTEN',
          {'cancelled': true},
        ),
      );
      if (!jsonValuesEqual(receipt['requestBody'], command)) {
        throw ApiException(
          'CONFLICT',
          '原批次正文不一致',
          httpStatus: 409,
          hasResponseCode: true,
        );
      }
      if (loseCancel && cancellations.length == 1) {
        throw NetworkTimeoutException();
      }
      return Map<String, dynamic>.from(receipt);
    }
    paths.add(path);
    bodies.add(Map<String, dynamic>.from(body as Map));
    final key = body['idempotencyKey'] as String;
    final old = receipts[key];
    if (old != null) {
      if (!jsonValuesEqual(old['requestBody'], body)) {
        throw ApiException(
          'CONFLICT',
          '原批次正文不一致',
          httpStatus: 409,
          hasResponseCode: true,
        );
      }
      if (old['outcome'] == 'CANCELLED_UNWRITTEN') {
        throw ApiException(
          'CONFLICT',
          '原批次已停止',
          httpStatus: 409,
          hasResponseCode: true,
          details: {'outcome': 'CANCELLED_UNWRITTEN'},
        );
      }
      return Map<String, dynamic>.from(old['result'] as Map);
    }
    if (reject) {
      throw ApiException(
        'VALIDATION_FAILED',
        '原来源已变化',
        httpStatus: 422,
        hasResponseCode: true,
      );
    }
    if (timeout && !commitBeforeTimeout) throw NetworkTimeoutException();
    final groups = (body['documents'] as List)
        .cast<Map<String, dynamic>>()
        .map((entry) => financeEntryGroupKey(Map<String, dynamic>.from(entry)))
        .toSet();
    final result = <String, dynamic>{
      'items': [
        for (var index = 0; index < groups.length; index++)
          {'id': 'created-$index', 'items': <dynamic>[], 'status': 0},
      ],
    };
    commits++;
    receipts[key] = _receipt(
      path.replaceFirst(RegExp(r'/batch$'), ''),
      Map<String, dynamic>.from(body),
      'SUCCEEDED',
      result,
    );
    if (timeout) throw NetworkTimeoutException();
    return result;
  }

  Map<String, dynamic> _receipt(
    String base,
    Map<String, dynamic> body,
    String outcome,
    Object? result,
  ) => {
    'found': true,
    'requestId': body['idempotencyKey'],
    'idempotencyKey': body['idempotencyKey'],
    'actorId': 'fixture',
    'operation': 'FINANCE_BATCH_CREATE',
    'method': 'POST',
    'path': '$base/batch',
    'requestHash': ''.padLeft(64, 'a'),
    'requestBody': body,
    'outcome': outcome,
    'result': result,
  };
}
