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
                .filter(call -> call.sql().contains("fn_procurement_iqc_ap_hold_reason"))
                .toList();
        assertThat(holdQueries).hasSize(2);
        assertThat(holdQueries.get(0).parameters())
                .containsEntry("allowedCaseId", allowedCaseId);
        assertThat(holdQueries.get(1).parameters())
                .containsEntry("allowedCaseId", null);
        assertThat(holdQueries.get(0).sql())
                .contains("fn_procurement_iqc_ap_hold_reason(ledger.id,cast(:allowedcaseid as uuid)) is not null")
                .contains("source_ap_ledger_id=ledger.id and parent_funding_slice_id is null")
                .contains("fn_procurement_consideration_active('funding',id)")
                .contains("receipt_type||'_receipt'=ledger.source_doc_type and status<>'reversed'");
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
            when(query.getSingleResult()).thenAnswer(ignored -> {
                boolean sameCase = caseId.equals(parameters.get("caseId"));
                if (sql.contains("fn_procurement_iqc_slice_offset_authorized")) {
                    @SuppressWarnings("unchecked")
                    List<UUID> targets = (List<UUID>) parameters.get("targets");
                    return sameCase && creditLedgerId.equals(parameters.get("source"))
                            && targets.contains(targetLedgerId) ? 1L : 0L;
                }
                return 0L;
            });
            return query;
        });
        SupplierPayableHoldGuard guard = new SupplierPayableHoldGuard(em);

        assertThat(guard.authorizedIqcCreditOffset(
                caseId, creditLedgerId, List.of(targetLedgerId))).isTrue();
        assertThat(guard.authorizedIqcCreditOffset(
                caseId, creditLedgerId, List.of(targetLedgerId, UUID.randomUUID()))).isFalse();

        assertThat(calls).hasSize(2);
        NativeCall authorization = calls.getFirst();
        assertThat(authorization.parameters())
                .containsEntry("caseId", caseId)
                .containsEntry("source", creditLedgerId)
                .containsEntry("targets", List.of(targetLedgerId));
        assertThat(authorization.sql())
                .contains("count(distinct funding.source_ap_ledger_id)")
                .contains("funding.id=credit.funding_slice_id")
                .contains("credit.case_id=:caseid")
                .contains("funding.source_ap_ledger_id in (:targets)")
                .contains("fn_procurement_iqc_slice_offset_authorized(:caseid,:source,funding.source_ap_ledger_id)");
        assertThat(guard.authorizedIqcCreditOffset(
                UUID.randomUUID(), creditLedgerId, List.of(targetLedgerId))).isFalse();
        assertThat(guard.authorizedIqcCreditOffset(
                caseId, UUID.randomUUID(), List.of(targetLedgerId))).isFalse();
        assertThat(guard.authorizedIqcCreditOffset(
                caseId, creditLedgerId, List.of(UUID.randomUUID()))).isFalse();
        assertThat(calls.stream().filter(call -> call.sql().contains("from procurement_iqc_rejection_cases")))
                .hasSize(3).allSatisfy(call -> assertThat(call.sql())
                        .contains("rejection.status='return_recorded'")
                        .contains("rejection.source_ap_ledger_id=:targetledgerid")
                        .contains("credit.source_doc_id=rejection.id")
                        .contains("credit.status=1")
                        .contains("coalesce(credit.is_deleted,false)=false"));
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
