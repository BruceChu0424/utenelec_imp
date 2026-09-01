package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class WarehouseDocumentHistoryPermissionMigrationContractTest {

    @Test
    void migrationIsAdditiveAndRegistersExactReadOnlySurfaces() throws Exception {
        String sql = Files.readString(Path.of(
                "src/main/resources/db/migration/V445__warehouse_document_history_permissions.sql"));
        String normalized = sql.toLowerCase();

        assertThat(normalized)
                .doesNotContain("delete from")
                .contains("bulk_assignable")
                .contains("sensitive_commercial")
                .contains("warehouse_purchase_receipt_history:view")
                .contains("warehouse_subcontract_receipt_history:view")
                .contains("warehouse_subcontract_outbound_history:view")
                .contains("warehouse_subcontract_finished_return_history:view")
                .contains("warehouse_subcontract_material_return_history:view")
                .contains("warehouse_subcontract_waste_history:view")
                .contains("warehouse_iqc_return:view")
                .contains("warehouse.purchase-receipt-history")
                .contains("warehouse.subcontract-waste-history")
                .contains("warehouse.iqc-return")
                .contains("procurement_iqc_rejection:record_return")
                .contains("procurement_iqc_rejection:amount:view")
                .contains("permission.action_type <> 'view'");
    }
}
