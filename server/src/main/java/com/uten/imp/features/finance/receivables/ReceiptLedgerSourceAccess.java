package com.uten.imp.features.finance.receivables;

import com.uten.imp.application.port.*;
import com.uten.imp.common.util.*;
import com.uten.imp.common.web.*;
import com.uten.imp.security.DocumentAccessPolicy.NativeReadScope;
import jakarta.persistence.*;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;
import java.util.*;

/** A receipt references this actual shipment AR; legacy opening AR must carry its independent proof. */
@Component @RequiredArgsConstructor
public class ReceiptLedgerSourceAccess {
    private final EntityManager em;
    private final SalesDocumentReadScopePort salesScope;
    private final CurrentStaffAuthorityPort staff;
    private NativeReadScope scope(){
        return staff.currentStaffPermissions().contains("finance:view:all")?new NativeReadScope("TRUE",null,Set.of())
                :salesScope.nativeReadScope("shipment.owner_employee_id","receiptShipmentOwners");
    }
    private String from(NativeReadScope scope){return """
        FROM ar_ap_ledger ledger
        LEFT JOIN sales_shipments shipment ON ledger.source_doc_type='SALES_SHIPMENT' AND shipment.id=ledger.source_doc_id
        LEFT JOIN currencies currency ON currency.id=ledger.currency_id
        LEFT JOIN clients party ON party.id=ledger.client_id
        WHERE ledger.direction='AR' AND (ledger.open_item_kind='RECEIVABLE' OR fn_is_verified_legacy_opening_ar(ledger.id))
          AND ledger.status=1 AND NOT ledger.is_deleted
          AND ((shipment.id IS NOT NULL AND NOT shipment.is_deleted AND shipment.status=1 AND shipment.ar_posted
                AND shipment.client_id=ledger.client_id AND shipment.currency_id=ledger.currency_id)
               OR fn_is_verified_legacy_opening_ar(ledger.id))
          AND (
        """+scope.predicate()+")";}
    @Transactional(readOnly=true)
    public void require(UUID ledgerId){
        NativeReadScope scope=scope();var query=em.createNativeQuery("SELECT ledger.id "+from(scope)+" AND ledger.id=:ledgerId")
                .setParameter("ledgerId",ledgerId);scope.bind(query);
        if(query.getResultList().size()!=1)throw new ApiException(ErrorCode.NOT_FOUND,"出货应收批次不存在、尚未立账或无权引用；历史期初须已核验来源");
    }
    @Transactional(readOnly=true,isolation=org.springframework.transaction.annotation.Isolation.REPEATABLE_READ)
    public PageResponse<Map<String,Object>> choices(UUID client,String keyword,int page,int size){
        NativeReadScope scope=scope();var pageable=Pageables.of(page,size);
        String where=from(scope)+" AND NOT ledger.is_settled AND ledger.amount_balance_original>0";
        if(client!=null)where+=" AND ledger.client_id=:client";
        boolean search=keyword!=null&&!keyword.isBlank();if(search)where+=" AND (ledger.source_doc_no ILIKE :keyword OR ledger.bill_no ILIKE :keyword OR party.name ILIKE :keyword)";
        var count=em.createNativeQuery("SELECT count(*) "+where);
        var data=em.createNativeQuery("""
            SELECT ledger.id,ledger.bill_no,ledger.bill_date,ledger.source_doc_type,ledger.source_doc_id,ledger.source_doc_no,
                ledger.client_id,ledger.currency_id,currency.code,currency.name,ledger.exchange_rate,
                ledger.amount_original,ledger.amount_received_original,ledger.amount_offset_original,
                ledger.amount_write_off_original,ledger.amount_balance_original,ledger.due_date,ledger.open_item_kind,
                COALESCE((SELECT sum(application.amount_original) FROM customer_open_item_offsets application
                  WHERE application.target_ledger_id=ledger.id AND application.status='APPLIED'),0),party.name
            """+where+" ORDER BY ledger.bill_date,ledger.id");
        for(var query:List.of(count,data)){scope.bind(query);if(client!=null)query.setParameter("client",client);if(search)query.setParameter("keyword","%"+keyword.trim()+"%");}
        long total=((Number)count.getSingleResult()).longValue();
        var rows=NativeQueryResults.objectArrayRows(data.setFirstResult(Pageables.checkedOffset(pageable.getPageNumber()+1,pageable.getPageSize())).setMaxResults(pageable.getPageSize()));
        List<Map<String,Object>> items=new ArrayList<>();
        for(Object[] row:rows){
            Map<String,Object> item=new LinkedHashMap<>();String[] keys={"id","billNo","billDate","sourceDocType","sourceDocId","sourceDocNo","clientId","currencyId","currencyCode","currencyName",
                    "exchangeRateExact","amountOriginalExact","amountReceivedOriginalExact","amountOffsetOriginalExact","amountWriteOffOriginalExact","amountBalanceOriginalExact","dueDate","openItemKind","prepaymentAppliedOriginal","clientName"};
            for(int i=0;i<keys.length;i++){
                Object value=i==2||i==16?row[i]==null?null:NativeValueConverters.toLocalDate(row[i]).toString():row[i];
                item.put(keys[i],i>=10&&i<=15||i==18?row[i]==null?null:DecimalText.of(NativeValueConverters.toBigDecimal(row[i])):value);
                if(i>=10&&i<=15)item.put(keys[i].replace("Exact",""),row[i]);
            }
            item.put("direction","AR");item.put("status",1);item.put("settled",false);items.add(item);
        }
        return new PageResponse<>(items,pageable.getPageNumber()+1,pageable.getPageSize(),total,total==0?0:Math.toIntExact((total+pageable.getPageSize()-1)/pageable.getPageSize()));
    }
}
