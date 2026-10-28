package com.uten.imp.features.org.employee;

import com.uten.imp.common.util.ColumnKeywordSearch;
import com.uten.imp.common.util.SqlColumnSearch;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/** Shared employee header contract; each owning relation supplies its trusted SQL and eligibility. */
public record EmployeeHeaderQuery(Map<String,String> searches, String accountStatus,
        String employmentStatus, String sort, boolean descending, Columns columns) {
    public record Columns(Map<String,String> textFields, String accountStatus, String employmentStatus,
            String identity, Set<String> eligibleStatuses) {
        public Columns { textFields=Map.copyOf(textFields);eligibleStatuses=Set.copyOf(eligibleStatuses); }
    }
    public static EmployeeHeaderQuery read(Map<String,String> parameters, Columns columns) {
        Map<String,String> request=parameters==null?Map.of():parameters;
        var values=new LinkedHashMap<String,String>();
        request.forEach((key,value)->{if(key.startsWith("search."))values.put(key.substring(7),value);});
        var searches=ColumnKeywordSearch.validate(values,columns.textFields().keySet());
        String account=choice(request.get("accountStatus"),Set.of("notProvisioned","active","locked","disabled"));
        String employment=choice(request.get("employmentStatus"),columns.eligibleStatuses());
        String sort=blank(request.get("sort"));String direction=request.getOrDefault("order","asc");
        if(sort!=null&&(!columns.textFields().containsKey(sort)||!Set.of("asc","desc").contains(direction.toLowerCase(java.util.Locale.ROOT))))
            throw invalid("人员排序字段或方向无效");
        return new EmployeeHeaderQuery(Map.copyOf(searches),account,employment,sort,"desc".equalsIgnoreCase(direction),columns);
    }
    public boolean active() { return !searches.isEmpty()||accountStatus!=null||employmentStatus!=null||sort!=null; }
    public void append(StringBuilder filter,List<Object> parameters) {
        var fields=new LinkedHashMap<String,SqlColumnSearch.Field>();
        columns.textFields().forEach((key,expression)->fields.put(key,SqlColumnSearch.Field.text(expression)));
        var criteria=SqlColumnSearch.criteria(searches,fields);
        var source=new org.springframework.jdbc.core.namedparam.MapSqlParameterSource(criteria.parameters());
        var parsed=org.springframework.jdbc.core.namedparam.NamedParameterUtils.parseSqlStatement(criteria.predicate());
        filter.append(" AND (").append(org.springframework.jdbc.core.namedparam.NamedParameterUtils.substituteNamedParameters(parsed,source)).append(")\n");
        parameters.addAll(java.util.Arrays.asList(org.springframework.jdbc.core.namedparam.NamedParameterUtils.buildValueArray(parsed,source,null)));
        if(accountStatus!=null) { filter.append(" AND ").append(columns.accountStatus()).append("=?\n");parameters.add(accountStatus); }
        if(employmentStatus!=null) { filter.append(" AND ").append(columns.employmentStatus()).append("=?\n");parameters.add(employmentStatus); }
    }
    public String ordering() { return sort==null?null:columns.textFields().get(sort)+(descending?" DESC":" ASC")+" NULLS LAST,"+columns.identity(); }
    private static String choice(String raw,Set<String> allowed) {
        String value=blank(raw);if(value!=null&&!allowed.contains(value))throw invalid("人员状态筛选无效");return value;
    }
    private static String blank(String value) { return value==null||value.isBlank()?null:value.strip(); }
    private static ApiException invalid(String text) { return new ApiException(ErrorCode.VALIDATION_FAILED,text); }
}
