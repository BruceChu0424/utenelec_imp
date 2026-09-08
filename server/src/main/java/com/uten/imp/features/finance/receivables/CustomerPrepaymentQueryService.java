package com.uten.imp.features.finance.receivables;

import com.uten.imp.common.util.NativeValueConverters;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;
import java.util.Objects;
import java.util.UUID;

import static com.uten.imp.features.finance.receivables.CustomerPrepaymentContracts.*;

/** Read model for available advances and exact sales-order money summaries. */
@Service
@RequiredArgsConstructor
public class CustomerPrepaymentQueryService {

    private final EntityManager em;
    private final SalesOrderMoneyPositionQuery positions;

    @Transactional(readOnly = true)
    public PrepaymentPage list(
            UUID clientId, UUID currencyId, UUID salesOrderId, int requestedPage, int requestedSize) {
        int page = Math.max(1, requestedPage);
        int size = Math.min(200, Math.max(1, requestedSize));
        String where = """
                FROM ar_ap_ledger ledger
                JOIN finance_receipts receipt ON receipt.id=ledger.source_doc_id
                LEFT JOIN clients client ON client.id=ledger.client_id
                LEFT JOIN currencies currency ON currency.id=ledger.currency_id
                WHERE ledger.direction='AR' AND ledger.open_item_kind='CUSTOMER_PREPAYMENT'
                  AND ledger.source_doc_type='DIRECT_RECEIPT' AND ledger.status=1
                  AND COALESCE(ledger.is_deleted,FALSE)=FALSE
                  AND receipt.receipt_kind='CUSTOMER_PREPAYMENT' AND receipt.status=1
                  AND COALESCE(receipt.is_deleted,FALSE)=FALSE
                """ + (clientId == null ? "" : " AND ledger.client_id=:clientId")
                + (currencyId == null ? "" : " AND ledger.currency_id=:currencyId")
                + (salesOrderId == null ? "" : " AND (receipt.sales_order_id IS NULL OR receipt.sales_order_id=:salesOrderId)");
        Query countQuery = bind(em.createNativeQuery("SELECT COUNT(*) " + where),
                clientId, currencyId, salesOrderId);
        long total = number(countQuery.getSingleResult()).longValue();
        @SuppressWarnings("unchecked")
        List<Object[]> rows = bind(em.createNativeQuery("""
                SELECT ledger.id,receipt.id,receipt.bill_no,receipt.bill_date,receipt.sales_order_id,
                       ledger.client_id,client.name,ledger.currency_id,currency.code,currency.name,
                       ledger.exchange_rate,
                       ledger.amount_received_original,ledger.amount_received_local,
                       ABS(ledger.amount_offset_original),ABS(ledger.amount_offset_local),
                       ABS(ledger.amount_balance_original),ABS(ledger.amount_balance),ledger.updated_at
                """ + where + " ORDER BY receipt.bill_date DESC,receipt.bill_no DESC,ledger.id"),
                clientId, currencyId, salesOrderId)
                .setFirstResult((page - 1) * size).setMaxResults(size).getResultList();
        List<PrepaymentItem> items = rows.stream().map(row -> new PrepaymentItem(
                (UUID) row[0], (UUID) row[1], Objects.toString(row[2], null),
                NativeValueConverters.toLocalDate(row[3]), (UUID) row[4], (UUID) row[5],
                Objects.toString(row[6], null), (UUID) row[7], Objects.toString(row[8], null),
                Objects.toString(row[9], null), rate(row[10]), money(row[11]), money(row[12]),
                money(row[13]), money(row[14]), money(row[15]), money(row[16]),
                NativeValueConverters.toOffsetDateTime(row[17]))).toList();
        Object[] summary = (Object[]) bind(em.createNativeQuery("""
                SELECT COALESCE(SUM(ledger.amount_received_original),0),
                       COALESCE(SUM(ledger.amount_received_local),0),
                       COALESCE(SUM(ABS(ledger.amount_offset_original)),0),
                       COALESCE(SUM(ABS(ledger.amount_offset_local)),0),
                       COALESCE(SUM(ABS(ledger.amount_balance_original)),0),
                       COALESCE(SUM(ABS(ledger.amount_balance)),0)
                """ + where), clientId, currencyId, salesOrderId).getSingleResult();
        return new PrepaymentPage(new PrepaymentListSummary(
                money(summary[0]), money(summary[1]), money(summary[2]),
                money(summary[3]), money(summary[4]), money(summary[5])), items,
                page, size, total, total == 0 ? 0 : (int) Math.ceil((double) total / size));
    }

