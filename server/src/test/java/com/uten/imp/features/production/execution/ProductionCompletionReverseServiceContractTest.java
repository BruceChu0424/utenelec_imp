package com.uten.imp.features.production.execution;

import com.uten.imp.application.port.ProductionCompletionReversePort;
import org.junit.jupiter.api.Test;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.lang.reflect.Method;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

class ProductionCompletionReverseServiceContractTest {

    @Test
    void portImplementationRequiresCallersExistingTransaction()
            throws Exception {
        assertThat(ProductionCompletionReversePort.class)
                .isAssignableFrom(ProductionCompletionReverseService.class);

        Method method = ProductionCompletionReverseService.class.getMethod(
                "beforeFinishedInboundReversed", UUID.class);
        Transactional transactional =
                method.getAnnotation(Transactional.class);

        assertThat(transactional).isNotNull();
        assertThat(transactional.propagation())
                .isEqualTo(Propagation.MANDATORY);
    }
}
