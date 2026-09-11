package com.uten.imp.common.report;

import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.function.Consumer;
import java.util.regex.Pattern;

/**
 * 报表「表格下方合计」的服务端聚合（全 *ReportService 共用）。
 *
 * <p><b>口径</b>：把列表查询原样包成派生表再聚合——
 * {@code SELECT SUM(t."qty") FROM ( <dataSelect> <fromJoin> <where> ) t}。
 * 因为用的是同一段 {@code fromJoin} 与同一份 {@code where}（含日期/facet/关键字
 * <b>以及对象级授权谓词</b>），合计与列表的口径天然一致；派生表里不带
 * ORDER BY/LIMIT/OFFSET，所以聚合覆盖<b>整个结果集</b>而不是当前这一页。
 *
 * <p><b>绝不跨单位/跨币种相加</b>：{@link Spec#groupKey()} 指向行里的单位名或币种名列，
 * 聚合时 {@code GROUP BY} 该列，前端只把各组拼成「12 个 · 3 箱」。没有分组列的报表
 * 只有一组（{@code unit == null}）。
 *
 * <p><b>查询数量</b>：按 groupKey 归并后每个分组维度<b>一条</b>聚合查询（通常 1~2 条），
 * 与列数无关，不存在 N+1。
 *
 * <p><b>防 SQL 注入</b>：列 key 全部来自服务端 {@code ReportColumn} 常量定义（非用户输入），
 * 仍按 {@link #SAFE_IDENT} 白名单二次校验，不合规的列直接丢弃，绝不拼进 SQL
 * （与 {@link ReportSort} 同一防线）。
 */
public final class ReportTotalsCalculator {

    /**
     * 列 key 合法字符白名单：字母或下划线开头 + 字母/数字/下划线。
     * 允许下划线开头是为了让分组列可以用隐藏列（{@code __currencyCode} 这类以 "__" 开头、
     * 只进派生表不进前端 columns 的列）——报表原本不展示币种/单位时，靠隐藏列也能正确分组。
     */
    private static final Pattern SAFE_IDENT = Pattern.compile("[A-Za-z_][A-Za-z0-9_]*");

    private ReportTotalsCalculator() {}

    /**
     * 一个合计项的声明。
     *
     * @param key      要聚合的列 key（= dataSelect 里的双引号别名）
     * @param label    合计项标题（如「合计数量」）
     * @param type     number / money
     * @param groupKey 分组列 key（单位名/币种名）；null = 不分组
     */
    public record Spec(String key, String label, String type, String groupKey) {}

    /**
     * 跑合计。任一环节不满足（无 spec / 列名不合法 / 结果全为 NULL）都返回空，
     * 前端据此整项隐藏——<b>宁可不显示，也不显示一个 0 或一个只覆盖当前页的数</b>。
     */
    public static List<ReportTotal> compute(EntityManager em, String dataSelect, String fromJoin,
                                            String whereSql, Map<String, Object> params, List<Spec> specs) {
        return compute(em, dataSelect, fromJoin, whereSql,
                q -> { if (params != null) params.forEach(q::setParameter); }, specs);
    }

