package com.uten.imp.common.report;

import com.uten.imp.common.web.NativeFacets;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import java.util.Map;
import java.util.List;
import java.util.LinkedHashMap;
import java.util.function.Consumer;

/** Producer-declared value/label normalization; no request key becomes SQL. */
public final class NativeReportFacetProducer {
    private NativeReportFacetProducer() { }
    public static Map<String,String> selectedScope(Map<String,String> filters,List<String> declaredFields) {
        if(!com.uten.imp.common.web.NativeFacetCandidates.active())return filters;
        var selected=new LinkedHashMap<String,String>();if(filters!=null)selected.putAll(filters);
        for(String field:declaredFields)if(NativeFacets.wants(field)) {
            selected.remove(field);selected.remove("search."+field);
        }
        return selected;
    }
    public static String completeApprovalStates(String groupedSql) {
        return "WITH native_states(value,label,bucket_count) AS ("+groupedSql+") "
                +"SELECT value,label,bucket_count FROM native_states UNION ALL "
                +"SELECT state,state,0::bigint FROM (VALUES (true),(false)) fixed_states(state) "
                +"WHERE NOT EXISTS(SELECT 1 FROM native_states original WHERE original.value=fixed_states.state)";
    }
    public static String originalLabel() { return "CAST(native_value.label AS text)"; }
    public static String booleanApprovalLabel() {
        return "CASE WHEN CAST(native_value.value AS text)='true' THEN '已审' ELSE '未审（含已撤回）' END";
    }
    public static String styleLabel(Map<Integer,String> labels) {
        var expression=new StringBuilder("CASE CAST(native_value.value AS text)");
        labels.entrySet().stream().sorted(Map.Entry.comparingByKey()).forEach(entry->expression
                .append(" WHEN ").append(literal(entry.getKey().toString())).append(" THEN ").append(literal(entry.getValue())));
        return expression.append(" ELSE CAST(native_value.value AS text) END").toString();
    }
    public static void read(EntityManager em,String field,String groupedSql,Consumer<Query> bind,
                            String nullSentinel,String labelExpression) {
        if(!NativeFacets.wants(field))throw new IllegalArgumentException("Facet producer field mismatch");
        // Alias the producer's three declared projections. Never split a SELECT,
        // strip a LIMIT, or infer field/label SQL from a client expression.
        String value="CASE WHEN native_value.value IS NULL THEN "+literal(nullSentinel)
                +" ELSE CAST(native_value.value AS text) END";
        String label="CASE WHEN native_value.value IS NULL THEN '(空)' ELSE COALESCE("
                +labelExpression+",CAST(native_value.value AS text)) END";
        Query query=NativeFacets.queryLabeled(em,field,"SELECT "+value+","+label+",native_value.bucket_count FROM ("
                +groupedSql+") native_value(value,label,bucket_count)");
        bind.accept(query);NativeFacets.rowsOf(query);
    }
    private static String literal(String trusted) { return "'"+trusted.replace("'","''")+"'"; }
}
