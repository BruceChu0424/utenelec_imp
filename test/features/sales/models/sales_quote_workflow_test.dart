// 报价单财务核价状态(ADR-134)：分桶映射、allowedActions 解析、核价记录解析。
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';

void main() {
  group('salesQuoteStageFor bucket mapping', () {
    test('falls back to status + return reason when the bucket is absent', () {
      expect(
        salesQuoteStageFor(status: kSalesStatusDraft),
        SalesQuoteStage.draft,
      );
      expect(
        salesQuoteStageFor(status: kSalesStatusDraft, financeReturnReason: ' '),
        SalesQuoteStage.draft,
        reason: 'blank reason is not a return',
      );
      expect(
        salesQuoteStageFor(
          status: kSalesStatusDraft,
          financeReturnReason: '客户要改数量',
        ),
        SalesQuoteStage.financeRejected,
      );
      expect(
        salesQuoteStageFor(status: kSalesStatusPendingFinance),
        SalesQuoteStage.pendingFinance,
      );
      expect(
        salesQuoteStageFor(status: kSalesStatusApproved),
        SalesQuoteStage.approved,
      );
      expect(
        salesQuoteStageFor(status: kSalesStatusReversed),
        SalesQuoteStage.reversed,
      );
      expect(salesQuoteStageFor(status: 9), isNull);
    });

    test('server bucket wins over the local derivation', () {
      expect(
        salesQuoteStageFor(
          status: kSalesStatusDraft,
          statusBucket: SalesQuoteStage.financeRejected,
        ),
        SalesQuoteStage.financeRejected,
      );
      // 不认识的分桶键退回本地推算，不把未知值当成分段。
      expect(
        salesQuoteStageFor(status: kSalesStatusApproved, statusBucket: 'X'),
        SalesQuoteStage.approved,
      );
    });

    test('segment keys equal the shipment draft key used by drafts', () {
      expect(SalesQuoteStage.draft, SalesShipmentStage.draft);
      expect(SalesQuoteStage.segments, [
        'DRAFT',
        'FINANCE_REJECTED',
        'PENDING_FINANCE',
        'AWAITING_CUSTOMER',
        'AWAITING_CONVERSION',
        'APPROVED',
        'REVERSED',
      ]);
    });

    test('status 2 has a generic label and colour for pickers', () {
      expect(salesStatusLabel(kSalesStatusPendingFinance), '待财务核价');
    });
  });

  test('customer acceptance is tied to the current revision', () {
    final accepted = SalesQuoteWorkflow.fromJson({
      'reviewRevision': 4,
      'customerAcceptedAt': '2026-10-02',
      'customerAcceptedRevision': 4,
      'allowedActions': ['customerConfirm', 'cancel', 'requote'],
    });
    expect(accepted.customerAccepted, isTrue);
    expect(accepted.allows(SalesQuoteAction.cancel), isTrue);
    final stale = SalesQuoteWorkflow.fromJson({
      'reviewRevision': 5,
      'customerAcceptedAt': '2026-10-02',
      'customerAcceptedRevision': 4,
    });
    expect(stale.customerAccepted, isFalse);
  });

  group('SalesQuoteWorkflow parsing', () {
    test('list rows carry bucket, reason, revision and actions', () {
      final item = SalesDocListItem.fromJson(const {
        'id': 'q-1',
        'status': 0,
        'statusBucket': 'finance_rejected',
        'financeReturnReason': '价格需销售与客户确认',
        'reviewRevision': 3,
        'allowedActions': ['EDIT', 'SUBMIT', 'delete'],
      });
      expect(salesQuoteStageOf(item), SalesQuoteStage.financeRejected);
      expect(item.quoteWorkflow.reviewRevision, 3);
      expect(item.quoteWorkflow.allows(SalesQuoteAction.edit), isTrue);
      expect(item.quoteWorkflow.allows(SalesQuoteAction.submit), isTrue);
      expect(item.quoteWorkflow.allows(SalesQuoteAction.delete), isTrue);
      expect(item.quoteWorkflow.allows(SalesQuoteAction.convert), isFalse);
    });

    test('action codes are case and underscore insensitive', () {
      final detail = SalesDocDetail.fromJson(const {
        'id': 'q-2',
        'status': 2,
        'allowedActions': ['FINANCE_REVIEW', 'withdraw'],
      });
      expect(detail.quoteWorkflow.hasAllowedActions, isTrue);
      expect(
        detail.quoteWorkflow.allows(SalesQuoteAction.financeReview),
        isTrue,
      );
      expect(detail.quoteWorkflow.allows(SalesQuoteAction.withdraw), isTrue);
    });

    test('old payloads without actions expose no buttons', () {
      final detail = SalesDocDetail.fromJson(const {'id': 'q-3', 'status': 1});
      expect(detail.quoteWorkflow.hasAllowedActions, isFalse);
      for (final action in SalesQuoteAction.values) {
        expect(detail.quoteWorkflow.allows(action), isFalse);
      }
      expect(salesQuoteDetailStage(detail), SalesQuoteStage.approved);
    });

    test('converted quotes and revision history', () {
      final detail = SalesDocDetail.fromJson(const {
        'id': 'q-4',
        'status': 1,
        'convertedOrderId': 'o-1',
        'convertedOrderNo': 'XD-001',
        'financeConfirmedByName': '王会计',
        'revisions': [
          {
            'revision': 1,
            'action': 'submit',
            'actorName': '张销售',
            'createdAt': '2026-09-27T01:00:00Z',
          },
          {
            'revision': 2,
            'action': 'CONFIRM',
            'actorName': '王会计',
            'createdAt': '2026-09-27T02:00:00Z',
          },
          'not-an-object',
        ],
      });
      final wf = detail.quoteWorkflow;
      expect(wf.isConverted, isTrue);
      expect(wf.convertedOrderNo, 'XD-001');
      expect(wf.financeConfirmedByName, '王会计');
      expect(wf.revisions.map((r) => r.action), [
        SalesQuoteRevisionAction.submit,
        SalesQuoteRevisionAction.confirm,
      ]);
    });
  });
}
