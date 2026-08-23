package com.uten.imp.features.production.analysis;

import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
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
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class PreplanReallocationRestoreRevokeServiceTest {

    @Test
    void restoredTargetLotCanBeReleasedAndOriginalOutIsRestored() {
        UUID reallocationId = UUID.randomUUID();
        UUID fromAnalysisId = UUID.randomUUID();
        UUID fromMaterialId = UUID.randomUUID();
        UUID toAnalysisId = UUID.randomUUID();
        UUID toMaterialId = UUID.randomUUID();
        UUID reservationId = UUID.randomUUID();
        UUID outEventId = UUID.randomUUID();
        UUID exactPegId = UUID.randomUUID();
        UUID restoredLotId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID colorId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        UUID eventGroupId = UUID.randomUUID();

        Query header = rows(List.<Object[]>of(new Object[]{new BigDecimal("4")}));
        Query roots = rows(List.<Object[]>of(new Object[]{
                reservationId, outEventId, exactPegId, new BigDecimal("4")
        }));
        Query current = rows(List.<Object[]>of(new Object[]{
                restoredLotId, UUID.randomUUID(), reservationId,
                toAnalysisId, toMaterialId, "RESTORE", reallocationId,
                exactPegId, new BigDecimal("4"), goodsId, colorId, warehouseId
        }));

        List<Map<String, Object>> inserted = new ArrayList<>();
        Map<String, Object> pending = new LinkedHashMap<>();
        Query insert = mock(Query.class);
        when(insert.setParameter(anyString(), any())).thenAnswer(invocation -> {
            pending.put(invocation.getArgument(0), invocation.getArgument(1));
            return insert;
        });
        when(insert.executeUpdate()).thenAnswer(ignored -> {
            inserted.add(new LinkedHashMap<>(pending));
            pending.clear();
            return 1;
        });
        Query replay = mock(Query.class);
        when(replay.setParameter(anyString(), any())).thenReturn(replay);
        when(replay.getResultList()).thenAnswer(ignored -> {
            Map<String, Object> value = inserted.getLast();
            return List.<Object[]>of(new Object[]{
                    value.get("id"), value.get("eventGroupId"),
                    value.get("reservationId"), value.get("analysisId"),
                    value.get("materialId"), value.get("eventType"),
                    value.get("qty"), value.get("sourceEventId"),
                    value.get("reallocationId"), value.get("exactPegId"),
                    value.get("receiptType"), value.get("receiptId"),
                    value.get("dispositionEventId"),
                    value.get("stockDocumentId"),
                    value.get("stockDocumentItemId"),
                    value.get("packageId"), value.get("demandId"),
                    value.get("targetReservationId"),
                    value.get("counterEventId")
            });
        });

        List<String> sql = new ArrayList<>();
        EntityManager em = mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String statement = invocation.getArgument(0, String.class);
            sql.add(statement);
            if (statement.contains("SELECT qty")
                    && statement.contains("preplan_material_reallocations")) {
                return header;
            }
            if (statement.contains("SELECT incoming.stock_reservation_id")) {
                return roots;
            }
            if (statement.contains("SELECT positive.id")
                    && statement.contains(
                    "positive.event_type IN ('REALLOCATE_IN', 'RESTORE')")) {
                return current;
            }
            if (statement.contains(
                    "INSERT INTO preplan_stock_entitlement_events")) {
                return insert;
            }
            if (statement.contains("WHERE idempotency_key = :key")) {
                return replay;
            }
            throw new AssertionError("Unexpected SQL: " + statement);
        });
        SecurityContextCurrentUser currentUser =
                mock(SecurityContextCurrentUser.class);
        when(currentUser.requireId()).thenReturn(UUID.randomUUID());
        PreplanStockEntitlementService service =
                new PreplanStockEntitlementService(
                        em, currentUser, mock(TxSessionVars.class));

        service.reverseUnformalizedReallocation(
                reallocationId, fromAnalysisId, fromMaterialId,
                toAnalysisId, toMaterialId, eventGroupId,
                "revoke-after-restore");

        assertThat(inserted).hasSize(2);
        Map<String, Object> release = inserted.get(0);
        assertThat(release)
                .containsEntry("eventType", "RELEASE")
                .containsEntry("sourceEventId", restoredLotId)
                .containsEntry("analysisId", toAnalysisId)
                .containsEntry("materialId", toMaterialId)
                .containsEntry("qty", new BigDecimal("4"));
        Map<String, Object> restore = inserted.get(1);
        assertThat(restore)
                .containsEntry("eventType", "RESTORE")
                .containsEntry("counterEventId", outEventId)
                .containsEntry("analysisId", fromAnalysisId)
                .containsEntry("materialId", fromMaterialId)
                .containsEntry("reservationId", reservationId)
                .containsEntry("exactPegId", exactPegId)
                .containsEntry("qty", new BigDecimal("4"));
        assertThat(sql)
                .anySatisfy(statement -> assertThat(statement)
                        .contains("incoming.event_type = 'REALLOCATE_IN'")
                        .contains("incoming.counter_event_id IS NOT NULL"))
                .anySatisfy(statement -> assertThat(statement)
                        .contains(
                                "positive.event_type IN ('REALLOCATE_IN', 'RESTORE')")
                        .contains("positive.beneficiary_analysis_id = :toAnalysisId")
                        .contains("FOR UPDATE OF positive, reservation"));
    }

    private static Query rows(List<?> values) {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(values);
        return query;
    }
}
