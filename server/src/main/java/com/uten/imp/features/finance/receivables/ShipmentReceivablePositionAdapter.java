package com.uten.imp.features.finance.receivables;

import com.uten.imp.application.port.ShipmentReceivablePositionPort;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.util.*;
import com.uten.imp.common.web.*;
import com.uten.imp.features.finance.receipt.ReceiptCashPostingProof;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.*;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import java.math.BigDecimal;
import java.time.*;
import java.time.temporal.ChronoUnit;
import java.util.*;

/** One physical batch, one active AR; no order-wide advance or future promise is treated as paid. */
@Component
@RequiredArgsConstructor
public class ShipmentReceivablePositionAdapter implements ShipmentReceivablePositionPort {
    private final EntityManager em;
    static final String SQL="""
        SELECT shipment.id,shipment.currency_id,currency.name,shipment.total_original,shipment.status,shipment.ar_posted,shipment.billing_mode,
               ledger.id,ledger.currency_id,ledger.open_item_kind,ledger.amount_original,ledger.amount_received_original,
               ledger.amount_offset_original,ledger.amount_write_off_original,ledger.amount_balance_original,ledger.due_date,
               count(ledger.id) OVER(PARTITION BY shipment.id),cash.received,cash.unverified,
               advances.applied,advances.unverified,shipment.client_id,ledger.client_id
        FROM sales_shipments shipment LEFT JOIN currencies currency ON currency.id=shipment.currency_id
        LEFT JOIN ar_ap_ledger ledger ON ledger.source_doc_id=shipment.id AND ledger.source_doc_type='SALES_SHIPMENT'
          AND ledger.direction='AR' AND ledger.status=1 AND NOT ledger.is_deleted
        LEFT JOIN LATERAL(
          SELECT COALESCE(sum(line.amount_original),0) AS received,
            count(*) FILTER(WHERE (%s) IS NOT TRUE OR receipt.client_id IS DISTINCT FROM shipment.client_id
              OR receipt.currency_id IS DISTINCT FROM ledger.currency_id OR line.currency_id IS DISTINCT FROM ledger.currency_id OR receipt.bank_booked_at>:asOf) AS unverified
          FROM finance_receipt_lines line JOIN finance_receipts receipt ON receipt.id=line.receipt_id
          LEFT JOIN LATERAL(%s) bank ON TRUE
          WHERE line.applied_ledger_id=ledger.id AND receipt.status=1 AND NOT receipt.is_deleted AND NOT line.is_deleted
        ) cash ON TRUE
        LEFT JOIN LATERAL(
          SELECT COALESCE(sum(application.amount_original),0) AS applied,
            count(*) FILTER(WHERE (%s) IS NOT TRUE OR source.status<>1 OR source.is_deleted
              OR source.open_item_kind<>'CUSTOMER_PREPAYMENT' OR source.source_doc_type<>'DIRECT_RECEIPT'
              OR source.client_id IS DISTINCT FROM shipment.client_id OR source.currency_id IS DISTINCT FROM ledger.currency_id
              OR receipt.client_id IS DISTINCT FROM source.client_id OR receipt.currency_id IS DISTINCT FROM source.currency_id
              OR application.amount_original<=0 OR receipt.bank_booked_at>:asOf) AS unverified
          FROM customer_open_item_offsets application JOIN ar_ap_ledger source ON source.id=application.source_ledger_id
          LEFT JOIN finance_receipts receipt ON receipt.id=source.source_doc_id AND receipt.status=1 AND NOT receipt.is_deleted
          LEFT JOIN LATERAL(%s) bank ON TRUE
          WHERE application.target_ledger_id=ledger.id AND application.status='APPLIED'
        ) advances ON TRUE
        WHERE shipment.id IN(:ids) AND NOT shipment.is_deleted
        """.formatted(ReceiptCashPostingProof.approvedPosting("receipt","bank"),ReceiptCashPostingProof.aggregate("receipt"),
                ReceiptCashPostingProof.approvedPosting("receipt","bank"),ReceiptCashPostingProof.aggregate("receipt"));

