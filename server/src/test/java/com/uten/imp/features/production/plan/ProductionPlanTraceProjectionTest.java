package com.uten.imp.features.production.plan;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ProductionPlanTraceProjectionTest {

    @Test
    void stockTraceKindKeepsDrawAndFinishedInboundDistinct() {
        assertThat(ProductionPlanService.stockTraceKind("DRAW"))
                .isEqualTo("STOCK_DRAW");
        assertThat(ProductionPlanService.stockTraceKind("FINISHED_IN"))
                .isEqualTo("FINISHED_IN");
        assertThat(ProductionPlanService.stockTraceKind("OTHER"))
                .isEqualTo("STOCK_DOCUMENT");
    }

    @Test
    void traceQueryReadsDocumentTypeAndUsesOnlyExplicitLineage() throws Exception {
        String source = Files.readString(
                Path.of("src/main/java/com/uten/imp/features/production/plan/"
                        + "ProductionPlanService.java"),
                StandardCharsets.UTF_8);

        assertThat(source)
                .contains("SELECT sd.id, sd.bill_no, sd.doc_type")
                .contains("sd.doc_type IN ('DRAW', 'FINISHED_IN')")
                .contains("stockTraceKind((String) r[2])")
                .contains("analysis_item.id = plan.material_analysis_item_id")
                .contains("analysis_item.analysis_id = plan.material_analysis_id")
                .contains("soi.id = analysis_item.sales_order_item_id")
                .contains("material.analysis_item_id = plan.material_analysis_item_id")
                .contains("allocation.analysis_material_id = material.id")
                .contains("action.external_document_type = 'PURCHASE_REQUEST'")
                .contains("action.external_document_type = 'SUBCONTRACT_APPLICATION'")
                .contains("JOIN subcontract_applications application")
                .doesNotContain("new PlanTraceLink((UUID) r[0], (String) r[1], \"STOCK_DRAW\")");
    }
}
