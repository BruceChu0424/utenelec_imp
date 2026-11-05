import 'dart:ui' show PointerDeviceKind, SemanticsAction;
import '../../support/finance_command_test_support.dart';
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
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
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
import '../../shared/drafts/memory_form_draft_storage.dart';
import '../../support/audit_screenshot_support.dart';
import '../../support/finance_dropdown_dom_stub.dart'
    if (dart.library.js_interop) '../../support/finance_dropdown_dom_web.dart'
    as dropdown_dom;
import '../../support/native_detail_reader_overrides.dart';

final _batchPermissions = StateProvider<Set<String>>(
  (_) => {
    for (final type in FinanceDocType.values) ...{
      FinanceDocConfig.by(type).createPerm!,
      FinanceDocConfig.by(type).listPerm,
    },
  },
);

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
        final env = await _open(tester, type);
        final table = _table(tester);
        expect(table.selectable, isTrue);
        expect(table.columns.last.key, 'remark');
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
            '未结金额',
          );
          expect(
            table.columns.singleWhere((column) => column.key == 'amount').label,
            type == FinanceDocType.receipt ? '本次分配收款(原币)' : '本次付款(原币)',
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

  testWidgets(
    'unknown result keeps original command across hard close and replays exactly',
    (tester) async {
      final storage = MemoryFormDraftStorage();
      var env = await _open(tester, FinanceDocType.payment, storage: storage);
      _payment(
        _table(tester).controller[0],
        'supplier-A',
        'ledger-1',
        '0.000000000000000000000001',
      );
      env.api.timeout = true;
      await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
      await tester.pumpAndSettle();
      final original = jsonEncode(env.api.bodies.single);
      final draft = env.container.read(formDraftsProvider).single;
      expect(draft.hasUnknownSubmission, isTrue);
      await env.close(tester);
      env = await _open(
        tester,
        FinanceDocType.payment,
        storage: storage,
        location: draft.resumeLocation,
      );
      await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
      await tester.pumpAndSettle();
      expect(jsonEncode(env.api.bodies.single), original);
      expect(find.text('已完成'), findsOneWidget);
      await env.close(tester);
    },
  );

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
  Size size = const Size(1800, 1100),
  double zoom = 1,
  _Api? backend,
  Set<String>? permissions,
  bool productionGuard = false,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final api = backend ?? _Api();
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      apiBaseUrlProvider.overrideWithValue('https://finance-batch.test/api'),
      sessionProvider.overrideWith(_Session.new),
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
  if (permissions != null) {
    container.read(_batchPermissions.notifier).state = permissions;
  }
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
            child: FinanceDocEditPage(docType: type),
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
      child: MaterialApp.router(
        theme: auditScreenshotTheme(buildLightTheme()),
        routerConfig: router,
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

class _Api extends ApiClient {
  _Api() : super(Dio());
  final bodies = <Map<String, dynamic>>[];
  final paths = <String>[];
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
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
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
