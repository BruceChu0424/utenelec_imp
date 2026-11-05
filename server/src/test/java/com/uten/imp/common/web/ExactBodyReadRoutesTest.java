package com.uten.imp.common.web;

import org.junit.jupiter.api.Test;
import java.util.List;
import static org.assertj.core.api.Assertions.assertThat;

class ExactBodyReadRoutesTest {
    @Test void salesDeliveryPreviewIsOnlyTheExactReadPost() {
        String preview="/api/sales/orders/delivery-preview";
        assertThat(ExactBodyReadRoutes.matches("POST",preview)).isTrue();
        for(String method:List.of("GET","PUT","PATCH","DELETE","post"))
            assertThat(ExactBodyReadRoutes.matches(method,preview)).as(method).isFalse();
        for(String path:List.of(preview+"/",preview+"/save",preview+"/confirm",preview+"-rules",
                "/api/sales/orders/delivery-bom/rules/12345678-1234-1234-1234-123456789abc"))
            for(String method:List.of("POST","PUT"))
                assertThat(ExactBodyReadRoutes.matches(method,path)).as(method+" "+path).isFalse();
    }

    @Test void processingCommandsNeverInheritAReadOnlyBodyExemption() {
        String task="/api/production/delivery-processing-tasks/12345678-1234-1234-1234-123456789abc/";
        for(String action:List.of("assignment","start","reports","cancel-start"))
            assertThat(ExactBodyReadRoutes.matches("POST",task+action)).as(action).isFalse();
        assertThat(ExactBodyReadRoutes.matches("POST",null)).isFalse();
    }
}
