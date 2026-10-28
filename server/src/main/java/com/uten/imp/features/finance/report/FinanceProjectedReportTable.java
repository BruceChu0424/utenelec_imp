package com.uten.imp.features.finance.report;

import com.uten.imp.common.report.*;
import com.uten.imp.common.util.JpaColumnSearch;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import java.util.*;
import java.util.function.Consumer;

/** Query the completed, authorised finance projection, preserving its aggregate/window grain. */
public final class FinanceProjectedReportTable {
    private FinanceProjectedReportTable() { }

    /** Only visible declared totals with their complete grouping evidence may be aggregated. */
    public static List<ReportTotalsCalculator.Spec> totalSpecs(List<ReportColumn> emitted,List<ReportColumn> projected) {
        Set<String> present=new HashSet<>();for(ReportColumn column:projected)present.add(column.key());
        List<ReportTotalsCalculator.Spec> specs=new ArrayList<>();
        for(ReportColumn column:emitted) {
            String label=column.totalLabel();if(label==null||label.isBlank())continue;
            String group=column.totalGroupKey();if(group!=null&&!present.contains(group))continue;
            String identity=column.totalGroupIdentityKey();if(identity!=null&&!present.contains(identity))continue;
            specs.add(new ReportTotalsCalculator.Spec(column.key(),label,column.type(),group,identity));
        }
        return specs;
    }

    /** The SQL and all column identifiers here are application-owned, never request expressions. */
    public static ReportTableResponse query(EntityManager em,List<ReportColumn> columns,String source,
            Consumer<Query> bindSource,String fallbackOrder,Map<String,String> filters,Set<String> facetKeys,
            int page,int size,String sort,String order,boolean chronological,
            List<ReportTotalsCalculator.Spec> totalSpecs) {
        return query(em,columns,source,bindSource,fallbackOrder,filters,facetKeys,page,size,sort,order,chronological,totalSpecs,Set.of());
    }

    public static ReportTableResponse query(EntityManager em,List<ReportColumn> columns,String source,
            Consumer<Query> bindSource,String fallbackOrder,Map<String,String> filters,Set<String> facetKeys,
            int page,int size,String sort,String order,boolean chronological,
            List<ReportTotalsCalculator.Spec> totalSpecs,Set<String> nonQueryableKeys) {
        Map<String,String> input=filters==null?Map.of():filters;
        if(sort!=null&&nonQueryableKeys.contains(sort)||nonQueryableKeys.stream().anyMatch(key->nonblank(input.get("search."+key))))
            throw invalid("此列尚无可检索或排序的已核实事实");
        var header=conditions(columns,input,facetKeys,sort,nonQueryableKeys);
        String filtered="SELECT report.* FROM ("+source+") report "+header.where().sql();
        int safePage=Math.max(1,page),safeSize=Math.min(500,Math.max(1,size));
        String ordering=fallbackOrder;
        Set<String> visible=new LinkedHashSet<>();for(var column:columns)if(!column.key().startsWith("__"))visible.add(column.key());
        if(sort!=null&&!sort.isBlank()&&visible.contains(sort)) {
            if(chronological)throw invalid("此报表按业务时间保留结余顺序");
            if(order!=null&&!Set.of("asc","desc").contains(order))throw invalid("排序方向无效");
            ordering=expression(sort)+("desc".equals(order)?" DESC":" ASC")+" NULLS LAST,"+fallbackOrder;
        }
        Consumer<Query> bind=query->{bindSource.accept(query);header.where().params().forEach(query::setParameter);};
        var data=ReportExportCursor.query(em,filtered+" ORDER BY "+ordering+" LIMIT :__limit OFFSET :__offset");
        bind.accept(data);data.setParameter("__limit",safeSize).setParameter("__offset",(long)(safePage-1)*safeSize);
        @SuppressWarnings("unchecked") List<Object[]> values=ReportExportCursor.rows(em,data);
        var rows=new ArrayList<Map<String,Object>>();
        for(Object[] value:values){var row=new LinkedHashMap<String,Object>();for(int i=0;i<columns.size();i++)row.put(columns.get(i).key(),normal(value[i]));ReportQueryKit.includeDecimalTexts(row);rows.add(row);}
        long total=ReportReadPlan.UNKNOWN_TOTAL;
        if(ReportReadPlan.current().includeCount()){var count=em.createNativeQuery("SELECT COUNT(*) FROM ("+filtered+") header_count");bind.accept(count);total=((Number)count.getSingleResult()).longValue();}
        var facets=new LinkedHashMap<String,List<ReportFacet>>();
        var candidates=new LinkedHashSet<>(facetKeys);
        if(hasCurrencyIdentity(columns))candidates.add("currencyCode");
        if(ReportReadPlan.current().includeFacets())for(String key:candidates){
            var remaining=new LinkedHashMap<>(input);remaining.remove(key);remaining.remove("search."+key);
            if(key.equals("currencyCode"))for(var column:columns)if(isOriginal(column))remaining.remove("search."+column.key());
            var facet=conditions(columns,remaining,facetKeys,null,nonQueryableKeys);
            String value=key.equals("currencyCode")&&hasCurrencyIdentity(columns)?expression("__currencyId"):expression(key);
            String label=key.equals("settled")?"CASE WHEN "+expression(key)+" THEN '已收/付' ELSE '未收/付' END":expression(key);
            var query=em.createNativeQuery("SELECT "+value+","+label+",COUNT(*) FROM ("+source+") report "+facet.where().sql()+" GROUP BY "+value+","+label+" ORDER BY COUNT(*) DESC,"+label+" LIMIT 1000");
            bindSource.accept(query);facet.where().params().forEach(query::setParameter);
            @SuppressWarnings("unchecked") List<Object[]> result=query.getResultList();var buckets=new ArrayList<ReportFacet>();
            for(Object[] row:result)buckets.add(new ReportFacet(row[0]==null?ReportTableResponse.NULL_FACET:row[0].toString(),row[1]==null?"(空)":row[1].toString(),((Number)row[2]).longValue()));
            facets.put(key,buckets);
        }
        List<ReportTotal> totals=ReportReadPlan.current().includeTotals()?ReportTotalsCalculator.compute(em,filtered,"","",bind,totalSpecs):List.of();
        return new ReportTableResponse(columns,rows,facets,safePage,safeSize,total,ReportReadPlan.totalPages(total,safeSize),ReportTotal.withColumnUnits(totals,columns)).withColumnSearchKeys(header.keys());
    }

