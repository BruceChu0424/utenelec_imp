package com.uten.imp.features.finance.receivables;

import com.uten.imp.application.port.SalesOrderMoneyReadPort;
import com.uten.imp.common.util.DecimalText;
import com.uten.imp.common.util.NativeValueConverters;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;
import java.util.*;

@Component
@RequiredArgsConstructor
public class SalesOrderMoneyReadAdapter implements SalesOrderMoneyReadPort {
    private final CustomerPrepaymentQueryService query;
    private final EntityManager em;

    @Override
    @Transactional(readOnly = true,isolation=org.springframework.transaction.annotation.Isolation.REPEATABLE_READ)
    public Map<UUID, Position> read(Collection<UUID> salesOrderIds, boolean includeCustomerUnassigned) {
        Integer isolation=org.springframework.transaction.support.TransactionSynchronizationManager.getCurrentTransactionIsolationLevel();
        if(!org.springframework.transaction.support.TransactionSynchronizationManager.isActualTransactionActive()
                || (!Objects.equals(isolation,java.sql.Connection.TRANSACTION_REPEATABLE_READ)
                    && !Objects.equals(isolation,java.sql.Connection.TRANSACTION_SERIALIZABLE))) {
            Map<UUID,Position> unavailable=new LinkedHashMap<>();
            SalesOrderMoneyBatchReader.ids(salesOrderIds).forEach(id->unavailable.put(id,Position.unavailable()));
            return unavailable;
        }
        var summaries = query.salesOrderSummaries(salesOrderIds);
        if (summaries.isEmpty()) {
            Map<UUID,Position> unavailable=new LinkedHashMap<>();
            SalesOrderMoneyBatchReader.ids(salesOrderIds).forEach(id->unavailable.put(id,Position.unavailable()));
            return unavailable;
        }
        var unassigned = includeCustomerUnassigned ? SalesOrderMoneyBatchReader.rows(em, """
                SELECT COALESCE(SUM(ABS(ledger.amount_balance_original)),0)
                FROM ar_ap_ledger ledger
                JOIN finance_receipts receipt ON receipt.id=ledger.source_doc_id
                JOIN sales_orders target ON target.id=:orderId
                WHERE ledger.direction='AR' AND ledger.open_item_kind='CUSTOMER_PREPAYMENT'
                  AND ledger.source_doc_type='DIRECT_RECEIPT' AND ledger.status=1 AND NOT ledger.is_deleted
                  AND receipt.receipt_kind='CUSTOMER_PREPAYMENT' AND receipt.status=1
                  AND receipt.legacy_id IS NULL AND NOT receipt.is_deleted AND receipt.sales_order_id IS NULL
                  AND ledger.client_id=target.client_id AND ledger.currency_id=target.currency_id
                """, summaries.keySet()) : Map.<UUID,List<Object[]>>of();
        var pending=SalesOrderMoneyBatchReader.rows(em,"""
                SELECT COALESCE((SELECT SUM(receipt.amount_original) FROM finance_receipts receipt
                  WHERE receipt.sales_order_id=:orderId AND receipt.receipt_kind='CUSTOMER_PREPAYMENT'
                    AND receipt.status=0 AND NOT receipt.is_deleted),0)
                  +COALESCE((SELECT SUM(line.amount_original) FROM finance_receipt_lines line
                    JOIN finance_receipts receipt ON receipt.id=line.receipt_id
                    WHERE line.requested_sales_order_id=:orderId AND receipt.receipt_kind='AR_SETTLEMENT'
                      AND receipt.status=0 AND NOT receipt.is_deleted),0)
                """,summaries.keySet());
        Map<UUID, Position> result = new LinkedHashMap<>();
        summaries.forEach((id, summary) -> {
            if(!pending.containsKey(id) || (includeCustomerUnassigned && !unassigned.containsKey(id))) {
                result.put(id,Position.unavailable());return;
            }
            result.put(id, new Position(summary.cashReceivedOriginal(),
                summary.plannedRemainingOriginal(), summary.prepaymentAvailableOriginal(),
                includeCustomerUnassigned ? DecimalText.of(NativeValueConverters.toBigDecimal(unassigned.get(id).getFirst()[0])) : null,
                summary.prepaymentAppliedOriginal(),summary.returnCreditOriginal(),summary.customerPendingBalanceOriginal(),
                DecimalText.of(NativeValueConverters.toBigDecimal(pending.get(id).getFirst()[0])),
                summary.hasUnallocated(), summary.positionComplete(),summary.orderBillNo(),summary.currencyName(), summary.warnings()));
        });
        SalesOrderMoneyBatchReader.ids(salesOrderIds).forEach(id->result.putIfAbsent(id,Position.unavailable()));
        return result;
    }
}
