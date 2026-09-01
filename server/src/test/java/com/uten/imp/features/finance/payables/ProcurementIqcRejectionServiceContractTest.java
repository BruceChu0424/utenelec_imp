package com.uten.imp.features.finance.payables;

import com.uten.imp.application.port.BusinessOutboxDomainHandler;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.ProcurementArrivalControlPort;
import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.finance.arap.ArApLedgerService;
import com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.CaseCounts;
import com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.CaseDetail;
import com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.CaseItem;
import com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.CloseNoCreditRequest;
import com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.ConfirmCreditRequest;
import com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.RecordReturnRequest;
import com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.ReverseRequest;
import com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.RetryFinanceProjectionRequest;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.springframework.security.access.prepost.PreAuthorize;

import java.lang.reflect.Method;
import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class ProcurementIqcRejectionServiceContractTest {

    @Test
    void controllerAndServiceExposeTheCurrentDetailContractWithoutWeakeningGates()
            throws Exception {
        assertReturnType(
                ProcurementIqcRejectionService.class, "counts", CaseCounts.class,
                String.class, String.class);
        assertReturnType(
                ProcurementIqcRejectionService.class, "detail", CaseDetail.class,
                UUID.class);
        assertReturnType(
                ProcurementIqcRejectionService.class, "recordReturn", CaseDetail.class,
                UUID.class, RecordReturnRequest.class);
        assertReturnType(
                ProcurementIqcRejectionService.class, "confirmCredit", CaseDetail.class,
                UUID.class, ConfirmCreditRequest.class);
        assertReturnType(
                ProcurementIqcRejectionService.class, "closeNoCredit", CaseDetail.class,
                UUID.class, CloseNoCreditRequest.class);
        assertReturnType(
                ProcurementIqcRejectionService.class, "reverse", CaseDetail.class,
                UUID.class, ReverseRequest.class);
        assertReturnType(
                ProcurementIqcRejectionService.class,
                "retryFinanceProjection",
                CaseDetail.class,
                UUID.class,
                RetryFinanceProjectionRequest.class);

        assertGate("recordReturn", "procurement_iqc_rejection:record_return");
        assertGate("confirmCredit", "procurement_iqc_rejection:confirm_credit");
        assertGate("closeNoCredit", "procurement_iqc_rejection:close_no_credit");
        assertGate("reverse", "procurement_iqc_rejection:reverse");
        assertGate("retryFinanceProjection", "procurement_iqc_rejection:confirm_credit");
        assertThat(BusinessOutboxDomainHandler.class
                .isAssignableFrom(ProcurementIqcRejectionOutboxHandler.class))
                .isTrue();
    }

    @Test
    void detailRecordsTheResolvedBusinessReferenceWithoutWeakeningTheGate() {
        UUID caseId = UUID.randomUUID();
        ProcurementIqcRejectionService service =
                mock(ProcurementIqcRejectionService.class);
        AuditDetailViewRecorder detailViewAudit =
                mock(AuditDetailViewRecorder.class);
        CaseItem caseItem = mock(CaseItem.class);
        when(caseItem.receiptBillNo()).thenReturn("CR-IQC-001");
        CaseDetail expected = new CaseDetail(caseItem, List.of(), List.of());
        when(service.detail(caseId)).thenReturn(expected);
        ProcurementIqcRejectionController controller =
                new ProcurementIqcRejectionController(service, detailViewAudit);

        CaseDetail actual = controller.detail(caseId);

        assertThat(actual).isSameAs(expected);
        verify(detailViewAudit).record(
                "view_procurement_iqc_rejection_detail",
                "procurement_iqc_rejection_cases",
                caseId,
                "CR-IQC-001",
                null,
                "采购质检不合格闭环");
        PreAuthorize gate = Arrays.stream(
                        ProcurementIqcRejectionController.class.getDeclaredMethods())
                .filter(candidate -> candidate.getName().equals("detail"))
                .findFirst()
                .orElseThrow()
                .getAnnotation(PreAuthorize.class);
        assertThat(gate).isNotNull();
        assertThat(gate.value()).contains("procurement_iqc_rejection:view");
    }

    @Test
    void nullOutboxActorFailsBeforeBindingAnyAuditSession() {
        EntityManager em = mock(EntityManager.class);
        TxSessionVars tx = mock(TxSessionVars.class);
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        ProcurementIqcRejectionService service = service(
                em, tx, currentUser, mock(BusinessEventPublisher.class));

        assertThrows(ApiException.class, () -> service.projectDetected(
                UUID.randomUUID(),
                "PURCHASE",
                UUID.randomUUID(),
                UUID.randomUUID(),
                UUID.randomUUID(),
                null));

        verifyNoInteractions(tx, em, currentUser);
    }

    @Test
    void outboxActorIsBoundAndPersistedWithoutReadingLoginContext() {
        UUID actorId = UUID.randomUUID();
        UUID receiptId = UUID.randomUUID();
        UUID inspectionId = UUID.randomUUID();
        UUID inspectionEventId = UUID.randomUUID();
        EntityManager em = mock(EntityManager.class);
        TxSessionVars tx = mock(TxSessionVars.class);
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        BusinessEventPublisher events = mock(BusinessEventPublisher.class);
        List<NativeCall> calls = new ArrayList<>();
        stubProjectionQueries(em, calls);
        ProcurementIqcRejectionService service =
                service(em, tx, currentUser, events);

        service.projectDetected(
                UUID.randomUUID(),
                "PURCHASE",
                receiptId,
                inspectionId,
                inspectionEventId,
                actorId);

        verify(tx).bindActor(actorId);
        verifyNoInteractions(currentUser);
        assertThat(oneCall(calls, "insert into procurement_iqc_rejection_cases")
                .parameters()).containsEntry("actor", actorId);
        assertThat(oneCall(calls, "insert into procurement_iqc_rejection_events")
                .parameters()).containsEntry("actor", actorId);
    }

    @Test
    void countsKeepsOrdinaryViewRowScopedAndAllowsOnlyExplicitGlobalScope() {
        UUID ordinaryUserId = UUID.randomUUID();
        EntityManager ordinaryEm = mock(EntityManager.class);
        SecurityContextCurrentUser ordinaryCurrent =
                currentUser(ordinaryUserId, "procurement_iqc_rejection:view");
        List<NativeCall> ordinaryCalls = new ArrayList<>();
        stubCountsQuery(ordinaryEm, ordinaryCalls);
        ProcurementIqcRejectionService ordinary = service(
                ordinaryEm,
                mock(TxSessionVars.class),
                ordinaryCurrent,
                mock(BusinessEventPublisher.class));

        CaseCounts ordinaryCounts = ordinary.counts("PURCHASE", " bolt ");

        assertThat(ordinaryCounts.total()).isEqualTo(7);
        NativeCall ordinaryQuery = oneCall(
                ordinaryCalls, "count(*) filter");
        assertThat(ordinaryQuery.sql())
                .contains("rejection.owner_user_id=:currentuserid");
        assertThat(ordinaryQuery.parameters())
                .containsEntry("currentUserId", ordinaryUserId)
                .containsEntry("receiptType", "PURCHASE")
                .containsEntry("keyword", "%bolt%");

        UUID globalUserId = UUID.randomUUID();
        EntityManager globalEm = mock(EntityManager.class);
        SecurityContextCurrentUser globalCurrent =
                currentUser(globalUserId, "procurement_iqc_rejection:view_all");
        List<NativeCall> globalCalls = new ArrayList<>();
        stubCountsQuery(globalEm, globalCalls);
        ProcurementIqcRejectionService global = service(
                globalEm,
                mock(TxSessionVars.class),
                globalCurrent,
                mock(BusinessEventPublisher.class));

        global.counts(null, null);

        assertThat(oneCall(globalCalls, "count(*) filter").sql())
                .doesNotContain("owner_user_id=:currentuserid");
        verify(globalCurrent, never()).requireId();
    }

    private static void stubProjectionQueries(
            EntityManager em, List<NativeCall> calls) {
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = compact(invocation.getArgument(0));
            Map<String, Object> parameters = new LinkedHashMap<>();
            calls.add(new NativeCall(sql, parameters));
            Query query = mock(Query.class);
            when(query.setParameter(anyString(), org.mockito.ArgumentMatchers.any()))
                    .thenAnswer(argument -> {
                        parameters.put(
                                argument.getArgument(0),
                                argument.getArgument(1));
                        return query;
                    });
            when(query.getSingleResult()).thenAnswer(ignored ->
                    sql.contains("count(*)") ? 0L : null);
            when(query.getResultList()).thenAnswer(ignored -> {
                if (sql.contains("from procurement_inspection_items inspection")) {
                    return rows(sourceRow());
                }
                if(sql.contains("from procurement_inspection_events")){
                    return rows(new Object[]{"FAIL",new BigDecimal("2")});
                }
                return List.of();
            });
            when(query.executeUpdate()).thenReturn(1);
            return query;
        });
    }

    private static void stubCountsQuery(
            EntityManager em, List<NativeCall> calls) {
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = compact(invocation.getArgument(0));
            Map<String, Object> parameters = new LinkedHashMap<>();
            calls.add(new NativeCall(sql, parameters));
            Query query = mock(Query.class);
            when(query.setParameter(anyString(), org.mockito.ArgumentMatchers.any()))
                    .thenAnswer(argument -> {
                        parameters.put(
                                argument.getArgument(0),
                                argument.getArgument(1));
                        return query;
                    });
            when(query.getSingleResult()).thenReturn(new Object[]{
                    7L, 1L, 2L, 1L, 1L, 1L, 1L
            });
            return query;
        });
    }

    private static Object[] sourceRow() {
        return new Object[]{
                UUID.randomUUID(),
                new BigDecimal("10"),
                new BigDecimal("2"),
                "RESOLVED",
                UUID.randomUUID(),
                UUID.randomUUID(),
                null,
                UUID.randomUUID(),
                BigDecimal.ONE,
                new BigDecimal("10"),
                new BigDecimal("100"),
                new BigDecimal("100"),
                "CR-IQC-001",
                new BigDecimal("100"),
                new BigDecimal("100"),
                UUID.randomUUID(),
                UUID.randomUUID(),
                BigDecimal.ONE,
                BigDecimal.ZERO,
                UUID.randomUUID(),
                "CG-IQC-001",
                UUID.randomUUID()
        };
    }

    private static ProcurementIqcRejectionService service(
            EntityManager em,
            TxSessionVars tx,
            SecurityContextCurrentUser currentUser,
            BusinessEventPublisher events) {
        return new ProcurementIqcRejectionService(
                em,
                tx,
                currentUser,
                mock(ArApLedgerService.class),
                mock(SupplierOpenItemOffsetService.class),
                events,
                mock(ProcurementArrivalControlPort.class));
    }

    private static SecurityContextCurrentUser currentUser(
            UUID userId, String... permissions) {
        SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
        AuthUser auth = new AuthUser(
                userId,
                UUID.randomUUID(),
                "iqc-test",
                java.util.Set.of(),
                java.util.Set.of(permissions),
                false,
                true,
                false);
        when(current.get()).thenReturn(Optional.of(auth));
        when(current.requireId()).thenReturn(userId);
        return current;
    }

    private static void assertReturnType(
            Class<?> type,
            String name,
            Class<?> expected,
            Class<?>... parameters) throws Exception {
        assertThat(type.getDeclaredMethod(name, parameters).getReturnType())
                .isEqualTo(expected);
        assertThat(ProcurementIqcRejectionController.class
                .getDeclaredMethod(name, parameters).getReturnType())
                .isEqualTo(expected);
    }

    private static void assertGate(String name, String permission) {
        Method method = Arrays.stream(
                        ProcurementIqcRejectionController.class.getDeclaredMethods())
                .filter(candidate -> candidate.getName().equals(name))
                .findFirst()
                .orElseThrow();
        PreAuthorize gate = method.getAnnotation(PreAuthorize.class);
        assertThat(gate).isNotNull();
        assertThat(gate.value())
                .contains("procurement_iqc_rejection:view")
                .contains(permission);
    }

    private static NativeCall oneCall(
            List<NativeCall> calls, String fragment) {
        List<NativeCall> matches = calls.stream()
                .filter(call -> call.sql().contains(fragment))
                .toList();
        assertThat(matches).hasSize(1);
        return matches.getFirst();
    }

    private static String compact(String sql) {
        return sql.replaceAll("\\s+", " ").trim().toLowerCase();
    }

    private static List<Object[]> rows(Object[]... rows) {
        return Arrays.asList(rows);
    }

    private record NativeCall(String sql, Map<String, Object> parameters) {
    }
}
