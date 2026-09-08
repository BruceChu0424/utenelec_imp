package com.uten.imp.features.stock.allocation;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.ProductionMaterialReadAccessPolicy;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.springframework.security.access.prepost.PreAuthorize;

import java.lang.reflect.Method;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ProductionMaterialReadGuardWiringTest {

    @Test
    void returnableSourceEndpointAcceptsEitherOwningModuleViewAuthority() throws Exception {
        Method endpoint = ProductionMaterialSettlementController.class
                .getDeclaredMethod(
                        "returnableSources", UUID.class, UUID.class);
        String gate = endpoint.getAnnotation(PreAuthorize.class).value();

        assertThat(gate)
                .contains("production_plan:view")
                .contains("stock_doc:view")
                .contains("hasAnyAuthority");
    }

    @Test
    void returnableSourcesRequiresEveryProvidedParentBeforeRunningThePickerSql() {
        EntityManager em = mock(EntityManager.class);
        Query relationQuery = mock(Query.class);
        Query pickerQuery = mock(Query.class);
        when(em.createNativeQuery(anyString()))
                .thenReturn(relationQuery, pickerQuery);
        when(relationQuery.setParameter(anyString(), org.mockito.ArgumentMatchers.any()))
                .thenReturn(relationQuery);
        when(relationQuery.getResultList()).thenReturn(List.of(1));
        when(pickerQuery.setParameter(anyString(), org.mockito.ArgumentMatchers.any()))
                .thenReturn(pickerQuery);
        when(pickerQuery.getResultList()).thenReturn(List.of());
        ProductionMaterialReadAccessPolicy access =
                mock(ProductionMaterialReadAccessPolicy.class);
        UUID planId = UUID.randomUUID();
        UUID drawId = UUID.randomUUID();
        ProductionMaterialStockLedgerService service =
                new ProductionMaterialStockLedgerService(
                        em, mock(TxSessionVars.class), access);

        assertThatCode(() -> service.returnableSources(planId, drawId))
                .doesNotThrowAnyException();
        verify(access).requirePlanReadable(planId);
        verify(access).requireDrawReadable(drawId);
        verify(relationQuery).getResultList();
        verify(pickerQuery).getResultList();
    }

    @Test
    void unrelatedReadablePlanAndDrawAreNotReportedAsAnEmptyResult() {
        EntityManager em = mock(EntityManager.class);
        Query relationQuery = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(relationQuery);
        when(relationQuery.setParameter(anyString(), org.mockito.ArgumentMatchers.any()))
                .thenReturn(relationQuery);
        when(relationQuery.getResultList()).thenReturn(List.of());
        ProductionMaterialReadAccessPolicy access =
                mock(ProductionMaterialReadAccessPolicy.class);
        UUID planId = UUID.randomUUID();
        UUID drawId = UUID.randomUUID();
        ProductionMaterialStockLedgerService service =
                new ProductionMaterialStockLedgerService(
                        em, mock(TxSessionVars.class), access);

        assertThatThrownBy(() -> service.returnableSources(planId, drawId))
                .isInstanceOfSatisfying(
                        ApiException.class,
                        error -> assertThat(error.getCode())
                                .isEqualTo(ErrorCode.NOT_FOUND));
        verify(access).requirePlanReadable(planId);
        verify(access).requireDrawReadable(drawId);
        verify(relationQuery).getResultList();
        verify(em, times(1)).createNativeQuery(anyString());
    }

    @Test
    void deniedReturnableSourceStopsBeforeThePickerSql() {
        EntityManager em = mock(EntityManager.class);
        ProductionMaterialReadAccessPolicy access =
                mock(ProductionMaterialReadAccessPolicy.class);
        UUID drawId = UUID.randomUUID();
        doThrow(new ApiException(ErrorCode.NOT_FOUND, "生产领料单不存在"))
                .when(access).requireDrawReadable(drawId);
        ProductionMaterialStockLedgerService service =
                new ProductionMaterialStockLedgerService(
                        em, mock(TxSessionVars.class), access);

        assertThatThrownBy(() -> service.returnableSources(null, drawId))
                .isInstanceOf(ApiException.class);
        verify(em, never()).createNativeQuery(anyString());
    }

    @Test
    void clearanceAndSettlementSourcesBothGuardThePlanBeforeDataQueries() {
        EntityManager em = mock(EntityManager.class);
        ProductionMaterialTaskAccessPolicy access =
                mock(ProductionMaterialTaskAccessPolicy.class);
        UUID planId = UUID.randomUUID();
        doThrow(new ApiException(ErrorCode.NOT_FOUND, "生产计划不存在"))
                .when(access).readable(planId,null);
        ProductionMaterialSettlementService service =
                new ProductionMaterialSettlementService(
                        em, mock(TxSessionVars.class), access,
                        mock(com.uten.imp.features.stock.valuation.ProductionInventoryValueService.class));

        assertThatThrownBy(() -> service.clearance(planId))
                .isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> service.settlementSources(planId))
                .isInstanceOf(ApiException.class);
        verify(em, never()).createNativeQuery(anyString());
    }

    private Query emptyQuery(EntityManager em) {
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), org.mockito.ArgumentMatchers.any()))
                .thenReturn(query);
        when(query.getResultList()).thenReturn(List.of());
        return query;
    }
}
