package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class PreplanAnalysisExactStockPegMigrationContractTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/"
                    + "V307__preplan_analysis_exact_stock_pegs.sql");

    @Test
    void exactPegReservesBeneficiaryIdentityButKeepsTheWholeRowImmutable()
            throws Exception {
        String sql = compact();

        assertThat(sql).contains("create table preplan_analysis_stock_exact_pegs");
        assertThat(sql).contains("origin_analysis_id uuid not null");
        assertThat(sql).contains("origin_analysis_material_id uuid not null");
        assertThat(sql).contains("beneficiary_analysis_id uuid not null");
        assertThat(sql).contains("beneficiary_analysis_material_id uuid not null");
        assertThat(sql).contains("new preplan exact stock peg must start at its origin material");
        assertThat(sql).contains(
                "preplan exact stock peg origin and beneficiary are immutable until an approved transfer ledger exists");
        assertThat(sql).doesNotContain("beneficiary change requires");
        assertThat(sql).contains("trg_audit_preplan_analysis_stock_exact_pegs");
        assertThat(sql).contains("trg_guard_pma_material_exact_peg_identity");
        assertThat(sql).contains(
                "material identity referenced by a preplan exact stock peg is immutable");
        assertThat(sql).contains("trg_validate_pma_material_exact_peg_endpoint");
        assertThat(sql).contains("deferrable initially deferred");
        assertThat(sql).contains(
                "effective preplan exact stock peg requires an active matching material endpoint");
    }

    @Test
    void physicalReservationAndSupplyAllocationCapacityAreDatabaseGuarded()
            throws Exception {
        String sql = compact();

        assertThat(sql).contains("unique (stock_reservation_id)");
        assertThat(sql).contains("references stock_reservations(id) on delete restrict");
        assertThat(sql).contains(
                "references procurement_inspection_events(id) on delete restrict");
        assertThat(sql).contains("foreign key (origin_analysis_id, supply_action_allocation_id)");
        assertThat(sql).contains("foreign key (origin_analysis_id, origin_analysis_material_id)");
        assertThat(sql).contains("foreign key (beneficiary_analysis_id, beneficiary_analysis_material_id)");
        assertThat(sql).contains("preplan exact stock peg exceeds supply allocation capacity");
        assertThat(sql).contains("v_reservation.source_doc_type <> new.source_receipt_type || '_receipt'");
        assertThat(sql).contains(
                "v_reservation.supply_id is distinct from v_allocation.external_item_id");
        assertThat(sql).contains("v_reservation.is_deleted is distinct from false");
        assertThat(sql).contains("v_reservation.status <> 0");
        assertThat(sql).contains("v_reservation.consumed_qty <> 0");
        assertThat(sql).contains("v_reservation.released_qty <> 0");
        assertThat(sql).contains("v_event.action <> 'pass'");
        assertThat(sql).contains("v_inspection.warehouse_id <> v_reservation.warehouse_id");
        assertThat(sql).contains("v_inspection.unit_id <> v_origin.unit_id");
        assertThat(sql).contains("preplan exact stock pegs exceed iqc pass event quantity");
        assertThat(sql).contains("deferrable initially immediate");
        assertThat(sql).contains(
                "where id = new.supply_action_allocation_id for update");
        assertThat(sql).contains(
                "where id = new.source_disposition_event_id for update");
        assertThat(sql).contains(
                "receipt_item.id = v_inspection.receipt_item_id");
        assertThat(sql).contains(
                "order_item.request_item_id = v_allocation.external_item_id");
        assertThat(sql).contains(
                "order_item.application_item_id = v_allocation.external_item_id");
        assertThat(sql).contains("preplan exact stock pegs are append-only");
    }

    @Test
    void migrationIsForwardOnlyAndDoesNotGuessHistoricalV298Rows() throws Exception {
        String sql = compact();

        assertThat(sql).doesNotContain(
                "insert into preplan_analysis_stock_exact_pegs select");
        assertThat(sql).contains("历史 v298 无子账行保持分析级兼容");
    }

    private static String compact() throws Exception {
        return Files.readString(MIGRATION, StandardCharsets.UTF_8)
                .replaceAll("--[^\\r\\n]*", " ")
                .replaceAll("\\s+", " ")
                .trim()
                .toLowerCase();
    }
}