    @Transactional(readOnly = true, isolation = org.springframework.transaction.annotation.Isolation.REPEATABLE_READ)
    public SalesOrderMoneySummary salesOrderSummary(UUID salesOrderId) {
        @SuppressWarnings("unchecked")
        List<Object[]> orders = em.createNativeQuery("""
                SELECT sales_order.id,sales_order.bill_no,sales_order.client_id,sales_order.currency_id,
                       currency.code,sales_order.total_original,sales_order.total_local
                FROM sales_orders sales_order
                LEFT JOIN currencies currency ON currency.id=sales_order.currency_id
                WHERE sales_order.id=:id AND COALESCE(sales_order.is_deleted,FALSE)=FALSE
                """).setParameter("id", salesOrderId).getResultList();
        if (orders.size() != 1) throw new ApiException(ErrorCode.NOT_FOUND, "销售单不存在");
        Object[] order = orders.getFirst();
        BigDecimal orderOriginal = decimal(order[5]);
        BigDecimal orderLocal = decimal(order[6]);

        var invoicePosition = positions.invoices(salesOrderId);
        var returnPosition = positions.returns(salesOrderId);
        var futurePosition = positions.future(salesOrderId);
        BigDecimal formalOriginal = invoicePosition.grossOriginal();
        BigDecimal formalLocal = invoicePosition.grossLocal();

        Object[] receiptApplied = (Object[]) em.createNativeQuery("""
                SELECT COALESCE(SUM(cash_original),0),COALESCE(SUM(cash_local),0),
                       COALESCE(SUM(write_off_original),0),COALESCE(SUM(write_off_local),0),
                       COALESCE(SUM(applied_book_local),0)
                FROM finance_receipt_source_allocations
                WHERE sales_order_id=:orderId AND status='APPLIED'
                """).setParameter("orderId", salesOrderId).getSingleResult();
        BigDecimal ordinaryCashOriginal = decimal(receiptApplied[0]);
        BigDecimal ordinaryCashLocal = decimal(receiptApplied[1]);
        BigDecimal writeOffOriginal = decimal(receiptApplied[2]);
        BigDecimal writeOffLocal = decimal(receiptApplied[3]);
        BigDecimal receiptBookLocal = decimal(receiptApplied[4]);

        Object[] boundPrepayments = (Object[]) em.createNativeQuery("""
                SELECT COALESCE(SUM(receipt.amount_original),0),COALESCE(SUM(receipt.amount_local),0),
                       COALESCE(SUM(ABS(ledger.amount_balance_original)),0),
                       COALESCE(SUM(ABS(ledger.amount_balance)),0)
                FROM finance_receipts receipt
                JOIN ar_ap_ledger ledger ON ledger.source_doc_id=receipt.id
                  AND ledger.source_doc_type='DIRECT_RECEIPT'
                WHERE receipt.sales_order_id=:orderId AND receipt.receipt_kind='CUSTOMER_PREPAYMENT'
                  AND receipt.status=1 AND COALESCE(receipt.is_deleted,FALSE)=FALSE
                  AND ledger.status=1 AND COALESCE(ledger.is_deleted,FALSE)=FALSE
                """).setParameter("orderId", salesOrderId).getSingleResult();
        BigDecimal prepaymentReceivedOriginal = decimal(boundPrepayments[0]);
        BigDecimal prepaymentReceivedLocal = decimal(boundPrepayments[1]);
        BigDecimal prepaymentAvailableOriginal = decimal(boundPrepayments[2]);
        BigDecimal prepaymentAvailableLocal = decimal(boundPrepayments[3]);

        Object[] offsets = (Object[]) em.createNativeQuery("""
                SELECT COALESCE(SUM(o.amount_original),0),
                       COALESCE(SUM(o.source_amount_local),0),
                       COALESCE(SUM(o.target_amount_local),0),
                       COALESCE(SUM(o.exchange_difference),0),
                       COALESCE(SUM(o.amount_original) FILTER(WHERE source_receipt.sales_order_id IS NULL),0),
                       COALESCE(SUM(o.source_amount_local) FILTER(WHERE source_receipt.sales_order_id IS NULL),0)
                FROM customer_open_item_offsets o
                JOIN ar_ap_ledger source_ledger ON source_ledger.id=o.source_ledger_id
                JOIN finance_receipts source_receipt ON source_receipt.id=source_ledger.source_doc_id
                WHERE o.sales_order_id=:orderId AND o.status='APPLIED'
                """).setParameter("orderId", salesOrderId).getSingleResult();
        BigDecimal prepaymentAppliedOriginal = decimal(offsets[0]);
        BigDecimal prepaymentAppliedSourceLocal = decimal(offsets[1]);
        BigDecimal prepaymentAppliedTargetLocal = decimal(offsets[2]);
        BigDecimal prepaymentFx = decimal(offsets[3]);
        BigDecimal generalAppliedOriginal = decimal(offsets[4]);
        BigDecimal generalAppliedSourceLocal = decimal(offsets[5]);

        List<UnallocatedReceiptLine> unallocated = unallocatedLines(salesOrderId);
        boolean hasUnallocated = !unallocated.isEmpty() || invoicePosition.unresolvedCashCount()>0;
        List<String> warnings = new ArrayList<>();
        if (hasUnallocated) warnings.add(
                "部分客户付款或历史结算缺少准确的订单来源明细，客户已付金额需财务核对");
        boolean positionComplete = invoicePosition.unresolvedCount()==0 && returnPosition.unresolvedCount()==0
                && futurePosition.unresolvedCount()==0 && (futurePosition.itemCount()>0 || orderOriginal.signum()==0);
        if (invoicePosition.unresolvedCount()>0) warnings.add("部分发货应收未准确对应到本订单，当前余额需财务核对");
        if (returnPosition.unresolvedCount()>0) warnings.add("部分退货金额或已处理金额无法准确对应到本订单，当前余额需财务核对");
        if (futurePosition.unresolvedCount()>0 || (futurePosition.itemCount()==0 && orderOriginal.signum()!=0)) {
            warnings.add("订单明细不足以准确计算后续发货金额，请先核对订单");
        }

        BigDecimal exactAppliedOriginal = ordinaryCashOriginal.add(writeOffOriginal)
                .add(prepaymentAppliedOriginal);
        BigDecimal exactAppliedLocal = receiptBookLocal.add(prepaymentAppliedTargetLocal);
        if (formalOriginal.subtract(exactAppliedOriginal).signum() < 0 || formalLocal.subtract(exactAppliedLocal).signum() < 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "销售单应收来源已被超额核销，资金汇总不守恒；请财务核验来源分配");
        }
        BigDecimal arOutstandingOriginal = invoicePosition.remainingOriginal();
        BigDecimal arOutstandingLocal = invoicePosition.remainingLocal();
        BigDecimal cashReceivedOriginal = ordinaryCashOriginal
                .add(prepaymentReceivedOriginal).add(generalAppliedOriginal);
        BigDecimal cashReceivedLocal = ordinaryCashLocal
                .add(prepaymentReceivedLocal).add(generalAppliedSourceLocal);
        BigDecimal signedNetOriginal = arOutstandingOriginal.subtract(returnPosition.unusedOriginal());
        BigDecimal signedNetLocal = arOutstandingLocal.subtract(returnPosition.unusedLocal());
        BigDecimal remainingAfterAvailableMoney = signedNetOriginal.add(futurePosition.original())
                .subtract(prepaymentAvailableOriginal);
        BigDecimal plannedRemaining = remainingAfterAvailableMoney.max(BigDecimal.ZERO);
        BigDecimal overpaid = remainingAfterAvailableMoney.negate().max(BigDecimal.ZERO);

