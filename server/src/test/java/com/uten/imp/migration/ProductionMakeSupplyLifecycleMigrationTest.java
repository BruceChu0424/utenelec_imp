package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ProductionMakeSupplyLifecycleMigrationTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/"
                    + "V194__production_make_supply_lifecycle.sql");

    @Test
    void makeSupplyUsesExactAttributedChildPlanItem() throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("'production_plan_item'")
                .contains("when 'production_plan_item' then")
                .contains("link.planning_package_id = v_demand.package_id")
                .contains("link.plan_id = v_demand.plan_id")
                .contains("link.source = 'execution_v1'")
                .contains("production_plan_item_supply_guard")
                .contains("production_material_supply_peg_capacity_guard");
    }

    @Test
    void finishedInboundProvenanceIsAppendOnlyAndReversible() throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("create table production_material_make_receipt_allocations")
                .contains("receipt_id uuid not null references stock_documents(id)")
                .contains("receipt_item_id uuid not null references stock_document_items(id)")
                .contains("supply_peg_id uuid not null references production_material_supply_pegs(id)")
                .contains("where status = 'effective'")
                .contains("make receipt allocation is append-only")
                .contains("make receipt allocation identity is immutable")
                .contains("production_make_receipt_issued_draw_guard")
                .contains("production_make_peg_conservation_guard")
                .contains("production_make_receipt_provenance_guard")
                .contains("for each row execute function fn_audit()");
    }

    @Test
    void deferredExecutionValidatorNoLongerRejectsMakeRoute() throws Exception {
        String sql = compact();
        int start = sql.indexOf(
                "create or replace function fn_assert_execution_segment_integrity(");
        int end = sql.indexOf(
                "comment on table production_material_make_receipt_allocations",
                start);

        assertThat(start).isGreaterThanOrEqualTo(0);
        assertThat(end).isGreaterThan(start);
        assertThat(sql.substring(start, end))
                .doesNotContain("or supply_route = 'make'")
                .contains("production_execution_segment_ready_guard")
                .contains("production_execution_segment_waiting_allocation_guard")
                .contains("v_segment.completion_reopened")
                .contains("production_execution_segment_completion_clearance_guard");
    }


    @Test
    void routeSourcePackageAndConcurrentCapacityAreFailClosed()
            throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("add column auto_promote_when_ready boolean not null default true")
                .contains("production_execution_segment_readiness_policy_guard")
                .contains("production_material_supply_peg_route_guard")
                .contains("fn_assert_active_make_supply_source")
                .contains("production_make_supply_source_link_guard")
                .contains("trg_guard_active_make_source_plan")
                .contains("trg_guard_active_make_subplan_link")
                .contains("fn_lock_make_receipt_allocation_capacity")
                .contains("make_receipt_item:")
                .contains("make_reservation:")
                .contains("production_make_receipt_capacity_guard")
                .contains("production_make_receipt_reservation_capacity_guard")
                .contains("package.status = 'confirmed'")
                .contains("package.execution_model_version = 1")
                .contains("trg_make_receipt_package_source");
    }

    @Test
    void newAssignmentsUseCanonicalProductionOrganization() throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("fn_guard_production_assignment_scope")
                .contains("production_department.code = 'dept_prod'")
                .contains("workshop.parent_id")
                .contains("team.parent_id = new.workshop_department_id")
                .contains("production_execution_segment_production_workshop_guard")
                .contains("production_execution_segment_direct_team_guard");
    }

    @Test
    void migrationDoesNotInventHistoricalMakeFacts() throws Exception {
        String sql = compact();

        assertThat(sql)
                .doesNotContain("insert into production_material_make_receipt_allocations")
                .doesNotContain("insert into production_material_supply_pegs")
                .doesNotContain("update production_material_demands set")
                .doesNotContain("update production_plan_items set");
    }

    private static String compact() throws Exception {
        return Files.readString(MIGRATION, StandardCharsets.UTF_8)
                .toLowerCase()
                .replaceAll("--[^\\r\\n]*", " ")
                .replaceAll("\\s+", " ")
                .trim();
    }
}
