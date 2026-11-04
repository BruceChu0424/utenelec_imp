package com.uten.imp.features.finance.asset.application;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.storage.ImmutableDocumentStore;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.*;
import com.uten.imp.features.finance.asset.api.AssetTemplateContracts.*;
import com.uten.imp.security.*;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.time.LocalDate;
import java.util.*;
import java.nio.charset.StandardCharsets;

/** Descriptive source fields are versioned by effective date; monetary facts stay in the asset workflow. */
@Service @RequiredArgsConstructor
public class FinanceAssetTemplateService {
    private final JdbcTemplate db;private final ObjectMapper json;private final TxSessionVars tx;
    private final SecurityContextCurrentUser current;private final FinanceAssetAuthorization authorization;
    @Transactional(readOnly=true)
    public Map<String,Object> get(String type,UUID id,LocalDate asOf) {
        authorization.require(FinanceAssetAuthorization.VIEW);target(type,id);
        LocalDate cutoff=asOf==null?BusinessTime.today():asOf;
        var rows=db.queryForList("""
            SELECT id,valid_from AS "validFrom",party_name AS "partyName",unit_specification AS "unitSpecification",
               category_caption AS "categoryCaption",usage_caption AS "usageCaption",source_month AS "sourceMonth",document_date AS "documentDate",
               first_level_caption AS "firstLevelCaption",second_level_caption AS "secondLevelCaption",acceptance_caption AS "acceptanceCaption",
               confirmed,source_reference AS "sourceReference",row_version AS version,location_caption AS "locationCaption"
            FROM finance_asset_template_metadata WHERE object_type=? AND object_id=? AND valid_from<=?
            ORDER BY valid_from DESC,updated_at DESC,id DESC LIMIT 1
            """,type,id,cutoff);
        var result=new LinkedHashMap<String,Object>(rows.isEmpty()?Map.of("version",-1):rows.getFirst());result.put("expectedExpenseCaption",expenseCaption(type,id));return result;
    }
    @Transactional(readOnly=true)
    public Map<String,Object> operation(UUID request) {
        authorization.require(FinanceAssetAuthorization.VIEW);
        var rows=db.queryForList("SELECT result::text FROM finance_asset_template_operations WHERE request_id=? AND actor_id=?",String.class,request,current.requireId());
        if(rows.isEmpty())throw new ApiException(ErrorCode.NOT_FOUND,"原请求结果不存在或不属于当前账号");return decode(rows.getFirst());
    }
    @Transactional
    public Saved save(Save input) {
        authorization.require(FinanceAssetAuthorization.EDIT);if(input==null||input.requestId()==null||input.validFrom()==null)throw invalid("请填写原表资料和有效日期");
        if(input.validFrom().isAfter(BusinessTime.today()))throw invalid("原表资料有效日不能晚于今天");
        tx.bind();
        db.query("SELECT pg_advisory_xact_lock(hashtextextended(?,997))",rs->{},"asset-template-request:"+input.requestId());
        String fingerprint=ImmutableDocumentStore.digest(encode(input).getBytes(StandardCharsets.UTF_8));
        var existing=db.queryForList("SELECT actor_id,fingerprint,result::text FROM finance_asset_template_operations WHERE request_id=?",input.requestId());
        if(!existing.isEmpty()) {
            var previous=existing.getFirst();if(!current.requireId().equals(previous.get("actor_id"))||!fingerprint.equals(previous.get("fingerprint")))throw conflict("原请求编号已用于其他内容，请核对原结果");
            var saved=decode((String)previous.get("result"));return new Saved(input.requestId(),UUID.fromString(saved.get("metadataId").toString()),((Number)saved.get("version")).longValue());
        }
        target(input.objectType(),input.objectId());
        String expected=expenseCaption(input.objectType(),input.objectId());
        if(input.confirmed()&&(expected==null||!expected.equals(input.firstLevelCaption())))throw invalid("原表科目与实际核算科目尚未对应，请先核对资产政策/财务科目，不能只改显示名称");
        db.query("SELECT pg_advisory_xact_lock(hashtextextended(?,997))",rs->{},input.objectType()+":"+input.objectId()+":"+input.validFrom());
        var currentRows=db.queryForList("SELECT id,row_version,location_caption FROM finance_asset_template_metadata WHERE object_type=? AND object_id=? AND valid_from=? FOR UPDATE",input.objectType(),input.objectId(),input.validFrom());
        long version=currentRows.isEmpty()?-1:((Number)currentRows.getFirst().get("row_version")).longValue();
        if(version!=input.expectedVersion())throw conflict("该有效日的原表资料已经变化，请刷新核对");
        UUID id=currentRows.isEmpty()?UUID.randomUUID():(UUID)currentRows.getFirst().get("id");long next=version+1;
        db.update("""
            INSERT INTO finance_asset_template_metadata(id,object_type,object_id,valid_from,party_name,unit_specification,category_caption,usage_caption,
                source_month,document_date,first_level_caption,second_level_caption,acceptance_caption,confirmed,source_reference,row_version,created_by,updated_by,location_caption)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(object_type,object_id,valid_from) DO UPDATE
            SET party_name=excluded.party_name,unit_specification=excluded.unit_specification,category_caption=excluded.category_caption,
                usage_caption=excluded.usage_caption,source_month=excluded.source_month,document_date=excluded.document_date,
                first_level_caption=excluded.first_level_caption,second_level_caption=excluded.second_level_caption,acceptance_caption=excluded.acceptance_caption,
                confirmed=excluded.confirmed,source_reference=excluded.source_reference,row_version=excluded.row_version,updated_at=now(),updated_by=excluded.updated_by,location_caption=excluded.location_caption
            """,id,input.objectType(),input.objectId(),input.validFrom(),input.partyName(),input.unitSpecification(),input.categoryCaption(),input.usageCaption(),
                input.sourceMonth(),input.documentDate(),input.firstLevelCaption(),input.secondLevelCaption(),input.acceptanceCaption(),input.confirmed(),input.sourceReference(),next,current.requireId(),current.requireId(),
                input.locationCaption()!=null?input.locationCaption():currentRows.isEmpty()?"":currentRows.getFirst().get("location_caption"));
        Saved result=new Saved(input.requestId(),id,next);db.update("INSERT INTO finance_asset_template_operations(request_id,actor_id,fingerprint,result) VALUES(?,?,?,?::jsonb)",input.requestId(),current.requireId(),fingerprint,encode(result));return result;
    }
    private void target(String type,UUID id){String table=table(type);if(id==null||db.queryForObject("SELECT count(*) FROM "+table+" WHERE id=? AND NOT is_deleted",Integer.class,id)!=1)throw new ApiException(ErrorCode.NOT_FOUND,"资产或待摊记录不存在");}
    private String expenseCaption(String type,UUID id) {
        String table=table(type);
        var rows=db.queryForList("""
            SELECT CASE WHEN chart.code LIKE '4101%%' THEN '制造费用' WHEN chart.code LIKE '5601%%' THEN '销售费用'
                WHEN chart.code LIKE '5602%%' THEN '管理费用' WHEN chart.code LIKE '5603%%' THEN '财务费用'
                WHEN chart.code LIKE '5401%%' THEN '主营业务成本' ELSE NULL END
            FROM %s a LEFT JOIN finance_asset_categories category ON category.id=a.category_id
            LEFT JOIN finance_chart_code_styles mapped ON mapped.style_id=COALESCE(a.expense_style_snapshot_id,category.expense_style_id,a.expense_style_id)
            LEFT JOIN finance_chart_codes chart ON chart.code=mapped.code WHERE a.id=?
            """.formatted(table),String.class,id);return rows.isEmpty()?null:rows.getFirst();
    }
    private static String table(String type){return switch(Objects.toString(type,"")){case "FIXED_ASSET"->"fixed_assets";case "DEFERRED_EXPENSE"->"deferred_expenses";default->throw invalid("资产类型不正确");};}
    private String encode(Object value){try{return json.writeValueAsString(value);}catch(Exception e){throw new IllegalStateException("原表资料编码失败",e);}}
    @SuppressWarnings("unchecked") private Map<String,Object> decode(String value){try{return json.readValue(value,Map.class);}catch(Exception e){throw new IllegalStateException("原表资料回执无效",e);}}
    private static ApiException invalid(String m){return new ApiException(ErrorCode.VALIDATION_FAILED,m);}
    private static ApiException conflict(String m){return new ApiException(ErrorCode.CONFLICT,m);}
}
