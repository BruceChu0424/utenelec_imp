package com.uten.imp.common.numeric;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.BusinessNumericInputEvidencePort;
import com.uten.imp.common.finance.BusinessPrecisionContext;
import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.common.util.FinancialExactAmount;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.*;

@Service
public class BusinessNumericInputEvidenceService implements BusinessNumericInputEvidencePort {
    private final NamedParameterJdbcTemplate db;
    private final ObjectMapper json;
    public BusinessNumericInputEvidenceService(NamedParameterJdbcTemplate db,ObjectMapper json){this.db=db;this.json=json;}
    private static String text(BigDecimal number,boolean recorded){
        Objects.requireNonNull(number,"Numeric input evidence requires an actual original/recorded value");
        if(recorded)FinancialExactAmount.book(number,"实际记录数值");
        BigDecimal normal=number.stripTrailingZeros();
        if(normal.scale()>1000||normal.precision()-normal.scale()>40)throw invalid("原数超出可审计的支持范围，原输入应保留");
        return recorded?normal.toPlainString():number.toPlainString();
    }
    private static void unit(Unit unit){if(unit==null||unit.kind()==null||!unit.kind().matches("[A-Z][A-Z0-9_]{0,39}")||unit.code()!=null&&(unit.code().isBlank()||unit.code().length()>80)||unit.kind()!=null&&!Set.of("NONE","NUMBER","RATIO").contains(unit.kind())&&unit.code()==null&&unit.referenceId()==null)throw invalid("原数单位证据不完整");}
    private String encode(Object value){try{return json.writeValueAsString(value);}catch(JsonProcessingException error){throw new IllegalStateException("Numeric input evidence cannot be encoded",error);}}
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
    @Override @Transactional(propagation=Propagation.MANDATORY)
    public UUID record(Capture capture){
        Objects.requireNonNull(capture);unit(capture.originalUnit());unit(capture.recordedUnit());
        if(capture.ownerKind()==null||!capture.ownerKind().matches("[A-Z][A-Z0-9_]{0,79}")||capture.ownerId()==null||capture.sourceRowId()==null
            ||capture.fieldKey()==null||!capture.fieldKey().matches("[A-Za-z][A-Za-z0-9_.]{0,79}")||capture.ownerVersion()==null||capture.ownerVersion().isBlank()||capture.ownerVersion().length()>128)throw invalid("原数的真实来源、行与版本不完整");
        String raw=text(capture.original(),false),recorded=text(capture.recorded(),true);
        Map<String,Object> context=db.queryForMap("SELECT pg_current_xact_id()::text action_id,NULLIF(current_setting('app.actor_id',true),'')::uuid actor_id,NULLIF(current_setting('app.audit_request_id',true),'')::uuid request_id,COALESCE(NULLIF(current_setting('app.business_precision_used',true),''),'{}') used_policy",Map.of());
        var used=new TreeMap<>(BusinessPrecisionContext.usedChoices());
        try{used.putAll(json.readValue(context.get("used_policy").toString(),new TypeReference<Map<String,BusinessPrecisionContext.Choice>>(){}));}
        catch(JsonProcessingException error){throw new IllegalStateException("Used numeric precision policy is invalid",error);}
        for(var choice:capture.usedPolicy().entrySet())if(!choice.getValue().equals(used.get(choice.getKey())))throw invalid("只能记录本次实际使用的精度策略");
        if(context.get("actor_id")==null)throw new IllegalStateException("Numeric input evidence has no current transaction actor");
        String policy=encode(Map.of("version",1,"choices",new TreeMap<>(capture.usedPolicy())));
        String fingerprint=CanonicalFingerprint.sha256(Arrays.asList("owner:"+capture.ownerKind()+":"+capture.ownerId(),"row:"+capture.sourceRowId(),"field:"+capture.fieldKey(),"version:"+capture.ownerVersion(),"original:"+raw+":"+encode(capture.originalUnit()),"recorded:"+recorded+":"+encode(capture.recordedUnit()),"policy:"+policy,"actor:"+context.get("actor_id"),"request:"+context.get("request_id")));
        var args=new MapSqlParameterSource("id",UUID.randomUUID()).addValue("kind",capture.ownerKind()).addValue("owner",capture.ownerId()).addValue("row",capture.sourceRowId()).addValue("field",capture.fieldKey()).addValue("version",capture.ownerVersion())
            .addValue("raw",raw).addValue("rawUnit",encode(capture.originalUnit())).addValue("recorded",recorded).addValue("recordedUnit",encode(capture.recordedUnit())).addValue("policy",policy).addValue("action",context.get("action_id")).addValue("actor",context.get("actor_id")).addValue("request",context.get("request_id")).addValue("fp",fingerprint);
        db.update("""
            INSERT INTO business_numeric_input_evidence(id,owner_kind,owner_id,source_row_id,field_key,owner_version,original_decimal,original_unit,recorded_decimal,recorded_unit,precision_policy,source_action_id,actor_id,request_id,fingerprint)
            VALUES(:id,:kind,:owner,:row,:field,:version,:raw,CAST(:rawUnit AS jsonb),:recorded,CAST(:recordedUnit AS jsonb),CAST(:policy AS jsonb),:action,:actor,:request,:fp)
            ON CONFLICT(owner_kind,owner_id,source_row_id,field_key,source_action_id) DO NOTHING
            """,args);
        var saved=db.queryForMap("SELECT id,fingerprint FROM business_numeric_input_evidence WHERE owner_kind=:kind AND owner_id=:owner AND source_row_id=:row AND field_key=:field AND source_action_id=:action",args);
        if(!fingerprint.equals(saved.get("fingerprint")))throw new ApiException(ErrorCode.CONFLICT,"同一次真实动作已有不同原数证据，不能覆盖");
        return (UUID)saved.get("id");
    }
    @Override @Transactional(readOnly=true)
    public Map<UUID,List<Value>> readForAuthorizedOwner(String kind,UUID owner,List<UUID> rows){
        if(owner==null||rows==null||rows.isEmpty())return Map.of();if(rows.size()>5000)throw invalid("原数证据请按原单分页读取");
        var result=new LinkedHashMap<UUID,List<Value>>();
        db.query("SELECT * FROM business_numeric_input_evidence WHERE owner_kind=:kind AND owner_id=:owner AND source_row_id IN(:rows) ORDER BY created_at,id",Map.of("kind",kind,"owner",owner,"rows",rows),rs->{
            try{
                Map<String,BusinessPrecisionContext.Choice> policy=json.readValue(rs.getString("precision_policy"),new TypeReference<Map<String,Object>>(){}).get("choices") instanceof Map<?,?> values
                    ?json.convertValue(values,new TypeReference<Map<String,BusinessPrecisionContext.Choice>>(){}):Map.of();
                UUID row=rs.getObject("source_row_id",UUID.class);
                result.computeIfAbsent(row,unused->new ArrayList<>()).add(new Value(rs.getObject("id",UUID.class),rs.getString("field_key"),rs.getString("owner_version"),rs.getString("original_decimal"),json.readValue(rs.getString("original_unit"),Unit.class),rs.getString("recorded_decimal"),json.readValue(rs.getString("recorded_unit"),Unit.class),policy,rs.getObject("actor_id",UUID.class),rs.getObject("request_id",UUID.class),rs.getString("source_action_id"),rs.getObject("created_at",OffsetDateTime.class)));
            }catch(JsonProcessingException error){throw new IllegalStateException("Numeric input evidence is invalid",error);}
        });
        result.replaceAll((key,value)->List.copyOf(value));return Collections.unmodifiableMap(result);
    }
}
