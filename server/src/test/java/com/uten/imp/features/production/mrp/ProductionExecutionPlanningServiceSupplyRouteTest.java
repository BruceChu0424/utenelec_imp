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
    void selfMadeSourceMapsToMake() {
        // \u81ea\u5236\u4ef6\u53c2\u4e0e\u9f50\u5957\u5224\u5b9a\uff08\u6d88\u8017\u534a\u6210\u54c1\u73b0\u8d27\u5e93\u5b58\uff09\uff0c\u7f3a\u53e3\u7531\u5b50\u751f\u4ea7\u8ba1\u5212\u4f9b\u7ed9\uff0c
        // \u6545\u6620\u5c04\u4e3a MAKE \u8def\u7ebf\u800c\u975e\u62d2\u6536\u3002
        assertThat(ProductionExecutionPlanningService
                .supportedSupplyRoute("\u81ea\u5236"))
                .isEqualTo(ProductionMaterialDemand.ROUTE_MAKE);
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
