package com.uten.imp.common.finance;

import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class ProcurementIqcReplacementAllocationBehaviorTest {

    @Test
    void purchaseReplacementSpansCasesAndTheLastCaseAbsorbsTheMoneyTail() {
        UUID firstCase = UUID.randomUUID();
        UUID secondCase = UUID.randomUUID();
        UUID actor = UUID.randomUUID();
        List<NativeCall> calls = new ArrayList<>();
        EntityManager em = allocationEntityManager(
                calls,
                List.of(firstCase, secondCase),
                Map.of(
                        firstCase, capacity("1", "1", "3.3333", "3.3333"),
                        secondCase, capacity("2", "2", "6.6667", "6.6667")),
                List.of());
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        when(currentUser.requireId()).thenReturn(actor);
        ProcurementIqcReplacementAllocationService service =
                new ProcurementIqcReplacementAllocationService(em, currentUser);

        service.allocateForReceiptItem(
                "purchase",
                UUID.randomUUID(),
                UUID.randomUUID(),
                UUID.randomUUID(),
                new BigDecimal("3"),
                BigDecimal.ONE,
                new BigDecimal("10.0000"),
                new BigDecimal("10.0000"),
                new BigDecimal("10"),
                new BigDecimal("100.0000"),
                new BigDecimal("100.0000"),
                new BigDecimal("10"),
                new BigDecimal("100.0000"),
                new BigDecimal("100.0000"));

        List<NativeCall> allocations = calls(calls,
                "insert into procurement_iqc_replacement_allocations");
        assertThat(allocations).hasSize(2);
        assertThat(allocations).extracting(call -> call.parameters().get("caseId"))
                .containsExactly(firstCase, secondCase);
        assertThat(sum(allocations, "qty")).isEqualByComparingTo("3");
        assertThat(sum(allocations, "baseQty")).isEqualByComparingTo("3.0000");
        assertThat(sum(allocations, "original")).isEqualByComparingTo("10.0000");
        assertThat(sum(allocations, "local")).isEqualByComparingTo("10.0000");
        assertThat(allocations.get(0).parameters().get("original"))
                .isEqualTo(new BigDecimal("3.3333"));
        assertThat(allocations.get(1).parameters().get("original"))
                .isEqualTo(new BigDecimal("6.6667"));
        assertThat(calls(calls,
                "insert into procurement_iqc_rejection_events")).hasSize(2);
    }

    @Test
    void zeroPricedReturnedSliceStillReleasesQuantityForSubcontractReplacement() {
        UUID rejectionCase = UUID.randomUUID();
        List<NativeCall> calls = new ArrayList<>();
        EntityManager em = allocationEntityManager(
                calls,
                List.of(rejectionCase),
                Map.of(rejectionCase, capacity("2", "4", "0", "0")),
                List.of());
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        when(currentUser.requireId()).thenReturn(UUID.randomUUID());
        ProcurementIqcReplacementAllocationService service =
                new ProcurementIqcReplacementAllocationService(em, currentUser);

        service.allocateForReceiptItem(
                "SUBCONTRACT",
                UUID.randomUUID(),
                UUID.randomUUID(),
                UUID.randomUUID(),
                new BigDecimal("2"),
                new BigDecimal("2"),
                BigDecimal.ZERO,
                BigDecimal.ZERO,
                new BigDecimal("10"),
                BigDecimal.ZERO,
                BigDecimal.ZERO,
                new BigDecimal("10"),
                BigDecimal.ZERO,
                BigDecimal.ZERO);

        NativeCall allocation = onlyCall(calls,
                "insert into procurement_iqc_replacement_allocations");
        assertThat(allocation.parameters().get("qty"))
                .isEqualTo(new BigDecimal("2"));
        assertThat(allocation.parameters().get("baseQty"))
                .isEqualTo(new BigDecimal("4.0000"));
        assertThat(allocation.parameters().get("original"))
                .isEqualTo(new BigDecimal("0.0000"));
        assertThat(allocation.parameters().get("local"))
                .isEqualTo(new BigDecimal("0.0000"));
    }

    @Test
    void reverseChangesEveryActiveAllocationAndWritesOneEventPerCase() {
        UUID firstAllocation = UUID.randomUUID();
        UUID secondAllocation = UUID.randomUUID();
        UUID firstCase = UUID.randomUUID();
        UUID secondCase = UUID.randomUUID();
        UUID actor = UUID.randomUUID();
        List<NativeCall> calls = new ArrayList<>();
        EntityManager em = allocationEntityManager(
                calls,
                List.of(),
                Map.of(),
                List.of(
                        new Object[]{firstAllocation, firstCase, 3L},
                        new Object[]{secondAllocation, secondCase, 7L}));
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        when(currentUser.requireId()).thenReturn(actor);
        ProcurementIqcReplacementAllocationService service =
                new ProcurementIqcReplacementAllocationService(em, currentUser);

        service.reverseForReceipt("PURCHASE", UUID.randomUUID(), " receipt reversed ");

        List<NativeCall> updates = calls(calls,
                "update procurement_iqc_replacement_allocations");
        assertThat(updates).hasSize(2);
        assertThat(updates).extracting(call -> call.parameters().get("id"))
                .containsExactly(firstAllocation, secondAllocation);
        assertThat(updates).extracting(call -> call.parameters().get("version"))
                .containsExactly(3L, 7L);
        assertThat(updates).allSatisfy(call -> {
            assertThat(call.parameters()).containsEntry("actor", actor);
            assertThat(call.parameters()).containsEntry("reason", "receipt reversed");
        });
        List<NativeCall> events = calls(calls,
                "'replacement_allocation_reversed'");
        assertThat(events).hasSize(2);
        assertThat(events).extracting(call -> call.parameters().get("caseId"))
                .containsExactly(firstCase, secondCase);
    }

    private static EntityManager allocationEntityManager(
            List<NativeCall> calls,
            List<UUID> caseIds,
            Map<UUID, Object[]> capacities,
            List<Object[]> activeAllocations) {
        EntityManager em = mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = compact(invocation.getArgument(0));
            Map<String, Object> parameters = new LinkedHashMap<>();
            NativeCall call = new NativeCall(sql, parameters);
            calls.add(call);
            Query query = mock(Query.class);
            when(query.setParameter(anyString(), org.mockito.ArgumentMatchers.any()))
                    .thenAnswer(argument -> {
                        parameters.put(argument.getArgument(0), argument.getArgument(1));
                        return query;
                    });
            when(query.getResultList()).thenAnswer(ignored -> {
                if (sql.startsWith("select id from procurement_iqc_rejection_cases")) {
                    return caseIds;
                }
                if (sql.startsWith("select id,case_id,row_version")) {
                    return activeAllocations;
                }
                return List.of();
            });
            when(query.getSingleResult()).thenAnswer(ignored -> {
                if (sql.contains("left join procurement_iqc_replacement_allocations")) {
                    return capacities.get(parameters.get("caseId"));
                }
                return BigDecimal.ZERO;
            });
            when(query.executeUpdate()).thenReturn(1);
            return query;
        });
        return em;
    }

    private static Object[] capacity(
            String qty, String baseQty, String original, String local) {
        return new Object[]{
                new BigDecimal(qty), new BigDecimal(baseQty),
                new BigDecimal(original), new BigDecimal(local),
                BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO
        };
    }

    private static BigDecimal sum(List<NativeCall> calls, String parameter) {
        return calls.stream()
                .map(call -> (BigDecimal) call.parameters().get(parameter))
                .reduce(BigDecimal.ZERO, BigDecimal::add);
    }

    private static NativeCall onlyCall(List<NativeCall> calls, String fragment) {
        List<NativeCall> matches = calls(calls, fragment);
        assertThat(matches).hasSize(1);
        return matches.getFirst();
    }

    private static List<NativeCall> calls(List<NativeCall> calls, String fragment) {
        return calls.stream().filter(call -> call.sql().contains(fragment)).toList();
    }

    private static String compact(String sql) {
        return sql.replaceAll("\\s+", " ").trim().toLowerCase();
    }

    private record NativeCall(String sql, Map<String, Object> parameters) {
    }
}
