package com.uten.imp.features.stock.valuation;

import com.uten.imp.application.port.InventoryProductionCostPort;
import com.uten.imp.application.port.InventoryValuationPort;
import com.uten.imp.features.stock.InventoryMutationLock;
import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.scheduling.annotation.EnableScheduling;
import org.springframework.transaction.PlatformTransactionManager;

import java.time.Duration;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;
import static org.awaitility.Awaitility.await;
import static org.mockito.ArgumentMatchers.anyMap;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class InventoryValueWorkSchedulerTest {

    @Test
    void cloudKeepsTheRealWorkServiceInjectableWithoutPolling() {
        context("cloud").run(context -> {
            assertThat(context).hasSingleBean(InventoryValueWorkService.class)
                    .doesNotHaveBean(InventoryValueWorkScheduler.class);
            AtomicInteger polls = context.getBean(AtomicInteger.class);
            await().during(Duration.ofMillis(150)).atMost(Duration.ofSeconds(2))
                    .untilAsserted(() -> assertThat(polls.get()).isZero());

            assertThat(context.getBean(InventoryValueWorkService.class).runBatch()).isZero();
            assertThat(polls.get()).isEqualTo(1);
        });
    }

    @Test
    void localProfilePollsAndClosingItsContextStopsFurtherWork() {
        AtomicInteger[] observed = new AtomicInteger[1];
        context("dev").run(context -> {
            assertThat(context).hasSingleBean(InventoryValueWorkService.class)
                    .hasSingleBean(InventoryValueWorkScheduler.class);
            observed[0] = context.getBean(AtomicInteger.class);
            await().atMost(Duration.ofSeconds(3))
                    .untilAsserted(() -> assertThat(observed[0].get()).isPositive());
        });

        int pollsAtClose = observed[0].get();
        await().during(Duration.ofMillis(150)).atMost(Duration.ofSeconds(2))
                .untilAsserted(() -> assertThat(observed[0].get()).isEqualTo(pollsAtClose));
    }

    private ApplicationContextRunner context(String profile) {
        return new ApplicationContextRunner()
                .withInitializer(context -> {
                    context.getEnvironment().setActiveProfiles(profile);
                    AtomicInteger polls = new AtomicInteger();
                    NamedParameterJdbcTemplate database = mock(NamedParameterJdbcTemplate.class);
                    when(database.queryForList(anyString(), anyMap(), eq(UUID.class))).thenAnswer(invocation -> {
                        polls.incrementAndGet();
                        return List.of();
                    });
                    InventoryValuationPort values = mock(InventoryValuationPort.class);
                    when(values.pendingWork(50)).thenReturn(List.of());
                    InventoryProductionCostPort production = mock(InventoryProductionCostPort.class);
                    when(production.pendingRecalculations(10)).thenReturn(List.of());
                    when(production.pendingWork(50)).thenReturn(List.of());
                    var beans = context.getBeanFactory();
                    // Prebuilt collaborators are test doubles, not additional Spring services.
                    beans.registerSingleton("polls", polls);
                    beans.registerSingleton("database", database);
                    beans.registerSingleton("valuation", values);
                    beans.registerSingleton("production", production);
                    beans.registerSingleton("mutex", mock(InventoryMutationLock.class));
                    beans.registerSingleton("transactions", mock(PlatformTransactionManager.class));
                    beans.registerSingleton("support", mock(InventoryBusinessValueSupport.class));
                    beans.registerSingleton("materials", mock(ProductionInventoryValueService.class));
                    beans.registerSingleton("subcontract", mock(SubcontractOwnMaterialCostService.class));
                })
                .withPropertyValues("uten.inventory.value-work-delay-ms=20",
                        "uten.inventory.value-work-initial-delay-ms=0")
                .withUserConfiguration(WorkerConfiguration.class);
    }

    @TestConfiguration(proxyBeanMethods = false)
    @EnableScheduling
    @Import({InventoryValueWorkService.class, InventoryValueWorkScheduler.class})
    static class WorkerConfiguration {
    }
}
