package com.uten.imp.features.master.goods.pricing;

import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.FacetBucket;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.*;
import static com.uten.imp.features.master.goods.pricing.GoodsPriceContracts.*;
import static com.uten.imp.features.master.goods.pricing.GoodsPriceHistoryTableContracts.*;

/** Never filters or sorts a Java page and presents it as the whole authorized history. */
@Service
@RequiredArgsConstructor
@Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
public class GoodsPriceHistoryTableService {
    static final int INITIAL_FACET_SIZE=200;
    private static final Map<String,String> COLUMNS;
    private static final Set<String> NUMERIC=Set.of("unitPrice","quantity","amount");
    private static final Map<String,String> LIFECYCLE_LABELS=Map.of("ACTIVE","当前有效","SOURCE_DELETED","来源已删除","SOURCE_REVERSED","来源已红冲",
            "SOURCE_CANCELLED","来源已取消","SUPERSEDED_APPROVED_VERSION","历史批准版本","CONFIRMED_QUOTATION","已确认报价");
    private static final Set<String> LIFECYCLES=LIFECYCLE_LABELS.keySet();
    static {
        var columns=new LinkedHashMap<String,String>();
        columns.put("businessDate","business_date");columns.put("sourceNo","source_no");columns.put("partnerName","partner_name");
        columns.put("unitPrice","__history_price");columns.put("quantity","quantity");columns.put("amount","amount_original");
        columns.put("currencyName","currency_name");columns.put("unitName","unit_name");columns.put("colorName","color_name");columns.put("lifecycle","lifecycle");
        COLUMNS=Collections.unmodifiableMap(columns);
    }
    private final NamedParameterJdbcTemplate db;
    private final GoodsPriceAccess access;
    private final MasterReferenceValidationPort references;
    private final GoodsPriceSourceReader sources;

    /** Numeric division is computed at ample precision, then rounded HALF_EVEN to Java DECIMAL128's 34 significant digits. */
    static final String PRICED_CTE="""
            , base AS (
              SELECT authorized.*,
                CASE WHEN kind='SALES' AND (discount_factor IS NULL OR discount_factor<=0) THEN NULL
                     ELSE COALESCE(total_amount_input,recorded_unit_price*quantity)
                       *CASE WHEN kind='SALES' THEN discount_factor ELSE 1 END END AS __history_base
              FROM authorized
            ), precise AS (
              SELECT base.*,CASE WHEN quantity>0 THEN __history_base::numeric(1000,200)
                  /NULLIF(quantity::numeric(1000,200),0) END AS __history_precise FROM base
            ), scaled AS (
              SELECT precise.*,CASE WHEN __history_precise=0 THEN 0
                  ELSE (33-floor(log(10::numeric,abs(__history_precise))))::integer END AS __history_scale
              FROM precise
            ), decimal128 AS (
              SELECT scaled.*,__history_precise*power(10::numeric,__history_scale) AS __history_scaled FROM scaled
            ), priced AS MATERIALIZED (
              SELECT decimal128.*,round((CASE
                WHEN abs(__history_scaled-trunc(__history_scaled))=0.5 AND mod(abs(trunc(__history_scaled)),2)=0
                  THEN trunc(__history_scaled) ELSE round(__history_scaled) END)::numeric(1000,200)
                    /power(10::numeric,__history_scale),__history_scale) AS __history_price
              FROM decimal128
            )
            """;
    private record Prepared(String cte,MapSqlParameterSource parameters,Map<String,String> filters,
            com.uten.imp.common.util.SqlColumnSearch.Criteria searches) {}
    private record Facets(Map<String,List<FacetBucket>> buckets,Map<String,Long> nulls,Map<String,Long> totals,Map<String,Boolean> more) {}