        return new SalesOrderMoneySummary((UUID) order[0], Objects.toString(order[1], null),
                (UUID) order[2], (UUID) order[3], Objects.toString(order[4], null),
                money(orderOriginal), money(orderLocal), money(formalOriginal), money(formalLocal),
                hasUnallocated ? null : money(cashReceivedOriginal), hasUnallocated ? null : money(cashReceivedLocal), money(writeOffOriginal), money(writeOffLocal),
                money(prepaymentReceivedOriginal), money(prepaymentReceivedLocal),
                money(prepaymentAppliedOriginal), money(prepaymentAppliedSourceLocal),
                money(prepaymentAppliedTargetLocal), money(prepaymentFx),
                money(prepaymentAvailableOriginal), money(prepaymentAvailableLocal),
                positionComplete ? money(arOutstandingOriginal) : null, positionComplete ? money(arOutstandingLocal) : null,
                futurePosition.unresolvedCount()==0 ? money(futurePosition.original()) : null, null,
                positionComplete ? money(plannedRemaining) : null, positionComplete ? money(overpaid) : null,
                hasUnallocated, unallocated, List.copyOf(warnings),
                returnPosition.unresolvedCount()==0 ? money(returnPosition.totalOriginal()) : null,
                returnPosition.unresolvedCount()==0 ? money(returnPosition.totalLocal()) : null,
                returnPosition.unresolvedCount()==0 ? money(returnPosition.unusedOriginal()) : null,
                returnPosition.unresolvedCount()==0 ? money(returnPosition.unusedLocal()) : null,
                positionComplete ? money(signedNetOriginal.max(BigDecimal.ZERO)) : null,
                positionComplete ? money(signedNetLocal.max(BigDecimal.ZERO)) : null,
                positionComplete ? money(signedNetOriginal.negate().max(BigDecimal.ZERO)) : null,
                positionComplete ? money(signedNetLocal.negate().max(BigDecimal.ZERO)) : null,
                positionComplete, invoicePosition.unresolvedCount()+returnPosition.unresolvedCount()
                        +futurePosition.unresolvedCount()
                        +(futurePosition.itemCount()==0 && orderOriginal.signum()!=0 ? 1 : 0));
    }

    @SuppressWarnings("unchecked")
    private List<UnallocatedReceiptLine> unallocatedLines(UUID salesOrderId) {
        List<Object[]> rows = em.createNativeQuery("""
                SELECT line.id,receipt.id,receipt.bill_no,receipt.bill_date,
                       line.amount_original,line.amount_local,
                       CASE WHEN (SELECT COUNT(*) FROM ar_ap_source_refs source_count
                                   WHERE source_count.ledger_id=line.applied_ledger_id
                                     AND source_count.source_type='SALES_ORDER')>1
                            THEN '历史应收包含多个销售单来源且本收款未完整冻结来源分配'
                            ELSE '收款来源分配与权威明细金额不守恒' END reason
                FROM finance_receipt_lines line
                JOIN finance_receipts receipt ON receipt.id=line.receipt_id
                JOIN ar_ap_source_refs order_ref ON order_ref.ledger_id=line.applied_ledger_id
                  AND order_ref.source_type='SALES_ORDER' AND order_ref.source_id=:orderId
                LEFT JOIN finance_receipt_source_allocations allocation
                  ON allocation.receipt_line_id=line.id AND allocation.status='APPLIED'
                WHERE receipt.receipt_kind='AR_SETTLEMENT' AND receipt.status=1
                  AND COALESCE(receipt.is_deleted,FALSE)=FALSE
                  AND COALESCE(line.is_deleted,FALSE)=FALSE
                GROUP BY line.id,receipt.id,receipt.bill_no,receipt.bill_date,line.applied_ledger_id,
                         line.amount_original,line.amount_local,line.write_off_amount,line.applied_amount_local
                HAVING COALESCE(SUM(allocation.cash_original),0)<>line.amount_original
                    OR COALESCE(SUM(allocation.write_off_original),0)<>COALESCE(line.write_off_amount,0)
                    OR COALESCE(SUM(allocation.applied_book_local),0)<>COALESCE(line.applied_amount_local,line.amount_local)
                ORDER BY receipt.bill_date,line.id
                """).setParameter("orderId", salesOrderId).getResultList();
        return rows.stream().map(row -> new UnallocatedReceiptLine(
                (UUID) row[0], (UUID) row[1], Objects.toString(row[2], null),
                NativeValueConverters.toLocalDate(row[3]), money(row[4]), money(row[5]),
                Objects.toString(row[6], null))).toList();
    }

    private Query bind(Query query, UUID clientId, UUID currencyId, UUID salesOrderId) {
        if (clientId != null) query.setParameter("clientId", clientId);
        if (currencyId != null) query.setParameter("currencyId", currencyId);
        if (salesOrderId != null) query.setParameter("salesOrderId", salesOrderId);
        return query;
    }

    private static Number number(Object value) {
        if (value instanceof Number number) return number;
        return new BigDecimal(value.toString());
    }

    private static BigDecimal decimal(Object value) {
        return NativeValueConverters.toBigDecimal(value);
    }

    private static String money(Object value) {
        return value==null?null:com.uten.imp.common.util.DecimalText.of(decimal(value));
    }

    private static String rate(Object value) {
        return value==null?null:com.uten.imp.common.util.DecimalText.of(decimal(value));
    }
}
