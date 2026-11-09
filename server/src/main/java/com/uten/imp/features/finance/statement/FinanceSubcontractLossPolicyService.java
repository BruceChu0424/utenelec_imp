package com.uten.imp.features.finance.statement;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.finance.BusinessPrecisionContext;
import com.uten.imp.common.report.ReportQueryKit;
import com.uten.imp.common.storage.ImmutableDocumentStore;
import com.uten.imp.common.web.*;
import com.uten.imp.features.finance.*;
import com.uten.imp.security.*;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;

/** Reviewed physical SKU/unit rules, independent of every processing currency. */
@Service @RequiredArgsConstructor
public class FinanceSubcontractLossPolicyService {
    private final JdbcTemplate db;private final ObjectMapper json;private final TxSessionVars tx;
    private final SecurityContextCurrentUser current;private final FinanceDocumentAccessPolicy access;
    public record Save(UUID requestId,long expectedRevision,UUID supplierId,UUID goodsId,UUID colorId,UUID unitId,
        LocalDate effectiveFrom,LocalDate effectiveTo,BigDecimal ratePercent,Boolean enabled,String sourceReference){ }
    public record Decision(Boolean approve,String reason){ }
    private void read(){CurrentAuthorityGuard.requireAll("finance_report:view");FinanceCompanyReportAccess.require(access);}
    @Transactional(readOnly=true)
    public Map<String,Object> list(UUID supplierId,String keyword,int page,int size){
        read();int p=Math.max(1,page),s=Math.max(1,Math.min(Pageables.MAX_PAGE_SIZE,size));var values=new ArrayList<Object>();String where=" WHERE 1=1";
        if(supplierId!=null){where+=" AND policy.supplier_id=?";values.add(supplierId);}
        if(keyword!=null&&!keyword.isBlank()){where+=" AND lower(concat_ws(' ',supplier.code,supplier.name,goods.code,goods.name,unit.code,unit.name)) LIKE '%'||lower(?)||'%'";values.add(keyword.strip());}
        String from=" FROM finance_subcontract_loss_policies policy JOIN suppliers supplier ON supplier.id=policy.supplier_id JOIN goods goods ON goods.id=policy.goods_id JOIN units unit ON unit.id=policy.unit_id LEFT JOIN colors color ON color.id=policy.color_id";
        long total=Objects.requireNonNull(db.queryForObject("SELECT count(*)"+from+where,Long.class,values.toArray()));values.add(s);values.add((long)(p-1)*s);
        var rows=db.queryForList("SELECT policy.*,policy.rate*100 AS \"ratePercent\",supplier.code AS \"supplierCode\",supplier.name AS \"supplierName\",goods.code AS \"goodsCode\",goods.name AS \"goodsName\",unit.code AS \"unitCode\",unit.name AS \"unitName\",color.name AS \"colorName\""+from+where+" ORDER BY supplier.code,goods.code,policy.effective_from DESC,policy.revision DESC,policy.id LIMIT ? OFFSET ?",values.toArray());
        rows.forEach(ReportQueryKit::includeDecimalTexts);return Map.of("items",rows,"page",p,"size",s,"total",total,"totalPages",(total+s-1)/s);
    }
    /** Actual outbound dimensions plus the master record's own base unit; names are display only. */
    @Transactional(readOnly=true)
    public Map<String,Object> sourceChoices(UUID supplierId,String keyword,int page,int size){
        read();if(supplierId==null)throw invalid("请先选择真实委外供应商");dictionary("suppliers",supplierId);
        int p=Math.max(1,page),s=Math.max(1,Math.min(Pageables.MAX_PAGE_SIZE,size));
        String candidates="""
            WITH dimensions AS (
              SELECT item.goods_id,item.color_id,item.unit_id,true AS actual_source
              FROM subcontract_material_issue_items item JOIN subcontract_material_issues document ON document.id=item.issue_id
              WHERE document.supplier_id=:supplier AND document.status IN(1,-1) AND NOT item.is_deleted AND item.unit_id IS NOT NULL
              UNION ALL SELECT goods.id,NULL::uuid,goods.unit_id,false FROM goods
              WHERE NOT goods.is_deleted AND goods.unit_id IS NOT NULL
            ), choices AS (
              SELECT dimension.goods_id AS "goodsId",dimension.color_id AS "colorId",dimension.unit_id AS "unitId",
                goods.code AS "goodsCode",goods.name AS "goodsName",color.name AS "colorName",unit.code AS "unitCode",unit.name AS "unitName",
                bool_or(dimension.actual_source) AS "actualSource"
              FROM dimensions dimension JOIN goods ON goods.id=dimension.goods_id JOIN units unit ON unit.id=dimension.unit_id
              LEFT JOIN colors color ON color.id=dimension.color_id
              WHERE NOT goods.is_deleted AND NOT unit.is_deleted AND(color.id IS NULL OR NOT color.is_deleted)
              GROUP BY dimension.goods_id,dimension.color_id,dimension.unit_id,goods.code,goods.name,color.name,unit.code,unit.name
            ) SELECT * FROM choices
            """;
        var named=new org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate(db);
        var parameters=new org.springframework.jdbc.core.namedparam.MapSqlParameterSource("supplier",supplierId);
        if(keyword!=null&&!keyword.isBlank()){
            candidates+=" WHERE lower(concat_ws(' ',\"goodsCode\",\"goodsName\",\"colorName\",\"unitCode\",\"unitName\")) LIKE '%'||lower(:keyword)||'%'";
            parameters.addValue("keyword",keyword.strip());
        }
        long total=Objects.requireNonNull(named.queryForObject("SELECT count(*) FROM ("+candidates+") source",parameters,Long.class));
        parameters.addValue("size",s).addValue("offset",(long)(p-1)*s);
        var rows=named.queryForList(candidates+" ORDER BY \"actualSource\" DESC,\"goodsCode\",\"goodsId\",\"colorId\" NULLS FIRST,\"unitId\" LIMIT :size OFFSET :offset",parameters);
        return Map.of("items",rows,"page",p,"size",s,"total",total,"totalPages",(total+s-1)/s);
    }
    @Transactional(readOnly=true)public Map<String,Object> get(UUID id){read();return view(row(id,false));}
    @Transactional(readOnly=true)public Map<String,Object> operation(UUID request){
        read();var rows=db.queryForList("SELECT * FROM finance_subcontract_loss_policies WHERE request_id=? AND submitted_by=?",request,current.requireId());
        if(rows.size()!=1)throw new ApiException(ErrorCode.NOT_FOUND,"本人原损耗率提交尚未取得成功回执，请保留原请求核对");return view(rows.getFirst());
    }
    @Transactional public Map<String,Object> save(Save input){
        read();CurrentAuthorityGuard.requireAll("payment_style:edit");
        if(input==null||input.requestId()==null||input.supplierId()==null||input.goodsId()==null||input.unitId()==null||input.effectiveFrom()==null||input.enabled()==null)throw invalid("请选择真实供应商、商品、单位、有效期和启用状态，并保留请求编号");
        String reference=reference(input.sourceReference());
        var percent=input.ratePercent();if(percent==null||percent.signum()<0||percent.compareTo(new BigDecimal("100"))>0||percent.precision()>4096||Math.abs((long)percent.scale())>1000)throw invalid("允许损耗率请填写支持范围内0至100之间的原百分数");
        if(input.effectiveTo()!=null&&input.effectiveTo().isBefore(input.effectiveFrom()))throw invalid("损耗率截止日期不能早于生效日期");
        String fingerprint=hash(Arrays.asList(input.expectedRevision(),input.supplierId(),input.goodsId(),input.colorId(),input.unitId(),input.effectiveFrom(),input.effectiveTo(),percent.stripTrailingZeros().toPlainString(),input.enabled(),reference,new TreeMap<>(BusinessPrecisionContext.choices())));
        tx.bind();db.query("SELECT pg_advisory_xact_lock(hashtextextended(?,1022))",rs->{},"request:"+input.requestId());
        var prior=db.queryForList("SELECT * FROM finance_subcontract_loss_policies WHERE request_id=?",input.requestId());
        if(!prior.isEmpty()){var old=prior.getFirst();if(!current.requireId().equals(old.get("submitted_by"))||!fingerprint.equals(old.get("fingerprint")))throw conflict("该原请求已属于其他操作人或内容，请保留本人原请求");return view(old);}
        lock(input.supplierId(),input.goodsId(),input.unitId());
        dictionary("suppliers",input.supplierId());dictionary("goods",input.goodsId());dictionary("units",input.unitId());if(input.colorId()!=null)dictionary("colors",input.colorId());
        Boolean realDimension=db.queryForObject("""
            SELECT EXISTS(SELECT 1 FROM goods WHERE id=? AND unit_id=? AND CAST(? AS uuid) IS NULL)
              OR EXISTS(SELECT 1 FROM subcontract_material_issue_items item JOIN subcontract_material_issues document ON document.id=item.issue_id
                WHERE document.supplier_id=? AND document.status IN(1,-1) AND NOT item.is_deleted
                  AND item.goods_id=? AND item.color_id IS NOT DISTINCT FROM CAST(? AS uuid) AND item.unit_id=?)
            """,Boolean.class,input.goodsId(),input.unitId(),input.colorId(),input.supplierId(),input.goodsId(),input.colorId(),input.unitId());
        if(!Boolean.TRUE.equals(realDimension))throw invalid("商品、颜色与单位须来自同一真实发料行或商品主档的基本单位，请重新选择实际来源");
        Long latest=db.queryForObject("SELECT COALESCE(max(revision),-1) FROM finance_subcontract_loss_policies WHERE supplier_id=? AND goods_id=? AND color_id IS NOT DISTINCT FROM CAST(? AS uuid) AND unit_id=? AND effective_from=?",Long.class,input.supplierId(),input.goodsId(),input.colorId(),input.unitId(),input.effectiveFrom());
        if(latest==null||latest!=input.expectedRevision())throw conflict("该商品损耗率已有后续版本，请先读取原提交再更正");
        var rate=BusinessPrecisionContext.divide(percent,new BigDecimal("100"),"finance.subcontract.loss-percent","本次允许损耗百分率",24);
        UUID id=UUID.randomUUID();db.update("""
            INSERT INTO finance_subcontract_loss_policies(id,request_id,supplier_id,goods_id,color_id,unit_id,effective_from,effective_to,
              revision,rate_percent_original,precision_policy,rate,enabled,source_reference,fingerprint,submitted_by)
            VALUES(?,?,?,?,?,?,?,?,?,?,CAST(? AS jsonb),?,?,?,?,?)
            """,id,input.requestId(),input.supplierId(),input.goodsId(),input.colorId(),input.unitId(),input.effectiveFrom(),input.effectiveTo(),Math.addExact(latest,1),percent,usedPrecisionJson(),rate,input.enabled(),reference,fingerprint,current.requireId());
        return get(id);
    }
    @Transactional public Map<String,Object> decide(UUID id,Decision input){
        read();CurrentAuthorityGuard.requireAll("payment_style:edit","finance_post:execute");if(input==null||input.approve()==null)throw invalid("请明确损耗率审核结果");String reason=reference(input.reason());tx.bind();
        var initial=row(id,false);lock((UUID)initial.get("supplier_id"),(UUID)initial.get("goods_id"),(UUID)initial.get("unit_id"));var saved=row(id,true);
        if(!"SUBMITTED".equals(saved.get("status"))){if(Objects.equals(saved.get("reviewed_by"),current.requireId())&&Objects.equals(saved.get("review_reason"),reason)&&Objects.equals(saved.get("status"),input.approve()?"APPROVED":"REJECTED"))return view(saved);throw conflict("该原损耗率版本已审核，请核对原回执");}
        if(current.requireId().equals(saved.get("submitted_by")))throw conflict("损耗率提交人与审核人不可相同");
        db.update("UPDATE finance_subcontract_loss_policies SET status=?,reviewed_by=?,reviewed_at=now(),review_reason=? WHERE id=?",input.approve()?"APPROVED":"REJECTED",current.requireId(),reason,id);return get(id);
    }
    /** Only rules affecting the actual source rows enter this statement's proof. */
    @Transactional(readOnly=true)public List<Map<String,Object>> rulesFor(UUID supplier,LocalDate to){
        read();var rows=db.queryForList("""
            SELECT policy.id,policy.goods_id AS "goodsId",policy.color_id AS "colorId",policy.unit_id AS "unitId",policy.rate,
              policy.effective_from AS "effectiveFrom",policy.effective_to AS "effectiveTo",policy.revision,policy.source_reference AS "sourceReference"
            FROM v_finance_subcontract_loss_policy_current policy WHERE policy.enabled AND policy.supplier_id=?
              AND policy.effective_from<=?
              AND EXISTS(SELECT 1 FROM subcontract_material_issue_items item JOIN subcontract_material_issues document ON document.id=item.issue_id
                WHERE document.supplier_id=policy.supplier_id AND document.status IN(1,-1) AND NOT item.is_deleted
                  AND item.goods_id=policy.goods_id AND item.unit_id=policy.unit_id AND(policy.color_id IS NULL OR item.color_id=policy.color_id)
                  AND COALESCE(item.bill_date,document.bill_date)<=?
                  AND COALESCE(item.bill_date,document.bill_date)>=policy.effective_from
                  AND(policy.effective_to IS NULL OR COALESCE(item.bill_date,document.bill_date)<=policy.effective_to))
            ORDER BY policy.goods_id,policy.color_id NULLS FIRST,policy.unit_id,policy.effective_from,policy.id
            """,supplier,to,to);rows.forEach(ReportQueryKit::includeDecimalTexts);return rows;
    }
    public String rulesJson(List<Map<String,Object>> rules){
        var rows=new ArrayList<Map<String,Object>>();for(var rule:rules){var item=new LinkedHashMap<String,Object>();
            for(String key:List.of("id","goodsId","colorId","unitId","rate","effectiveFrom","effectiveTo")){Object value=rule.get(key);item.put(key,value==null?null:value instanceof BigDecimal amount?amount.toPlainString():value.toString());}rows.add(item);}
        try{return json.writeValueAsString(rows);}catch(Exception failure){throw new IllegalStateException("损耗率来源无法编码",failure);}
    }
    private Map<String,Object> row(UUID id,boolean lock){var rows=db.queryForList("SELECT *,rate*100 AS \"ratePercent\" FROM finance_subcontract_loss_policies WHERE id=?"+(lock?" FOR UPDATE":""),id);if(rows.size()!=1)throw new ApiException(ErrorCode.NOT_FOUND,"原损耗率版本不存在");return rows.getFirst();}
    private Map<String,Object> view(Map<String,Object> row){
        var result=new LinkedHashMap<>(row);result.remove("fingerprint");
        var labels=db.queryForMap("""
            SELECT supplier.code AS "supplierCode",supplier.name AS "supplierName",goods.code AS "goodsCode",goods.name AS "goodsName",
              unit.code AS "unitCode",unit.name AS "unitName",color.name AS "colorName"
            FROM finance_subcontract_loss_policies policy JOIN suppliers supplier ON supplier.id=policy.supplier_id
            JOIN goods goods ON goods.id=policy.goods_id JOIN units unit ON unit.id=policy.unit_id LEFT JOIN colors color ON color.id=policy.color_id WHERE policy.id=?
            """,row.get("id"));result.putAll(labels);ReportQueryKit.includeDecimalTexts(result);return result;
    }
    private void lock(UUID supplier,UUID goods,UUID unit){db.query("SELECT pg_advisory_xact_lock(hashtextextended(?,0))",rs->{},"uten:subcontract-loss-policy:"+supplier+":"+goods+":"+unit);}
    private void dictionary(String table,UUID id){if(db.queryForObject("SELECT count(*) FROM "+table+" WHERE id=? AND NOT is_deleted",Integer.class,id)!=1)throw invalid("所选供应商、商品、颜色或单位不存在或已删除，请重新选择实际记录");}
    private String usedPrecisionJson(){try{var choice=BusinessPrecisionContext.usedChoices().get("finance.subcontract.loss-percent");return json.writeValueAsString(Map.of("version",1,"choices",choice==null?Map.of():Map.of("finance.subcontract.loss-percent",choice)));}catch(Exception failure){throw new IllegalStateException("损耗率本次精度选择无法保存",failure);}}
    private String hash(Object input){try{return ImmutableDocumentStore.digest(json.writeValueAsBytes(input));}catch(Exception failure){throw new IllegalStateException("损耗率原请求无法校验",failure);}}
    private static String reference(String value){if(value==null||value.isBlank()||value.length()>2000)throw invalid("请填写1至2000字的实际来源或审核依据");return value.strip();}
    private static ApiException invalid(String text){return new ApiException(ErrorCode.VALIDATION_FAILED,text);}
    private static ApiException conflict(String text){return new ApiException(ErrorCode.CONFLICT,text);}
}
