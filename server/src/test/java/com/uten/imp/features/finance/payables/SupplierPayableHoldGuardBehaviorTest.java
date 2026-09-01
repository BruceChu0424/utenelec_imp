package com.uten.imp.features.finance.payables;

import com.uten.imp.common.web.ApiException;
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
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class SupplierPayableHoldGuardBehaviorTest {

    @Test
    void verifiedCaseCreditCanUseItsDedicatedOffsetLaneWhileOrdinaryPaymentStaysHeld() {
        UUID ledgerId = UUID.randomUUID();
        UUID allowedCaseId = UUID.randomUUID();
        List<NativeCall> calls = new ArrayList<>();
        EntityManager em = holdEntityManager(calls, ledgerId);
        SupplierPayableHoldGuard guard = new SupplierPayableHoldGuard(em);

        guard.requireUnheld(List.of(ledgerId), "IQC供应商贷项抵销", allowedCaseId);

        assertThatThrownBy(() -> guard.requireUnheld(List.of(ledgerId), "付款审核"))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("付款审核")
                .hasMessageContaining("AP-IQC-001")
                .hasMessageContaining("失败基本量 2");

        List<NativeCall> holdQueries = calls.stream()
                .filter(call -> call.sql().contains("with inspection_link as"))
                .toList();
        assertThat(holdQueries).hasSize(2);
        assertThat(holdQueries.get(0).parameters())
                .containsEntry("allowedCaseId", allowedCaseId);
        assertThat(holdQueries.get(1).parameters())
                .containsEntry("allowedCaseId", null);
        assertThat(holdQueries.get(0).sql())
                .contains("allowed_case.status='return_recorded'")
                .contains("allowed_case.source_ap_ledger_id=ledger.id")
                .contains("allowed_credit.status=1")
                .contains("rejection.id=:allowedcaseid");
    }

    @Test
    void onlyTheExactActiveCreditForTheExactCaseAndTargetLedgerIsAuthorized() {
        UUID caseId = UUID.randomUUID();
        UUID creditLedgerId = UUID.randomUUID();
        UUID targetLedgerId = UUID.randomUUID();
        List<NativeCall> calls = new ArrayList<>();
        EntityManager em = mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = compact(invocation.getArgument(0));
            Map<String, Object> parameters = new LinkedHashMap<>();
            calls.add(new NativeCall(sql, parameters));
            Query query = mock(Query.class);
            when(query.setParameter(anyString(), org.mockito.ArgumentMatchers.any()))
                    .thenAnswer(argument -> {
                        parameters.put(argument.getArgument(0), argument.getArgument(1));
                        return query;
                    });
            when(query.getSingleResult()).thenReturn(1L);
            return query;
        });
        SupplierPayableHoldGuard guard = new SupplierPayableHoldGuard(em);

        assertThat(guard.authorizedIqcCreditOffset(
                caseId, creditLedgerId, List.of(targetLedgerId))).isTrue();
        assertThat(guard.authorizedIqcCreditOffset(
                caseId, creditLedgerId, List.of(targetLedgerId, UUID.randomUUID()))).isFalse();

        assertThat(calls).hasSize(1);
        NativeCall authorization = calls.getFirst();
        assertThat(authorization.parameters())
                .containsEntry("caseId", caseId)
                .containsEntry("sourceCreditLedgerId", creditLedgerId)
                .containsEntry("targetLedgerId", targetLedgerId);
        assertThat(authorization.sql())
                .contains("rejection.status='return_recorded'")
                .contains("rejection.source_ap_ledger_id=:targetledgerid")
                .contains("credit.source_doc_id=rejection.id")
                .contains("credit.status=1")
                .contains("coalesce(credit.is_deleted,false)=false");
    }

    @Test
    void batchHoldInfoPreservesEveryBlockedLedgerAndFailedQuantity() {
        UUID first = UUID.randomUUID();
        UUID second = UUID.randomUUID();
        EntityManager em = mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            Query query = mock(Query.class);
            when(query.setParameter(anyString(), org.mockito.ArgumentMatchers.any()))
                    .thenReturn(query);
            when(query.getResultList()).thenReturn(List.of(
                    new Object[]{first, "AP-001", BigDecimal.ONE, new BigDecimal("2.5")},
                    new Object[]{second, "AP-002", BigDecimal.ZERO, new BigDecimal("1")}));
            return query;
        });
        SupplierPayableHoldGuard guard = new SupplierPayableHoldGuard(em);

        Map<UUID, SupplierPayableHoldGuard.HoldInfo> infos =
                guard.holdInfos(List.of(first, second));

        assertThat(infos).hasSize(2);
        assertThat(infos.get(first).held()).isTrue();
        assertThat(infos.get(first).failedBaseQty()).isEqualByComparingTo("2.5");
        assertThat(infos.get(second).reason()).contains("AP-002");
    }

    private static EntityManager holdEntityManager(
            List<NativeCall> calls, UUID ledgerId) {
        EntityManager em = mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = compact(invocation.getArgument(0));
            Map<String, Object> parameters = new LinkedHashMap<>();
            calls.add(new NativeCall(sql, parameters));
            Query query = mock(Query.class);
            when(query.setParameter(anyString(), org.mockito.ArgumentMatchers.any()))
                    .thenAnswer(argument -> {
                        parameters.put(argument.getArgument(0), argument.getArgument(1));
                        return query;
                    });
            when(query.getResultList()).thenAnswer(ignored ->
                    parameters.get("allowedCaseId") == null
                            ? java.util.Collections.singletonList(new Object[]{
                                    ledgerId, "AP-IQC-001",
                                    BigDecimal.ZERO, new BigDecimal("2")})
                            : List.of());
            return query;
        });
        return em;
    }

    private static String compact(String sql) {
        return sql.replaceAll("\\s+", " ").trim().toLowerCase();
    }

    private record NativeCall(String sql, Map<String, Object> parameters) {
    }
}
