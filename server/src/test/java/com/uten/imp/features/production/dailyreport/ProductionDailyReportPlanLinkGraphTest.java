package com.uten.imp.features.production.dailyreport;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.plan.PlanOrderItemLink;
import com.uten.imp.features.production.plan.PlanOrderItemLinkRepository;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.inOrder;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/** Multi-plan reporting must compare link identities, not JVM/database UUID ordering. */
@ExtendWith(MockitoExtension.class)
class ProductionDailyReportPlanLinkGraphTest {
    // Read-only diagnosis of SR20260924000013: 300 and 100 on separate plans.
    private static final UUID LOW_LINK = UUID.fromString("32c1837b-9241-49c7-a298-5078d5f980b4");
    private static final UUID HIGH_LINK = UUID.fromString("cc3697a4-6c92-487a-bb82-8b333ece73f8");
    private static final UUID OTHER_LINK = UUID.fromString("e0000000-0000-4000-8000-000000000003");
    private static final UUID FIRST_PLAN = UUID.fromString("20000000-0000-4000-8000-000000000004");
    private static final UUID SECOND_PLAN = UUID.fromString("a0000000-0000-4000-8000-000000000005");
    private static final UUID FIRST_ORDER_ITEM = UUID.fromString("30000000-0000-4000-8000-000000000006");
    private static final UUID SECOND_ORDER_ITEM = UUID.fromString("b0000000-0000-4000-8000-000000000007");

    @Mock EntityManager em;
    @Mock PlanOrderItemLinkRepository linkRepo;
    @InjectMocks ProductionDailyReportService service;

    @ParameterizedTest
    @ValueSource(booleans = {true, false})
    void unchangedTwoPlanGraphAcceptsUuidsAcrossTheSignedBoundary(boolean positiveWrite) {
        PlanOrderItemLink first = link(LOW_LINK, FIRST_PLAN, FIRST_ORDER_ITEM, "300");
        PlanOrderItemLink second = link(HIGH_LINK, SECOND_PLAN, SECOND_ORDER_ITEM, "100");
        stubGraph(List.of(second, first), List.of(LOW_LINK, HIGH_LINK));
        when(em.find(PlanOrderItemLink.class, LOW_LINK, LockModeType.PESSIMISTIC_WRITE))
                .thenReturn(first);
        when(em.find(PlanOrderItemLink.class, HIGH_LINK, LockModeType.PESSIMISTIC_WRITE))
                .thenReturn(second);

        Map<UUID, List<PlanOrderItemLink>> result = lockGraph(positiveWrite);

        assertEquals(List.of(first), result.get(FIRST_PLAN));
        assertEquals(List.of(second), result.get(SECOND_PLAN));
        // PostgreSQL already acquired the graph in its UUID byte order. Keep the
        // refresh/find lock order identical, including when Java sorts HIGH first.
        var locks = inOrder(em);
        locks.verify(em).find(PlanOrderItemLink.class, LOW_LINK, LockModeType.PESSIMISTIC_WRITE);
        locks.verify(em).refresh(first, LockModeType.PESSIMISTIC_WRITE);
        locks.verify(em).find(PlanOrderItemLink.class, HIGH_LINK, LockModeType.PESSIMISTIC_WRITE);
        locks.verify(em).refresh(second, LockModeType.PESSIMISTIC_WRITE);
        verify(linkRepo, never()).save(any());
    }

    @ParameterizedTest
    @ValueSource(strings = {"insert", "delete", "replace", "duplicate"})
    void realGraphChangesStillFailBeforeAnyLinkIsUsed(String change) {
        List<UUID> current = switch (change) {
            case "insert" -> List.of(LOW_LINK, HIGH_LINK, OTHER_LINK);
            case "delete" -> List.of(LOW_LINK);
            case "replace" -> List.of(LOW_LINK, OTHER_LINK);
            case "duplicate" -> List.of(LOW_LINK, LOW_LINK);
            default -> throw new AssertionError(change);
        };
        stubGraph(List.of(
                link(LOW_LINK, FIRST_PLAN, FIRST_ORDER_ITEM, "300"),
                link(HIGH_LINK, SECOND_PLAN, SECOND_ORDER_ITEM, "100")), current);

        ApiException failure = assertThrows(ApiException.class, () -> lockGraph(true));

        assertTrue(failure.getMessage().contains("排产分摊已被并发变更"));
        verify(em, never()).find(eq(PlanOrderItemLink.class), any(), any(LockModeType.class));
        verify(linkRepo, never()).save(any());
    }