    public TablePage table(TableQuery request) {
        Prepared p=prepare(request);int size=size(request.size(),50,100),page=page(request.page());
        String sort=request.sort()==null||request.sort().isBlank()?"businessDate":request.sort();column(sort);
        boolean ascending=request.sort()!=null&&!request.sort().isBlank()&&Boolean.TRUE.equals(request.ascending());
        String filter=filters(p,null);
        long total=count(p.cte()+" SELECT count(*) FROM priced WHERE "+filter,p.parameters());
        int pages=pages(total,size);page=Math.min(page,Math.max(1,pages));
        p.parameters().addValue("limit",size).addValue("offset",(long)(page-1)*size);
        List<Observation> observations=db.queryForList(p.cte()+" SELECT * FROM priced WHERE "+filter+" ORDER BY "+column(sort)
                +(ascending?" ASC":" DESC")+" NULLS LAST,business_date DESC,history_version_id DESC,source_item_id DESC,source_type DESC LIMIT :limit OFFSET :offset",p.parameters())
                .stream().map(row->{var raw=new LinkedHashMap<>(row);raw.keySet().removeIf(k->k.startsWith("__history_"));return sources.observation(raw);}).toList();
        Facets facets=allFacets(p);
        return new TablePage(observations,page,size,total,pages,facets.buckets(),facets.nulls(),
                facets.totals(),facets.more(),INITIAL_FACET_SIZE,OffsetDateTime.now());
    }
    public FacetPage facets(FacetQuery request) {
        if(request==null)throw GoodsPriceAnalysisService.invalid("请选择历史筛选字段");
        column(request.column());String search=request.search()==null?null:request.search().strip();
        if(search!=null&&search.length()>256)throw GoodsPriceAnalysisService.invalid("筛选搜索文字过长");
        return facet(prepare(request.table()),request.column(),search,page(request.page()),size(request.size(),100,200));
    }
    /** Ten facets scan one materialized price projection, never ten copies of the source/evidence graph. */
    private Facets allFacets(Prepared p) {
        List<String> branches=new ArrayList<>();
        for(String key:COLUMNS.keySet())branches.add("SELECT '"+key+"'::text field,"+value(key)+" value,count(*) bucket_count FROM priced WHERE "+filters(p,key)+" GROUP BY "+column(key));
        String sql=p.cte()+", grouped_facets AS ("+String.join(" UNION ALL ",branches)+")"
                +", ranked_facets AS (SELECT *,row_number() OVER(PARTITION BY field ORDER BY "
                +"CASE WHEN field IN ('unitPrice','quantity','amount') THEN value::numeric END ASC NULLS LAST,value ASC NULLS LAST) position,"
                +"count(*) FILTER(WHERE value IS NOT NULL) OVER(PARTITION BY field) total,"
                +"COALESCE(sum(bucket_count) FILTER(WHERE value IS NULL) OVER(PARTITION BY field),0) null_count FROM grouped_facets)"
                +" SELECT field,value,bucket_count,total,null_count FROM ranked_facets WHERE position<=:initialFacetLimit OR value IS NULL ORDER BY field,position";
        p.parameters().addValue("initialFacetLimit",INITIAL_FACET_SIZE);
        var buckets=new LinkedHashMap<String,List<FacetBucket>>();var nulls=new LinkedHashMap<String,Long>();
        var totals=new LinkedHashMap<String,Long>();var more=new LinkedHashMap<String,Boolean>();
        COLUMNS.keySet().forEach(key->{buckets.put(key,new ArrayList<>());nulls.put(key,0L);totals.put(key,0L);more.put(key,false);});
        for(var row:db.queryForList(sql,p.parameters())){
            String key=row.get("field").toString();long total=((Number)row.get("total")).longValue();
            nulls.put(key,((Number)row.get("null_count")).longValue());totals.put(key,total);more.put(key,total>INITIAL_FACET_SIZE);
            if(row.get("value")!=null){String value=row.get("value").toString();buckets.get(key).add(new FacetBucket(value,((Number)row.get("bucket_count")).longValue(),label(key,value)));}
        }
        buckets.replaceAll((key,value)->List.copyOf(value));
        return new Facets(Collections.unmodifiableMap(buckets),Collections.unmodifiableMap(nulls),Collections.unmodifiableMap(totals),Collections.unmodifiableMap(more));
    }
    private FacetPage facet(Prepared p,String key,String search,int requestedPage,int size) {
        String expression=column(key),filter=filters(p,key),value=value(key);
        var parameters=new MapSqlParameterSource(p.parameters().getValues());
        String searchClause="";
        if(search!=null&&!search.isEmpty()){
            String label="lifecycle".equals(key)?lifecycleLabelSql("value"):"value";
            searchClause=" AND (position(lower(:facetSearch) IN lower(value))>0 OR position(lower(:facetSearch) IN lower("+label+"))>0)";
            parameters.addValue("facetSearch",search);
        }
        parameters.addValue("facetLimit",size).addValue("facetRequestedPage",requestedPage);
        String sql=p.cte()+", buckets AS MATERIALIZED (SELECT "+expression+" ordering,"+value+" value,count(*) bucket_count FROM priced WHERE "+filter+" GROUP BY "+expression+")"
                +", matching AS MATERIALIZED (SELECT * FROM buckets WHERE value IS NOT NULL"+searchClause+")"
                +", totals AS (SELECT (SELECT count(*) FROM matching) total,COALESCE((SELECT sum(bucket_count) FROM buckets WHERE value IS NULL),0) null_count)"
                +", selected AS (SELECT * FROM matching ORDER BY ordering ASC LIMIT :facetLimit OFFSET (SELECT (least(:facetRequestedPage,greatest(1,(total+:facetLimit-1)/:facetLimit))-1)*:facetLimit FROM totals))"
                +" SELECT selected.value,selected.bucket_count,totals.total,totals.null_count FROM totals LEFT JOIN selected ON true ORDER BY selected.ordering ASC";
        var rows=db.queryForList(sql,parameters);var counts=rows.getFirst();
        long total=((Number)counts.get("total")).longValue(),nullCount=((Number)counts.get("null_count")).longValue();
        int totalPages=pages(total,size),page=Math.min(requestedPage,Math.max(1,totalPages));
        var buckets=rows.stream().filter(r->r.get("value")!=null).map(r->new FacetBucket(r.get("value").toString(),((Number)r.get("bucket_count")).longValue(),label(key,r.get("value").toString()))).toList();
        return new FacetPage(key,buckets,page,size,total,totalPages,nullCount,page<totalPages,OffsetDateTime.now());
    }
    private Prepared prepare(TableQuery request) {
        if(request==null||request.context()==null||request.context().goodsId()==null)throw GoodsPriceAnalysisService.invalid("请选择历史货品");
        Query q=request.context();access.requireHistory(q.kind());references.requireVisibleGoods(q.goodsId());
        LocalDate to=request.to()==null?BusinessTime.today():request.to();
        if(to.isAfter(BusinessTime.today())||request.from()!=null&&request.from().isAfter(to))throw GoodsPriceAnalysisService.invalid("历史日期范围无效");
        var p=new MapSqlParameterSource().addValue("kind",q.kind().name()).addValue("goods",q.goodsId()).addValue("to",to)
                .addValue("procurementFilter","{\"items\":[{\"goodsId\":\""+q.goodsId()+"\"}]}")
                .addValue("quoteFilter","{\"lines\":[{\"goodsId\":\""+q.goodsId()+"\"}]}");
        String where="kind=:kind AND goods_id=:goods AND business_date<=:to "
                +sources.historyVisibility(q.kind(),access.sourceScope(q.kind()),access.has("sales_quote_finance:view"),access.available(q.kind()),p)
                +" AND (history_kind<>'PROCUREMENT_CASE' OR snapshot_filter @> CAST(:procurementFilter AS jsonb))"
                +" AND (history_kind<>'QUOTE_CONFIRMATION' OR snapshot_filter @> CAST(:quoteFilter AS jsonb))";
        if(request.from()!=null){where+=" AND business_date>=:from";p.addValue("from",request.from());}
        if(q.supplierId()!=null){where+=" AND supplier_id=:supplier";p.addValue("supplier",q.supplierId());}
        if(q.clientId()!=null){where+=" AND client_id=:client";p.addValue("client",q.clientId());}
        if(q.colorId()!=null){where+=" AND color_id=:color";p.addValue("color",q.colorId());}
        if(q.unitId()!=null){where+=" AND unit_id=:unit";p.addValue("unit",q.unitId());}
        if(q.currencyId()!=null){where+=" AND currency_id=:currency";p.addValue("currency",q.currencyId());}
        if(q.taxRate()!=null){where+=" AND tax_rate=:tax";p.addValue("tax",GoodsPriceAnalysisService.decimal(q.taxRate(),"税率",false));}
        if(q.unitRate()!=null){where+=" AND unit_rate=:rate";p.addValue("rate",GoodsPriceAnalysisService.decimal(q.unitRate(),"换算率",true));}
        Map<String,String> supplied=request.filters()==null?Map.of():request.filters();
        if(supplied.size()>2*COLUMNS.size())throw GoodsPriceAnalysisService.invalid("历史筛选字段过多");
        Map<String,String> filters=new LinkedHashMap<>(),searches=new LinkedHashMap<>();
        supplied.forEach((key,text)->{if(key!=null&&key.startsWith("search."))searches.put(key.substring(7),text);else filters.put(key,text);});
        for(var entry:filters.entrySet()){
            column(entry.getKey());String text=entry.getValue();
            if(text==null||text.isEmpty())continue;
            if(text.length()>512)throw GoodsPriceAnalysisService.invalid("历史筛选值过长");
            if("__null__".equals(text))continue;
            if(NUMERIC.contains(entry.getKey()))numeric(text);
            if(entry.getKey().equals("businessDate"))date(text);
            if(entry.getKey().equals("lifecycle")&&!LIFECYCLES.contains(text))throw GoodsPriceAnalysisService.invalid("历史状态筛选无效");
        }
        var headerFields=new LinkedHashMap<String,com.uten.imp.common.util.SqlColumnSearch.Field>();
        for(var entry:COLUMNS.entrySet()){
            if(entry.getKey().equals("lifecycle"))continue; // finite lifecycle values retain their exact source contract
            headerFields.put(entry.getKey(),NUMERIC.contains(entry.getKey())?com.uten.imp.common.util.SqlColumnSearch.Field.decimal(entry.getValue())
                    :entry.getKey().equals("businessDate")?com.uten.imp.common.util.SqlColumnSearch.Field.calendarDate(entry.getValue())
                    :com.uten.imp.common.util.SqlColumnSearch.Field.text(entry.getValue()));
        }
        var headers=com.uten.imp.common.util.SqlColumnSearch.criteria(searches,headerFields,"price_history_header_");
        headers.parameters().forEach(p::addValue);
        return new Prepared("WITH authorized AS MATERIALIZED (SELECT * FROM v_goods_price_history WHERE "+where+")\n"+PRICED_CTE,p,filters,headers);
    }
    private static String filters(Prepared p,String excluded) {
        StringBuilder sql=new StringBuilder("("+p.searches().predicate()+")");
        int index=0;
        for(var column:COLUMNS.entrySet()){
            String key=column.getKey(),text=p.filters().get(key),parameter="filter_"+index++;
            if(key.equals(excluded)||text==null||text.isEmpty())continue;
            String expression=column.getValue();
            if(text.equals("__null__")){sql.append(" AND ").append(expression).append(" IS NULL");continue;}
            Object value=NUMERIC.contains(key)?numeric(text):key.equals("businessDate")?date(text):text;
            p.parameters().addValue(parameter,value);sql.append(" AND ").append(expression).append("=:").append(parameter);
        }
        return sql.toString();
    }
    private static String column(String key){String value=COLUMNS.get(key);if(value==null)throw GoodsPriceAnalysisService.invalid("不支持的历史筛选或排序字段");return value;}
    private static String value(String key){String c=column(key);return NUMERIC.contains(key)?"trim_scale("+c+")::text":c+"::text";}
    private static BigDecimal numeric(String value){try{BigDecimal n=new BigDecimal(value);if(n.precision()>100||Math.abs(n.scale())>300)throw new NumberFormatException();return n;}catch(NumberFormatException invalid){throw GoodsPriceAnalysisService.invalid("历史数字筛选值无效");}}
    private static LocalDate date(String value){try{return LocalDate.parse(value);}catch(java.time.DateTimeException invalid){throw GoodsPriceAnalysisService.invalid("历史日期筛选无效");}}
    private long count(String sql,MapSqlParameterSource p){Long result=db.queryForObject(sql,p,Long.class);return result==null?0:result;}
    private static int size(Integer value,int fallback,int maximum){int size=value==null?fallback:value;if(size<1||size>maximum)throw GoodsPriceAnalysisService.invalid("每页数量超出有效范围");return size;}
    private static int page(Integer value){int page=value==null?1:value;if(page<1||page>1000000)throw GoodsPriceAnalysisService.invalid("历史页码超出有效范围");return page;}
    private static int pages(long total,int size){return (int)Math.min(Integer.MAX_VALUE,(total+size-1)/size);}
    private static String label(String key,String value){return key.equals("lifecycle")?LIFECYCLE_LABELS.getOrDefault(value,value):value;}
    private static String lifecycleLabelSql(String value){
        return "CASE "+value+LIFECYCLE_LABELS.entrySet().stream().map(entry->" WHEN '"+entry.getKey()+"' THEN '"+entry.getValue()+"'")
                .collect(java.util.stream.Collectors.joining())+" ELSE "+value+" END";
    }
}
