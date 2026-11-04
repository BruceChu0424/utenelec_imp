package com.uten.imp.features.finance.statement;

import com.uten.imp.application.port.FinancePayableClassificationPort;
import com.uten.imp.common.web.*;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.*;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.util.*;
import static com.uten.imp.features.finance.statement.FinanceOpenItemClassificationContracts.*;

@Service @RequiredArgsConstructor
public class FinancePayableClassificationAdapter implements FinancePayableClassificationPort {
    private final FinanceOpenItemClassificationService classifications;private final JdbcTemplate db;
    @Override @Transactional(propagation=Propagation.MANDATORY)public void lockForWrite(){classifications.read();classifications.lock();}
    @Override @Transactional(readOnly=true)public Target target(UUID id){return readTarget(id,null);}
    private Target readTarget(UUID id,UUID ownNewOffset){
        var source=classifications.source(id);
        if(!"AP".equals(source.get("direction"))||!Boolean.TRUE.equals(source.get("sourceVerified")))throw invalid("请先核对原应付来源、对象和金额");
        UUID classification=(UUID)source.get("classificationId");
        if(classification==null)throw invalid("请先明确原应付的货款/模具款组成，不能用本次减免类别猜整笔应付归属");
        var parts=new ArrayList<Part>();
        if(source.get("parts") instanceof List<?> rows)for(Object value:rows){if(!(value instanceof Map<?,?> row))throw invalid("原应付分类来源无效");parts.add(new Part(Objects.toString(row.get("category"),""),amount(row.get("amount_original")),amount(row.get("amount_local"))));}
        if(parts.size()>1&&hasUnassignedSettlement(id,ownNewOffset))throw invalid("原应付有尚未分配货款/模具款的付款或抵销，请先核对这些原记录，再明确减免归属");
        if(amount(source.get("amountOriginal")).signum()<=0||amount(source.get("amountLocal")).signum()<0)throw invalid("减免目标须为真实正原币应付和非负账面，不能把贷项当未付金额");
        var balance=db.queryForMap("SELECT amount_balance_original,amount_balance FROM ar_ap_ledger WHERE id=?",id);
        BigDecimal original=nullable(balance.get("amount_balance_original")),local=nullable(balance.get("amount_balance"));
        if(ownNewOffset!=null){var own=db.queryForList("SELECT amount_original,target_amount_local FROM supplier_open_item_offsets WHERE id=? AND target_ledger_id=? AND status='APPLIED'",ownNewOffset,id);if(!own.isEmpty()){if(original!=null){original=original.add(amount(own.getFirst().get("amount_original")));}if(local!=null)local=local.add(amount(own.getFirst().get("target_amount_local")));}}
        var remaining=new ArrayList<Part>();
        if(parts.size()==1){var part=parts.getFirst();remaining.add(new Part(part.category(),part.amountOriginal(),part.amountLocal(),original,local));}
        else{
            var usage=new HashMap<String,Map<String,Object>>();for(var row:db.queryForList(FinanceClassificationCapacitySql.CURRENT_USAGE,id,ownNewOffset,ownNewOffset))usage.put(row.get("category").toString(),row);
            BigDecimal sumOriginal=BigDecimal.ZERO,sumLocal=BigDecimal.ZERO;
            for(var part:parts){var spent=usage.getOrDefault(part.category(),Map.of("used_original",BigDecimal.ZERO,"used_local",BigDecimal.ZERO));var ro=part.amountOriginal().subtract(amount(spent.get("used_original")));var rl=part.amountLocal().subtract(amount(spent.get("used_local")));if(ro.signum()<0||rl.signum()<0)throw invalid("原分类清偿超过已确认份额，请先核对实际付款、抵销及预付应用");sumOriginal=sumOriginal.add(ro);sumLocal=sumLocal.add(rl);remaining.add(new Part(part.category(),part.amountOriginal(),part.amountLocal(),original==null?null:ro,local==null?null:rl));}
            if(original!=null&&sumOriginal.compareTo(original)!=0||local!=null&&sumLocal.compareTo(local)!=0)throw invalid("原分类余额与当前未结金额未完整对应，请先核对原清偿归属，不能按比例补余数");
        }
        return new Target(id,classification,((Number)source.get("revision")).longValue(),remaining);
    }
    @Override @Transactional(propagation=Propagation.MANDATORY)public Applied assign(Assignment input){
        if(input==null||input.operationId()==null||input.creditLedgerId()==null||input.targetLedgerId()==null||input.offsetId()==null||input.category()==null||!Set.of("GOODS","MOULD").contains(input.category()))throw invalid("请保留减免实际来源、抵销及明确分类");
        var target=readTarget(input.targetLedgerId(),input.offsetId());
        if(!Objects.equals(target.classificationId(),input.expectedTargetClassificationId()))throw new ApiException(ErrorCode.CONFLICT,"原应付分类已变化，请重新核对减免依据，不能静默采用另一版本");
        if(target.parts().stream().noneMatch(part->part.category().equals(input.category())))throw invalid("本次减免类别不属于原应付已确认组成");
        var source=classifications.classifySource(input.creditLedgerId(),new SourceInput(request(input.operationId(),"source"),-1,null,input.sourceReference(),
            List.of(new FinanceOpenItemClassificationContracts.Part(input.category(),amount(input.amountOriginal()).negate(),amount(input.sourceLocal()).negate()))));
        var offset=classifications.classifyOffset(input.offsetId(),new OffsetInput(request(input.operationId(),"offset"),-1,source.batchId(),target.classificationId(),input.sourceReference(),
            List.of(new OffsetPart(input.category(),input.category(),amount(input.amountOriginal()),amount(input.sourceLocal()),amount(input.targetLocal())))));
        return new Applied(source.batchId(),offset.batchId());
    }
    private boolean hasUnassignedSettlement(UUID ledger,UUID ownNewOffset){
        return Boolean.TRUE.equals(db.queryForObject("""
            SELECT EXISTS(SELECT 1 FROM finance_payment_lines line JOIN finance_payments payment ON payment.id=line.payment_id
              WHERE line.applied_ledger_id=? AND payment.status IN(1,-1) AND NOT payment.is_deleted AND NOT line.is_deleted
                AND NOT EXISTS(SELECT 1 FROM v_finance_payment_classification_current assigned WHERE assigned.payment_line_id=line.id))
            OR EXISTS(SELECT 1 FROM supplier_open_item_offsets actual WHERE(actual.source_ledger_id=? OR actual.target_ledger_id=?)
              AND actual.id IS DISTINCT FROM CAST(? AS uuid)
              AND NOT EXISTS(SELECT 1 FROM v_finance_supplier_offset_classification_current assigned WHERE assigned.offset_id=actual.id))
            """,Boolean.class,ledger,ledger,ledger,ownNewOffset));
    }
    private static UUID request(UUID operation,String kind){return UUID.nameUUIDFromBytes(("payable-statement-adjustment:"+operation+":"+kind).getBytes(StandardCharsets.UTF_8));}
    private static BigDecimal amount(Object value){if(value==null)throw invalid("减免原币或账面份额缺失，不得补零");return value instanceof BigDecimal decimal?decimal:new BigDecimal(value.toString());}
    private static BigDecimal nullable(Object value){return value==null?null:amount(value);}
    private static ApiException invalid(String value){return new ApiException(ErrorCode.VALIDATION_FAILED,value);}
}
