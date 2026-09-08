import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/procurement_iqc_rejection/models/procurement_iqc_rejection.dart';
import 'package:uten_imp/features/procurement_iqc_rejection/widgets/procurement_iqc_actual_credit_dialog.dart';
import 'package:uten_imp/features/procurement_iqc_rejection/widgets/procurement_iqc_rejection_action_dialog.dart';

void main() {
  testWidgets(
    'actual 24-place amounts and each case unit survive preview and confirmation',
    (tester) async {
      _view(tester);
      final gateway = _Actions();
      await _show(tester, gateway);
      expect(find.textContaining('可贷项 5 件'), findsOneWidget);
      expect(find.textContaining('可贷项 2.5 千克'), findsOneWidget);
      await _fill(
        tester,
        total: '0.000000000000000000000003',
        first: '0.000000000000000000000001',
      );
      await _tap(tester, 'iqc-credit-case-case-2');
      await _enter(tester, 'iqc-credit-qty-case-2', '1.25');
      await _enter(
        tester,
        'iqc-credit-amount-case-2',
        '0.000000000000000000000002',
      );
      await _tap(tester, 'iqc-credit-preview');
      await tester.pumpAndSettle();
      final previewRequest = gateway.previews.single;
      expect(previewRequest.actualAmountOriginal, '0.000000000000000000000003');
      expect(previewRequest.allocations.map((a) => a.expectedVersion), [7, 12]);
      expect(previewRequest.allocations.last.baseQty, '1.25');
      expect(find.byKey(const Key('iqc-credit-book-preview')), findsOneWidget);
      expect(
        find.textContaining('账面本币 0.000000000000000000000007000001'),
        findsOneWidget,
      );
      await _tap(tester, 'iqc-action-submit');
      await tester.pumpAndSettle();
      expect(gateway.confirmations.single.expectedBookAllocationHash, _hash);
      expect(gateway.confirmations.single.commandId, previewRequest.commandId);
      expect(gateway.confirmations.single.toJson()['allocations'], [
        {
          'caseId': 'case-1',
          'expectedVersion': 7,
          'baseQty': '5',
          'amountOriginal': '0.000000000000000000000001',
        },
        {
          'caseId': 'case-2',
          'expectedVersion': 12,
          'baseQty': '1.25',
          'amountOriginal': '0.000000000000000000000002',
        },
      ]);
    },
  );

  testWidgets('a one-unit-in-the-24th-place mismatch blocks all API calls', (
    tester,
  ) async {
    _view(tester);
    final gateway = _Actions();
    await _show(tester, gateway);
    await _fill(
      tester,
      total: '0.000000000000000000000002',
      first: '0.000000000000000000000001',
    );
    await _tap(tester, 'iqc-credit-preview');
    await tester.pump();
    expect(gateway.previews, isEmpty);
    expect(
      find.byWidgetPredicate(
        (w) => w is Tooltip && (w.message ?? '').contains('必须与实际贷项原币金额完全一致'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('iqc-action-submit')), findsNothing);
  });

  testWidgets(
    'missing source and unavailable history cannot produce a request',
    (tester) async {
      _view(tester);
      final gateway = _Actions(detail: _detail(twoSources: true));
      await _show(tester, gateway);
      await _fill(tester, total: '1', first: null);
      await _tap(tester, 'iqc-credit-preview');
      await tester.pump();
      expect(gateway.previews, isEmpty);
      expect(
        find.byWidgetPredicate(
          (w) => w is Tooltip && (w.message ?? '').contains('请选择来源应付'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      final legacy = _Actions(
        detail: ProcurementIqcRejectionDetail(
          caseItem: _case(),
          resolution: const ProcurementIqcResolution(
            state: 'LEGACY_UNCLASSIFIED',
            legacyUnclassified: true,
          ),
        ),
      );
      await _show(tester, legacy);
      expect(find.textContaining('历史案件须先核对原应付'), findsOneWidget);
      expect(find.byKey(const Key('iqc-credit-actual')), findsNothing);
      expect(find.byKey(const Key('iqc-credit-preview')), findsNothing);
    },
  );

  testWidgets(
    'editing invalidates the preview and a late old preview is discarded',
    (tester) async {
      _view(tester);
      final gateway = _Actions()..blockedPreview = Completer();
      await _show(tester, gateway);
      await _fill(tester, total: '1', first: '1');
      await _tap(tester, 'iqc-credit-preview');
      await tester.pump();
      final field = tester.widget<TextFormField>(
        find.byKey(const Key('iqc-credit-actual')),
      );
      field.controller!.text = '2';
      gateway.blockedPreview!.complete(_preview(gateway.previews.single));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('iqc-action-submit')), findsNothing);
      gateway.blockedPreview = null;
      await _enter(tester, 'iqc-credit-amount-case-1', '2');
      await _tap(tester, 'iqc-credit-preview');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('iqc-action-submit')), findsOneWidget);
      await _enter(tester, 'iqc-action-reference', 'CR-CHANGED');
      await tester.pump();
      expect(find.byKey(const Key('iqc-action-submit')), findsNothing);
    },
  );

  testWidgets(
    'pending confirmation disables duplicate clicks and uncertain retry reuses exact command',
    (tester) async {
      _view(tester);
      final gateway = _Actions()..blockedConfirm = Completer();
      await _show(tester, gateway);
      await _fill(tester, total: '1', first: '1');
      await _tap(tester, 'iqc-credit-preview');
      await tester.pumpAndSettle();
      await _tap(tester, 'iqc-action-submit');
      await tester.pump();
      expect(gateway.confirmations, hasLength(1));
      expect(
        tester
            .widget<UtenButton>(find.byKey(const Key('iqc-action-submit')))
            .onPressed,
        isNull,
      );
      gateway.blockedConfirm!.completeError(NetworkTimeoutException());
      await tester.pumpAndSettle();
      expect(find.text('重试同一次确认'), findsOneWidget);
      expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('iqc-credit-actual')))
            .enabled,
        isFalse,
      );
      gateway.blockedConfirm = null;
      await _tap(tester, 'iqc-action-submit');
      await tester.pumpAndSettle();
      expect(gateway.previews, hasLength(1));
      expect(gateway.confirmations, hasLength(2));
      expect(
        gateway.confirmations.last.toJson(),
        gateway.confirmations.first.toJson(),
      );
    },
  );

  testWidgets(
    'source balance conflict requires refreshed versions and a new preview',
    (tester) async {
      _view(tester);
      final gateway = _Actions()..conflictOnce = true;
      await _show(tester, gateway);
      await _fill(tester, total: '1', first: '1');
      await _tap(tester, 'iqc-credit-preview');
      await tester.pumpAndSettle();
      await _tap(tester, 'iqc-action-submit');
      await tester.pumpAndSettle();
      expect(find.text('来源余额已变化'), findsOneWidget);
      expect(
        tester
            .widget<UtenButton>(find.byKey(const Key('iqc-credit-preview')))
            .onPressed,
        isNull,
      );
      gateway.detail = _detail(version: 8);
      await tester.tap(find.text('刷新来源与余额'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('iqc-credit-actual')))
            .controller!
            .text,
        '1',
      );
      await _tap(tester, 'iqc-credit-preview');
      await tester.pumpAndSettle();
      expect(gateway.previews.last.expectedVersion, 8);
      expect(gateway.previews.last.allocations.single.expectedVersion, 8);
    },
  );

  testWidgets(
    'whole-document reversal explicitly chooses one credit and includes its UUID',
    (tester) async {
      _view(tester);
      ProcurementIqcReasonCommand? submitted;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () {
                  showDialog<ProcurementIqcRejectionDetail>(
                    context: context,
                    builder: (_) => ProcurementIqcRejectionActionDialog(
                      caseItem: _case(),
                      kind: ProcurementIqcRejectionActionKind.reverse,
                      creditDocuments: [
                        _document('credit-1', 'CR-ONE', 2),
                        _document('credit-2', 'CR-TWO', 3),
                      ],
                      onSubmit: (command) async {
                        submitted = command as ProcurementIqcReasonCommand;
                        return _detail();
                      },
                    ),
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await _enter(tester, 'iqc-action-note', '供应商撤回本次整张凭证');
      await _tap(tester, 'iqc-action-submit');
      await tester.pump();
      expect(submitted, isNull);
      await tester.tap(find.byKey(const Key('iqc-reverse-credit-document')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('CR-TWO · 原币 10').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('3 个案件分项，全部一起反向'), findsOneWidget);
      await _tap(tester, 'iqc-action-submit');
      await tester.pumpAndSettle();
      expect(submitted!.creditDocumentId, 'credit-2');
      expect(submitted!.expectedVersion, 7);
    },
  );

  testWidgets(
    'dark small phone with enlarged text keeps fields and actions usable',
    (tester) async {
      _view(tester, width: 375, height: 812);
      final gateway = _Actions();
      await _show(tester, gateway, dark: true, textScale: 1.4);
      await _fill(tester, total: '1', first: '1');
      await _tap(tester, 'iqc-credit-preview');
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('iqc-credit-book-preview')),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('确认以上金额与分项'), findsOneWidget);
    },
  );
}

