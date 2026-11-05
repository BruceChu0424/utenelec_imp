package com.uten.imp.features.finance.receivables;

import com.uten.imp.common.util.*;
import com.uten.imp.common.web.*;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.math.BigDecimal;
import java.util.*;

/** Read-only preparation for "choose an order, enter this collection"; approval rechecks every source. */
@Service
@RequiredArgsConstructor
public class SalesOrderCollectionPreviewService {
    private final EntityManager em;
    private final CustomerPrepaymentQueryService summaries;
    private final ReceiptOrderSourceAccess orderSources;
    private final com.uten.imp.application.port.CurrentStaffAuthorityPort staff;

    public record Part(UUID ledgerId,String billNo,String sourceDocNo,String amountOriginal,String balanceOriginal) { }
    public record Preview(UUID salesOrderId,String orderBillNo,UUID clientId,UUID currencyId,String receiptKind,
                          String amountOriginal,List<Part> items) { }

    @Transactional(readOnly=true,isolation=org.springframework.transaction.annotation.Isolation.REPEATABLE_READ)
    public Preview preview(UUID orderId,BigDecimal entered) {
        return preview(orderId,entered,null);
    }
    @Transactional(readOnly=true,isolation=org.springframework.transaction.annotation.Isolation.REPEATABLE_READ)
    public Preview preview(UUID orderId,BigDecimal entered,UUID selectedLedgerId) {
        BigDecimal amount=FinancialExactAmount.require(entered,"本次收款金额");
        if (amount.signum()<=0) throw new ApiException(ErrorCode.VALIDATION_FAILED,"本次收款金额必须大于0");
        var source=orderSources.require(orderId);
        var summary=summaries.salesOrderSummary(orderId);
        if (source.status()!=1 || summary.clientId()==null || summary.currencyId()==null
                || !Objects.equals(source.clientId(),summary.clientId()) || !Objects.equals(source.currencyId(),summary.currencyId()))
            throw new ApiException(ErrorCode.CONFLICT,"请选择已审核且客户、币种完整的销售订货单");
        if (!summary.positionComplete() || summary.hasUnallocated())
            throw new ApiException(ErrorCode.CONFLICT,"本订单应收或收款来源尚未核对清楚，请先由财务核对订单资金明细");
        var rows=NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT ledger.id,ledger.bill_no,ledger.source_doc_no,
                  SUM(remaining.original) AS available,BOOL_OR(remaining.original<0) AS invalid_source
                FROM ar_ap_source_refs ref JOIN ar_ap_ledger ledger ON ledger.id=ref.ledger_id
                CROSS JOIN LATERAL(SELECT ref.amount_original
                    -COALESCE((SELECT sum(a.cash_original+a.write_off_original)
                       FROM finance_receipt_source_allocations a WHERE a.source_ref_id=ref.id AND a.status='APPLIED'),0)
                    -COALESCE((SELECT sum(o.amount_original) FROM customer_open_item_offsets o
                       WHERE o.target_source_ref_id=ref.id AND o.status='APPLIED'),0) AS original) remaining
                WHERE ref.source_type='SALES_ORDER' AND ref.source_id=:orderId
                  AND ledger.status=1 AND NOT ledger.is_deleted AND ledger.direction='AR'
                  AND ledger.open_item_kind='RECEIVABLE' AND ledger.client_id=:client AND ledger.currency_id=:currency
                GROUP BY ledger.id,ledger.bill_no,ledger.source_doc_no,ledger.bill_date
                ORDER BY ledger.bill_date,ledger.id
                """).setParameter("orderId",orderId).setParameter("client",summary.clientId()).setParameter("currency",summary.currencyId()));
        if(rows.stream().anyMatch(row->NativeValueConverters.toBigDecimal(row[3]).signum()<0 || Boolean.TRUE.equals(row[4])))
            throw new ApiException(ErrorCode.CONFLICT,"本订单应收来源已超额使用，请先核对来源分配");
        if(selectedLedgerId!=null){
            rows=rows.stream().filter(row->selectedLedgerId.equals(row[0])).toList();
            if(rows.isEmpty())throw new ApiException(ErrorCode.CONFLICT,"所选订单不属于本次明确选择的出货应收批次");
        }else if(rows.stream().filter(row->NativeValueConverters.toBigDecimal(row[3]).signum()>0).count()>1){
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"同一订货单有多笔出货应收，请先明确选择本次出货批次，不能自动跨批分摊收款");
        }
        BigDecimal available=rows.stream().map(row->NativeValueConverters.toBigDecimal(row[3]))
                .reduce(BigDecimal.ZERO,BigDecimal::add);
        if (available.signum()==0) {
            if(selectedLedgerId!=null)throw new ApiException(ErrorCode.CONFLICT,"本次出货批次已无可分配给所选订单的应收，请核对批次来源");
            if(!staff.currentStaffPermissions().containsAll(Set.of("customer_prepayment:view","finance:view:all")))
                throw new ApiException(ErrorCode.FORBIDDEN,"本订单尚无正式应收，登记订单预收需要客户预收和全部财务查看权限");
            BigDecimal pending=NativeValueConverters.toBigDecimal(summary.plannedRemainingOriginal());
            if(pending.signum()<=0)throw new ApiException(ErrorCode.CONFLICT,"本订单当前已无待收金额，不能自动登记新的订单预收");
            if(amount.compareTo(pending)>0)throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "本次金额超过本订单当前待收金额 "+DecimalText.of(pending)+"，请先核对既有预收和超收处理");
            if (source.stopped() || source.closed())
                throw new ApiException(ErrorCode.CONFLICT,"已中止或结案订单不能新增预收款");
            return new Preview(orderId,summary.orderBillNo(),summary.clientId(),summary.currencyId(),
                    "CUSTOMER_PREPAYMENT",DecimalText.of(amount),List.of());
        }
        if (amount.compareTo(available)>0)
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"本次金额超过本订单已立账未收金额 "+DecimalText.of(available)
                    +"；未来货款请另用订单预收登记，不能把余额分给其他订单");
        BigDecimal remaining=amount;
        List<Part> parts=new ArrayList<>();
        for(Object[] row:rows) {
            BigDecimal balance=NativeValueConverters.toBigDecimal(row[3]);
            if (balance.signum()<0) throw new ApiException(ErrorCode.CONFLICT,"本订单应收来源已超额使用，请核对");
            BigDecimal slice=remaining.min(balance);
            if(slice.signum()>0) parts.add(new Part((UUID)row[0],Objects.toString(row[1],null),
                    Objects.toString(row[2],null),DecimalText.of(slice),DecimalText.of(balance)));
            remaining=remaining.subtract(slice);
            if(remaining.signum()==0)break;
        }
        return new Preview(orderId,summary.orderBillNo(),summary.clientId(),summary.currencyId(),
                "AR_SETTLEMENT",DecimalText.of(amount),List.copyOf(parts));
    }
}
