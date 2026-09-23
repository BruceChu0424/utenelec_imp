package com.uten.imp.features.production.dailyreport;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ReportablePlanLineQuerySecurityContractTest {

    @Test
    void pickerExposesOnlyAssignedStartedSegmentsWithNetCapacityInsideObjectScope()
            throws Exception {
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/production/dailyreport/"
                        + "ReportablePlanLineQueryService.java"));

        assertThat(source)
                .contains("segment.status = 'IN_PROGRESS'")
                .contains("segment.workshop_department_id IS NOT NULL")
                .contains("segment.responsible_employee_id IS NOT NULL")
                .contains("demand.status NOT IN (")
                .contains("'RELEASED', 'REVERSED'")
                .contains("fn_execution_material_output_capacity(segment.id, TRUE)")
                .contains("execution_segment_id IN (")
                .contains("var readScope = access.scope()")
                // ADR-109：没有负责人的计划只对全量范围可见，不再有「maker 为空即可见」分支。
                .doesNotContain("p.maker_id IS NULL")
                .contains("ownerPredicate = \"1=0\"")
                .contains("p.maker_id IN (")
                .contains("workshopAssignmentPredicate()")
                .contains("production_execution:view")
                .contains("employee_secondary_departments")
                .contains("managed.manager_id");
    }
}
