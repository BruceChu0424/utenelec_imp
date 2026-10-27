package com.uten.imp.features.subcontract.draw;

import com.uten.imp.common.finance.ProcurementDeliveryDifference;
import com.uten.imp.features.subcontract.SubcontractDocumentAccessPolicy;
import com.uten.imp.security.DocumentAccessPolicy;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import java.math.BigDecimal;
import java.util.Collections;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.*;

class SubcontractDrawDeliveryDifferenceTest {
    @Test void taskUsesExactOrderDeliveryFactAndExistingReadableOwnerScope() {
        var fixture = fixture(true, new BigDecimal("-9007199254740993.0001"));
        var task = fixture.service.tasks(1, 20, "", "", null, List.of()).page().getItems().getFirst();
        assertThat(task.getDifferenceQtyExact()).isEqualTo("-9007199254740993.0001");
        assertThat(task.unitName()).isEqualTo("套");
        assertThat(task.shortQty()).isEqualByComparingTo("0");
        var sql = ArgumentCaptor.forClass(String.class);
        verify(fixture.em).createNativeQuery(sql.capture());
        assertThat(sql.getValue()).contains(
                ProcurementDeliveryDifference.sql("oi.qty", "oi.received_qty", "oi.returned_qty") + " AS difference_qty",
                "page.difference_qty", "o.maker_id IN (:readOwners)");
        verify(fixture.query).setParameter("readOwners", Set.of(fixture.owner));
    }

    @Test void unavailableAndUnauthorizedFactsStayUnknownInsteadOfUsingDrawShortage() {
        for (var fixture : List.of(fixture(true, null), fixture(false, new BigDecimal("-10")))) {
            var task = fixture.service.tasks(1, 20, "", "", null, List.of()).page().getItems().getFirst();
            assertThat(task.differenceQty()).isNull();
            assertThat(task.getDifferenceQtyExact()).isNull();
        }
    }

    private static Fixture fixture(boolean canView, BigDecimal difference) {
        var em = mock(EntityManager.class);
        var query = mock(Query.class);
        var access = mock(SubcontractDocumentAccessPolicy.class);
        UUID owner = UUID.randomUUID();
        when(access.nativeReadScope("o.maker_id", "readOwners")).thenReturn(
                new DocumentAccessPolicy.NativeReadScope("o.maker_id IN (:readOwners)", "readOwners", Set.of(owner)));
        when(access.hasAuthority("subcontract_order:view")).thenReturn(canView);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        Object[] row = new Object[34];
        row[4] = 1L; row[5] = 1L;
        int offset = 6;
        row[offset] = UUID.randomUUID(); row[offset + 1] = UUID.randomUUID();
        row[offset + 2] = "WW-1"; row[offset + 3] = 1;
        row[offset + 12] = "套";
        row[offset + 13] = BigDecimal.TEN;
        row[offset + 14] = BigDecimal.TEN;
        row[offset + 15] = BigDecimal.ZERO;
        row[offset + 16] = BigDecimal.ZERO;
        row[offset + 17] = BigDecimal.ZERO;
        row[offset + 18] = 1; row[offset + 19] = 1; row[offset + 20] = 0;
        row[offset + 21] = "DRAW_SUBMITTED"; row[offset + 23] = owner;
        row[offset + 24] = BigDecimal.TEN; row[offset + 25] = "WL-1";
        row[offset + 26] = new UUID[0]; row[offset + 27] = difference;
        when(query.getResultList()).thenReturn(Collections.singletonList(row));
        return new Fixture(new SubcontractDrawQueryService(em, access), em, query, owner);
    }

    private record Fixture(SubcontractDrawQueryService service, EntityManager em, Query query, UUID owner) { }
}
