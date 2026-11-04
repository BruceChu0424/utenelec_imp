package com.uten.imp.features.finance.gl;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.*;
import com.uten.imp.common.storage.ImmutableDocumentStore;
import com.uten.imp.common.web.*;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;

/** The source-owning R1 read adapter; imported financial facts are never patched by the native bridge. */
@Service @RequiredArgsConstructor
public class FinancialOpeningSourceReadService implements FinancialOpeningSourceReadPort {
    private final JdbcTemplate db;
    private final ObjectMapper json;
    private static final String FROM="""
        FROM finance_gl_entry_allocations a JOIN gl_entries e ON e.id=a.entry_id JOIN gl_vouchers v ON v.id=e.voucher_id
        JOIN payment_styles style ON style.id=e.style_id AND style.category IN('ACCOUNT','LIABILITY')
        JOIN finance_gl_voucher_evidence proof ON proof.voucher_id=v.id AND proof.purpose='OPENING'
        JOIN finance_accounting_import_batches batch ON batch.id=proof.import_batch_id AND batch.status='POSTED' AND batch.reversed_at IS NULL
        JOIN finance_gl_auxiliary_opening_evidence opening ON opening.entry_id=e.id AND opening.account_code=a.account_code
          AND opening.auxiliary_id=a.auxiliary_id AND opening.currency_id=a.currency_id
        WHERE v.status=1 AND NOT v.is_deleted AND v.reversed_by_voucher_id IS NULL AND NOT e.is_deleted
        """;
    private static final String SELECT="""
        SELECT a.*,e.voucher_id,e.style_id,e.direction,opening.id opening_evidence_id,opening.import_batch_id balance_import_id,
          opening.effective_from,opening.source_row opening_source_row,opening.source_sha256,proof.import_batch_id,
          proof.source_system opening_source_system,proof.source_ledger,opening.source_account_name opening_account_name
        """;
    @Override @Transactional(readOnly=true)
    public Map<FinanceGlSettlementCapacityPort.SourceRef,Source> read(List<FinanceGlSettlementCapacityPort.SourceRef> refs){
        if(refs==null||refs.size()>2000||refs.stream().anyMatch(Objects::isNull))throw invalid("一次最多读取2000份真实期初分配");
        var unique=refs.stream().distinct().sorted(Comparator.comparing(FinanceGlSettlementCapacityPort.SourceRef::entryId).thenComparingInt(FinanceGlSettlementCapacityPort.SourceRef::allocationNo)).toList();
        if(unique.isEmpty())return Map.of();var args=new ArrayList<Object>();var placeholders=new ArrayList<String>();
        for(var r:unique){if(r.entryId()==null||r.allocationNo()<1)throw invalid("期初分录及分配号不正确");placeholders.add("(?,?)");args.add(r.entryId());args.add(r.allocationNo());}
        var result=new LinkedHashMap<FinanceGlSettlementCapacityPort.SourceRef,Source>();
        for(var row:db.queryForList(SELECT+FROM+" AND(a.entry_id,a.allocation_no)IN("+String.join(",",placeholders)+") ORDER BY a.entry_id,a.allocation_no",args.toArray())){
            var source=source(row);if(result.put(source.reference(),source)!=null)throw invalid("原期初分配对应多份辅助证据，请先核对原来源");
        }return Collections.unmodifiableMap(result);
    }
    @Override @Transactional(readOnly=true)
    public Map<String,Object> choices(String role,UUID party,LocalDate effective,int page,int size){
        if(!Set.of("CUSTOMER","SUPPLIER").contains(role)||party==null||effective==null)throw invalid("请选择旧往来及明确截止日期");
        int p=Math.max(1,page),s=Math.max(1,Math.min(200,size));String where=" AND a.auxiliary_role=? AND a.party_id_snapshot=? AND opening.effective_from=?";
        long total=db.queryForObject("SELECT count(*) "+FROM+where,Long.class,role,party,effective);
        var rows=db.queryForList(SELECT+FROM+where+" ORDER BY a.account_code,a.entry_id,a.allocation_no LIMIT ? OFFSET ?",role,party,effective,s,(long)(p-1)*s);
        return Map.of("items",rows.stream().map(this::source).toList(),"page",p,"size",s,"total",total,"totalPages",(total+s-1)/s);
    }
    private Source source(Map<String,Object> r){
        var reference=new FinanceGlSettlementCapacityPort.SourceRef((UUID)r.get("entry_id"),((Number)r.get("allocation_no")).intValue());
        var auxiliary=new FinancialAuxiliaryValidationPort.Ref((UUID)r.get("auxiliary_id"),text(r,"auxiliary_role"),(UUID)r.get("party_id_snapshot"),text(r,"source_system"),text(r,"source_code"),text(r,"source_name"));
        var stable=new LinkedHashMap<String,Object>();for(String key:List.of("entry_id","allocation_no","voucher_id","style_id","direction","account_code","currency_id","original_currency_id","amount_local","amount_original","auxiliary_id","party_id_snapshot","opening_evidence_id","effective_from","source_sha256"))stable.put(key,r.get(key));
        String fingerprint;try{fingerprint=ImmutableDocumentStore.digest(json.writeValueAsBytes(stable));}catch(Exception e){throw invalid("原期初证据无法读取");}
        return new Source(reference,(UUID)r.get("voucher_id"),(UUID)r.get("import_batch_id"),(UUID)r.get("balance_import_id"),(UUID)r.get("opening_evidence_id"),date(r.get("effective_from")),(UUID)r.get("style_id"),text(r,"account_code"),(UUID)r.get("currency_id"),(UUID)r.get("original_currency_id"),((Number)r.get("direction")).intValue(),(BigDecimal)r.get("amount_local"),(BigDecimal)r.get("amount_original"),auxiliary,text(r,"opening_account_name"),text(r,"opening_source_system"),text(r,"source_ledger"),text(r,"source_sha256"),((Number)r.get("opening_source_row")).intValue(),fingerprint);
    }
    private static String text(Map<String,Object> r,String key){return Objects.toString(r.get(key),null);}
    private static LocalDate date(Object value){return value instanceof java.sql.Date d?d.toLocalDate():(LocalDate)value;}
    private static ApiException invalid(String value){return new ApiException(ErrorCode.VALIDATION_FAILED,value);}
}