    /**
     * 同上，但参数绑定交给调用方（{@code binder}）。
     *
     * <p>给那些不把参数收在一个 Map 里的执行器用（如钱流的 CTE 报表：{@code :from/:to/:kw}
     * 由专用 bind 方法绑定、对象级授权谓词由 {@code NativeReadScope.bind} 绑定）。
     * <b>必须把列表查询用的同一套绑定原样传进来</b>——合计与列表口径一致的前提就是同一份
     * where + 同一份参数。
     */
    public static List<ReportTotal> compute(EntityManager em, String dataSelect, String fromJoin,
                                            String whereSql, Consumer<Query> binder, List<Spec> specs) {
        if (em == null || specs == null || specs.isEmpty()) return List.of();

        // 按分组维度归并：同一个 groupKey 的所有列合并进一条聚合查询。
        Map<String, List<Spec>> byGroup = new LinkedHashMap<>();
        for (Spec s : specs) {
            if (s == null || !safe(s.key())) continue;
            String g = safe(s.groupKey()) ? s.groupKey() : null;
            byGroup.computeIfAbsent(g == null ? "" : g, k -> new ArrayList<>()).add(s);
        }
        if (byGroup.isEmpty()) return List.of();

        String inner = dataSelect + " " + fromJoin + " " + (whereSql == null ? "" : whereSql);
        Map<String, ReportTotal> out = new LinkedHashMap<>();

        for (Map.Entry<String, List<Spec>> e : byGroup.entrySet()) {
            String groupKey = e.getKey().isEmpty() ? null : e.getKey();
            // 同一维度内列 key 去重，保持声明顺序。
            List<Spec> cols = dedupe(e.getValue());

            StringBuilder sql = new StringBuilder("SELECT ");
            if (groupKey != null) sql.append("t.\"").append(groupKey).append("\" AS __grp, ");
            for (int i = 0; i < cols.size(); i++) {
                if (i > 0) sql.append(", ");
                sql.append("SUM(t.\"").append(cols.get(i).key()).append("\")");
            }
            sql.append(" FROM (").append(inner).append(") t");
            if (groupKey != null) {
                sql.append(" GROUP BY t.\"").append(groupKey).append("\" ORDER BY 1 NULLS LAST");
            }

            Query q = em.createNativeQuery(sql.toString());
            if (binder != null) binder.accept(q);
            @SuppressWarnings("unchecked")
            List<Object> raw = q.getResultList();

            // 收集：列 key → 分组列表（丢掉 SUM 为 NULL 的组，即该组无数据）。
            Map<String, List<ReportTotalGroup>> groups = new LinkedHashMap<>();
            for (Object rowObj : raw) {
                Object[] row = (rowObj instanceof Object[] arr) ? arr : new Object[] {rowObj};
                int offset = groupKey == null ? 0 : 1;
                String unit = groupKey == null ? null : Objects.toString(row[0], null);
                for (int i = 0; i < cols.size(); i++) {
                    int idx = i + offset;
                    if (idx >= row.length) continue;
                    BigDecimal v = toDecimal(row[idx]);
                    if (v == null) continue;
                    groups.computeIfAbsent(cols.get(i).key(), k -> new ArrayList<>())
                            .add(new ReportTotalGroup(unit, v));
                }
            }

            for (Spec s : cols) {
                List<ReportTotalGroup> g = groups.get(s.key());
                if (g == null || g.isEmpty()) continue;
                out.put(s.key(), new ReportTotal(s.key(), s.label(), s.type(), groupKey, List.copyOf(g)));
            }
        }

        // 按声明顺序输出（LinkedHashMap 已按分组维度分批，这里重排回 specs 的顺序）。
        List<ReportTotal> ordered = new ArrayList<>(out.size());
        for (Spec s : specs) {
            ReportTotal t = out.remove(s.key());
            if (t != null) ordered.add(t);
        }
        ordered.addAll(out.values());
        return List.copyOf(ordered);
    }

    /**
     * 在<b>已全量取回内存</b>的行上算同一套合计（给 Java 端分页的执行器用）。
     *
     * <p>有些报表（往来对帐单的滚动余额、客户预收台账）必须先把整段结果取回内存才能算出
     * 滚动余额/事件序，随后在内存里切页。对这类报表再去数据库跑一次聚合既多一次查询、
     * 又可能与内存里的口径漂移——所以直接对<b>同一份全量行</b>求和：覆盖整个结果集，
     * 与翻到第几页无关，语义与 {@link #compute} 完全一致。
     *
     * <p>分组、丢弃空组、"全为空则整项不出"的规则与 SQL 版一字不差。
     *
     * @param rows  整个结果集的行（不是当前页！），key = 列 key
     * @param specs 合计声明
     */
    public static List<ReportTotal> computeFromRows(List<Map<String, Object>> rows, List<Spec> specs) {
        if (rows == null || specs == null || specs.isEmpty()) return List.of();
        List<ReportTotal> out = new ArrayList<>();
        for (Spec s : dedupe(specs)) {
            if (!safe(s.key())) continue;
            String groupKey = safe(s.groupKey()) ? s.groupKey() : null;
            // null 分组值排在最后，与 SQL 版的 ORDER BY 1 NULLS LAST 一致。
            Map<String, BigDecimal> sums = new java.util.TreeMap<>(
                    java.util.Comparator.nullsLast(java.util.Comparator.<String>naturalOrder()));
            boolean any = false;
            for (Map<String, Object> row : rows) {
                if (row == null) continue;
                BigDecimal v = toDecimal(row.get(s.key()));
                if (v == null) continue;
                String g = groupKey == null ? null : Objects.toString(row.get(groupKey), null);
                sums.merge(g, v, BigDecimal::add);
                any = true;
            }
            if (!any) continue;
            List<ReportTotalGroup> groups = new ArrayList<>(sums.size());
            sums.forEach((g, v) -> groups.add(new ReportTotalGroup(groupKey == null ? null : g, v)));
            out.add(new ReportTotal(s.key(), s.label(), s.type(), groupKey, List.copyOf(groups)));
        }
        return List.copyOf(out);
    }

    private static List<Spec> dedupe(List<Spec> specs) {
        Map<String, Spec> seen = new LinkedHashMap<>();
        for (Spec s : specs) seen.putIfAbsent(s.key(), s);
        return new ArrayList<>(seen.values());
    }

    private static boolean safe(String ident) {
        return ident != null && !ident.isBlank() && SAFE_IDENT.matcher(ident).matches();
    }

    private static BigDecimal toDecimal(Object v) {
        if (v == null) return null;
        if (v instanceof BigDecimal d) return d;
        if (v instanceof Number n) return new BigDecimal(n.toString());
        String s = v.toString().trim();
        if (s.isEmpty()) return null;
        try {
            return new BigDecimal(s);
        } catch (NumberFormatException ex) {
            return null;
        }
    }
}
