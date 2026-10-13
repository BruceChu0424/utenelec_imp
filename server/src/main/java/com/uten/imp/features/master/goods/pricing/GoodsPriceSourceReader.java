package com.uten.imp.features.master.goods.pricing;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.finance.ProcurementApprovedExchangeRate;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.features.master.client.ClientAccessPolicy;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Component;
import java.math.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.*;
import static com.uten.imp.features.master.goods.pricing.GoodsPriceContracts.*;

@Component
@RequiredArgsConstructor
final class GoodsPriceSourceReader {
    private final NamedParameterJdbcTemplate db;
    private final ObjectMapper json;
    private final ClientAccessPolicy clients;
    private final GoodsPriceAccess access;
    record Goods(UUID id,String code,String name,UUID unitId,UUID colorId) {}
    record Data(Context context,List<Observation> observations,boolean complete) {}
    record Plan(Context context,MapSqlParameterSource parameters,String where) {}
    Goods goods(UUID id) {
        var rows=db.queryForList("SELECT id,code,name,unit_id,color_id FROM goods WHERE id=:id AND NOT is_deleted AND NOT auto_created",Map.of("id",id));
        if(rows.size()!=1)throw GoodsPriceAnalysisService.invalid("货品不存在或不是正式货品");
        var r=rows.getFirst();return new Goods(id,text(r,"code"),text(r,"name"),uuid(r,"unit_id"),uuid(r,"color_id"));
    }
    Data read(Query q,Goods goods,int days,OwnerVisibility.OwnerScope scope) {
        Plan plan=plan(q,goods,days,scope);Context context=plan.context();var p=plan.parameters();
        if(context.currencyId()==null||context.taxRate()==null||context.unitRate()==null||context.unitId()==null)return new Data(context,List.of(),true);
        var rows=db.queryForList("SELECT * FROM v_goods_price_observations WHERE "+plan.where()
                +" ORDER BY business_date DESC,source_id DESC,source_item_id DESC LIMIT 501",p);
        boolean complete=rows.size()<=GoodsPriceStatistics.MAX_ROWS;
        return new Data(context,rows.stream().limit(GoodsPriceStatistics.MAX_ROWS).map(this::observation).toList(),complete);
    }
    private Plan plan(Query q,Goods goods,int days,OwnerVisibility.OwnerScope scope) {
        LocalDate today=BusinessTime.today();
        UUID color=q.colorId(); // Null is an explicit uncoloured line, not permission to substitute today's master default.
        UUID unit=q.unitId()==null?goods.unitId():q.unitId();
        var p=new MapSqlParameterSource().addValue("kind",q.kind().name()).addValue("goods",goods.id())
                .addValue("from",today.minusDays(days-1L)).addValue("to",today).addValue("color",color).addValue("unit",unit)
                .addValue("supplier",q.supplierId()).addValue("client",q.clientId()).addValue("exclude",q.excludeOrderId());
        String where="""
                kind=:kind AND goods_id=:goods AND business_date BETWEEN :from AND :to
                AND color_id IS NOT DISTINCT FROM CAST(:color AS uuid)
                AND unit_id IS NOT DISTINCT FROM CAST(:unit AS uuid)
                AND (CAST(:supplier AS uuid) IS NULL OR supplier_id=CAST(:supplier AS uuid))
                AND (CAST(:client AS uuid) IS NULL OR client_id=CAST(:client AS uuid))
                AND (CAST(:exclude AS uuid) IS NULL OR source_id<>CAST(:exclude AS uuid))
                """+ownerClause(scope,p)+clientClause(q.kind(),p);
        if(q.currencyId()!=null){where+=" AND currency_id=:currency";p.addValue("currency",q.currencyId());}
        if(q.taxRate()!=null){where+=" AND tax_rate=:tax";p.addValue("tax",GoodsPriceAnalysisService.decimal(q.taxRate(),"税率",false));}
        if(q.unitRate()!=null){where+=" AND unit_rate=:rate";p.addValue("rate",GoodsPriceAnalysisService.decimal(q.unitRate(),"换算率",true));}
        var anchor=db.queryForList("SELECT currency_id,currency_name,tax_rate,unit_rate,unit_name,color_name FROM v_goods_price_observations WHERE "+where
                +" AND currency_id IS NOT NULL AND tax_rate IS NOT NULL AND unit_rate>0 ORDER BY business_date DESC,source_id DESC,source_item_id DESC LIMIT 1",p);
        UUID currency=q.currencyId();String currencyName=null,unitName=null,colorName=null;
        BigDecimal tax=q.taxRate()==null?null:new BigDecimal(q.taxRate()),rate=q.unitRate()==null?null:new BigDecimal(q.unitRate());
        if(!anchor.isEmpty()){
            var first=anchor.getFirst();currency=uuid(first,"currency_id");currencyName=text(first,"currency_name");
            tax=amount(first,"tax_rate");rate=amount(first,"unit_rate");unitName=text(first,"unit_name");colorName=text(first,"color_name");
        }
        Context context=new Context(q.supplierId(),q.clientId(),color,unit,unitName,currency,currencyName,decimalText(tax),q.quantity(),days,
                "AS_RECORDED",q.kind()==Kind.SUBCONTRACT?"APPROVED_PROCESSING_FEE":"APPROVED_ORDER_TERMS","CHARGED_LINE_QUANTITY",decimalText(rate),colorName);
        p.addValue("currency",currency).addValue("tax",tax).addValue("rate",rate);
        // Filter every sensitive source scope before LIMIT and before any aggregate.
        return new Plan(context,p,where+" AND currency_id=:currency AND tax_rate=:tax AND unit_rate=:rate");
    }
    History history(HistoryQuery request,OwnerVisibility.OwnerScope scope,boolean includeQuotes,boolean includeOrders) {
        Query q=request.context();int size=request.pageSize()==null?50:request.pageSize();
        if(size<1||size>100)throw GoodsPriceAnalysisService.invalid("历史每页须为1至100条");
        LocalDate to=request.to()==null?BusinessTime.today():request.to();
        if(to.isAfter(BusinessTime.today())||request.from()!=null&&request.from().isAfter(to))throw GoodsPriceAnalysisService.invalid("历史日期范围无效");
        var p=new MapSqlParameterSource().addValue("kind",q.kind().name()).addValue("goods",q.goodsId()).addValue("to",to).addValue("size",size+1)
                .addValue("procurementFilter","{\"items\":[{\"goodsId\":\""+q.goodsId()+"\"}]}")
                .addValue("quoteFilter","{\"lines\":[{\"goodsId\":\""+q.goodsId()+"\"}]}");
        String where="kind=:kind AND goods_id=:goods AND business_date<=:to"+historyVisibility(q.kind(),scope,includeQuotes,includeOrders,p)
                +" AND (history_kind<>'PROCUREMENT_CASE' OR snapshot_filter @> CAST(:procurementFilter AS jsonb))"
                +" AND (history_kind<>'QUOTE_CONFIRMATION' OR snapshot_filter @> CAST(:quoteFilter AS jsonb))"
                ;
        if(request.from()!=null){where+=" AND business_date>=:from";p.addValue("from",request.from());}
        if(q.supplierId()!=null){where+=" AND supplier_id=:supplier";p.addValue("supplier",q.supplierId());}
        if(q.clientId()!=null){where+=" AND client_id=:client";p.addValue("client",q.clientId());}
        if(q.colorId()!=null){where+=" AND color_id=:color";p.addValue("color",q.colorId());}
        if(q.unitId()!=null){where+=" AND unit_id=:unit";p.addValue("unit",q.unitId());}
        if(q.currencyId()!=null){where+=" AND currency_id=:currency";p.addValue("currency",q.currencyId());}
        if(q.taxRate()!=null){where+=" AND tax_rate=:tax";p.addValue("tax",GoodsPriceAnalysisService.decimal(q.taxRate(),"税率",false));}
        if(q.unitRate()!=null){where+=" AND unit_rate=:rate";p.addValue("rate",GoodsPriceAnalysisService.decimal(q.unitRate(),"换算率",true));}
        if(request.cursor()!=null){
            try{String[] cursor=new String(Base64.getUrlDecoder().decode(request.cursor()),StandardCharsets.UTF_8).split("\\|");
                if(cursor.length!=4||cursor[3].length()>80)throw new IllegalArgumentException();
                p.addValue("cursorDate",LocalDate.parse(cursor[0])).addValue("cursorOrder",UUID.fromString(cursor[1])).addValue("cursorItem",UUID.fromString(cursor[2])).addValue("cursorType",cursor[3]);
            }catch(IllegalArgumentException malformed){throw GoodsPriceAnalysisService.invalid("历史分页游标无效");}
            where+=" AND (business_date,history_version_id,source_item_id,source_type)<(:cursorDate,:cursorOrder,:cursorItem,:cursorType)";
        }
        var rows=db.queryForList("SELECT * FROM v_goods_price_history WHERE "+where+" ORDER BY business_date DESC,history_version_id DESC,source_item_id DESC,source_type DESC LIMIT :size",p);
        boolean more=rows.size()>size;var observations=rows.stream().limit(size).map(this::observation).toList();String next=null;
        if(more){var last=observations.getLast();next=Base64.getUrlEncoder().withoutPadding().encodeToString((last.businessDate()+"|"+last.historyVersionId()+"|"+last.sourceItemId()+"|"+last.sourceType()).getBytes(StandardCharsets.UTF_8));}
        return new History(observations,next,more,OffsetDateTime.now());
    }
    /** Resolve exactly one currently authorized row, never a current document substituted for an old version. */
    Observation detail(UUID goodsId,DetailQuery request,OwnerVisibility.OwnerScope scope,boolean includeQuotes,boolean includeOrders) {
        var p=new MapSqlParameterSource().addValue("kind",request.kind().name()).addValue("goods",goodsId)
                .addValue("sourceType",request.sourceType()).addValue("source",request.sourceId()).addValue("item",request.sourceItemId())
                .addValue("version",request.historyVersionId()).addValue("today",BusinessTime.today());
        boolean history=request.historyVersionId()!=null;
        String view=history?"v_goods_price_history":"v_goods_price_observations";
        String where="kind=:kind AND goods_id=:goods AND source_type=:sourceType AND source_id=:source AND source_item_id=:item AND business_date<=:today";
        if(history)where+=" AND history_version_id=:version"+historyVisibility(request.kind(),scope,includeQuotes,includeOrders,p);
        else where+=includeOrders?ownerClause(scope,p)+clientClause(request.kind(),p):" AND 1=0";
        var rows=db.queryForList("SELECT * FROM "+view+" WHERE "+where+" LIMIT 2",p);
        if(rows.size()!=1)throw new ApiException(com.uten.imp.common.web.ErrorCode.NOT_FOUND,"价格记录不存在或无权查看，请重新加载");
        Observation result=observation(rows.getFirst());
        if(!Objects.equals(request.expectedSourceRevision(),result.sourceRevision()))
            throw new ApiException(com.uten.imp.common.web.ErrorCode.CONFLICT,"价格记录或访问范围已变化，请重新加载");
        return result;
    }
    String historyVisibility(Kind kind,OwnerVisibility.OwnerScope scope,boolean includeQuotes,boolean includeOrders,MapSqlParameterSource p) {
        String ordinary=includeOrders?"history_kind<>'QUOTE_CONFIRMATION'"+ownerClause(scope,p)
                +clientClause(kind,p).replace("v_goods_price_observations.client_id","v_goods_price_history.client_id"):"false";
        // Existing quote-finance history authority is its own scope; it never opens the order branches.
        return " AND (("+ordinary+") OR ("+(includeQuotes?"history_kind='QUOTE_CONFIRMATION'":"false")+"))";
    }
    static String ownerClause(OwnerVisibility.OwnerScope scope,MapSqlParameterSource p) {
        if(scope.seeAll())return " AND 1=1";
        if(scope.visibleOwners().isEmpty())return " AND 1=0";
        p.addValue("owners",scope.visibleOwners());return " AND owner_employee_id IN (:owners)";
    }
    private String clientClause(Kind kind,MapSqlParameterSource p) {
        if(kind!=Kind.SALES)return "";
        var scope=clients.nativeReadScope("price_client",clients.evaluate());
        if(scope.ownerParameter()!=null)p.addValue(scope.ownerParameter(),scope.ownerEmployees());
        if(scope.viewerParameter()!=null)p.addValue(scope.viewerParameter(),scope.viewerEmployeeId());
        return " AND EXISTS(SELECT 1 FROM clients price_client WHERE price_client.id=v_goods_price_observations.client_id AND "+scope.predicate()+")";
    }
    Observation observation(Map<String,Object> r) {
        List<String> reasons=new ArrayList<>();
        boolean historical=Boolean.TRUE.equals(r.get("historical_only"));
        if(historical)reasons.add("HISTORICAL_VERSION_ONLY");
        validateApproval(r,reasons);
        BigDecimal quantity=amount(r,"quantity"),recorded=amount(r,"recorded_unit_price"),total=amount(r,"total_amount_input"),actual=amount(r,"amount_original");
        if(quantity==null||quantity.signum()<=0)reasons.add("NO_CHARGED_QUANTITY");
        if(amount(r,"gift_quantity")!=null&&amount(r,"gift_quantity").signum()>0)reasons.add("GIFT_COMPONENT");
        boolean extra=hasPriceComponents(r.get("extra_columns"));
        if(extra)reasons.add("UNDIVIDED_PRICE_COMPONENTS");
        BigDecimal base=total!=null?total:recorded==null||quantity==null?null:recorded.multiply(quantity);
        if("SALES".equals(text(r,"kind"))&&base!=null){
            BigDecimal factor=amount(r,"discount_factor");
            if(factor==null||factor.signum()<=0){reasons.add("DISCOUNT_BASIS_INVALID");base=null;}else base=base.multiply(factor);
        }
        // Explicit total input is authoritative, never the rounded display unit price.
        if(base==null||base.signum()<=0)reasons.add("NO_POSITIVE_PRICE");
        if(actual==null||base==null||actual.compareTo(base)!=0)reasons.add("AMOUNT_BASIS_MISMATCH");
        if(text(r,"goods_code_snapshot")==null||text(r,"goods_name_snapshot")==null)reasons.add("SOURCE_IDENTITY_INCOMPLETE");
        BigDecimal price=base==null||quantity==null||quantity.signum()<=0?null:base.divide(quantity,MathContext.DECIMAL128);
        BigDecimal fx=amount(r,"contract_exchange_rate");String fxSource="ORDER_CONTRACT";
        if(!"SALES".equals(text(r,"kind"))&&(!r.containsKey("approval_status")||r.get("approval_status")==null||"APPROVED".equals(text(r,"approval_status")))){
            try {
                var terms=ProcurementApprovedExchangeRate.fromApprovedFacts(uuid(r,"finance_approval_case_id"),amount(r,"finance_exchange_rate"),amount(r,"finance_total_local"),fx);
                fx=terms.rate();fxSource=terms.financeDetermined()?"FINANCE_APPROVAL_CASE":"LEGACY_CONTRACT";
            } catch(ApiException invalid){fx=null;fxSource="UNAVAILABLE";reasons.add("FX_AUTHORITY_INCOMPLETE");}
        }else if(!"SALES".equals(text(r,"kind"))){fx=null;fxSource="UNAPPROVED_REVIEW";}
        String revision=hash(new TreeMap<>(r).toString());
        return new Observation(text(r,"source_type"),uuid(r,"source_id"),uuid(r,"source_item_id"),text(r,"source_no"),revision,
                date(r,"business_date"),uuid(r,"supplier_id"),uuid(r,"client_id"),text(r,"partner_name"),uuid(r,"color_id"),uuid(r,"unit_id"),text(r,"unit_name"),
                uuid(r,"currency_id"),text(r,"currency_name"),decimalText(amount(r,"tax_rate")),decimalText(quantity),decimalText(price),decimalText(actual),
                decimalText(fx),uuid(r,"finance_approval_case_id"),fxSource,reasons.isEmpty(),List.copyOf(reasons),text(r,"goods_code_snapshot"),text(r,"goods_name_snapshot"),!historical&&access.has(text(r,"kind").toLowerCase()+"_order:view"),decimalText(amount(r,"unit_rate")),
                uuid(r,"history_version_id"),Objects.toString(r.get("lifecycle"),"ACTIVE"),time(r.get("approval_decided_at")),text(r,"color_name"));
    }
    private boolean hasPriceComponents(Object value) {
        if(value==null)return false;
        try {JsonNode root=json.readTree(value.toString());if(!root.isArray())return true;
            for(JsonNode c:root)if(!"NONE".equals(c.path("operation").asText("NONE")))return true;
            return false;
        }catch(Exception malformed){return true;}
    }
    private void validateApproval(Map<String,Object> r,List<String> reasons) {
        Object decision=r.get("approval_decided_at");
        if(decision instanceof java.sql.Timestamp at&&at.toInstant().isAfter(java.time.Instant.now()))reasons.add("APPROVAL_NOT_EFFECTIVE");
        String state=text(r,"approval_status");
        if(state==null)return; // Explicit legacy approved-order facts remain distinguishable by missing case id.
        if(!"APPROVED".equals(state)){reasons.add("FINANCE_REVIEW_NOT_APPROVED");return;}
        try {
            JsonNode header=json.readTree(Objects.toString(r.get("approval_snapshot"),"null"));
            boolean match=same(header,"orderId",r.get("source_id"))&&same(header,"currencyId",r.get("currency_id"))
                    &&same(header,"supplierId",r.get("supplier_id"))&&sameDecimal(header,"taxRate",amount(r,"tax_rate"));
            JsonNode selected=null;
            for(JsonNode item:header.path("items"))if(same(item,"itemId",r.get("source_item_id"))){selected=item;break;}
            if(selected==null||!match||!same(selected,"goodsId",r.get("goods_id"))||!same(selected,"colorId",r.get("color_id"))
                    ||!same(selected,"unitId",r.get("unit_id"))||!sameDecimal(selected,"unitRate",amount(r,"unit_rate"))
                    ||!sameDecimal(selected,"qty",amount(r,"quantity"))||!sameDecimal(selected,"price",amount(r,"recorded_unit_price"))
                    ||!sameDecimal(selected,"amountOriginal",amount(r,"amount_original"))||!sameDecimal(selected,"totalAmountInput",amount(r,"total_amount_input")))
                reasons.add("APPROVED_SNAPSHOT_MISMATCH");
        }catch(Exception malformed){reasons.add("APPROVED_SNAPSHOT_INCOMPLETE");}
    }
    private static boolean same(JsonNode node,String key,Object expected){JsonNode v=node.get(key);return expected==null?v==null||v.isNull():v!=null&&!v.isNull()&&expected.toString().equals(v.asText());}
    private static boolean sameDecimal(JsonNode node,String key,BigDecimal expected){JsonNode v=node.get(key);return expected==null?v==null||v.isNull():v!=null&&!v.isNull()&&expected.compareTo(new BigDecimal(v.asText()))==0;}
    static String hash(String value){try{return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8)));}catch(Exception impossible){throw new IllegalStateException(impossible);}}
    static String decimalText(BigDecimal value){return value==null?null:value.stripTrailingZeros().toPlainString();}
    private static String text(Map<String,Object> r,String k){Object v=r.get(k);return v==null?null:v.toString();}
    private static UUID uuid(Map<String,Object> r,String k){return (UUID)r.get(k);}
    private static BigDecimal amount(Map<String,Object> r,String k){return (BigDecimal)r.get(k);}
    private static LocalDate date(Map<String,Object> r,String k){Object v=r.get(k);return v instanceof LocalDate d?d:((java.sql.Date)v).toLocalDate();}
    private static OffsetDateTime time(Object value){return value==null?null:value instanceof OffsetDateTime d?d:((java.sql.Timestamp)value).toInstant().atOffset(java.time.ZoneOffset.UTC);}
}
