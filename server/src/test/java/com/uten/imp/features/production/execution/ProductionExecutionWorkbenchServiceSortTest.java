package com.uten.imp.features.production.execution;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class ProductionExecutionWorkbenchServiceSortTest {

    @Test
    void rootSortUsesOnlyTheServerWhitelist() {
        assertThat(ProductionExecutionWorkbenchService.rootOrderBy(
                "latestEndDate", "desc"))
                .isEqualTo("root.latest_end_date DESC NULLS LAST");
        assertThat(ProductionExecutionWorkbenchService.rootOrderBy(
                "status", "asc"))
                .contains("CASE root.status")
                .contains("WHEN 'PARTIALLY_SCHEDULED' THEN 0")
                .contains("WHEN 'KIT_SHORT' THEN 1")
                .contains("WHEN 'IN_PROGRESS' THEN 5")
                .endsWith("END ASC NULLS LAST");
        assertThat(ProductionExecutionWorkbenchService.rootOrderBy(
                "rootLabel", "desc"))
                .isEqualTo("root.root_label DESC NULLS LAST");
        assertThat(ProductionExecutionWorkbenchService.rootOrderBy(
                "root.latest_end_date; DELETE", "desc"))
                .isEqualTo("root.latest_end_date DESC NULLS LAST");
    }

    @Test
    void segmentSelectIsPureColumnList() {
        // FROM 子句由 segmentPage 统一拼接；select 列清单顶层再带 FROM 会拼出
        // 双 FROM 语法错误（车间任务 500 事故），此处锁死。
        // 括号内的子查询 FROM（如 V491 显式开工 EXISTS）不拼外层，属合法。
        String select = ProductionExecutionWorkbenchService.segmentSelect();
        assertThat(select).startsWith("SELECT task.segment_id");
        int depth = 0;
        for (int i = 0; i < select.length(); i++) {
            char current = select.charAt(i);
            if (current == '(') {
                depth++;
            } else if (current == ')') {
                depth--;
            } else if (depth == 0 && select.startsWith(" FROM ", i)) {
                throw new AssertionError(
                        "select 列清单顶层出现 FROM（会拼出双 FROM）: " + select);
            }
        }
    }
}
