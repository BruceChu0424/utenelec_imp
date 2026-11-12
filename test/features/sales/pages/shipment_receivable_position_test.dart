import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/data_display/uten_detail_summary_card.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/data_write_revision.dart';
import 'package:uten_imp/components/layout/uten_history_time_filter.dart';
import 'package:uten_imp/core/router/page_resume_provider.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/finance/pages/finance_sales_shipment_audit_review_page.dart';
import 'package:uten_imp/features/finance/widgets/finance_actual_receipt_context.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/pages/sales_doc_detail_page.dart';
import 'package:uten_imp/features/sales/pages/sales_doc_list_page.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/attachments/attachment_section.dart';
import 'package:uten_imp/shared/attachments/business_attachment_section.dart';
import 'package:uten_imp/shared/providers/list_refresh_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/drafts/review_task_draft.dart';
import 'package:uten_imp/shared/widgets/shipment_receivable_position_view.dart';
import '../../../support/audit_screenshot_support.dart';
import '../../../support/native_detail_reader_overrides.dart';

const _capture = bool.fromEnvironment('UTEN_SHIPMENT_MONEY_SCREENSHOTS');
const _reviewCaptureOnly = bool.fromEnvironment(
  'UTEN_SHIPMENT_MONEY_REVIEW_ONLY',
);
bool _captureMode(String mode) =>
    _capture && (!_reviewCaptureOnly || mode == 'review');
const _finance = {Perm.salesShipmentView, Perm.salesShipmentFinanceView};
final _moneyPermissions = StateProvider<Set<String>>((ref) => {});

Map<String, dynamic> _position({
  String cash = '300',
  String prepayment = '100',
  String paid = '400',
  String debt = '600',
  String state = 'READY',
}) => {
  'ledgerId': state == 'NOT_POSTED' ? null : 'ledger-shipment-1',
  'currencyId': 'currency-cny',
  'currencyName': '人民币',
  'shipmentOriginal': '1000',
  'formalReceivableOriginal': state == 'NOT_POSTED' ? null : '1000',
  'cashReceivedOriginal': state == 'NOT_POSTED' ? null : cash,
  'prepaymentAppliedOriginal': state == 'NOT_POSTED' ? null : prepayment,
  'confirmedPaidOriginal': state == 'NOT_POSTED' ? null : paid,
  'balanceOriginal': state == 'NOT_POSTED' ? null : debt,
  'reductionOriginal': '0',
  'returnOffsetOriginal': '0',
  'otherOffsetOriginal': '0',
  'dueDate': state == 'NOT_POSTED' ? null : '2026-12-01',
  'overdueDays': 0,
  'state': state,
  'complete': true,
  'warnings': <String>[],
};

Map<String, dynamic> _reference(String amount) => {
  'available': true,
  'verifiedCount': 3,
  'pendingCount': 1,
  'verifiedCashLocal': amount,
  'more': true,
  'basis': '示例：客户累计账户实到，仅完整账户入账证明计入；不作为本批已收或还欠。',
  'receipts': <Map<String, dynamic>>[],
};

List<Map<String, dynamic>> _fileRows() => [
  {
    'id': 'file-1',
    'ownerType': 'SALES_SHIPMENT',
    'ownerId': 'shipment-1',
    'storageKey': 'anonymous/customer-confirmation.pdf',
    'originalName': '客户确认单.pdf',
    'contentType': 'application/pdf',
    'sizeBytes': 2048,
    'category': '客户确认',
  },
];
const _filePermissions = {
  ..._finance,
  Perm.salesOrderPriceView,
  Perm.attachmentView,
  Perm.attachmentDownload,
  Perm.attachmentUpload,
  Perm.attachmentDelete,
};

