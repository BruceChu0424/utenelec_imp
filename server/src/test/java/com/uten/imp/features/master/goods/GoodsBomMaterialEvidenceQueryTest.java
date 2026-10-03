package com.uten.imp.features.master.goods;

import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.sql.Timestamp;
import java.time.Instant;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class GoodsBomMaterialEvidenceQueryTest {
    @Test void hidesInvisibleMaterialsAndPreservesEvidenceIdentityWithoutInventingUsage() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        UUID parent = UUID.randomUUID(), material = UUID.randomUUID(), unit = UUID.randomUUID();
        UUID visible = UUID.randomUUID(), hidden = UUID.randomUUID(), color = UUID.randomUUID();
        Instant when = Instant.parse("2026-10-02T10:00:00Z");
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of(
                new Object[]{"PERIODIC_CHOICE", "CONFIRMED", material, "M1", "颗粒", color, "黑色", unit,
                        "千克", false, 1L, Timestamp.from(when), visible},
                new Object[]{"DISCOVERY_REQUEST", "PENDING", UUID.randomUUID(), "SECRET", "隐藏材料", null,
                        null, unit, "千克", true, 2L, when, hidden}));

        var evidence = new GoodsBomMaterialEvidenceQuery(em).list(parent, visible::equals);

        assertEquals(1, evidence.size());
        var row = evidence.getFirst();
        assertEquals("PERIODIC_CHOICE", row.source());
        assertEquals("CONFIRMED", row.status());
        assertEquals(material, row.componentGoodsId());
        assertEquals(color, row.colorId());
        assertEquals(unit, row.unitId());
        assertFalse(row.inBom());
        assertEquals(1, row.sourceCount());
        assertEquals(when, row.updatedAt().toInstant());
        verify(query).setParameter("goods", parent);
        verify(em, times(1)).createNativeQuery(anyString());
        verify(query, never()).executeUpdate();
    }
}