const _hash =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

class _Actions {
  _Actions({ProcurementIqcRejectionDetail? detail})
    : detail = detail ?? _detail();
  ProcurementIqcRejectionDetail detail;
  final previews = <ProcurementIqcConfirmCreditCommand>[],
      confirmations = <ProcurementIqcConfirmCreditCommand>[];
  Completer<ProcurementIqcCreditPreview>? blockedPreview;
  Completer<ProcurementIqcRejectionDetail>? blockedConfirm;
  bool conflictOnce = false;
  Future<ProcurementIqcCreditPreview> preview(
    ProcurementIqcConfirmCreditCommand command,
  ) {
    previews.add(command);
    return blockedPreview?.future ?? Future.value(_preview(command));
  }

  Future<ProcurementIqcRejectionDetail> confirm(
    ProcurementIqcConfirmCreditCommand command,
  ) {
    confirmations.add(command);
    if (conflictOnce) {
      conflictOnce = false;
      throw ApiException('CONFLICT', '来源余额已变化');
    }
    return blockedConfirm?.future ?? Future.value(detail);
  }
}

Future<void> _show(
  WidgetTester tester,
  _Actions actions, {
  bool dark = false,
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? ThemeData.dark() : ThemeData.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<ProcurementIqcRejectionDetail>(
              context: context,
              barrierDismissible: false,
              builder: (_) => ProcurementIqcActualCreditDialog(
                detail: actions.detail,
                onPreview: actions.preview,
                onConfirm: actions.confirm,
                onRefresh: () async => actions.detail,
              ),
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String key, String value) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.enterText(finder, value);
  await tester.pump();
}

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pump();
}

