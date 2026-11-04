package com.uten.imp.features.finance.statement;

import com.uten.imp.application.port.FinanceMaterialStatementSourcePort.*;
import com.uten.imp.common.util.KeywordSearch;
import com.uten.imp.features.finance.statement.FinanceMaterialStatementContracts.GlAllocationKey;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.time.LocalDate;
import java.util.*;
import static com.uten.imp.features.finance.statement.FinanceMaterialStatementService.*;

/** Minimum directory/source fields for the company-wide financial material purpose, no master editing or prices. */
@Service @RequiredArgsConstructor
public class FinanceMaterialStatementReferences {
    private final FinanceMaterialStatementService s;private final org.springframework.jdbc.core.JdbcTemplate db;private final com.uten.imp.application.port.FinanceMaterialStatementSourcePort physical;
    @Transactional(readOnly=true)
    public Map<String,Object> labels(Map<String,List<String>> input){
        s.readAccess();if(input==null||input.values().stream().mapToInt(List::size).sum()>300)throw invalid("请分批读取最多300个确切来源名称");var result=new LinkedHashMap<String,Object>();
        for(var request:input.entrySet()){
            String source=switch(request.getKey()){
                case "accounts"->"SELECT code::text AS id,code,name FROM finance_chart_codes";
                case "auxiliaries"->"SELECT id::text AS id,source_code AS code,source_name AS name FROM finance_auxiliary_items";
                case "contexts"->"SELECT id::text AS id,account_code AS code,COALESCE((SELECT e.input->>'productNameCaption' FROM finance_material_evidence e WHERE e.context_id=c.id AND e.kind='CONTEXT' AND e.current_approved),'未审核分组') AS name FROM finance_material_contexts c";
                case "goods","colors","units","currencies","suppliers","clients"->"SELECT id::text AS id,COALESCE(to_jsonb(native)->>'code','') AS code,name FROM "+request.getKey()+" native";
                default->throw invalid("来源名称类型不正确");};
            var ids=request.getValue().stream().filter(Objects::nonNull).distinct().toList();var labels=new LinkedHashMap<String,String>();
            if(!ids.isEmpty())for(var row:db.queryForList("SELECT * FROM ("+source+") original WHERE id IN("+String.join(",",Collections.nCopies(ids.size(),"?"))+")",ids.toArray()))labels.put(row.get("id").toString(),Objects.toString(row.get("code"),"")+" / "+Objects.toString(row.get("name"),""));result.put(request.getKey(),labels);
        }return result;
    }
    @Transactional(readOnly=true)
    public Map<String,Object> options(String kind,String keyword,int page,int size){
        s.readAccess();String source=switch(kind){
            case "auxiliaries"->"SELECT id,source_code AS code,source_name AS name,role FROM finance_auxiliary_items WHERE status='ACTIVE' AND role IN('OTHER','SUPPLIER','CUSTOMER')";
            case "accounts"->"SELECT chart.code AS id,chart.code,chart.name,chart.currency_id FROM finance_chart_codes chart WHERE EXISTS(SELECT 1 FROM finance_chart_code_styles mapped JOIN payment_styles style ON style.id=mapped.style_id WHERE mapped.code=chart.code AND style.category='ACCOUNT' AND style.status='使用' AND NOT style.is_deleted AND EXISTS(SELECT 1 FROM finance_report_line_bindings binding WHERE binding.binding_kind='STYLE' AND binding.style_id=style.id AND binding.line_key IN('BS_4','BS_8')))";
            case "currencies"->"SELECT id,code,name,is_base_currency FROM currencies WHERE NOT is_deleted AND status='使用'";
            case "goods","colors","units","suppliers","clients"->"SELECT native.id,COALESCE(to_jsonb(native)->>'code','') AS code,native.name FROM "+kind+" native WHERE NOT native.is_deleted";
            default->throw invalid("原表候选类型不正确");
        };
        var args=new ArrayList<Object>();String where=" WHERE true";
        if(keyword!=null&&keyword.length()>240)throw invalid("候选检索内容过长");
        for(String term:KeywordSearch.terms(keyword)){where+=" AND (code ILIKE ? ESCAPE '\\' OR name ILIKE ? ESCAPE '\\')";args.add(KeywordSearch.containsPattern(term));args.add(KeywordSearch.containsPattern(term));}
        int p=Math.max(1,page),n=Math.max(1,Math.min(100,size));long total=Objects.requireNonNull(db.queryForObject("SELECT count(*) FROM ("+source+") native_option"+where,Long.class,args.toArray()));args.add(n);args.add((long)(p-1)*n);
        var rows=db.queryForList("SELECT * FROM ("+source+") native_option"+where+" ORDER BY code,name,id LIMIT ? OFFSET ?",args.toArray());return s.exactMap(Map.of("items",rows,"page",p,"size",n,"total",total,"totalPages",(total+n-1)/n));
    }
    @Transactional(readOnly=true)
    public Page sources(UUID contextId,Kind kind,LocalDate from,LocalDate to,UUID supplierId,UUID customerId,String keyword,int page,int size){return sources(contextId,kind,from,to,supplierId,customerId,keyword,page,size,null,null);}
    @Transactional(readOnly=true)
    public Page sources(UUID contextId,Kind kind,LocalDate from,LocalDate to,UUID supplierId,UUID customerId,String keyword,int page,int size,UUID goodsId,UUID colorId){
        s.readAccess();s.context(contextId,false);var rules=s.sourceGoods(contextId,new FinanceMaterialStatementService.ReadScope()).stream().filter(rule->rule.sourceKind()==kind).toList();
        var chosen=goodsId==null?(rules.size()==1?rules.getFirst():null):rules.stream().filter(rule->rule.goodsId().equals(goodsId)&&Objects.equals(rule.colorId(),colorId)).findFirst().orElse(null);
        if(chosen==null)throw invalid("请选择此组已核对的真实原料/产品和颜色；没有对应时先维护材料/产品对应");
        return physical.candidates(new Query(kind,supplierId,customerId,chosen.goodsId(),chosen.colorId(),from,to,keyword,page,size));
    }
    @Transactional(readOnly=true)
    public Map<String,Object> gl(UUID contextId,LocalDate from,LocalDate to,String keyword,int page,int size){
        s.readAccess();if(from==null||to==null||from.isAfter(to))throw invalid("请选择完整GL期间");var c=s.context(contextId,false);
        var args=new ArrayList<Object>(List.of(c.get("account_code"),c.get("auxiliary_id"),c.get("accounting_currency_id"),from,to));
        String query="""
            FROM finance_gl_entry_allocations a JOIN gl_entries e ON e.id=a.entry_id JOIN gl_vouchers v ON v.id=e.voucher_id
            LEFT JOIN finance_material_evidence assigned ON assigned.kind='FEE' AND assigned.current_approved AND assigned.resource_key=e.id::text||':'||a.allocation_no::text
            WHERE a.account_code=? AND a.auxiliary_id=? AND a.currency_id=? AND e.entry_date BETWEEN ? AND ? AND e.direction=1
              AND v.reversal_of_voucher_id IS NULL AND NOT e.is_deleted AND fn_finance_gl_voucher_is_booked(v.id) AND NOT fn_finance_entry_is_pnl_closing(e.id)
            """;
        for(String term:KeywordSearch.terms(keyword)){query+=" AND (v.voucher_no ILIKE ? ESCAPE '\\' OR e.summary ILIKE ? ESCAPE '\\')";args.add(KeywordSearch.containsPattern(term));args.add(KeywordSearch.containsPattern(term));}
        int p=Math.max(1,page),n=Math.max(1,Math.min(100,size));long total=Objects.requireNonNull(db.queryForObject("SELECT count(*) "+query,Long.class,args.toArray()));args.add(n);args.add((long)(p-1)*n);
        var rows=db.queryForList("SELECT e.id AS entry_id,a.allocation_no,e.entry_date,v.voucher_no,e.summary,a.amount_local::text AS amount_local,a.amount_original::text AS amount_original,a.currency_id,a.original_currency_id,assigned.id AS approved_assignment_id "+query+" ORDER BY e.entry_date,e.id,a.allocation_no LIMIT ? OFFSET ?",args.toArray());
        return s.exactMap(Map.of("items",rows,"page",p,"size",n,"total",total,"totalPages",(total+n-1)/n));
    }
    @Transactional(readOnly=true)
    public Map<String,Object> adjustments(UUID contextId,UUID receivableEntry,int receivableAllocation,FinanceMaterialStatementContracts.AdjustmentPurpose purpose,String keyword,int page,int size){
        s.readAccess();var ar=quote(contextId,receivableEntry,receivableAllocation);String binding=purpose==FinanceMaterialStatementContracts.AdjustmentPurpose.VAT?"BS_36":"PL_22";
        var args=new ArrayList<Object>(List.of(ar.get("voucher_id"),binding));String where=" FROM gl_entries e LEFT JOIN finance_gl_entry_allocations a ON a.entry_id=e.id WHERE e.voucher_id=? AND e.direction=-1 AND NOT e.is_deleted AND NOT fn_finance_entry_is_pnl_closing(e.id) AND EXISTS(SELECT 1 FROM finance_report_line_bindings b JOIN payment_styles ancestor ON ancestor.id=b.style_id JOIN payment_styles actual ON actual.id=e.style_id WHERE b.binding_kind='STYLE' AND b.line_key=? AND (actual.id=ancestor.id OR (ancestor.path IS NOT NULL AND ancestor.path<>'' AND actual.path LIKE ancestor.path||'/%')))";
        for(String term:KeywordSearch.terms(keyword)){where+=" AND e.summary ILIKE ? ESCAPE '\\'";args.add(KeywordSearch.containsPattern(term));}int p=Math.max(1,page),n=Math.max(1,Math.min(100,size));long total=Objects.requireNonNull(db.queryForObject("SELECT count(*)"+where,Long.class,args.toArray()));args.add(n);args.add((long)(p-1)*n);
        var rows=db.queryForList("SELECT e.id AS entry_id,COALESCE(a.allocation_no,0) AS allocation_no,e.entry_date,e.summary,COALESCE(a.amount_local,e.amount)::text AS amount_local,a.amount_original::text,a.original_currency_id,e.voucher_id"+where+" ORDER BY e.line_no,e.id,a.allocation_no LIMIT ? OFFSET ?",args.toArray());for(var row:rows)row.put("voucher_no",ar.get("voucher_no"));return s.exactMap(Map.of("items",rows,"page",p,"size",n,"total",total,"totalPages",(total+n-1)/n));
    }
    @Transactional(readOnly=true)
    public Map<String,Object> adjustmentQuote(UUID contextId,UUID receivableEntry,int receivableAllocation,UUID entry,int allocation,FinanceMaterialStatementContracts.AdjustmentPurpose purpose){
        s.readAccess();var ar=quote(contextId,receivableEntry,receivableAllocation);var value=new LinkedHashMap<>(s.adjustmentCreditSource(new GlAllocationKey(entry,allocation),ar,purpose));value.put("identityFingerprint",s.hash(value));return s.exactMap(value);
    }
    @Transactional(readOnly=true)
    public Map<String,Object> quote(UUID contextId,UUID entry,int allocation){
        s.readAccess();var c=s.context(contextId,false);var source=s.feeSource(new GlAllocationKey(entry,allocation),false);
        if(!Objects.equals(c.get("account_code"),source.get("account_code"))||!Objects.equals(c.get("auxiliary_id"),source.get("auxiliary_id"))||!Objects.equals(c.get("accounting_currency_id"),source.get("currency_id")))throw invalid("所选GL不属于当前财务辅助/科目/会计币别");
        var result=new LinkedHashMap<>(source);result.put("identityFingerprint",s.hash(source));var assigned=s.currentEvidence(FinanceMaterialStatementContracts.EvidenceKind.FEE,entry+":"+allocation);result.put("approvedAssignmentId",assigned==null?null:assigned.get("id"));return s.exactMap(result);
    }
}
