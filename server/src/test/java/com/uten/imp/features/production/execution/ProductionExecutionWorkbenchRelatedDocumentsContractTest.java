package com.uten.imp.features.production.execution;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 「进行中 → 关联单据」的生产计划分支契约：ANALYSIS 根除直接携带分析 id 的
 * 顶层计划外，必须沿 subplan_links 血缘下钻——EXECUTION_V1 自动生成的自制
 * 子计划不回填 material_analysis_id（该列语义=直接由本分析创建，1:1 锚点
 * 不动），但它们仍是本批次的子计划单，缺了用户就找不到全部子计划。
 */
class ProductionExecutionWorkbenchRelatedDocumentsContractTest {

    @Test
    void analysisRootPlansIncludeSubplanLineageDescendants() throws Exception {
        Path direct = Path.of(
                "src/main/java/com/uten/imp/features/production/execution/"
                        + "ProductionExecutionWorkbenchService.java");
        Path fallback = Path.of("server").resolve(direct);
        String source = Files.readString(
                Files.exists(direct) ? direct : fallback,
                StandardCharsets.UTF_8);
        String branch = slice(
                source,
                "String rootPredicate = \"ANALYSIS\".equals(rootType)",
                "bindings.add(new ScopeBinding(scope));");
        assertThat(branch)
                .contains("document.material_analysis_id = :rootId")
                .contains("WITH RECURSIVE analysis_root_plans(id) AS (")
                .contains("JOIN subplan_links link")
                .contains("ON link.plan_id = parent_plan.id")
                .contains("root.is_deleted = FALSE")
                .contains("child.is_deleted = FALSE");
        // PLAN 根走工单视图的既有口径不受影响。
        assertThat(branch)
                .contains("task.root_type = 'PLAN' AND task.root_id = :rootId");
    }

    private static String slice(
            String source, String startMarker, String endMarker) {
        int start = source.indexOf(startMarker);
        int end = source.indexOf(endMarker, start + startMarker.length());
        assertThat(start).isGreaterThanOrEqualTo(0);
        assertThat(end).isGreaterThan(start);
        return source.substring(start, end);
    }
}
