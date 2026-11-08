package com.uten.imp.common.history;

import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;

import java.util.List;
import java.util.Map;
import java.util.regex.Pattern;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * W7 P1.6 读视图合同(2026-11-08)：完整迁移链之后，任何业务读视图都不得再调用导入单据的
 * 权威遍历入口(fn_imported_business_document / _row / _row_internal)。
 *
 * <p>W1(V1120)把读侧来源判定换成登记表谓词，权威遍历只留给写路径守卫。只要有一条读视图
 * 重新内联遍历，每次列表/徽章读取就会按行递归追溯来源(2026-11-07 调研的 190 万行反连接
 * 形态)。这里直接核对迁移后的视图定义——比单条 EXPLAIN 更严：覆盖全部视图且不受计划器
 * 选择影响；履约任务中心视图另做一次 VERBOSE 计划核对(plpgsql 函数不会被内联，出现即按名
 * 可见)。允许的只有不遍历的成员/根列表/登记表谓词函数。</p>
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ImportedDocumentReadViewContractPostgresTest {
    private static final Pattern WALK = Pattern.compile(
            "fn_imported_business_document(?:_row|_row_internal)?\\s*\\(");

    @Test
    void noMigratedReadViewWalksTheAuthoritativeProvenanceGraph() throws Exception {
        try (var lease = MigratedSchemaBaseline.openDatabase("read_view_contract");
             var connection = lease.openConnection()) {
            var db = new JdbcTemplate(new SingleConnectionDataSource(connection, true));
            List<Map<String, Object>> views = db.queryForList("""
                    SELECT c.relname AS name, pg_get_viewdef(c.oid, true) AS definition
                    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
                    WHERE c.relkind IN ('v','m') ORDER BY c.relname
                    """);
            assertThat(views).as("迁移后的公共视图").isNotEmpty();
            List<String> walking = views.stream()
                    .filter(view -> WALK.matcher(String.valueOf(view.get("definition"))).find())
                    .map(view -> String.valueOf(view.get("name"))).toList();
            assertThat(walking).as("读视图不得内联导入单据的权威遍历").isEmpty();

            String plan = String.join("\n", db.queryForList(
                    "EXPLAIN (VERBOSE, COSTS OFF) SELECT * FROM v_procurement_decomposition_tasks", String.class));
            assertThat(plan).as("履约任务中心视图").contains("Output:");
            assertThat(WALK.matcher(plan).find()).as("履约任务中心视图的计划不得出现权威遍历: " + plan).isFalse();
        }
    }
}
