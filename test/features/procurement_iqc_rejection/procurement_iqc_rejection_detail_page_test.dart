import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/procurement_iqc_rejection/models/procurement_iqc_rejection.dart';
import 'package:uten_imp/features/procurement_iqc_rejection/pages/procurement_iqc_rejection_detail_page.dart';
import 'package:uten_imp/features/procurement_iqc_rejection/repositories/procurement_iqc_rejection_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

void main() {
  testWidgets('view-only and amount-view roles still obey server priceMasked', (
    tester,
  ) async {
    _largeView(tester);
    final gateway = _Gateway(_detail(_case()));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentPermissionsProvider.overrideWithValue(const {
            Perm.procurementIqcRejectionView,
            Perm.procurementIqcRejectionAmountView,
          }),
        ],
        child: MaterialApp(
          home: ProcurementIqcRejectionDetailPage(
            id: 'case-1',
            repository: gateway,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('***'), findsWidgets);
    expect(find.text('金额已由服务端按权限脱敏；view_all 不自动授予金额。'), findsOneWidget);
    expect(
      find.byKey(const Key('iqc-detail-action-confirmCredit')),
      findsNothing,
    );
    expect(find.text('IQC 不合格数量已冻结'), findsOneWidget);
  });

  testWidgets(
    'record-return validates form, prevents double submit and sends CAS',
    (tester) async {
      _largeView(tester);
      final item = _case(
        status: ProcurementIqcRejectionStatus.pendingReturn,
        actions: const {ProcurementIqcRejectionAction.recordReturn},
        version: 9,
      );
      final gateway = _Gateway(_detail(item))..blockRecordReturn = true;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentPermissionsProvider.overrideWithValue(const {
              Perm.procurementIqcRejectionView,
              Perm.procurementIqcRejectionRecordReturn,
            }),
          ],
          child: MaterialApp(
            home: ProcurementIqcRejectionDetailPage(
              id: 'case-1',
              repository: gateway,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('iqc-detail-action-recordReturn')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('iqc-action-submit')));
      await tester.pump();
      expect(
        find.byWidgetPredicate(
          (w) => w is Tooltip && (w.message ?? '').contains('退回凭证号不能为空'),
        ),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate(
          (w) => w is Tooltip && (w.message ?? '').contains('退回说明不能为空'),
        ),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(const Key('iqc-action-reference')),
        'RET-20260831-001',
      );
      await tester.enterText(
        find.byKey(const Key('iqc-action-note')),
        '供应商已签收不合格货品',
      );
      await tester.tap(find.byKey(const Key('iqc-action-submit')));
      await tester.pump();

      expect(gateway.recordCalls, 1);
      final button = tester.widget<UtenButton>(
        find.byKey(const Key('iqc-action-submit')),
      );
      expect(button.isLoading, isTrue);
      expect(button.onPressed, isNull);
      expect(gateway.lastReturn!.expectedVersion, 9);
      expect(gateway.lastReturn!.returnReference, 'RET-20260831-001');
      expect(gateway.lastReturn!.commandId, isNotEmpty);

      gateway.completeRecordReturn();
      await tester.pumpAndSettle();
      expect(find.text('实物已退回 / 待财务'), findsWidgets);
    },
  );

  testWidgets('finance actions use exact permissions and one primary CTA', (
    tester,
  ) async {
    _largeView(tester);
    final item = _case(masked: false);
    final gateway = _Gateway(_detail(item));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentPermissionsProvider.overrideWithValue(const {
            Perm.procurementIqcRejectionView,
            Perm.procurementIqcRejectionConfirmCredit,
            Perm.procurementIqcRejectionCloseNoCredit,
            Perm.procurementIqcRejectionAmountView,
          }),
        ],
        child: MaterialApp(
          home: ProcurementIqcRejectionDetailPage(
            id: 'case-1',
            repository: gateway,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('CNY 25.0000'), findsWidgets);
    expect(
      find.byKey(const Key('iqc-detail-action-confirmCredit')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('iqc-detail-action-closeNoCredit')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('iqc-detail-action-reverse')), findsNothing);
    expect(
      tester
          .widget<UtenButton>(
            find.byKey(const Key('iqc-detail-action-confirmCredit')),
          )
          .type,
      UtenButtonType.primary,
    );
    expect(
      tester
          .widget<UtenButton>(
            find.byKey(const Key('iqc-detail-action-closeNoCredit')),
          )
          .type,
      UtenButtonType.secondary,
    );

    await tester.tap(find.byKey(const Key('iqc-detail-action-confirmCredit')));
    await tester.pumpAndSettle();
    expect(find.text('服务器冻结贷项金额(只读)'), findsNothing);
    expect(find.byKey(const Key('iqc-credit-actual')), findsOneWidget);
    await tester.tap(find.byKey(const Key('iqc-credit-preview')));
    await tester.pump();
    expect(
      find.byWidgetPredicate(
        (w) => w is Tooltip && (w.message ?? '').contains('供应商贷项凭证号不能为空'),
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (w) => w is Tooltip && (w.message ?? '').contains('贷项确认原因不能为空'),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'confirm-credit permission without amount-view hides the action',
    (tester) async {
      _largeView(tester);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentPermissionsProvider.overrideWithValue(const {
              Perm.procurementIqcRejectionView,
              Perm.procurementIqcRejectionConfirmCredit,
            }),
          ],
          child: MaterialApp(
            home: ProcurementIqcRejectionDetailPage(
              id: 'case-1',
              repository: _Gateway(_detail(_case(masked: false))),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('iqc-detail-action-confirmCredit')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'local permission with state blocker keeps an explained disabled action',
    (tester) async {
      _largeView(tester);
      final item = _case(
        status: ProcurementIqcRejectionStatus.pendingReturn,
        actions: const {},
        holdReason: '品质处置尚未完成，暂不能登记退回',
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentPermissionsProvider.overrideWithValue(const {
              Perm.procurementIqcRejectionView,
              Perm.procurementIqcRejectionRecordReturn,
            }),
          ],
          child: MaterialApp(
            home: ProcurementIqcRejectionDetailPage(
              id: 'case-1',
              repository: _Gateway(_detail(item)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final action = tester.widget<UtenButton>(
        find.byKey(const Key('iqc-detail-action-recordReturn')),
      );
      expect(action.onPressed, isNull);
      expect(action.onDisabledTap, isNotNull);
    },
  );

  testWidgets('detail load error has a working recovery action', (
    tester,
  ) async {
    _largeView(tester);
    final gateway = _Gateway(_detail(_case()))..failFirstDetail = true;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentPermissionsProvider.overrideWithValue(const {
            Perm.procurementIqcRejectionView,
          }),
        ],
        child: MaterialApp(
          home: ProcurementIqcRejectionDetailPage(
            id: 'case-1',
            repository: gateway,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('无法加载 IQC 不合格任务'), findsOneWidget);
    await tester.tap(find.text('重新加载'));
    await tester.pumpAndSettle();
    expect(find.text('无法加载 IQC 不合格任务'), findsNothing);
    expect(find.textContaining('G-001'), findsWidgets);
  });
}

void _largeView(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

class _Gateway implements ProcurementIqcRejectionGateway {
  _Gateway(this.value);

  ProcurementIqcRejectionDetail value;
  bool failFirstDetail = false;
  bool blockRecordReturn = false;
  int detailCalls = 0;
  int recordCalls = 0;
  ProcurementIqcRecordReturnCommand? lastReturn;
  Completer<ProcurementIqcRejectionDetail>? _recordCompleter;

  void completeRecordReturn() {
    final next = _detail(_case(version: 10));
    value = next;
    _recordCompleter?.complete(next);
  }

  @override
  Future<ProcurementIqcRejectionDetail> detail(String id) async {
    detailCalls++;
    if (failFirstDetail && detailCalls == 1) {
      throw ApiException('NETWORK', '网络暂不可用');
    }
    return value;
  }

  @override
  Future<ProcurementIqcRejectionDetail> recordReturn(
    String id,
    ProcurementIqcRecordReturnCommand command,
  ) {
    recordCalls++;
    lastReturn = command;
    if (!blockRecordReturn) return Future.value(value);
    _recordCompleter ??= Completer<ProcurementIqcRejectionDetail>();
    return _recordCompleter!.future;
  }

  @override
  Future<ProcurementIqcCreditPreview> previewCredit(
    String id,
    ProcurementIqcConfirmCreditCommand command,
  ) async => ProcurementIqcCreditPreview(
    bookAllocationHash: List.filled(64, 'a').join(),
    amountOriginal: command.actualAmountOriginal,
    amountLocal: command.actualAmountOriginal,
    caseAllocations: [
      for (final a in command.allocations)
        ProcurementIqcCreditCaseBook(
          caseId: a.caseId,
          baseQty: a.baseQty,
          amountOriginal: a.amountOriginal,
          amountLocal: a.amountOriginal,
        ),
    ],
  );
  @override
  Future<ProcurementIqcRejectionDetail> closeNoCredit(
    String id,
    ProcurementIqcReasonCommand command,
  ) async => value;
  @override
  Future<ProcurementIqcRejectionDetail> confirmCredit(
    String id,
    ProcurementIqcConfirmCreditCommand command,
  ) async => value;
  @override
  Future<ProcurementIqcRejectionDetail> retryFinanceProjection(
    String id,
    ProcurementIqcReasonCommand command,
  ) async => value;
  @override
  Future<ProcurementIqcRejectionDetail> reverse(
    String id,
    ProcurementIqcReasonCommand command,
  ) async => value;

  @override
  Future<PagedResult<ProcurementIqcRejectionCase>> list(
    ProcurementIqcRejectionFilter filter,
  ) => throw UnimplementedError();
  @override
  Future<ProcurementIqcRejectionCounts> counts(
    ProcurementIqcRejectionFilter filter,
  ) => throw UnimplementedError();
}

ProcurementIqcRejectionDetail _detail(ProcurementIqcRejectionCase item) =>
    ProcurementIqcRejectionDetail(
      caseItem: item,
      resolution: const ProcurementIqcResolution(
        baseUnitName: '件',
        creditableBaseQty: '5',
        state: 'OPEN',
        legacyUnclassified: false,
      ),
      creditSources: item.priceMasked
          ? const []
          : [
              ProcurementIqcCreditSource(
                sourceApLedgerId: 'ap-1',
                sourceBillNo: 'AP-001',
                amountOriginal: '25.0000',
                amountLocal: '25.0000',
                remainingAmountOriginal: '25.0000',
                creditedAmountOriginal: '0',
                cases: [
                  ProcurementIqcCreditCase(
                    caseId: item.id,
                    version: item.version,
                    receiptBillNo: item.receiptBillNo,
                    goodsName: item.goodsName,
                    creditableBaseQty: '5',
                    baseUnitName: '件',
                  ),
                ],
              ),
            ],
      events: const [
        ProcurementIqcRejectionEvent(
          id: 'event-1',
          eventType: 'FAIL_RECORDED',
          createdAt: '2026-08-31T10:00:00Z',
        ),
      ],
    );

ProcurementIqcRejectionCase _case({
  ProcurementIqcRejectionStatus status =
      ProcurementIqcRejectionStatus.returnRecorded,
  Set<String> actions = const {
    ProcurementIqcRejectionAction.confirmCredit,
    ProcurementIqcRejectionAction.closeNoCredit,
    ProcurementIqcRejectionAction.reverse,
  },
  bool masked = true,
  int version = 7,
  String? holdReason,
}) => ProcurementIqcRejectionCase(
  id: 'case-1',
  receiptType: ProcurementIqcReceiptType.purchase,
  receiptBillNo: 'PR-001',
  orderBillNo: 'PO-001',
  supplierName: '供应商A',
  goodsCode: 'G-001',
  goodsName: '轴套',
  failedBaseQty: '5',
  failedQty: '5',
  unitName: '件',
  failedAmountOriginal: '25.0000',
  failedAmountLocal: '25.0000',
  currencyCode: 'CNY',
  status: status,
  version: version,
  allowedActions: actions,
  priceMasked: masked,
  holdReason: holdReason,
);
