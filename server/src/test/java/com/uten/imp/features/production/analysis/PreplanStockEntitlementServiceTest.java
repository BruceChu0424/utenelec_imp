package com.uten.imp.features.production.analysis;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.Map;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class PreplanStockEntitlementServiceTest {

    @Test
    void makeDelegationQuantityIsCappedByTargetHeadroomAndReplaySafe() {
        assertThat(PreplanStockEntitlementService.makeDelegationTake(
                new BigDecimal("10"), new BigDecimal("4"),
                new BigDecimal("10"))).isEqualByComparingTo("6");
        assertThat(PreplanStockEntitlementService.makeDelegationTake(
                new BigDecimal("4"), BigDecimal.ZERO,
                new BigDecimal("10"))).isEqualByComparingTo("4");
        assertThat(PreplanStockEntitlementService.makeDelegationTake(
                new BigDecimal("4"), new BigDecimal("4"),
                new BigDecimal("10"))).isZero();
    }

    @Test
    void beneficiaryLotBalanceIncludesMakeDelegateInAndConsumesMakeDelegateOut() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of());
        when(em.createNativeQuery(anyString())).thenReturn(query);
        PreplanStockEntitlementService service =
                new PreplanStockEntitlementService(
                        em, mock(SecurityContextCurrentUser.class),
                        mock(TxSessionVars.class));

        service.listAvailableBeneficiaryLots(
                UUID.randomUUID(), UUID.randomUUID(), UUID.randomUUID(),
                UUID.randomUUID(), null, false);

        org.mockito.ArgumentCaptor<String> sql =
                org.mockito.ArgumentCaptor.forClass(String.class);
        verify(em).createNativeQuery(sql.capture());
        assertThat(sql.getValue())
                .contains("'MAKE_DELEGATE_IN'")
                .contains("'MAKE_DELEGATE_OUT'");
    }

    @Test
    void formalizedMakeDelegationFailsClosedBeforeCancellationWrites() {
        EntityManager em = mock(EntityManager.class);
        Query delegations = mock(Query.class);
        Query unavailableLot = mock(Query.class);
        for (Query query : List.of(delegations, unavailableLot)) {
            when(query.setParameter(anyString(), any())).thenReturn(query);
        }
        when(delegations.getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{UUID.randomUUID(), UUID.randomUUID(),
                        UUID.randomUUID(), BigDecimal.ONE,
                        UUID.randomUUID(), UUID.randomUUID()}));
        when(unavailableLot.getResultList()).thenReturn(List.of());
        List<String> sql = new ArrayList<>();
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String value = invocation.getArgument(0);
            sql.add(value);
            if (value.contains(
                    "FROM preplan_make_entitlement_delegations delegation")) {
                return delegations;
            }
            if (value.contains("WHERE positive.id = :eventId")) {
                return unavailableLot;
            }
            throw new AssertionError("Unexpected SQL: " + value);
        });
        PreplanStockEntitlementService service =
                new PreplanStockEntitlementService(
                        em, mock(SecurityContextCurrentUser.class),
                        mock(TxSessionVars.class));

        assertThatThrownBy(() -> service.restoreMakeDelegationsForAction(
                UUID.randomUUID(), UUID.randomUUID(),
                "make-delegate-cancel-test"))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("no longer available");
        assertThat(sql).noneMatch(value ->
                value.contains("INSERT INTO preplan_stock_entitlement_events"));
    }

    @Test
    void idempotencyKeyWithDifferentPayloadFailsClosed() {
        Fixture fixture = fixture();
        Object[] conflictingReplay = fixture.originReplay(new BigDecimal("2"));
        when(fixture.replay().getResultList())
                .thenReturn(List.<Object[]>of(conflictingReplay));

        assertThatThrownBy(() -> fixture.service().appendOriginIqc(
                fixture.groupId(), fixture.reservationId(),
                fixture.analysisId(), fixture.materialId(), BigDecimal.ONE,
                fixture.exactPegId(), "PURCHASE", fixture.receiptId(),
                fixture.dispositionId(), "origin-iqc-idempotency-1"))
                .isInstanceOf(ApiException.class)
                .satisfies(error -> assertThat(((ApiException) error).getCode())
                        .isEqualTo(ErrorCode.CONFLICT))
                .hasMessageContaining("different payload");
    }

    @Test
    void originReplayReturnsExistingEventWithoutReportingANewInsert() {
        Fixture fixture = fixture();
        Object[] replay = fixture.originReplay(BigDecimal.ONE);
        when(fixture.insert().executeUpdate()).thenReturn(0);
        when(fixture.replay().getResultList())
                .thenReturn(List.<Object[]>of(replay));

        PreplanStockEntitlementService.OriginAppendResult result =
                fixture.service().appendOriginIqc(
                        fixture.groupId(), fixture.reservationId(),
                        fixture.analysisId(), fixture.materialId(),
                        BigDecimal.ONE, fixture.exactPegId(),
                        "PURCHASE", fixture.receiptId(),
                        fixture.dispositionId(),
                        "origin-iqc-idempotency-1");

        assertThat(result.eventId()).isEqualTo(replay[0]);
        assertThat(result.inserted()).isFalse();
    }

    @Test
    void manualReallocationSourceUsesOriginTerminalRestoreLineage() {
        EntityManager em = mock(EntityManager.class);
        Query query = query();
        UUID reservationId = UUID.randomUUID();
        UUID analysisId = UUID.randomUUID();
        UUID materialId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID exactPegId = UUID.randomUUID();
        when(query.getResultList()).thenReturn(List.of(
                lotRow("ORIGIN_IQC", reservationId, analysisId, materialId,
                        warehouseId, goodsId, exactPegId),
                lotRow("RESTORE", reservationId, analysisId, materialId,
                        warehouseId, goodsId, exactPegId)));
        when(em.createNativeQuery(anyString())).thenReturn(query);
        PreplanStockEntitlementService service =
                new PreplanStockEntitlementService(
                        em, mock(SecurityContextCurrentUser.class),
                        mock(TxSessionVars.class));

        List<PreplanStockEntitlementService.AvailableLot> result =
                service.listAvailableOriginalLots(
                        analysisId, materialId, warehouseId,
                        goodsId, null, false);

        assertThat(result)
                .extracting(PreplanStockEntitlementService.AvailableLot
                        ::originEventType)
                .containsExactly("ORIGIN_IQC", "RESTORE");
        org.mockito.ArgumentCaptor<String> sql =
                org.mockito.ArgumentCaptor.forClass(String.class);
        verify(em).createNativeQuery(sql.capture());
        assertThat(sql.getValue())
                .contains("WITH RECURSIVE entitlement_lineage")
                .contains("current_positive.event_type IN (")
                .contains("'RESTORE', 'MAKE_DELEGATE_IN'")
                .contains("current_positive.counter_event_id")
                .contains("counter_negative.source_entitlement_event_id")
                .contains("lineage.depth < 64")
                .contains("positive.event_type IN ('RESTORE', 'MAKE_DELEGATE_IN')")
                .contains("'REALLOCATE_IN', 'PRIORITY_IN'");
    }

    @Test
    void prioritySatisfiedInPlacePersistsNeutralEventAgainstSourceLot() {
        Fixture fixture = fixture();
        UUID reallocationId = UUID.randomUUID();
        PreplanStockEntitlementService.AvailableLot source =
                new PreplanStockEntitlementService.AvailableLot(
                        fixture.sourceEventId(), fixture.groupId(),
                        fixture.reservationId(), fixture.analysisId(),
                        fixture.materialId(), "ORIGIN_IQC", null,
                        fixture.exactPegId(), BigDecimal.ONE,
                        UUID.randomUUID(), null, UUID.randomUUID());
        Object[] replay = new Object[]{
                UUID.randomUUID(), fixture.groupId(), fixture.reservationId(),
                fixture.analysisId(), fixture.materialId(),
                "PRIORITY_SATISFIED_IN_PLACE", BigDecimal.ONE,
                fixture.sourceEventId(), reallocationId, null,
                null, null, null, null, null, null, null, null, null
        };
        when(fixture.replay().getResultList())
                .thenReturn(List.<Object[]>of(replay));

        fixture.service().appendPrioritySatisfiedInPlace(
                fixture.groupId(), source, reallocationId, BigDecimal.ONE,
                "priority-in-place-idempotency-1");

        verify(fixture.insert()).setParameter(
                "eventType", "PRIORITY_SATISFIED_IN_PLACE");
        verify(fixture.insert()).setParameter(
                "sourceEventId", fixture.sourceEventId());
    }

    @Test
    void beneficiaryReleaseWritesEveryLotAndAggregatesPhysicalReservationQty() {
        UUID analysisId = UUID.randomUUID();
        UUID materialA = UUID.randomUUID();
        UUID materialB = UUID.randomUUID();
        UUID reservationA = UUID.randomUUID();
        UUID reservationB = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        UUID eventA1 = UUID.randomUUID();
        UUID eventA2 = UUID.randomUUID();
        UUID eventB = UUID.randomUUID();
        UUID groupId = UUID.randomUUID();

        Query lots = query();
        when(lots.getResultList()).thenReturn(List.of(
                activeLotRow(
                        eventA1, groupId, reservationA, analysisId, materialA,
                        "ORIGIN_IQC", null, new BigDecimal("2"),
                        goodsId, warehouseId),
                activeLotRow(
                        eventA2, groupId, reservationA, analysisId, materialA,
                        "RESTORE", UUID.randomUUID(), new BigDecimal("3"),
                        goodsId, warehouseId),
                activeLotRow(
                        eventB, groupId, reservationB, analysisId, materialB,
                        "REALLOCATE_IN", UUID.randomUUID(), BigDecimal.ONE,
                        goodsId, warehouseId)));

        Query insert = mock(Query.class);
        Map<String, Object> current = new HashMap<>();
        List<Map<String, Object>> persisted = new ArrayList<>();
        when(insert.setParameter(anyString(), any())).thenAnswer(invocation -> {
            current.put(invocation.getArgument(0, String.class),
                    invocation.getArgument(1));
            return insert;
        });
        when(insert.executeUpdate()).thenAnswer(ignored -> {
            persisted.add(new HashMap<>(current));
            return 1;
        });
        Query replay = query();
        when(replay.getResultList()).thenAnswer(ignored ->
                List.<Object[]>of(eventReplayRow(persisted.getLast())));

        EntityManager em = mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0, String.class);
            if (sql.contains("ORDER BY reservation.created_at")) return lots;
            if (sql.contains(
                    "INSERT INTO preplan_stock_entitlement_events")) {
                return insert;
            }
            if (sql.contains("WHERE idempotency_key = :key")) return replay;
            throw new AssertionError("Unexpected entitlement SQL: " + sql);
        });
        SecurityContextCurrentUser currentUser =
                mock(SecurityContextCurrentUser.class);
        when(currentUser.requireId()).thenReturn(UUID.randomUUID());
        PreplanStockEntitlementService service =
                new PreplanStockEntitlementService(
                        em, currentUser, mock(TxSessionVars.class));

        List<PreplanStockEntitlementService.ReservationRelease> releases =
                service.appendReleaseForBeneficiaryAnalysis(
                        analysisId, groupId, "ANALYSIS-CANCEL-AGGREGATE-1");

        assertThat(releases).hasSize(2);
        assertThat(releases).anySatisfy(release -> {
            assertThat(release.stockReservationId()).isEqualTo(reservationA);
            assertThat(release.qty()).isEqualByComparingTo("5");
        }).anySatisfy(release -> {
            assertThat(release.stockReservationId()).isEqualTo(reservationB);
            assertThat(release.qty()).isEqualByComparingTo("1");
        });
        assertThat(persisted).hasSize(3);
        assertThat(persisted)
                .extracting(parameters -> parameters.get("eventType"))
                .containsOnly("RELEASE");
        assertThat(persisted)
                .extracting(parameters -> parameters.get("sourceEventId"))
                .containsExactly(eventA1, eventA2, eventB);
        assertThat(persisted)
                .extracting(parameters -> parameters.get("analysisId"))
                .containsOnly(analysisId);
    }

    private static Object[] activeLotRow(
            UUID eventId,
            UUID eventGroupId,
            UUID reservationId,
            UUID analysisId,
            UUID materialId,
            String eventType,
            UUID reallocationId,
            BigDecimal qty,
            UUID goodsId,
            UUID warehouseId) {
        return new Object[]{
                eventId, eventGroupId, reservationId,
                analysisId, materialId, eventType, reallocationId,
                UUID.randomUUID(), qty, goodsId, null, warehouseId
        };
    }

    private static Object[] eventReplayRow(Map<String, Object> parameters) {
        return new Object[]{
                parameters.get("id"),
                parameters.get("eventGroupId"),
                parameters.get("reservationId"),
                parameters.get("analysisId"),
                parameters.get("materialId"),
                parameters.get("eventType"),
                parameters.get("qty"),
                parameters.get("sourceEventId"),
                parameters.get("reallocationId"),
                parameters.get("exactPegId"),
                parameters.get("receiptType"),
                parameters.get("receiptId"),
                parameters.get("dispositionEventId"),
                parameters.get("stockDocumentId"),
                parameters.get("stockDocumentItemId"),
                parameters.get("packageId"),
                parameters.get("demandId"),
                parameters.get("targetReservationId"),
                parameters.get("counterEventId")
        };
    }
    @Test
    void activeFormalizationBlocksCancellationEvenAfterTargetWasFullyReleased() {
        EntityManager em = mock(EntityManager.class);
        Query query = query();
        when(query.getResultList()).thenReturn(List.<Object[]>of(new Object[]{
                UUID.randomUUID(), BigDecimal.ZERO,
                BigDecimal.TEN, BigDecimal.TEN
        }));
        when(em.createNativeQuery(anyString())).thenReturn(query);
        PreplanStockEntitlementService service =
                new PreplanStockEntitlementService(
                        em, mock(SecurityContextCurrentUser.class),
                        mock(TxSessionVars.class));

        assertThatThrownBy(() ->
                service.requireNoActiveFormalizationForBeneficiary(
                        UUID.randomUUID(), true))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("RESTORE");
        org.mockito.ArgumentCaptor<String> sql =
                org.mockito.ArgumentCaptor.forClass(String.class);
        verify(em).createNativeQuery(sql.capture());
        assertThat(sql.getValue())
                .contains("formalize.beneficiary_analysis_id = :analysisId")
                .contains("restored.counter_event_id = formalize.id")
                .contains(
                        "FOR UPDATE OF formalize, source_lot, target_reservation");
    }

    @Test
    void restoredFormalizationQueryIsEmptyAndNoLongerBlocksCancellation() {
        EntityManager em = mock(EntityManager.class);
        Query query = query();
        when(query.getResultList()).thenReturn(List.of());
        when(em.createNativeQuery(anyString())).thenReturn(query);
        PreplanStockEntitlementService service =
                new PreplanStockEntitlementService(
                        em, mock(SecurityContextCurrentUser.class),
                        mock(TxSessionVars.class));

        service.requireNoActiveFormalizationForBeneficiary(
                UUID.randomUUID(), true);

        verify(query).getResultList();
    }

    @Test
    void activeFormalizationQueryMapsReallocationBeforeExactPeg() {
        UUID formalizeId = UUID.randomUUID();
        UUID sourceReservationId = UUID.randomUUID();
        UUID analysisId = UUID.randomUUID();
        UUID materialId = UUID.randomUUID();
        UUID sourceEventId = UUID.randomUUID();
        UUID exactPegId = UUID.randomUUID();
        UUID reallocationId = UUID.randomUUID();
        UUID packageId = UUID.randomUUID();
        UUID demandId = UUID.randomUUID();
        UUID targetReservationId = UUID.randomUUID();
        Query query = query();
        when(query.getResultList()).thenReturn(List.<Object[]>of(new Object[]{
                formalizeId, sourceReservationId, analysisId, materialId,
                BigDecimal.ONE, sourceEventId, exactPegId, reallocationId,
                packageId, demandId, targetReservationId,
                BigDecimal.ZERO, BigDecimal.ONE, BigDecimal.ONE
        }));
        EntityManager em = mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        PreplanStockEntitlementService service =
                new PreplanStockEntitlementService(
                        em, mock(SecurityContextCurrentUser.class),
                        mock(TxSessionVars.class));

        PreplanStockEntitlementService.Formalization result =
                service.listActiveFormalizations(
                        List.of(targetReservationId), false).getFirst();

        assertThat(result.formalizeEventId()).isEqualTo(formalizeId);
        assertThat(result.sourceEntitlementEventId()).isEqualTo(sourceEventId);
        assertThat(result.reallocationId()).isEqualTo(reallocationId);
        assertThat(result.sourceExactPegId()).isEqualTo(exactPegId);
        assertThat(result.targetStockReservationId())
                .isEqualTo(targetReservationId);
    }

    private static Fixture fixture() {
        EntityManager em = mock(EntityManager.class);
        Query insert = query();
        Query replay = query();
        when(insert.executeUpdate()).thenReturn(1);
        when(em.createNativeQuery(anyString())).thenAnswer(invocation ->
                invocation.<String>getArgument(0).contains(
                        "INSERT INTO preplan_stock_entitlement_events")
                        ? insert : replay);
        SecurityContextCurrentUser currentUser =
                mock(SecurityContextCurrentUser.class);
        when(currentUser.requireId()).thenReturn(UUID.randomUUID());
        return new Fixture(
                new PreplanStockEntitlementService(
                        em, currentUser, mock(TxSessionVars.class)),
                insert, replay,
                UUID.randomUUID(), UUID.randomUUID(), UUID.randomUUID(),
                UUID.randomUUID(), UUID.randomUUID(), UUID.randomUUID(),
                UUID.randomUUID(), UUID.randomUUID());
    }

    private static Query query() {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        return query;
    }

    private static Object[] lotRow(
            String eventType, UUID reservationId,
            UUID analysisId, UUID materialId,
            UUID warehouseId, UUID goodsId, UUID exactPegId) {
        return new Object[]{
                UUID.randomUUID(), UUID.randomUUID(), reservationId,
                analysisId, materialId, eventType, null, exactPegId,
                BigDecimal.ONE, goodsId, null, warehouseId
        };
    }

    private record Fixture(
            PreplanStockEntitlementService service,
            Query insert,
            Query replay,
            UUID groupId,
            UUID reservationId,
            UUID analysisId,
            UUID materialId,
            UUID exactPegId,
            UUID receiptId,
            UUID dispositionId,
            UUID sourceEventId) {
        Object[] originReplay(BigDecimal qty) {
            return new Object[]{
                    UUID.randomUUID(), groupId, reservationId,
                    analysisId, materialId, "ORIGIN_IQC", qty,
                    null, null, exactPegId,
                    "PURCHASE", receiptId, dispositionId,
                    null, null, null, null, null, null
            };
        }
    }
}
