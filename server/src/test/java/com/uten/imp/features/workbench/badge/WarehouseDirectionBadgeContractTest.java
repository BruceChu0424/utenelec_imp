package com.uten.imp.features.workbench.badge;

import com.uten.imp.application.port.WarehouseTaskScopePort;
import com.uten.imp.application.port.WorkbenchBadgeSources;
import jakarta.persistence.EntityManager;
import org.hibernate.Session;
import org.hibernate.jdbc.ReturningWork;
import org.hibernate.jdbc.Work;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.datasource.ConnectionHolder;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.Savepoint;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.stream.Stream;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

class WarehouseDirectionBadgeContractTest {
    @Test
    void directionEntriesReplaceTheDrawContributionWhileTheLegacyAliasKeepsItsCount() throws Exception {
        Harness harness = harness();
        WorkbenchBadgeSummary summary = harness.service.summary(Set.of(
                "warehouseOutboundCenter", "warehouseInboundCenter", "warehouseDrawCenter"));
        assertThat(summary.entries().get("warehouseOutboundCenter").todo()).isEqualTo(4);
        assertThat(summary.entries().get("warehouseInboundCenter").todo()).isEqualTo(1);
        assertThat(summary.entries().get("warehouseDrawCenter").todo()).isEqualTo(5);
        assertThat(summary.modules().get("warehouse").todo()).isEqualTo(5);
        assertThat(summary.total().todo()).isEqualTo(5);
        assertThat(summary.total().inProgress()).isZero();
        assertThat(harness.drawReads.get()).isEqualTo(1);
        assertThat(harness.returnReads.get()).isEqualTo(1);
        assertThat(WorkbenchBadgeCatalog.warehouseDrawCenter.contributesToModule()).isFalse();
        verify(harness.scopes).withQueryScopeCache(any());
    }

    @Test
    void oldClientsMayStillAskForTheDrawAliasWithoutAddingAnotherModuleContribution() throws Exception {
        Harness harness = harness();
        var entries = harness.service.entries(Set.of("warehouseDrawCenter"));
        assertThat(entries.todo()).containsOnlyKeys("warehouseDrawCenter");
        assertThat(entries.todo().get("warehouseDrawCenter")).isEqualTo(5);
        assertThat(entries.fact("productionDraw.count")).isEqualTo(4);
        assertThat(entries.fact("productionReturn.count")).isEqualTo(1);
        assertThat(entries.staleEntries()).isEmpty();
    }

    @Test void physicalLineFactsPropagateThroughDirectionQualityModuleAndNavigationCounts() throws Exception {
        Harness harness = harness(Map.of(
                "warehouseInboundExpectation", Map.of("count",2L,"PURCHASE",2L,"SUBCONTRACT",0L),
                "finishedInbound", Map.of("count",3L),
                "productionReturn", Map.of("count",2L),
                "warehouseSalesOutbound", Map.of("PENDING_PICK",2L),
                "subcontractOutbound", Map.of("count",2L),
                "productionDraw", Map.of("count",3L),
                "qualityResult", Map.of("actionable.PURCHASE",2L,"inProgress.PURCHASE",3L)));
        var summary=harness.service.summary(Set.of("warehouseOutboundCenter","warehouseInboundCenter",
                "warehouseDrawCenter","warehouseQualityResult"));
        assertThat(summary.entries().get("warehouseInboundCenter").todo()).isEqualTo(7);
        assertThat(summary.entries().get("warehouseOutboundCenter").todo()).isEqualTo(7);
        assertThat(summary.entries().get("warehouseDrawCenter").todo()).isEqualTo(5);
        assertThat(summary.entries().get("warehouseQualityResult").todo()).isEqualTo(2);
        assertThat(summary.entries().get("warehouseQualityResult").inProgress()).isEqualTo(3);
        assertThat(summary.modules().get("warehouse").todo()).isEqualTo(16);
        assertThat(summary.total().todo()).isEqualTo(16);
        assertThat(summary.total().inProgress()).isEqualTo(3);
        assertThat(summary.facts()).containsEntry("warehouseInboundExpectation.PURCHASE",2L);
    }

    private record Harness(WorkbenchBadgeService service, WarehouseTaskScopePort scopes,
                           AtomicInteger drawReads, AtomicInteger returnReads) {}

    private static Harness harness() throws Exception {
        return harness(Map.of());
    }

    private static Harness harness(Map<String,Map<String,Long>> facts) throws Exception {
        DataSource dataSource = mock(DataSource.class);
        when(dataSource.getConnection()).thenAnswer(call -> {
            Connection connection = mock(Connection.class);
            when(connection.getAutoCommit()).thenReturn(true);
            when(connection.setSavepoint()).thenReturn(mock(Savepoint.class));
            return connection;
        });
        var manager = new DataSourceTransactionManager(dataSource);
        AtomicInteger draw = new AtomicInteger(), returned = new AtomicInteger();
        var registered = Arrays.stream(WorkbenchBadgeCatalog.values())
                .flatMap(entry -> Stream.concat(entry.todoFacts().stream(), entry.inProgressFacts().stream()))
                .map(WorkbenchBadgeCatalog::sourceOf).distinct()
                .map(key -> new WorkbenchBadgeSources.Source(key, () -> {
                    if (facts.containsKey(key)) return facts.get(key);
                    if (key.equals("productionDraw")) { draw.incrementAndGet(); return Map.of("count", 4L); }
                    if (key.equals("productionReturn")) { returned.incrementAndGet(); return Map.of("count", 1L); }
                    return Map.of("count", 0L);
                })).toList();
        WorkbenchBadgeSources contributor = () -> registered;
        WarehouseTaskScopePort scopes = mock(WarehouseTaskScopePort.class);
        when(scopes.withQueryScopeCache(any())).thenAnswer(call -> ((WarehouseTaskScopePort.ReadQuery<?>) call.getArgument(0)).read());
        WorkbenchBadgeService service = new WorkbenchBadgeService(List.of(contributor), manager, scopes, com.uten.imp.testsupport.TaskAudienceTestSupport.direct());
        EntityManager em = mock(EntityManager.class);
        Session session = mock(Session.class);
        when(em.unwrap(Session.class)).thenReturn(session);
        when(session.doReturningWork(any())).thenAnswer(call -> ((ReturningWork<?>) call.getArgument(0)).execute(
                ((ConnectionHolder) TransactionSynchronizationManager.getResource(dataSource)).getConnection()));
        doAnswer(call -> {
            ((Work) call.getArgument(0)).execute(((ConnectionHolder) TransactionSynchronizationManager.getResource(dataSource)).getConnection());
            return null;
        }).when(session).doWork(any());
        ReflectionTestUtils.setField(service, "entityManager", em);
        return new Harness(service, scopes, draw, returned);
    }
}
