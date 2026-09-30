package com.uten.imp.config.cloud;

import com.uten.imp.features.sales.learning.SalesLearningEvidenceCleanupScheduler;
import com.uten.imp.features.sales.learning.SalesLearningReceiptService;
import com.uten.imp.features.sales.template.SalesQuoteTemplateCleanupScheduler;
import com.uten.imp.features.sales.template.SalesQuoteTemplateStore;
import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.*;

class SalesLearningCleanupProfileTest {
    private final SalesQuoteTemplateStore store = mock(SalesQuoteTemplateStore.class);
    private final SalesLearningReceiptService receipts = mock(SalesLearningReceiptService.class);
    private final ApplicationContextRunner context = new ApplicationContextRunner()
            .withBean(SalesQuoteTemplateStore.class, () -> store)
            .withBean(SalesLearningReceiptService.class, () -> receipts)
            .withUserConfiguration(SalesQuoteTemplateCleanupScheduler.class, SalesLearningEvidenceCleanupScheduler.class);

    @Test
    void cloudKeepsBusinessServicesAvailableWithoutEitherAutomaticWriter() {
        context.withPropertyValues("spring.profiles.active=cloud").run(ctx -> {
            assertThat(ctx).hasNotFailed().hasSingleBean(SalesQuoteTemplateStore.class)
                    .hasSingleBean(SalesLearningReceiptService.class)
                    .doesNotHaveBean(SalesQuoteTemplateCleanupScheduler.class)
                    .doesNotHaveBean(SalesLearningEvidenceCleanupScheduler.class);
            verifyNoInteractions(store, receipts);
        });
    }

    @Test
    void internalDeploymentDelegatesBothCleanupsThroughTheBusinessServiceBeans() {
        context.withPropertyValues("spring.profiles.active=prod").run(ctx -> {
            assertThat(ctx).hasNotFailed();
            ctx.getBean(SalesQuoteTemplateCleanupScheduler.class).purgeExpired();
            ctx.getBean(SalesLearningEvidenceCleanupScheduler.class).purgeExpiredEvidence();
            verify(store).purgeExpired();
            verify(receipts).purgeExpiredEvidence();
            verifyNoMoreInteractions(store, receipts);
        });
    }
}
