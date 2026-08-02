package com.uten.imp.features.subcontract.application;

import com.uten.imp.application.port.ProductionSubcontractSupplyTransitionPort;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.integrity.ProductionSupplySourceGuard;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.subcontract.application.dto.DecompositionPreviewItem;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class SubcontractApplicationDecompositionPreviewTest {

    @Test
    void previewDeduplicatesAndSortsIdsAndSubtractsPendingFinanceOccupancy() {
        Fixture fixture = new Fixture();
        UUID item1 = UUID.fromString("00000000-0000-0000-0000-000000000001");
        UUID item2 = UUID.fromString("00000000-0000-0000-0000-000000000002");
        UUID applicationId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        List<Object[]> rows = new ArrayList<>();
        rows.add(row(applicationId, "WS-1", item2, goodsId, unitId,
                "10", "2", "4", warehouseId, "PP-2"));
        rows.add(row(applicationId, "WS-1", item1, goodsId, unitId,
                "6", "1", "0", warehouseId, "PP-1"));
        when(fixture.query.getResultList()).thenReturn(rows);

        List<DecompositionPreviewItem> result = fixture.service.decompositionPreview(
                List.of(item2, item1, item2));

        assertThat(result).extracting(DecompositionPreviewItem::sourceItemId)
                .containsExactly(item1, item2);
        assertThat(result.get(1).pendingQty()).isEqualByComparingTo("4");
        assertThat(result.get(1).remainingQty()).isEqualByComparingTo("4");
        verify(fixture.query).setParameter("itemIds", List.of(item1, item2));
        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(fixture.em).createNativeQuery(sql.capture());
        assertThat(sql.getValue())
                .contains("procurement_order_approval_cases")
                .contains("order_type = 'SUBCONTRACT'")
                .contains("status = 'PENDING'")
                .doesNotContain("supplier_id", "price", "amount_original", "amount_local");
    }

    @Test
    void anyMissingOrUnavailableLineFailsTheWholePreview() {
        Fixture fixture = new Fixture();
        when(fixture.query.getResultList()).thenReturn(List.of());

        assertThatThrownBy(() -> fixture.service.decompositionPreview(
                List.of(UUID.randomUUID(), UUID.randomUUID())))
                .isInstanceOfSatisfying(ApiException.class, error ->
                        assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT));
    }

    @Test
    void differentWarehousesFailTheWholePreview() {
        Fixture fixture = new Fixture();
        UUID item1 = UUID.fromString("00000000-0000-0000-0000-000000000001");
        UUID item2 = UUID.fromString("00000000-0000-0000-0000-000000000002");
        UUID applicationId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        List<Object[]> rows = new ArrayList<>();
        rows.add(row(applicationId, "WS-1", item1, goodsId, unitId,
                "5", "0", "0", UUID.randomUUID(), "PP-1"));
        rows.add(row(applicationId, "WS-1", item2, goodsId, unitId,
                "5", "0", "0", UUID.randomUUID(), "PP-1"));
        when(fixture.query.getResultList()).thenReturn(rows);

        assertThatThrownBy(() -> fixture.service.decompositionPreview(List.of(item1, item2)))
                .isInstanceOfSatisfying(ApiException.class, error -> {
                    assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT);
                    assertThat(error.getMessage()).isEqualTo("不同仓库请分别生成订货单");
                });
    }

    private static Object[] row(
            UUID applicationId,
            String applicationNo,
            UUID itemId,
            UUID goodsId,
            UUID unitId,
            String requested,
            String ordered,
            String pending,
            UUID warehouseId,
            String sourcePlanNo) {
        return new Object[]{
                applicationId, applicationNo, itemId, goodsId, null, unitId,
                BigDecimal.ONE, new BigDecimal(requested), new BigDecimal(ordered),
                new BigDecimal(pending), LocalDate.of(2026, 8, 20), warehouseId,
                sourcePlanNo
        };
    }

    private static final class Fixture {
        private final EntityManager em = mock(EntityManager.class);
        private final Query query = mock(Query.class);
        private final SubcontractApplicationService service;

        private Fixture() {
            when(em.createNativeQuery(anyString())).thenReturn(query);
            when(query.setParameter(anyString(), any())).thenReturn(query);
            service = new SubcontractApplicationService(
                    mock(SubcontractApplicationRepository.class),
                    mock(SubcontractApplicationItemRepository.class),
                    mock(TxSessionVars.class),
                    mock(DocNumberService.class),
                    em,
                    mock(SecurityContextCurrentUser.class),
                    mock(EmployeeNameResolver.class),
                    mock(ProductionSubcontractSupplyTransitionPort.class),
                    mock(ProductionSupplySourceGuard.class));
        }
    }
}
