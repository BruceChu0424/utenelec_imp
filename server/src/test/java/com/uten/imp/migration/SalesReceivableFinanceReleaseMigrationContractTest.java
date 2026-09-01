package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class SalesReceivableFinanceReleaseMigrationContractTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/"
                    + "V443__sales_receivable_finance_release_and_client_payment_type.sql");
    private static final Path ORDER_FINANCE_SERVICE = Path.of(
            "src/main/java/com/uten/imp/features/sales/order/"
                    + "SalesOrderFinanceConfirmService.java");

    @Test
    void forwardMigrationPreservesHistoricalAuditTruthAndGuardsNewWarehouseWork()
            throws Exception {
        String sql = Files.readString(MIGRATION).replaceAll("\\s+", " ");

        assertThat(sql)
                .contains("finance_gate_version = 0")
                .contains("WHERE status <> 0 OR warehouse_work_status IS DISTINCT FROM 'PENDING_PICK'")
                .contains("NEW.finance_gate_version = 1")
                .contains("NEW.warehouse_work_status IN ('PICKING', 'PICKED', 'SHIPPED')")
                .contains("NEW.finance_audit <> 1")
                .contains("OLD.warehouse_work_status = 'LEGACY_PENDING'")
                .contains("legacy pending sales shipment is read-only and must be manually rebuilt")
                .contains("UPDATE OF status, finance_gate_version, finance_audit")
                .contains("sales_shipments_v1_shipped_terminal_chk")
                .contains("v_sales_shipment_finance_gate_migration_exceptions")
                .contains("'LEGACY_PENDING', 'PENDING_PICK', 'PICKING', 'PICKED', 'EXCEPTION'")
                .contains("LEGACY_PENDING is read-only")
                .doesNotContain("WHERE legacy_id IS NOT NULL OR status <> 0")
                .doesNotContain("SET finance_audit = 1");
    }

    @Test
    void creditFloorAndThreeWayLabelUseOnlyProvableLegacyEvidence()
            throws Exception {
        String sql = Files.readString(MIGRATION).replaceAll("\\s+", " ");

        assertThat(sql)
                .contains("credit_floor = COALESCE(credit_floor, credit, 0)")
                .contains("legacy_id IS NOT NULL")
                .contains("ALTER COLUMN credit_floor SET DEFAULT 0")
                .contains("sales_payment_type IN ('MONTHLY', 'CASH', 'DEPOSIT')")
                .contains("clients_online_sales_payment_type_required_chk CHECK ( legacy_id IS NOT NULL OR sales_payment_type IS NOT NULL ) NOT VALID")
                .contains("27300000-0000-4000-8100-000000000006")
                .contains("legacy_id = 6")
                .contains("count(*) FROM settlement_methods WHERE system_role = 'MONTHLY') <> 1")
                .contains("cannot verify the unique active MONTHLY settlement UUID role")
                .contains("Non-deleted clients whose three-way sales payment label")
                .contains("method.system_role IN ('CASH', 'MONTHLY')")
                .contains("v_client_sales_payment_type_migration_issues")
                .contains("44300000-0000-4000-8000-000000000001")
                .contains("finance.sales-shipment-audit', 'finance_shipment_audit")
                .contains("44300000-0000-4000-8000-000000000002")
                .contains("warehouse.sales-outbound', 'sales_shipment:warehouse-work")
                .contains("permission surfaces are incomplete or over-broad")
                .contains("CREATE TABLE sales_shipment_finance_release_events")
                .contains("shipment_total_original NUMERIC(18,4) NOT NULL")
                .contains("event_type <> 'RELEASED' OR sales_payment_type IS NOT NULL")
                .contains("sales shipment finance release events are append-only")
                .contains("ENABLE ALWAYS TRIGGER trg_guard_sales_shipment_finance_release_event_append_only")
                .contains("trg_audit_sales_shipment_finance_release_events")
                .contains("FOR EACH ROW EXECUTE FUNCTION fn_audit()")
                .doesNotContain("INSERT INTO department_permissions")
                .doesNotContain("INSERT INTO sales_shipment_finance_release_events")
                .doesNotContain("WHEN 'DEPOSIT' THEN 'DEPOSIT'", "explicitly legacy shipments retain");
    }

    @Test
    void legacyCreditSnapshotIsNotTreatedAsVerifiedCreditLimit() throws Exception {
        String source = Files.readString(ORDER_FINANCE_SERVICE)
                .replaceAll("\\s+", " ");
        assertThat(source).contains(
                "CASE WHEN c.legacy_id IS NULL THEN c.credit ELSE NULL END");
    }
}