    /** Positional aliases preserve each SQL owner's exact output, including internal identity columns. */
    public static String aliasProjection(String source,List<ReportColumn> columns,String alias,String... extraColumns) {
        var names=new ArrayList<String>();for(var column:columns)names.add(quoted(column.key()));for(String key:extraColumns)names.add(quoted(key));
        return "SELECT "+alias+".* FROM ("+source+") "+alias+"("+String.join(",",names)+")";
    }
    private record Header(ReportQueryKit.WhereBuilder.Built where,Set<String> keys) { }
    private static Header conditions(List<ReportColumn> columns,Map<String,String> filters,Set<String> facetKeys,String sort,Set<String> nonQueryableKeys){
        var types=new LinkedHashMap<String,String>();var expressions=new LinkedHashMap<String,String>();var dates=new LinkedHashMap<String,JpaColumnSearch.Kind>();
        for(var column:columns){if(nonQueryableKeys.contains(column.key()))continue;types.put(column.key(),column.type());
            String value=expression(column.key());
            // An existing NULL placeholder has PostgreSQL type text; metadata's
            // numeric contract must still compare unknown as NULL, never zero.
            expressions.put(column.key(),Set.of("money","number").contains(column.type())?"CAST("+value+" AS numeric)":value);
            if(column.type().equals("date"))dates.put(column.key(),JpaColumnSearch.Kind.DATE);}
        if(hasCurrencyIdentity(columns)){
            boolean monetary=columns.stream().anyMatch(column->isOriginal(column)&&(nonblank(filters.get("search."+column.key()))||column.key().equals(sort)));
            if(monetary&&(filters.get("currencyCode")==null||filters.get("currencyCode").equals(ReportTableResponse.NULL_FACET)))throw invalid("按原币金额检索或排序前，请先选择币别");
        }
        var where=new ReportQueryKit.WhereBuilder("WHERE TRUE");
        Set<String> keys=ReportColumnSearch.apply(where,filters,types,expressions,dates);
        for(var entry:filters.entrySet()){
            String key=entry.getKey(),value=entry.getValue();if(!nonblank(value))continue;
            if(key.startsWith("search.")){if(!keys.contains(key.substring(7)))throw invalid("此报表列不支持搜索："+key.substring(7));continue;}
            if(key.equals("currencyCode")&&hasCurrencyIdentity(columns)){
                if(value.equals(ReportTableResponse.NULL_FACET))where.add(expression("__currencyId")+" IS NULL",null,null);
                else {UUID id;try{id=UUID.fromString(value);}catch(IllegalArgumentException failure){throw invalid("币别条件无效");}where.add(expression("__currencyId")+"=:headerCurrency","headerCurrency",id);}
            }else if(facetKeys.contains(key)){
                if(value.equals(ReportTableResponse.NULL_FACET))where.add(expression(key)+" IS NULL",null,null);
                else where.add(expression(key)+"=:headerFacet_"+key,"headerFacet_"+key,key.equals("settled")?ReportQueryKit.parseRequiredBoolean(value):value);
            }else throw invalid("此报表列不支持候选筛选："+key);
        }
        return new Header(where.build(null),keys);
    }
    private static boolean hasCurrencyIdentity(List<ReportColumn> columns){return columns.stream().anyMatch(column->column.key().equals("__currencyId"))&&columns.stream().anyMatch(column->column.key().equals("currencyCode"));}
    private static boolean isOriginal(ReportColumn column){return "money".equals(column.type())&&"currencyCode".equals(column.unitKey());}
    private static boolean nonblank(String value){return value!=null&&!value.isBlank();}
    private static String quoted(String key){if(!key.matches("[A-Za-z_][A-Za-z_0-9]*"))throw new IllegalArgumentException("Trusted report key required");return "\""+key+"\"";}
    private static String expression(String key){return "report."+quoted(key);}
    private static Object normal(Object value){if(value instanceof UUID)return value.toString();if(value instanceof java.sql.Date date)return date.toLocalDate().toString();if(value instanceof java.time.LocalDate)return value.toString();return value;}
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
}