void main() {
  test(
    'shipment positions remain exact and never turn an unavailable AR into zero',
    () {
      final missing = ShipmentReceivablePosition.fromJson(
        _position(state: 'NOT_POSTED'),
      );
      expect(missing.balanceOriginal, isNull);
      expect(missing.confirmedPaidOriginal, isNull);
      expect(shipmentDebtLabel(missing), '待出库');
      final exact = ShipmentReceivablePosition.fromJson(
        _position(
          paid: '400.123456789012345678901234',
          debt: '599.876543210987654321098766',
        ),
      );
      expect(exact.confirmedPaidOriginal, '400.123456789012345678901234');
      expect(exact.hasDebt, true);
    },
  );

  for (final allowed in [false, true]) {
    testWidgets(
      'real shipment list money is limited by permission and appended at the table end: $allowed',
      (tester) async {
        final host = await _pump(
          tester,
          'list',
          permissions: allowed ? _finance : {Perm.salesShipmentView},
        );
        final table = tester.widget<MasterDataTableView<SalesDocListItem>>(
          find.byType(MasterDataTableView<SalesDocListItem>),
        );
        final keys = table.columns.map((column) => column.key).toList();
        expect(keys.contains('shipmentPaid'), allowed);
        expect(keys.contains('shipmentDebt'), allowed);
        if (allowed) {
          expect(keys.sublist(keys.length - 3), [
            'shipmentPaid',
            'shipmentDebt',
            'shipmentDue',
          ]);
          final paid = table.columns.singleWhere(
            (column) => column.key == 'shipmentPaid',
          );
          final debt = table.columns.singleWhere(
            (column) => column.key == 'shipmentDebt',
          );
          expect(paid.value(table.items.single), '400.00 元');
          expect(debt.value(table.items.single), '600.00 元');
          expect(paid.sortable, false);
          expect(debt.sortable, false);
          expect(debt.supportsKeywordSearch, false);
          expect(
            paid.cellColor?.call(
              tester.element(find.byType(SalesDocListPage)),
              table.items.single,
            ),
            isNull,
          );
          expect(
            debt.cellColor?.call(
              tester.element(find.byType(SalesDocListPage)),
              table.items.single,
            ),
            isNotNull,
          );
          if (_captureMode('list')) {
            await saveAuditScreenshot(
              tester,
              host.captureKey,
              'shipment-money-list-example',
            );
          }
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final mode in ['detail', 'review']) {
    testWidgets(
      '$mode shows current batch debt beside the original not-posted release evidence',
      (tester) async {
        final host = await _pump(
          tester,
          mode,
          width: mode == 'review' ? 1280 : 1440,
        );
        final section = find.byKey(
          const ValueKey('shipment-receivable-position'),
        );
        expect(section, findsOneWidget);
        expect(
          find.descendant(of: section, matching: find.text('400.00 元')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: section, matching: find.text('600.00 元')),
          findsOneWidget,
        );
        final fields = tester
            .widgetList<UtenSummaryField>(
              find.descendant(
                of: section,
                matching: find.byType(UtenSummaryField),
              ),
            )
            .toList();
        expect(fields.singleWhere((field) => field.label == '还欠').danger, true);
        expect(
          fields.singleWhere((field) => field.label == '货款').danger,
          false,
        );
        expect(
          fields.singleWhere((field) => field.label == '已收').danger,
          false,
        );
        if (_captureMode(mode)) {
          await _backToOverview(tester);
          expect(find.text('XC-1000-A').hitTestable(), findsOneWidget);
          expect(find.text('客户甲').hitTestable(), findsOneWidget);
          await saveAuditScreenshot(
            tester,
            host.captureKey,
            'shipment-money-$mode-example',
          );
        }
        await tester.tap(find.byTooltip('展开本批金额明细'));
        await tester.pumpAndSettle();
        final breakdown = tester.widgetList<UtenSummaryField>(
          find.descendant(of: section, matching: find.byType(UtenSummaryField)),
        );
        expect(
          breakdown.singleWhere((field) => field.label == '收款').value,
          _capture ? '400.00 元' : '300.00 元',
        );
        expect(
          breakdown.singleWhere((field) => field.label == '定金抵款').value,
          _capture ? '0.00 元' : '100.00 元',
        );
        expect(find.text('收款'), findsOneWidget);
        expect(find.text('定金抵款'), findsOneWidget);
        if (mode == 'review') {
          expect(find.text('当时审核记录'), findsNothing);
          await _openReferences(tester);
          expect(find.text('当时审核记录'), findsOneWidget);
          expect(find.text('待出库'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final mode in ['detail', 'review']) {
    testWidgets(
      '$mode keeps missing AR explicit and renders at 375px without producing zero balances',
      (tester) async {
        final api = _MoneyApi()..current = _position(state: 'NOT_POSTED');
        final host = await _pump(tester, mode, api: api, width: 375);
        final section = find.byKey(
          const ValueKey('shipment-receivable-position'),
        );
        await tester.ensureVisible(section);
        await tester.pumpAndSettle();
        expect(
          find.descendant(of: section, matching: find.text('待出库')),
          findsWidgets,
        );
        expect(
          find.descendant(of: section, matching: find.text('0.00 元')),
          findsNothing,
        );
        if (_captureMode(mode)) {
          await _backToOverview(tester);
          expect(find.text('XC-1000-A').hitTestable(), findsOneWidget);
          expect(find.text('客户甲').hitTestable(), findsOneWidget);
          await saveAuditScreenshot(
            tester,
            host.captureKey,
            'shipment-money-$mode-375-not-posted-example',
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final mode in ['list', 'detail', 'review']) {
    testWidgets(
      'receipt confirmation or reversal invalidates the open $mode through the common refresh hook',
      (tester) async {
        final host = await _pump(tester, mode);
        final before = host.api.moneyReads;
        final revision = host.container.read(dataWriteRevisionProvider);
        host.api.current = _position(cash: '0', paid: '100', debt: '900');
        bumpListRefresh(host.ref, 'finance:receipt');
        await tester.pumpAndSettle();
        expect(host.container.read(dataWriteRevisionProvider), revision + 1);
        expect(host.api.moneyReads, greaterThan(before));
        if (mode != 'list') {
          expect(
            find.descendant(
              of: find.byKey(const ValueKey('shipment-receivable-position')),
              matching: find.text('900.00 元'),
            ),
            findsOneWidget,
          );
        }
        final reads = host.api.moneyReads;
        bumpListRefresh(host.ref, 'finance:account-chart');
        await tester.pumpAndSettle();
        expect(
          host.api.moneyReads,
          reads,
          reason: 'Chart/report metadata is not a shipment-cash invalidation',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'warehouse reader cannot reveal a forged financial position in a real detail payload',
    (tester) async {
      await _pump(
        tester,
        'detail',
        permissions: {Perm.warehouseSalesOutboundView},
      );
      expect(
        find.byKey(const ValueKey('shipment-receivable-position')),
        findsNothing,
      );
      expect(find.text('400.00 元'), findsNothing);
      expect(find.text('600.00 元'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final mode in ['list', 'detail', 'review']) {
    testWidgets(
      'withdrawing money permission retires the open $mode projection',
      (tester) async {
        final host = await _pump(tester, mode);
        host.container.read(_moneyPermissions.notifier).state = {
          Perm.salesShipmentView,
        };
        await tester.pumpAndSettle();
        expect(find.byType(ShipmentReceivablePositionView), findsNothing);
        expect(find.text('600.00 元'), findsNothing);
        expect(find.text('400.00 元'), findsNothing);
        expect(
          find.byKey(const ValueKey('shipment-outstanding-all-dates')),
          findsNothing,
        );
        if (mode == 'list') {
          final table = tester.widget<MasterDataTableView<SalesDocListItem>>(
            find.byType(MasterDataTableView<SalesDocListItem>),
          );
          expect(
            table.columns.any((column) => column.key == 'shipmentDebt'),
            false,
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'zero debt after a formal reduction is settled, not falsely received in full; missing due date does not erase money',
    (tester) async {
      final api = _MoneyApi()
        ..current = {
          ..._position(debt: '0'),
          'reductionOriginal': '600',
          'dueDate': null,
          'overdueDays': 3,
        };
      await _pump(tester, 'detail', api: api);
      final section = find.byKey(
        const ValueKey('shipment-receivable-position'),
      );
      expect(
        find.descendant(of: section, matching: find.text('已结清')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: section, matching: find.text('400.00 元')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: section, matching: find.text('需核对')),
        findsNothing,
      );
      expect(
        find.descendant(of: section, matching: find.text('3天')),
        findsNothing,
      );
      await tester.tap(find.byTooltip('展开本批金额明细'));
      await tester.pumpAndSettle();
      expect(find.text('未约定/待核对付款时间'), findsOneWidget);
      final fields = tester
          .widgetList<UtenSummaryField>(
            find.descendant(
              of: section,
              matching: find.byType(UtenSummaryField),
            ),
          )
          .toList();
      expect(fields.singleWhere((field) => field.label == '还欠').danger, false);
      expect(
        fields.singleWhere((field) => field.label == '退减').value,
        '600.00 元',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    '375px keeps exact current amounts and the one important debt emphasis',
    (tester) async {
      final host = await _pump(tester, 'detail', width: 375);
      final section = find.byKey(
        const ValueKey('shipment-receivable-position'),
      );
      await tester.ensureVisible(section);
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: section, matching: find.text('600.00 元')),
        findsOneWidget,
      );
      if (_captureMode('detail')) {
        await _backToOverview(tester);
        expect(find.text('XC-1000-A').hitTestable(), findsOneWidget);
        expect(find.text('客户甲').hitTestable(), findsOneWidget);
        await saveAuditScreenshot(
          tester,
          host.captureKey,
          'shipment-money-detail-375-example',
        );
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reductions and return offsets never become received money', (
    tester,
  ) async {
    final api = _MoneyApi()
      ..current = {
        ..._position(debt: '300'),
        'reductionOriginal': '200',
        'returnOffsetOriginal': '100',
        'overdueDays': 3,
      };
    await _pump(tester, 'detail', api: api);
    final section = find.byKey(const ValueKey('shipment-receivable-position'));
    expect(
      find.descendant(of: section, matching: find.text('400.00 元')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: section, matching: find.text('700.00 元')),
      findsNothing,
    );
    await tester.tap(find.byTooltip('展开本批金额明细'));
    await tester.pumpAndSettle();
    final fields = tester
        .widgetList<UtenSummaryField>(
          find.descendant(of: section, matching: find.byType(UtenSummaryField)),
        )
        .toList();
    expect(
      fields.singleWhere((field) => field.label == '退减').value,
      '200.00 元',
    );
    expect(
      fields.singleWhere((field) => field.label == '退货抵款').value,
      '100.00 元',
    );
    expect(fields.singleWhere((field) => field.label == '逾期').danger, true);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'an obsolete money read is retired while the newer receipt event keeps original review inputs',
    (tester) async {
      final host = await _pump(tester, 'review');
      final state =
          tester.state(find.byType(FinanceSalesShipmentAuditReviewPage))
              as ReviewTaskDraftMixin<FinanceSalesShipmentAuditReviewPage>;
      const inputs = {'rate': '1.0000', 'rejectReason': '保留原核对意见'};
      state.restoreReviewInputs(inputs);
      final old = Completer<Map<String, dynamic>>(),
          fresh = Completer<Map<String, dynamic>>();
      host.api.queuedInfo.addAll([old, fresh]);
      host.api.current = _position(cash: '400', paid: '500', debt: '500');
      final oldResult = host.api.auditInfo;
      bumpListRefresh(host.ref, 'finance:receipt');
      await tester.pumpAndSettle();
      expect(host.api.queuedInfo.length, 1);
      host.api.current = _position(cash: '0', paid: '100', debt: '900');
      bumpListRefresh(host.ref, 'finance:receipt');
      await tester.pumpAndSettle();
      old.complete(oldResult);
      await tester.pumpAndSettle();
      expect(host.api.queuedInfo, isEmpty);
      expect(
        tester
            .widget<ShipmentReceivablePositionView>(
              find.byType(ShipmentReceivablePositionView),
            )
            .value
            .balanceOriginal,
        '600',
        reason:
            'The first read may not publish its obsolete 500 after a newer cash event',
      );
      fresh.complete(host.api.auditInfo);
      await tester.pumpAndSettle();
      final view = tester.widget<ShipmentReceivablePositionView>(
        find.byType(ShipmentReceivablePositionView),
      );
      expect(view.value.balanceOriginal, '900');
      await _openReferences(tester);
      expect(
        tester
            .widget<UtenSummaryField>(
              find.byWidgetPredicate(
                (w) => w is UtenSummaryField && w.label == '当时审核记录',
              ),
            )
            .value,
        '待出库',
      );
      expect(state.captureReviewInputs(), inputs);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'outbound guidance stays beside the status and supports touch and keyboard',
    (tester) async {
      await _pump(tester, 'review');
      const message = '仓库已确认出库，不能补做或撤销财务审核；纠错请走销售退货。';
      final hint = find.byKey(const ValueKey('shipment-outbound-review-hint'));
      expect(hint, findsOneWidget);
      expect(tester.widget<UtenFieldHintIcon>(hint).errorMessage, message);
      expect(find.text(message), findsNothing);
      await tester.tap(hint);
      await tester.pumpAndSettle();
      expect(find.text(message), findsOneWidget);
      Tooltip.dismissAllToolTips();
      await tester.pumpAndSettle();
      tester
          .widget<IconButton>(
            find.descendant(of: hint, matching: find.byType(IconButton)),
          )
          .focusNode!
          .requestFocus();
      await tester.pumpAndSettle();
      expect(find.text(message), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'customer cash reference is collapsed and read separately; cancel and late replies preserve the newer wait and batch inputs',
    (tester) async {
      final host = await _pump(tester, 'review');
      await _openReferences(tester);
      final state =
          tester.state(find.byType(FinanceSalesShipmentAuditReviewPage))
              as ReviewTaskDraftMixin<FinanceSalesShipmentAuditReviewPage>;
      const inputs = {'rate': '1.0000', 'rejectReason': '保留原意见'};
      state.restoreReviewInputs(inputs);
      expect(find.text('实际到账来源尚未读取'), findsNothing);
      expect(
        find.byKey(const ValueKey('shipment-actual-receipt-total')),
        findsNothing,
      );
      final before = host.api.moneyReads;
      final old = Completer<Map<String, dynamic>>(),
          fresh = Completer<Map<String, dynamic>>();
      host.api.queuedInfo.addAll([old, fresh]);
      await _revealReference(tester, find.text('客户到账参考（辅助）'));
      await tester.tap(find.text('客户到账参考（辅助）'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(host.api.moneyReads, before + 1);
      expect(find.byType(UtenBusyOverlay), findsOneWidget);
      await tester.tap(find.text('客户到账参考（辅助）'), warnIfMissed: false);
      await tester.pump();
      expect(host.api.moneyReads, before + 1);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.byType(UtenBusyOverlay), findsNothing);
      await _revealReference(tester, find.text('客户到账参考（辅助）'));
      await tester.tap(find.text('客户到账参考（辅助）'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      old.complete({
        ...host.api.auditInfo,
        'actualReceiptContext': _reference('8000'),
      });
      await tester.pump();
      expect(find.byType(UtenBusyOverlay), findsOneWidget);
      fresh.complete({
        ...host.api.auditInfo,
        'actualReceiptContext': _reference('9000'),
      });
      await tester.pumpAndSettle();
      expect(find.byType(UtenBusyOverlay), findsNothing);
      expect(
        tester
            .widget<UtenSummaryField>(
              find.byKey(const ValueKey('shipment-actual-receipt-total')),
            )
            .value,
        '9000.00 元',
      );
      await _backToOverview(tester);
      expect(
        tester
            .widget<ShipmentReceivablePositionView>(
              find.byType(ShipmentReceivablePositionView),
            )
            .value
            .balanceOriginal,
        '600',
      );
      expect(state.captureReviewInputs(), inputs);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'withdrawing reference permission dismisses its wait and retires the old customer response',
    (tester) async {
      final host = await _pump(tester, 'review');
      await _openReferences(tester);
      final pending = Completer<Map<String, dynamic>>();
      host.api.queuedInfo.add(pending);
      await _revealReference(tester, find.text('客户到账参考（辅助）'));
      await tester.tap(find.text('客户到账参考（辅助）'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(UtenBusyOverlay), findsOneWidget);
      host.container.read(_moneyPermissions.notifier).state = {
        Perm.salesShipmentView,
      };
      await tester.pumpAndSettle();
      expect(find.byType(UtenBusyOverlay), findsNothing);
      expect(find.byType(FinanceActualReceiptContext), findsNothing);
      pending.complete({
        ...host.api.auditInfo,
        'actualReceiptContext': _reference('9000'),
      });
      await tester.pumpAndSettle();
      expect(find.text('9000.00 元'), findsNothing);
      expect(find.byType(ShipmentReceivablePositionView), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed customer reference reads keep review inputs and can retry without inventing a zero',
    (tester) async {
      final host = await _pump(tester, 'review');
      await _openReferences(tester);
      final state =
          tester.state(find.byType(FinanceSalesShipmentAuditReviewPage))
              as ReviewTaskDraftMixin<FinanceSalesShipmentAuditReviewPage>;
      const inputs = {'rate': '1.0000', 'rejectReason': '保留原核对意见'};
      state.restoreReviewInputs(inputs);
      final failed = Completer<Map<String, dynamic>>();
      host.api.queuedInfo.add(failed);
      await _revealReference(tester, find.text('客户到账参考（辅助）'));
      await tester.tap(find.text('客户到账参考（辅助）'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      failed.completeError(StateError('fixture interrupted reference read'));
      await tester.pumpAndSettle();
      expect(find.byType(UtenBusyOverlay), findsNothing);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is UtenFieldHintIcon &&
              widget.errorMessage?.contains('客户到账参考读取未完成') == true,
        ),
        findsOneWidget,
      );
      expect(state.captureReviewInputs(), inputs);
      await _revealReference(tester, find.text('客户到账参考（辅助）'));
      await tester.tap(find.text('客户到账参考（辅助）'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<UtenSummaryField>(
              find.byKey(const ValueKey('shipment-actual-receipt-total')),
            )
            .value,
        '待核对',
      );
      await _backToOverview(tester);
      expect(
        tester
            .widget<ShipmentReceivablePositionView>(
              find.byType(ShipmentReceivablePositionView),
            )
            .value
            .balanceOriginal,
        '600',
      );
      expect(state.captureReviewInputs(), inputs);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('customer reference cancel aborts the real read transport', (
    tester,
  ) async {
    final transport = _DelayedListAdapter();
    final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'))
      ..httpClientAdapter = transport;
    addTearDown(() => dio.close(force: true));
    final api = _MoneyApi(dio: dio);
    await _pump(tester, 'review', api: api);
    await _openReferences(tester);
    api.readInfoThroughTransport = true;
    await _revealReference(tester, find.text('客户到账参考（辅助）'));
    await tester.tap(find.text('客户到账参考（辅助）'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(transport.requests, 1);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 150));
    expect(transport.cancelled, true);
    expect(find.byType(UtenBusyOverlay), findsNothing);
    transport.response.complete(
      ResponseBody.fromString(
        jsonEncode(api.auditInfo),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('shipment-actual-receipt-total')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a changed customer or currency review source cannot replace the old review cash reference',
    (tester) async {
      final host = await _pump(tester, 'review');
      await _openReferences(tester);
      final pending = Completer<Map<String, dynamic>>();
      host.api.queuedInfo.add(pending);
      await tester.tap(find.text('客户到账参考（辅助）'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      pending.complete({
        ...host.api.auditInfo,
        'reviewRevision': 2,
        'contentHash': 'example-other-customer-currency',
        'actualReceiptContext': _reference('9000'),
      });
      await tester.pumpAndSettle();
      expect(find.byType(UtenBusyOverlay), findsNothing);
      expect(
        find.byKey(const ValueKey('shipment-actual-receipt-total')),
        findsNothing,
      );
      expect(find.text('9000.00 元'), findsNothing);
      await _backToOverview(tester);
      expect(
        tester
            .widget<ShipmentReceivablePositionView>(
              find.byType(ShipmentReceivablePositionView),
            )
            .value
            .balanceOriginal,
        '600',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'outstanding shortcut searches every date on the server and restores the original local range',
    (tester) async {
      final host = await _pump(tester, 'list');
      final before = Map<String, dynamic>.from(host.api.listQueries.last);
      final previous = tester
          .widget<UtenHistoryTimeFilter>(find.byType(UtenHistoryTimeFilter))
          .value;
      expect(before['dateFrom'], isNotNull);
      expect(previous.all, false);
      await _tapOutstandingFilter(tester);
      final active = host.api.listQueries.last;
      expect(active['receivableState'], 'OPEN');
      expect(active['stage'], 'SHIPPED');
      expect(active.containsKey('dateFrom'), false);
      expect(active.containsKey('dateTo'), false);
      final date = tester.widget<UtenHistoryTimeFilter>(
        find.byType(UtenHistoryTimeFilter),
      );
      expect(date.value.all, true);
      expect(date.enabled, false);
      expect(date.allLabel, '全部日期');
      if (_captureMode('list')) {
        await saveAuditScreenshot(
          tester,
          host.captureKey,
          'shipment-money-outstanding-all-dates-example',
        );
      }
      await _tapOutstandingFilter(tester);
      expect(host.api.listQueries.last['receivableState'], isNull);
      expect(host.api.listQueries.last['dateFrom'], before['dateFrom']);
      expect(host.api.listQueries.last['dateTo'], before['dateTo']);
      expect(
        tester
            .widget<UtenHistoryTimeFilter>(find.byType(UtenHistoryTimeFilter))
            .value,
        previous,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final mode in ['detail', 'review']) {
    for (final administrator in [false, true]) {
      testWidgets(
        '$mode keeps the goods table directly after its main panel with authorized files; admin=$administrator',
        (tester) async {
          final api = _MoneyApi()
            ..priceMasked = false
            ..attachmentRows = _fileRows();
          final host = await _pump(
            tester,
            mode,
            api: api,
            permissions: _filePermissions,
            administrator: administrator,
          );
          final position = find.byType(ShipmentReceivablePositionView);
          final panel = find
              .ancestor(
                of: position,
                matching: find.byType(UtenDetailSummaryCard),
              )
              .first;
          final table = find.byType(MasterDataTableView<SalesDocItem>);
          final gap =
              tester.getTopLeft(table).dy - tester.getBottomLeft(panel).dy;
          expect(
            gap,
            inInclusiveRange(0, 100),
            reason:
                'No authorized empty-file card may separate the panel from goods',
          );
          expect(api.attachmentQueries, isEmpty);
          expect(find.byType(BusinessAttachmentSection), findsNothing);
          expect(find.text('这张单据还没有相关文件。'), findsNothing);
          if (_capture && administrator) {
            await saveAuditScreenshot(
              tester,
              host.captureKey,
              'shipment-money-$mode-files-collapsed-example',
            );
          }
          await _openFileReference(tester, mode);
          expect(api.attachmentQueries, [
            {'ownerType': 'SALES_SHIPMENT', 'ownerId': 'shipment-1'},
          ]);
          final filename = find.text('客户确认单.pdf');
          expect(filename, findsOneWidget);
          await tester.ensureVisible(filename);
          await tester.pumpAndSettle();
          expect(filename.hitTestable(), findsOneWidget);
          if (_capture && administrator) {
            await saveAuditScreenshot(
              tester,
              host.captureKey,
              'shipment-money-$mode-files-open-example',
            );
          }
          final section = tester.widget<AttachmentSection>(
            find.byType(AttachmentSection),
          );
          expect(section.ownerCanUpload, false);
          expect(section.ownerCanDelete, false);
          expect(
            tester
                .widgetList<IconButton>(
                  find.descendant(
                    of: find.byType(AttachmentSection),
                    matching: find.byType(IconButton),
                  ),
                )
                .singleWhere((button) => button.tooltip == '预览')
                .onPressed,
            isNotNull,
          );
          host.container.read(_moneyPermissions.notifier).state = {
            ..._filePermissions,
          }..remove(Perm.attachmentView);
          await tester.pumpAndSettle();
          expect(find.text('客户确认单.pdf'), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
    testWidgets(
      '$mode preserves attachment loading, failure, and retry behind the goods table',
      (tester) async {
        final failed = Completer<List<Map<String, dynamic>>>();
        final api = _MoneyApi()
          ..priceMasked = false
          ..attachmentReplies.add(failed);
        await _pump(tester, mode, api: api, permissions: _filePermissions);
        await _openFileReference(tester, mode, settle: false);
        expect(find.byType(UtenBusyOverlay), findsOneWidget);
        failed.completeError(
          StateError('anonymous fixture file read interrupted'),
        );
        await tester.pumpAndSettle();
        expect(find.byType(UtenBusyOverlay), findsNothing);
        expect(find.text('文件暂时无法读取，请重试；如果权限已调整，请刷新单据。'), findsOneWidget);
        final retry = Completer<List<Map<String, dynamic>>>();
        api.attachmentReplies.add(retry);
        await _revealReference(tester, find.text('重新读取'));
        await tester.tap(find.text('重新读取'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byType(UtenBusyOverlay), findsOneWidget);
        retry.complete(_fileRows());
        await tester.pumpAndSettle();
        expect(find.byType(UtenBusyOverlay), findsNothing);
        expect(find.text('客户确认单.pdf'), findsOneWidget);
        expect(api.attachmentQueries, hasLength(2));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'empty authorized files appear only after opening the post-table reference',
    (tester) async {
      final api = _MoneyApi()..priceMasked = false;
      await _pump(tester, 'detail', api: api, permissions: _filePermissions);
      expect(api.attachmentQueries, isEmpty);
      expect(find.text('这张单据还没有相关文件。'), findsNothing);
      await _openFileReference(tester, 'detail');
      expect(api.attachmentQueries, hasLength(1));
      expect(find.text('这张单据还没有相关文件。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'manual refresh shows one Uten wait and leaving cancels its real API read without publishing the old page',
    (tester) async {
      final transport = _DelayedListAdapter();
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'))
        ..httpClientAdapter = transport;
      final api = _MoneyApi(dio: dio);
      await _pump(tester, 'list', api: api);
      final router = GoRouter.of(tester.element(find.byType(SalesDocListPage)));
      api.readListThroughTransport = true;
      await tester.tap(find.byTooltip('刷新'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(transport.requests, 1);
      expect(find.byType(UtenBusyOverlay), findsOneWidget);
      await tester.tap(find.byTooltip('刷新'), warnIfMissed: false);
      await tester.pump();
      expect(transport.requests, 1);
      router.go('/away');
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pumpAndSettle();
      expect(transport.cancelled, true);
      expect(find.text('已离开出货页'), findsOneWidget);
      expect(find.byType(UtenBusyOverlay), findsNothing);
      transport.response.complete(
        ResponseBody.fromString(
          jsonEncode({
            'items': [api.detail],
            'page': 1,
            'size': 20,
            'total': 1,
            'totalPages': 1,
          }),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SalesDocListPage), findsNothing);
      expect(tester.takeException(), isNull);
      dio.close(force: true);
    },
  );

  testWidgets(
    '375px outstanding filter lives in the Uten table action panel and keeps server all-date filtering',
    (tester) async {
      final host = await _pump(tester, 'list', width: 375);
      final overflow = find.byKey(const ValueKey('shipment-filter-actions'));
      expect(overflow, findsOneWidget);
      await tester.tap(overflow);
      await tester.pumpAndSettle();
      final filter = find.byKey(
        const ValueKey('shipment-outstanding-all-dates'),
      );
      expect(filter, findsOneWidget);
      await tester.tap(filter);
      await tester.pumpAndSettle();
      expect(
        host.api.listQueries.last['receivableState'],
        'OPEN',
        reason: jsonEncode(host.api.listQueries),
      );
      expect(host.api.listQueries.last.containsKey('dateFrom'), false);
      expect(tester.takeException(), isNull);
      if (_captureMode('list')) {
        await saveAuditScreenshot(
          tester,
          host.captureKey,
          'shipment-money-list-375-example',
        );
      }
    },
  );
}

Future<void> _openFileReference(
  WidgetTester tester,
  String mode, {
  bool settle = true,
}) async {
  if (mode == 'review') {
    await tester.tap(find.byKey(const ValueKey('detail-summary-toggle')).first);
  } else {
    final fold = find.byKey(const ValueKey('shipment-attachments-reference'));
    await tester.ensureVisible(fold);
    await tester.pumpAndSettle();
    await tester.tap(find.text('资料与附件'));
  }
  await tester.pump();
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _tapOutstandingFilter(WidgetTester tester) async {
  final filter = find.byKey(const ValueKey('shipment-outstanding-all-dates'));
  if (filter.evaluate().isEmpty) {
    await tester.tap(find.byTooltip('筛选操作'));
    await tester.pumpAndSettle();
  }
  await tester.tap(filter);
  await tester.pumpAndSettle();
}

Future<void> _backToOverview(WidgetTester tester) async {
  final positions = tester
      .stateList<ScrollableState>(find.byType(Scrollable))
      .toList();
  for (final state in positions.reversed) {
    if (state.mounted && state.position.hasContentDimensions) {
      state.position.jumpTo(state.position.minScrollExtent);
    }
  }
  await tester.pumpAndSettle();
}

Future<void> _openReferences(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('detail-summary-toggle')).first);
  await tester.pumpAndSettle();
}

/// d3be61be8 保留式联动视口起，审核页参考资料区（货款表格的行尾合计条）按
/// 自然高度延入滚动内容：展开后「更多资料」的表尾自动揭示只保证表格末行入
/// 视口，参考区尾部的「客户到账参考」标题/附件重试按钮仍可能压在 900px 表
/// 面之外（实测标题中心 903px、重试按钮 948px）。点按前先把目标滚入真实
/// 视口；不缩表面尺寸。
Future<void> _revealReference(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  expect(target.hitTestable(), findsOneWidget);
}

class _Host {
  _Host(this.api, this.container, this.ref, this.captureKey);
  final _MoneyApi api;
  final ProviderContainer container;
  final WidgetRef ref;
  final GlobalKey captureKey;
}

Future<_Host> _pump(
  WidgetTester tester,
  String mode, {
  _MoneyApi? api,
  Set<String> permissions = _finance,
  double width = 1440,
  bool administrator = false,
}) async {
  await tester.binding.setSurfaceSize(Size(width, width == 375 ? 860 : 900));
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, width == 375 ? 860 : 900);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  if (_capture) await loadAuditScreenshotFonts(tester);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final source = api ?? _MoneyApi();
  final path = mode == 'list'
      ? '/sales/shipments'
      : mode == 'detail'
      ? '/sales/shipments/shipment-1'
      : '/finance/sales-shipment-audits/shipment-1';
  final captureKey = GlobalKey();
  late WidgetRef writeRef;
  final router = GoRouter(
    initialLocation: path,
    routes: [
      GoRoute(
        path: '/away',
        builder: (_, _) => const Scaffold(body: Text('已离开出货页')),
      ),
      GoRoute(
        path: path,
        builder: (_, _) => switch (mode) {
          'list' => const SalesDocListPage(
            docType: SalesDocType.shipment,
            initialHistory: true,
          ),
          'detail' => const SalesDocDetailPage(
            docType: SalesDocType.shipment,
            id: 'shipment-1',
          ),
          _ => const FinanceSalesShipmentAuditReviewPage(id: 'shipment-1'),
        },
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...nativeDetailReaderOverrides(),
        sharedPreferencesProvider.overrideWithValue(prefs),
        apiClientProvider.overrideWithValue(source),
        salesMasterNameServiceProvider.overrideWithValue(
          SalesMasterNameService(source),
        ),
        _moneyPermissions.overrideWith((ref) => permissions),
        currentPermissionsProvider.overrideWith(
          (ref) => ref.watch(_moneyPermissions),
        ),
        isSuperAdminProvider.overrideWithValue(administrator),
      ],
      child: Consumer(
        builder: (context, ref, _) {
          writeRef = ref;
          return RepaintBoundary(
            key: captureKey,
            child: MaterialApp.router(
              routerConfig: router,
              debugShowCheckedModeBanner: false,
              theme: _capture
                  ? auditScreenshotTheme(buildLightTheme())
                  : buildLightTheme(),
              locale: const Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
            ),
          );
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  final container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp)),
  );
  bumpPageResumeState(container.read(pageResumeProvider.notifier), path);
  await tester.pumpAndSettle();
  return _Host(source, container, writeRef, captureKey);
}

class _MoneyApi extends ApiClient {
  _MoneyApi({Dio? dio}) : super(dio ?? Dio());
  Map<String, dynamic> current = _capture
      ? _position(cash: '400', prepayment: '0')
      : _position();
  final queuedInfo = <Completer<Map<String, dynamic>>>[];
  final listQueries = <Map<String, dynamic>>[];
  final attachmentQueries = <Map<String, dynamic>>[];
  final attachmentReplies = <Completer<List<Map<String, dynamic>>>>[];
  List<Map<String, dynamic>> attachmentRows = [];
  bool priceMasked = true;
  bool readListThroughTransport = false;
  bool readInfoThroughTransport = false;
  int moneyReads = 0;
  Map<String, dynamic> get detail => {
    'id': 'shipment-1',
    'billNo': 'XC-1000-A',
    'billDate': '2026-10-20',
    'clientId': 'client-1',
    'currencyId': 'currency-cny',
    'shipmentKind': 'ORDER',
    'billingMode': 'CHARGED',
    'status': current['state'] == 'NOT_POSTED' ? 0 : 1,
    'financeAudit': 1,
    'arPosted': current['state'] != 'NOT_POSTED',
    'warehouseWorkStatus': current['state'] == 'NOT_POSTED'
        ? 'PENDING_PICK'
        : 'SHIPPED',
    'salesConfirmed': true,
    'priceMasked': priceMasked,
    'writable': false,
    'totalOriginal': 1000,
    'totalLocal': 1000,
    'warehouseId': 'warehouse-main',
    'sellerName': '示例业务员',
    'makerName': '示例制单员',
    'items': [
      {
        'id': 'line-1',
        'goodsId': 'sample-socket',
        'goodsNameSnapshot': '示例五孔插座',
        'goodsCodeSnapshot': 'EX-S001',
        'qty': 40,
        'qtyExact': '40',
        'unitId': 'unit-pc',
        'price': 12.5,
        'priceExact': '12.5',
        'amountOriginal': 500,
        'amountOriginalExact': '500',
        'amountLocal': 500,
      },
      {
        'id': 'line-2',
        'goodsId': 'sample-switch',
        'goodsNameSnapshot': '示例双控开关',
        'goodsCodeSnapshot': 'EX-S002',
        'qty': 20,
        'qtyExact': '20',
        'unitId': 'unit-pc',
        'price': 25,
        'priceExact': '25',
        'amountOriginal': 500,
        'amountOriginalExact': '500',
        'amountLocal': 500,
      },
    ],
    'remark': '示例：到货后付尾款，未到账仍记本批还欠',
    'receivablePosition': Map<String, dynamic>.from(current),
  };
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/documents/status-counts') {
      return {'SHIPPED': 1, 'DRAFT': 0, 'FINANCE_APPROVED': 0};
    }
    if (path == '/sales/shipments') {
      moneyReads++;
      listQueries.add(Map<String, dynamic>.from(query ?? const {}));
      if (readListThroughTransport) {
        readListThroughTransport = false;
        return super.get(path, query: query);
      }
      return {
        'items': [detail],
        'page': 1,
        'size': 20,
        'total': 1,
        'totalPages': 1,
      };
    }
    if (path.endsWith('/finance-audit-info')) {
      moneyReads++;
      if (readInfoThroughTransport) {
        readInfoThroughTransport = false;
        return super.get(path, query: query);
      }
      if (queuedInfo.isNotEmpty) return queuedInfo.removeAt(0).future;
      return auditInfo;
    }
    if (path == '/sales/shipments/shipment-1') {
      moneyReads++;
      return detail;
    }
    return <String, dynamic>{};
  }

  Map<String, dynamic> get auditInfo => {
    'shipmentId': 'shipment-1',
    'financeAudit': 1,
    'reviewRevision': 1,
    'contentHash': 'example-only',
    'billingMode': 'CHARGED',
    'clientName': '客户甲',
    'currencyName': '人民币',
    'baseCurrency': true,
    'financeRate': '1',
    'shipmentExchangeRate': '1',
    'financeRateReady': true,
    'suggestedExchangeRate': '1',
    'settlementMethodName': '按原约定结款',
    'allowedActions': <String>[],
    'commercialSnapshot': jsonEncode({
      'header': <String, dynamic>{},
      'items': <Object>[],
    }),
    'receivablePosition': Map<String, dynamic>.from(current),
    'frozenReceivablePosition': _position(state: 'NOT_POSTED'),
  };

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/attachments') {
      attachmentQueries.add(Map<String, dynamic>.from(query ?? const {}));
      if (attachmentReplies.isNotEmpty) {
        return attachmentReplies.removeAt(0).future;
      }
      return attachmentRows;
    }
    if (path.contains('clients')) {
      return [
        {'id': 'client-1', 'name': '客户甲', 'selectable': true},
      ];
    }
    if (path.contains('currencies')) {
      return [
        {
          'id': 'currency-cny',
          'name': '人民币',
          'code': 'CNY',
          'isBaseCurrency': true,
        },
      ];
    }
    if (path.contains('warehouses')) {
      return [
        {'id': 'warehouse-main', 'name': '主仓库'},
      ];
    }
    if (path.contains('units')) {
      return [
        {'id': 'unit-pc', 'name': '个'},
      ];
    }
    return [];
  }
}

class _DelayedListAdapter implements HttpClientAdapter {
  final response = Completer<ResponseBody>();
  int requests = 0;
  bool cancelled = false;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requests++;
    final aborted = cancelFuture?.then<ResponseBody>((_) {
      cancelled = true;
      throw DioException.requestCancelled(
        requestOptions: options,
        reason: 'reader retired',
      );
    });
    return Future.any([response.future, ?aborted]);
  }

  @override
  void close({bool force = false}) {}
}