Future<void> _fill(
  WidgetTester tester, {
  required String total,
  required String? first,
}) async {
  await _enter(tester, 'iqc-credit-actual', total);
  if (first != null) await _enter(tester, 'iqc-credit-amount-case-1', first);
  await _enter(tester, 'iqc-action-reference', 'CR-ACTUAL-001');
  await _enter(tester, 'iqc-action-note', '依据供应商原始凭证核对分项');
}

void _view(WidgetTester tester, {double width = 1100, double height = 1000}) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

ProcurementIqcRejectionCase _case({int version = 7}) =>
    ProcurementIqcRejectionCase(
      id: 'case-1',
      receiptType: ProcurementIqcReceiptType.purchase,
      status: ProcurementIqcRejectionStatus.returnRecorded,
      version: version,
      allowedActions: const {
        ProcurementIqcRejectionAction.confirmCredit,
        ProcurementIqcRejectionAction.reverse,
      },
      priceMasked: false,
      receiptBillNo: 'CJ-ONE',
      supplierName: '供应商',
      goodsName: '实际贷项物料',
      currencyCode: 'USD',
    );
ProcurementIqcRejectionDetail _detail({
  int version = 7,
  bool twoSources = false,
}) => ProcurementIqcRejectionDetail(
  caseItem: _case(version: version),
  resolution: const ProcurementIqcResolution(
    baseUnitName: '件',
    creditableBaseQty: '5',
    state: 'OPEN',
    legacyUnclassified: false,
  ),
  creditSources: [
    ProcurementIqcCreditSource(
      sourceApLedgerId: 'ap-1',
      sourceBillNo: 'AP-ONE',
      amountOriginal: '10',
      amountLocal: '70',
      creditedAmountOriginal: '0',
      remainingAmountOriginal: '10',
      cases: [
        ProcurementIqcCreditCase(
          caseId: 'case-1',
          version: version,
          receiptBillNo: 'CJ-ONE',
          goodsName: '物料甲',
          creditableBaseQty: '5',
          baseUnitName: '件',
        ),
        const ProcurementIqcCreditCase(
          caseId: 'case-2',
          version: 12,
          receiptBillNo: 'CJ-TWO',
          goodsName: '物料乙',
          creditableBaseQty: '2.5',
          baseUnitName: '千克',
        ),
      ],
    ),
    if (twoSources)
      const ProcurementIqcCreditSource(
        sourceApLedgerId: 'ap-2',
        sourceBillNo: 'AP-TWO',
        remainingAmountOriginal: '20',
      ),
  ],
);
ProcurementIqcCreditPreview _preview(
  ProcurementIqcConfirmCreditCommand command,
) => ProcurementIqcCreditPreview(
  bookAllocationHash: _hash,
  amountOriginal: command.actualAmountOriginal,
  amountLocal: '0.000000000000000000000007000001',
  offsetOriginal: command.actualAmountOriginal,
  offsetLocal: '0.000000000000000000000007000001',
  creditRemainingOriginal: '0',
  creditRemainingLocal: '0',
  sourceBeforeOriginal: '10',
  sourceBeforeLocal: '70',
  sourceAfterOriginal: '9',
  sourceAfterLocal: '69',
  caseAllocations: [
    for (final a in command.allocations)
      ProcurementIqcCreditCaseBook(
        caseId: a.caseId,
        baseQty: a.baseQty,
        amountOriginal: a.amountOriginal,
        amountLocal: '0.000000000000000000000001000001',
        afterOriginal: '0',
        afterLocal: '0',
      ),
  ],
);
ProcurementIqcCreditDocument _document(
  String id,
  String reference,
  int count,
) => ProcurementIqcCreditDocument(
  creditDocumentId: id,
  status: 'ACTIVE',
  canReverse: true,
  creditReference: reference,
  amountOriginal: '10',
  amountLocal: '70',
  caseAllocations: [
    for (var i = 0; i < count; i++)
      ProcurementIqcCreditCaseBook(caseId: 'case-$i'),
  ],
);
