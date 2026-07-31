package com.uten.imp.features.production.mrp;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.fulfillment.ProductionMaterialDemand;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class ProductionExecutionPlanningServiceSupplyRouteTest {

    @Test
    void explicitPurchaseSourceMapsToBuy() {
        assertThat(ProductionExecutionPlanningService
                .supportedSupplyRoute("\u91c7\u8d2d"))
                .isEqualTo(ProductionMaterialDemand.ROUTE_BUY);
        assertThat(ProductionExecutionPlanningService
                .supportedSupplyRoute("  \u91c7\u8d2d  "))
                .isEqualTo(ProductionMaterialDemand.ROUTE_BUY);
    }

    @Test
    void explicitSubcontractSourceMapsToSubcontract() {
        assertThat(ProductionExecutionPlanningService
                .supportedSupplyRoute("\u59d4\u5916"))
                .isEqualTo(
                        ProductionMaterialDemand.ROUTE_SUBCONTRACT);
    }

    @Test
    void selfMadeSourceFailsClosed() {
        assertUnsupported("\u81ea\u5236");
    }

    @Test
    void missingOrUnknownSourcesFailClosed() {
        assertUnsupported(null);
        assertUnsupported("");
        assertUnsupported(" ");
        assertUnsupported("UNKNOWN");
    }

    private static void assertUnsupported(String sourceType) {
        assertThatThrownBy(() -> ProductionExecutionPlanningService
                .supportedSupplyRoute(sourceType))
                .isInstanceOf(ApiException.class);
    }
}
