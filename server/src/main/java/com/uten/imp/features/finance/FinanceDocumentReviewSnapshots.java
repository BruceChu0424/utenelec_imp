package com.uten.imp.features.finance;

import com.uten.imp.application.port.DocumentUnapprovalPort;
import com.uten.imp.application.port.FinancialDocumentReviewSnapshotPort;
import com.uten.imp.common.platformcolumns.PlatformColumnContracts;
import com.uten.imp.common.platformcolumns.PlatformColumnService;
import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.stereotype.Component;
import java.util.*;

/** Uses the caller's single RR read view or already locked write view. Header,
 * row/source/platform/attachment xmin values distinguish ABA without inventing
 * business versions or changing the existing JPA entities/lock order. */
@Component @RequiredArgsConstructor
public class FinanceDocumentReviewSnapshots implements FinancialDocumentReviewSnapshotPort {
    public static final Set<String> FAMILIES=Set.of("financeReceipt","financePayment","financeExpense","financeOtherIncome","financeBankTransfer");
    private final EntityManager em;
    private final SecurityContextCurrentUser current;
    private final ObjectProvider<DocumentUnapprovalPort> adapters;
    private final ObjectProvider<PlatformColumnService> platform;
    public record Capture(String fingerprint,Long version,List<UUID> lineIds) { }
    @Override public boolean supports(String family){return FAMILIES.contains(family);}
    @Override public String factsSnapshot(String family,UUID id){return capture(family,id).fingerprint();}
    public Capture capture(String family,UUID id){
        if(!supports(family)||id==null)throw invalid("财务单据身份无效");
        var adapter=adapters.stream().filter(value->value.family().equals(family)).findFirst().orElseThrow(()->invalid("财务单据核对入口尚未准备好"));
        var header=adapter.header();var lines=adapter.lines();
        var heads=em.createNativeQuery("SELECT to_jsonb(h)::text,h.xmin::text,to_jsonb(h)->>'version' FROM "+header.table()+" h WHERE id=:id").setParameter("id",id).getResultList();
        if(heads.size()!=1)throw new ApiException(ErrorCode.NOT_FOUND,"财务单据不存在");Object[] head=(Object[])heads.getFirst();
        Long version=head[2]==null?null:Long.valueOf(head[2].toString());
        var facts=new ArrayList<String>();facts.add("family="+family);facts.add("id="+id);facts.add("actor="+current.requireId());
        facts.add("header="+head[0]);facts.add("headerXmin="+head[1]);
        String where=" WHERE l."+lines.parentColumn()+"=:id"+(lines.softDeleted()?" AND NOT l.is_deleted":"");
        @SuppressWarnings("unchecked")List<UUID> ids=em.createNativeQuery("SELECT l.id FROM "+lines.table()+" l"+where+" ORDER BY l.line_no,l.id").setParameter("id",id).getResultList();
        facts.add("lines="+em.createNativeQuery("SELECT COALESCE(jsonb_agg(jsonb_build_object('row',to_jsonb(l),'xmin',l.xmin::text) ORDER BY l.line_no,l.id),'[]'::jsonb)::text FROM "+lines.table()+" l"+where).setParameter("id",id).getSingleResult());
        for(var source:adapter.sources())facts.add("source:"+source.table()+"="+em.createNativeQuery("SELECT COALESCE(jsonb_agg(jsonb_build_object('row',to_jsonb(s),'xmin',s.xmin::text) ORDER BY to_jsonb(s)::text),'[]'::jsonb)::text FROM "+source.table()+" s WHERE s."+source.lineColumn()+" IN(SELECT l.id FROM "+lines.table()+" l"+where+")").setParameter("id",id).getSingleResult());
        String records="(SELECT l.id FROM "+lines.table()+" l"+where+" UNION SELECT CAST(:id AS uuid))";
        facts.add("platform="+em.createNativeQuery("SELECT COALESCE(jsonb_agg(jsonb_build_object('row',to_jsonb(p),'xmin',p.xmin::text) ORDER BY p.scope,p.record_id),'[]'::jsonb)::text FROM platform_record_fields p WHERE p.record_id IN "+records).setParameter("id",id).getSingleResult());
        // Definition usage counters are display feedback, not reviewed input.
        facts.add("definitions="+em.createNativeQuery("SELECT COALESCE(jsonb_agg(jsonb_build_object('id',d.id,'scope',d.scope,'name',d.name,'type',d.value_type,'protected',d.price_protected,'formula',d.formula,'fingerprint',d.definition_fingerprint,'deleted',deletion.definition_id IS NOT NULL,'deleteXmin',deletion.xmin::text) ORDER BY d.id),'[]'::jsonb)::text FROM platform_column_definitions d LEFT JOIN platform_column_definition_deletions deletion ON deletion.definition_id=d.id WHERE d.id IN(SELECT (cell->>'columnId')::uuid FROM platform_record_fields p CROSS JOIN LATERAL jsonb_array_elements(p.cells) cell WHERE p.record_id IN "+records+")").setParameter("id",id).getSingleResult());
        facts.add("attachments="+em.createNativeQuery("SELECT COALESCE(jsonb_agg(jsonb_build_object('row',to_jsonb(a),'xmin',a.xmin::text) ORDER BY a.id),'[]'::jsonb)::text FROM attachments a WHERE a.owner_id=:id").setParameter("id",id).getSingleResult());
        return new Capture(CanonicalFingerprint.sha256(facts),version,List.copyOf(ids));
    }
    public <T extends FinanceReviewMetadata>T decorate(String family,UUID id,T detail){
        Capture captured=capture(family,id);detail.setApprovalSnapshot(captured.fingerprint());detail.setApprovalVersion(captured.version());
        try(var readContext=com.uten.imp.common.platformcolumns.DocumentPlatformReadContext.open()){
        String scope=switch(family){case "financeReceipt"->"finance_receipt";case "financePayment"->"finance_payment";case "financeExpense"->"finance_expense";case "financeOtherIncome"->"finance_other_income";default->"finance_bank_transfer";};
        var projected=new LinkedHashMap<String,List<PlatformColumnContracts.Row>>();
        projected.put(scope,platform.getObject().read(scope,new PlatformColumnContracts.BatchRead(List.of(id),null)));
        var rows=new ArrayList<PlatformColumnContracts.Row>();
        for(int offset=0;offset<captured.lineIds().size();offset+=200)rows.addAll(platform.getObject().read(scope+"_item",new PlatformColumnContracts.BatchRead(captured.lineIds().subList(offset,Math.min(captured.lineIds().size(),offset+200)),null)));
        projected.put(scope+"_item",List.copyOf(rows));detail.setApprovalPlatformFields(Collections.unmodifiableMap(projected));return detail;
        }
    }
    public void require(String family,UUID id,Long expectedVersion,String expectedSnapshot){
        if(expectedSnapshot==null||!expectedSnapshot.matches("[a-f0-9]{64}"))throw invalid("请先读取并查看完整原单据，再审核本次所见内容");
        var actual=capture(family,id);
        if(!Objects.equals(expectedVersion,actual.version())||!expectedSnapshot.equals(actual.fingerprint()))
            throw new ApiException(ErrorCode.CONFLICT,"财务单据内容或代次已变化，不能审核未查看的新内容；请保留原请求并重新核对");
    }
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
}