    @Override @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
    public Map<UUID,Position> read(Collection<UUID> shipmentIds) {
        List<UUID> ids=shipmentIds==null?List.of():shipmentIds.stream().filter(Objects::nonNull).distinct().toList();
        if(ids.size()>200)throw new ApiException(ErrorCode.VALIDATION_FAILED,"批次资金每次最多查询200张出货单");
        Map<UUID,Position> result=new LinkedHashMap<>();if(ids.isEmpty())return result;
        Integer level=TransactionSynchronizationManager.getCurrentTransactionIsolationLevel();
        if(!TransactionSynchronizationManager.isActualTransactionActive() ||
                (!Objects.equals(level,java.sql.Connection.TRANSACTION_REPEATABLE_READ) && !Objects.equals(level,java.sql.Connection.TRANSACTION_SERIALIZABLE))){
            ids.forEach(id->result.put(id,unknown(null,null,null,"本批资金尚未建立一致性快照，请刷新后核对")));return result;
        }
        for(Object[] row:NativeQueryResults.objectArrayRows(em.createNativeQuery(SQL).setParameter("ids",ids).setParameter("asOf",OffsetDateTime.now()))){
            UUID id=(UUID)row[0],currency=(UUID)row[1];String name=Objects.toString(row[2],null),planned=text(row[3]);
            int status=((Number)row[4]).intValue();boolean posted=Boolean.TRUE.equals(row[5]);
            long ledgers=((Number)row[16]).longValue();
            if(status<0){result.put(id,ledgers==0?empty(currency,name,planned,"REVERSED"):unknown(currency,name,planned,"已反向出货仍有有效应收，请核对本批反向链"));continue;}
            BigDecimal plannedAmount=decimal(row[3]);
            if(plannedAmount==null||plannedAmount.signum()<0||(!"FREE".equals(row[6])&&!"CHARGED".equals(row[6]))){
                result.put(id,unknown(currency,name,planned,"本批货款或收费方式不完整，不能推定免费或已收清"));continue;
            }
            if("FREE".equals(row[6])){
                result.put(id,plannedAmount.signum()==0&&ledgers==0&&!posted
                    ?new Position(null,currency,name,planned,"0","0","0","0","0","0","0","0",null,0,"FREE",true,List.of())
                    :unknown(currency,name,planned,"不收费出货与实际货款或正式应收矛盾，请核对"));continue;
            }
            if(status!=1){result.put(id,!posted&&ledgers==0?empty(currency,name,planned,"NOT_POSTED")
                    :unknown(currency,name,planned,"待出库单已出现正式应收，不能作为正常本批收款依据"));continue;}
            if(!posted||ledgers==0){result.put(id,unknown(currency,name,planned,"已出库单缺少唯一有效正式应收，请核对本批立账"));continue;}
            if(ledgers!=1 || currency==null || !Objects.equals(currency,row[8]) || row[21]==null || !Objects.equals(row[21],row[22]) || !"RECEIVABLE".equals(row[9])){
                result.put(id,unknown(currency,name,planned,"本批应收不是唯一有效的同币种来源，请财务核对"));continue;
            }
            BigDecimal gross=decimal(row[10]),received=decimal(row[11]),offset=decimal(row[12]),reduction=decimal(row[13]),balance=decimal(row[14]);
            BigDecimal provenCash=decimal(row[17]),advance=decimal(row[19]);
            boolean valid=gross!=null&&received!=null&&offset!=null&&reduction!=null&&balance!=null&&provenCash!=null&&advance!=null
                    && gross.signum()>=0 && received.signum()>=0 && offset.signum()>=0 && reduction.signum()>=0 && balance.signum()>=0
                    && gross.compareTo(plannedAmount)==0
                    && ((Number)row[18]).longValue()==0 && ((Number)row[20]).longValue()==0
                    && received.compareTo(provenCash)==0 && advance.signum()>=0 && advance.compareTo(offset)<=0
                    && gross.subtract(received).subtract(offset).subtract(reduction).compareTo(balance)==0;
            if(!valid){result.put(id,unknown(currency,name,planned,"本批现金、预收抵扣或应收余额缺少守恒的核准来源，请财务核对"));continue;}
            LocalDate due=NativeValueConverters.toLocalDate(row[15]);
            long overdue=balance.signum()>0&&due!=null?Math.max(0,ChronoUnit.DAYS.between(due,BusinessTime.today())):0;
            // Existing customer_open_item_offsets is exclusively prepayment. Other recorded offsets are not cash.
            BigDecimal other=offset.subtract(advance);
            result.put(id,new Position((UUID)row[7],currency,name,planned,text(gross),text(received),text(advance),text(received.add(advance)),
                    text(reduction),other.signum()==0?"0":null,text(other),text(balance),due==null?null:due.toString(),overdue,"READY",true,
                    other.signum()>0?List.of("另有非现金抵扣，不能计入已收；退货和其它调整请按来源明细核对"):List.of()));
        }
        ids.forEach(id->result.putIfAbsent(id,unknown(null,null,null,"本批资料已变化，请刷新后核对")));
        return result;
    }
    private static BigDecimal decimal(Object value){return value==null?null:NativeValueConverters.toBigDecimal(value);}
    private static String text(Object value){return value==null?null:DecimalText.of(NativeValueConverters.toBigDecimal(value));}
    private static Position empty(UUID currency,String name,String planned,String state){return new Position(null,currency,name,planned,null,null,null,null,null,null,null,null,null,0,state,true,List.of());}
    private static Position unknown(UUID currency,String name,String planned,String warning){return new Position(null,currency,name,planned,null,null,null,null,null,null,null,null,null,0,"UNVERIFIED",false,List.of(warning));}
}
