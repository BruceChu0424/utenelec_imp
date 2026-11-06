package com.uten.imp.common.web;

import jakarta.persistence.Query;
import jakarta.persistence.EntityManager;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 原生 SQL facets 桶（2026-09-25 单号列统一）：把原生两列查询行 (单号, COUNT(*))
 * 映射成前端表头筛选拿的 {@code [{value, count, label}]}（label=value）。
 *
 * <p>与 {@link TableFacets} 配对：TableFacets 走 JPA {@code Specification} 分组计数，
 * 本工具面向 {@code em.createNativeQuery(...)} 的两列投影——各原生 SQL 服务
 * （列表 / 计数 / facets 同一过滤基座）共用的行映射，口径与 TableFacets 一致：
 * value 为 null 归空串，count 归 long；桶顺序即 SQL 的 ORDER BY。
 */
public final class NativeFacets {

    private NativeFacets() {}

    /** Keep the original named SQL: Hibernate's query string may already be positional. */
    public static Query query(EntityManager em,String field,String sql){return NativeFacetCandidates.query(em,field,sql);}

    public static Query queryLabeled(EntityManager em,String field,String sql) {return NativeFacetCandidates.query(em,field,sql,true);}
    public static boolean wants(String field) {return !NativeFacetCandidates.active()||NativeFacetCandidates.current().wants(field);}
    public static List<Map<String,Object>> jdbcRows(org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate jdbc,
            String field,String sql,org.springframework.jdbc.core.namedparam.SqlParameterSource parameters,boolean labeled) {
        if(NativeFacetCandidates.active())return NativeFacetCandidates.current().jdbcRows(jdbc,field,sql,parameters,labeled);
        return jdbc.query(sql,parameters,(result,index)->labeled
                ?bucket(result.getString(1),result.getString(2),result.getLong(3))
                :bucket(result.getString(1),result.getLong(2)));
    }

    public static List<Map<String,Object>> jdbcRows(org.springframework.jdbc.core.JdbcTemplate jdbc,
            String field,String sql,Object[] parameters,boolean labeled) {
        if(NativeFacetCandidates.active())return NativeFacetCandidates.current().jdbcRows(jdbc,field,sql,parameters,labeled);
        return jdbc.query(sql,new org.springframework.jdbc.core.ArgumentPreparedStatementSetter(parameters),(result,index)->labeled
                ?bucket(result.getString(1),result.getString(2),result.getLong(3))
                :bucket(result.getString(1),result.getLong(2)));
    }

    /** 单桶：{value, count, label=value}。 */
    public static Map<String, Object> bucket(String value, long count) {
        return bucket(value,value,count);
    }
    public static Map<String,Object> bucket(String value,String label,long count) {
        Map<String, Object> bucket = new LinkedHashMap<>();
        bucket.put("value", value);
        bucket.put("count", count);
        bucket.put("label", label);
        return bucket;
    }

    /** 原生查询行(value, count) → 桶列表；value null 归空串。 */
    private static List<Map<String, Object>> rows(List<Object[]> rows) {
        List<Map<String, Object>> buckets = new ArrayList<>(rows.size());
        for (Object[] row : rows) {
            String value = row[0] == null ? "" : row[0].toString();
            if(row.length==2)buckets.add(bucket(value, ((Number) row[1]).longValue()));
            else if(row.length==3)buckets.add(bucket(value,row[1]==null?"":row[1].toString(),((Number)row[2]).longValue()));
            else throw new IllegalStateException("Native facet queries require explicit two or three column projections");
        }
        return buckets;
    }

    /** Execute only bounded buckets, preserving a caller's stricter limit (including zero). */
    @SuppressWarnings("unchecked")
    public static List<Map<String, Object>> rowsOf(Query query) {
        if(NativeFacetCandidates.active())return NativeFacetCandidates.rows(query);
        query.setMaxResults(Math.min(query.getMaxResults(), TableFacets.DEFAULT_LIMIT));
        return rows((List<Object[]>) query.getResultList());
    }
}
