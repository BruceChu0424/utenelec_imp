package com.uten.imp.common.report;

import java.util.Collection;

/**
 * 报表列排序白名单解析（全报表服务共用，避免每个 *ReportService 重复实现）。
 *
 * <p>各报表的 {@code execute()} 把前端 {@code sort}(列 key)/{@code order}(asc|desc) 透传到这里，
 * 由本工具安全映射成 ORDER BY 片段。
 *
 * <p><b>防 SQL 注入</b>：{@code sort} 必须命中 {@code allowedKeys}（服务端权威列 key 集合，非用户串），
 * 命中才按投影别名 {@code ORDER BY "<sort>"} 排序（PostgreSQL 支持按 SELECT 输出别名排序）；
 * {@code order} 只认 {@code asc}/{@code desc}（其余一律按升序）。命中失败/为空 → 回落默认排序。
 * 绝不把用户原始串拼进 SQL。
 */
public final class ReportSort {

    private ReportSort() {}

    public static String resolveOrderBy(String sort, String order, String defaultOrderBy,
                                        Collection<String> allowedKeys) {
        if (sort == null || sort.isBlank() || allowedKeys == null || !allowedKeys.contains(sort)) {
            return defaultOrderBy;
        }
        return "\"" + sort + "\"" + ("desc".equalsIgnoreCase(order) ? " DESC" : " ASC");
    }
}