    @ParameterizedTest
    @ValueSource(strings = {"deleted", "reassigned", "overproduced"})
    void unchangedIdsStillRequireValidRefreshedLinkState(String change) {
        PlanOrderItemLink first = link(LOW_LINK, FIRST_PLAN, FIRST_ORDER_ITEM, "300");
        PlanOrderItemLink second = link(HIGH_LINK, SECOND_PLAN, SECOND_ORDER_ITEM, "100");
        stubGraph(List.of(first, second), List.of(LOW_LINK, HIGH_LINK));
        when(em.find(PlanOrderItemLink.class, LOW_LINK, LockModeType.PESSIMISTIC_WRITE))
                .thenReturn(first);
        doAnswer(invocation -> {
            switch (change) {
                case "deleted" -> first.setDeleted(true);
                case "reassigned" -> first.setPlanItemId(UUID.randomUUID());
                case "overproduced" -> first.setProducedQty(new BigDecimal("301"));
                default -> throw new AssertionError(change);
            }
            return null;
        }).when(em).refresh(first, LockModeType.PESSIMISTIC_WRITE);

        ApiException failure = assertThrows(ApiException.class, () -> lockGraph(true));

        assertTrue(failure.getMessage().contains("排产分摊状态或数量异常"));
        verify(linkRepo, never()).save(any());
    }

    @Test
    void previouslyLinkedPlanCannotSilentlyBecomeAnInternalPlan() {
        stubGraph(List.of(link(LOW_LINK, FIRST_PLAN, FIRST_ORDER_ITEM, "300")), List.of(LOW_LINK));

        ApiException failure = assertThrows(ApiException.class, () -> lockGraph(true));

        assertTrue(failure.getMessage().contains("当前联动已失效"));
        verify(em, never()).find(eq(PlanOrderItemLink.class), any(), any(LockModeType.class));
    }

    private Map<UUID, List<PlanOrderItemLink>> lockGraph(boolean positiveWrite) {
        return ReflectionTestUtils.invokeMethod(service, "lockPlanLinkGraph",
                List.of(FIRST_PLAN, SECOND_PLAN), positiveWrite);
    }

    private void stubGraph(List<PlanOrderItemLink> discovered, List<UUID> current) {
        when(linkRepo.findActiveByPlanItemIds(any())).thenReturn(discovered);
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            if (sql.contains("SELECT DISTINCT plan_item_id")) {
                return query(List.of(FIRST_PLAN, SECOND_PLAN));
            }
            if (sql.contains("FROM sales_order_items soi")) {
                return query(discovered.stream().map(link -> new Object[]{
                        link.getOrderItemId(), UUID.randomUUID(), (short) 1,
                        false, false, false, false, 5}).toList());
            }
            if (sql.contains("FROM plan_order_item_links") && sql.contains("FOR UPDATE")) {
                assertTrue(sql.contains("ORDER BY id"));
                return query(current);
            }
            throw new AssertionError("Unexpected graph query: " + sql);
        });
    }

    private static Query query(List<?> rows) {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(rows);
        return query;
    }

    private static PlanOrderItemLink link(UUID id, UUID plan, UUID orderItem, String allocated) {
        PlanOrderItemLink link = new PlanOrderItemLink();
        link.setId(id);
        link.setPlanItemId(plan);
        link.setOrderItemId(orderItem);
        link.setAllocatedQty(new BigDecimal(allocated));
        link.setProducedQty(BigDecimal.ZERO);
        link.setInboundQty(BigDecimal.ZERO);
        return link;
    }
}
