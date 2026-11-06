package com.uten.imp.common.web;

import org.junit.jupiter.api.Test;
import java.util.List;
import static org.assertj.core.api.Assertions.assertThat;

class ExactBodyReadRoutesTest {
    @org.junit.jupiter.api.Test void flatCompleteReadRoutesDoNotAuthorizeAdjacentCommands() {
        for(String path:java.util.List.of("/api/master/colors/summaries","/api/master/units/summaries",
                "/api/master/currencies/summaries","/api/master/accounts/summaries",
                "/api/master/reference-methods/settlement-admin/summaries")) {
            assertThat(ExactBodyReadRoutes.matches("POST",path)).isTrue();
            for(String suffix:java.util.List.of("/save","/export","/","-all"))
                assertThat(ExactBodyReadRoutes.matches("POST",path+suffix)).isFalse();
            assertThat(ExactBodyReadRoutes.matches("PUT",path)).isFalse();
        }
    }
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
