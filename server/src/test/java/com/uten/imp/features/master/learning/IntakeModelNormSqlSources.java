package com.uten.imp.features.master.learning;

import org.springframework.core.io.Resource;
import org.springframework.core.io.support.PathMatchingResourcePatternResolver;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;

/**
 * 从正式迁移目录里取出「客户型号规范化」的两处 SQL 表达式(按内容定位, 迁移号落地时重排也不受影响):
 * 历史客户型号播种里的 alias_norm 表达式, 与索引 idx_goods_model_norm 的表达式。
 */
final class IntakeModelNormSqlSources {

    private static final String INDEX_MARKER = "CREATE INDEX idx_goods_model_norm";

    private IntakeModelNormSqlSources() {
    }

    /** 含 idx_goods_model_norm 的那个迁移文件全文。 */
    static String migrationText() {
        try {
            Resource[] resources = new PathMatchingResourcePatternResolver()
                    .getResources("classpath*:db/migration/V*.sql");
            String found = null;
            for (Resource resource : resources) {
                String text = new String(resource.getContentAsByteArray(), StandardCharsets.UTF_8);
                if (text.contains(INDEX_MARKER)) {
                    if (found != null) throw new IllegalStateException("idx_goods_model_norm 出现在多个迁移里");
                    found = text;
                }
            }
            if (found == null) throw new IllegalStateException("找不到建 idx_goods_model_norm 的迁移");
            return found;
        } catch (IOException failure) {
            throw new UncheckedIOException(failure);
        }
    }

    /** 播种 alias_norm 的表达式, 参数位置用 {@code ?} 代替 {@code btrim(item.client_model)} 的输入列。 */
    static String seedExpression(String migration) {
        String start = "btrim(item.client_model) AS alias_text,";
        int from = migration.indexOf(start);
        int to = migration.indexOf("AS alias_norm", from);
        if (from < 0 || to < 0) throw new IllegalStateException("播种表达式定位失败");
        String expression = migration.substring(from + start.length(), to).strip();
        if (!expression.contains("item.client_model")) throw new IllegalStateException("播种表达式不含输入列");
        return expression.replace("item.client_model", "CAST(? AS text)");
    }

    /** 索引表达式原文(去掉外层括号前后的空白差异, 保留内部写法)。 */
    static String indexExpression(String migration) {
        int marker = migration.indexOf(INDEX_MARKER);
        int open = migration.indexOf("ON goods ((", marker);
        int close = migration.indexOf("))\n", open);
        int where = migration.indexOf("WHERE NOT is_deleted AND model IS NOT NULL", open);
        if (open < 0 || close < 0 || where < 0 || close > where) {
            throw new IllegalStateException("索引表达式定位失败");
        }
        return migration.substring(open + "ON goods ((".length(), close).strip();
    }

    /** 空白折叠后比较用。 */
    static String collapse(String sql) {
        return sql.replaceAll("\\s+", " ").replace("( ", "(").replace(" )", ")").strip();
    }
}
