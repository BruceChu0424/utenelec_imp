package com.uten.imp.features.production.dailyreport;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ReportablePlanLineQuerySecurityContractTest {

    @Test
    void pickerExposesOnlyAssignedAndMaterialReadySegmentsInsideObjectScope()
            throws Exception {
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/production/dailyreport/"
                        + "ReportablePlanLineQueryService.java"));

        assertThat(source)
                .contains("segment.status = 'IN_PROGRESS'")
                .contains("segment.workshop_department_id IS NOT NULL")
                .contains("segment.responsible_employee_id IS NOT NULL")
                .contains("demand.status NOT IN (")
                .contains("'FULFILLED', 'RELEASED', 'REVERSED'")
                .contains("execution_segment_id IN (")
                .contains("var readScope = access.scope()")
                .contains("p.maker_id IS NULL")
                .contains("p.maker_id IN (")
                .contains("workshopAssignmentPredicate()")
                .contains("production_execution:view")
                .contains("employee_secondary_departments")
                .contains("managed.manager_id");
    }
}
