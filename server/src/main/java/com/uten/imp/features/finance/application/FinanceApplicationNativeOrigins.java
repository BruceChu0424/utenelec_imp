package com.uten.imp.features.finance.application;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.*;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import java.math.BigDecimal;
import java.util.*;

/** Immutable original records stay separate from the current native draft. */
@Component @RequiredArgsConstructor
public class FinanceApplicationNativeOrigins implements NativeApplicationOriginPort {
    private final JdbcTemplate db;
    private final ObjectMapper json;
    private final AttachmentEvidencePort evidence;
    private final FinanceApplicationOriginalEvidence originals;
    private final ObjectProvider<NativeApplicationContinuationPort> targets;
    private final SecurityContextCurrentUser current;
    private Map<String,Object> mapping(String type,UUID id){
        if(!Set.of("EXPENSE_CLAIM","BUSINESS_APPLICATION").contains(type)||id==null)return null;
        var rows=db.queryForList("""
            SELECT mapping.*,review.original_snapshot::text,review.native_source_snapshot::text,
              review.original_command,review.proposed_input::text,
              currency.code AS currency_code,currency.name AS currency_name,currency.is_base_currency
            FROM finance_application_native_mappings mapping
            JOIN finance_application_continuation_reviews review ON review.id=mapping.review_id
            LEFT JOIN currencies currency ON currency.id=mapping.original_currency_id
            WHERE mapping.native_kind=? AND mapping.native_id=?
            """,type,id);
        return rows.isEmpty()?null:rows.getFirst();
    }
    private Map<String,Object> decode(Object raw){
        if(raw==null)return Map.of();
        try{return json.copy().enable(DeserializationFeature.USE_BIG_DECIMAL_FOR_FLOATS)
                .readValue(raw.toString(),new TypeReference<LinkedHashMap<String,Object>>(){});}
        catch(Exception failure){throw new ApiException(ErrorCode.CONFLICT,"原稿记录无法完整读取，请保留当前输入核对");}
    }
    @Override public Origin origin(String type,UUID id){
        var row=mapping(type,id);if(row==null)return null;
        var source=decode(row.get("original_snapshot"));var obligations=new ArrayList<Obligation>();
        try{
            List<Map<String,Object>> values=json.readValue(Objects.toString(row.get("original_obligations"),"[]"),new TypeReference<>(){});
            for(var value:values)obligations.add(new Obligation(UUID.fromString(value.get("ledgerId").toString()),new BigDecimal(value.get("amountOriginal").toString())));
        }catch(Exception invalid){throw new ApiException(ErrorCode.CONFLICT,"原应付义务依据无法核对，不能改用另一金额含义");}
        return new Origin((UUID)row.get("origin_id"),Objects.toString(source.get("applicationNo"),"本机原稿"),
                row.get("original_kind").toString(),Objects.toString(source.get("requestedDate"),null),
                (UUID)row.get("original_currency_id"),Objects.toString(row.get("currency_code"),null),Objects.toString(row.get("currency_name"),null),
                Boolean.TRUE.equals(row.get("is_base_currency")),AmountBasis.valueOf(row.get("amount_basis").toString()),
                (BigDecimal)row.get("original_amount"),obligations,source);
    }
    @Override public void requireReady(String type,UUID id){
        var row=mapping(type,id);if(row==null)return;
        var currentValues=db.queryForMap(type.equals("BUSINESS_APPLICATION")?"SELECT amount,supplier_id FROM business_applications WHERE id=?":"SELECT total_amount AS amount,NULL::uuid AS supplier_id FROM expense_claims WHERE id=?",id);
        requireCurrentValues(type,id,(BigDecimal)currentValues.get("amount"),(UUID)currentValues.get("supplier_id"));
        if(!evidence.frozenEvidenceReady(originals.linkedEvidence(type,id)))
            throw new ApiException(ErrorCode.CONFLICT,"原稿引用凭证已变化或尚未可用，请核对原件后继续；本次未办理");
    }
    @Override public void requireCurrentValues(String type,UUID id,BigDecimal amount,UUID supplierId){
        var row=mapping(type,id);if(row==null)return;
        BigDecimal original=(BigDecimal)row.get("original_amount");
        if(original==null?amount!=null:amount==null||original.compareTo(amount)!=0)throw new ApiException(ErrorCode.CONFLICT,"本次金额与已审阅原稿不同，请核对原稿；不能把原币、本币或未知金额互换");
        var source=decode(row.get("original_snapshot"));var payload=source.get("payload") instanceof Map<?,?> value?value:Map.of();
        Object supplier=payload.get("supplierId");
        if(supplier!=null&&!UUID.fromString(supplier.toString()).equals(supplierId))throw new ApiException(ErrorCode.CONFLICT,"当前供应商与已审阅原义务不一致，不能改用其他往来");
    }
    @Override public Map<String,Object> originalView(String type,UUID id){
        var actor=current.get().orElseThrow(()->new ApiException(ErrorCode.UNAUTHORIZED));
        var row=mapping(type,id);if(row==null)return Map.of();
        var target=targets.orderedStream().filter(port->port.targetType().equals(type)).findFirst().orElse(null);
        if(target==null||!target.mayRead(id,actor))throw new ApiException(ErrorCode.NOT_FOUND,"原稿不在当前申请查阅范围内");
        var result=new LinkedHashMap<String,Object>();result.put("originId",row.get("origin_id"));
        result.put("original",decode(row.get("original_snapshot")));result.put("nativeSource",decode(row.get("native_source_snapshot")));
        if(actor.getId().equals(row.get("actor_id")))result.put("rawCommand",row.get("original_command"));
        result.put("reviewedInput",decode(row.get("proposed_input")));
        var refs=originals.linkedEvidence(type,id);boolean canView=actor.getPermissions().contains("attachment:view");
        result.put("originalEvidenceState",refs.isEmpty()?"NOT_APPLICABLE":!canView?"REQUIRES_ACCESS":evidence.frozenEvidenceReady(refs)?"AVAILABLE":"UNAVAILABLE");
        if(canView)result.put("originalAttachments",refs);
        result.put("readOnly",true);return result;
    }
}
