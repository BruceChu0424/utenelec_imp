package com.uten.imp.features.production.fulfillment;

import com.uten.imp.application.port.ProductionSubcontractSupplyTransitionPort;
import org.junit.jupiter.api.Test;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.lang.reflect.Method;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

class ProductionSubcontractSupplyTransitionContractTest {

    @Test
    void callbacksRunInsideTheCallingDocumentTransaction() throws Exception {
        assertThat(ProductionSubcontractSupplyTransitionPort.class)
                .isAssignableFrom(
                        ProductionSubcontractSupplyTransitionService.class);

        for (Method method : new Method[]{
                ProductionSubcontractSupplyTransitionService.class.getMethod(
                        "onSubcontractOrderApproved", UUID.class),
                ProductionSubcontractSupplyTransitionService.class.getMethod(
                        "onSubcontractOrderReversed", UUID.class),
                ProductionSubcontractSupplyTransitionService.class.getMethod(
                        "onSubcontractReceiptApproved", UUID.class),
                ProductionSubcontractSupplyTransitionService.class.getMethod(
                        "beforeSubcontractReceiptReversed", UUID.class)
        }) {
            Transactional transactional =
                    method.getAnnotation(Transactional.class);
            assertThat(transactional)
                    .as(method.getName())
                    .isNotNull();
            assertThat(transactional.propagation())
                    .as(method.getName())
                    .isEqualTo(Propagation.MANDATORY);
        }
    }
}
