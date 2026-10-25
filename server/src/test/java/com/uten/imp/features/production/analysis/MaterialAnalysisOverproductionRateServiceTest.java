package com.uten.imp.features.production.analysis;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.execution.ProductionOverproductionRateService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class MaterialAnalysisOverproductionRateServiceTest {
    @Test void planAddedWhileWaitingForSharedAnalysisLockRejectsWholeRateChange() {
        EntityManager em=mock(EntityManager.class);
        var analyses=mock(MaterialAnalysisService.class);
        var rates=mock(ProductionOverproductionRateService.class);
        Query count=mock(Query.class),plans=mock(Query.class),command=mock(Query.class);
        routeQueries(em, count, plans, command);
        when(count.setParameter(anyString(),any())).thenReturn(count);
        when(plans.setParameter(anyString(),any())).thenReturn(plans);
        when(command.setParameter(anyString(),any())).thenReturn(command);
        when(command.getResultList()).thenReturn(List.of());
        when(count.getSingleResult()).thenReturn(1L);
        UUID analysis=UUID.randomUUID(),source=UUID.randomUUID(),oldPlan=UUID.randomUUID(),newPlan=UUID.randomUUID();
        when(plans.getResultList()).thenReturn(List.of(oldPlan),List.of(oldPlan,newPlan));
        doAnswer(call->{
            // Simulates beginPlans waiting behind a generate command: the generation
            // commits another exact-source plan before the analysis lock is acquired.
            call.<Runnable>getArgument(4).run();
            throw new AssertionError("a stale source set must abort before any allowance ledger write");
        }).when(rates).changePlanningRates(anyCollection(),anyList(),any(),anyString(),any());
        var actor=mock(SecurityContextCurrentUser.class);
        when(actor.requireId()).thenReturn(UUID.randomUUID());
        var service=new MaterialAnalysisOverproductionRateService(em,analyses,rates,actor,mock(TxSessionVars.class),new ObjectMapper());
        assertThrows(ApiException.class,()->service.change(analysis,Set.of(source),
                List.of(new ProductionOverproductionRateService.PlanningRateVersion(UUID.randomUUID(),0)),
                new BigDecimal(".2"),"rate-plan-race-test"));
        verify(analyses,times(2)).requireReadableAnalysis(analysis);
        verify(analyses,times(2)).requireWritableAnalysis(analysis);
        verify(plans,times(2)).getResultList();
        verify(count,times(2)).setParameter("analysis",analysis);
        verify(count,times(2)).setParameter("sources",Set.of(source));
        verify(plans,times(2)).setParameter("analysis",analysis);
        verify(plans,times(2)).setParameter("sources",Set.of(source));
    }

    @Test void sourceFromAnotherAnalysisIsRejectedBeforeTaskProjection() {
        EntityManager em=mock(EntityManager.class);
        var analyses=mock(MaterialAnalysisService.class);
        var rates=mock(ProductionOverproductionRateService.class);
        Query count=mock(Query.class);
        routeQueries(em, count, null, null);
        when(count.setParameter(anyString(),any())).thenReturn(count);
        when(count.getSingleResult()).thenReturn(0L);
        var service=new MaterialAnalysisOverproductionRateService(em,analyses,rates,mock(SecurityContextCurrentUser.class),mock(TxSessionVars.class),new ObjectMapper());
        UUID analysis=UUID.randomUUID(),source=UUID.randomUUID();
        assertThrows(ApiException.class,()->service.context(analysis,Set.of(source)));
        verify(count).setParameter("analysis",analysis);
        verify(count).setParameter("sources",Set.of(source));
        verifyNoInteractions(rates);
    }

    @Test void readOnlySharedAnalysisCannotAdvertiseOrExecutePlanningEdit() {
        EntityManager em=mock(EntityManager.class);
        var analyses=mock(MaterialAnalysisService.class);
        var rates=mock(ProductionOverproductionRateService.class);
        Query count=mock(Query.class),plans=mock(Query.class);
        routeQueries(em, count, plans, null);
        when(count.setParameter(anyString(),any())).thenReturn(count);
        when(plans.setParameter(anyString(),any())).thenReturn(plans);
        when(count.getSingleResult()).thenReturn(1L);
        UUID analysis=UUID.randomUUID(),source=UUID.randomUUID(),plan=UUID.randomUUID(),segment=UUID.randomUUID();
        when(plans.getResultList()).thenReturn(List.of(plan));
        when(rates.planningRates(List.of(plan))).thenReturn(List.of(
                new ProductionOverproductionRateService.PlanningRate(segment,plan,new BigDecimal(".1"),0,true,null)));
        when(analyses.canWriteAnalysis(analysis)).thenReturn(false);
        doThrow(new ApiException(com.uten.imp.common.web.ErrorCode.FORBIDDEN,"仅共享查看"))
                .when(analyses).requireWritableAnalysis(analysis);
        var service=new MaterialAnalysisOverproductionRateService(em,analyses,rates,mock(SecurityContextCurrentUser.class),mock(TxSessionVars.class),new ObjectMapper());
        org.junit.jupiter.api.Assertions.assertFalse(service.context(analysis,Set.of(source)).getFirst().canEdit());
        assertThrows(ApiException.class,()->service.change(analysis,Set.of(source),
                List.of(new ProductionOverproductionRateService.PlanningRateVersion(segment,0)),new BigDecimal(".2"),"readonly-share-rate-test"));
        verify(count,times(2)).setParameter("analysis",analysis);
        verify(count,times(2)).setParameter("sources",Set.of(source));
        verify(plans,times(2)).setParameter("analysis",analysis);
        verify(plans,times(2)).setParameter("sources",Set.of(source));
        verify(rates,never()).changePlanningRates(anyCollection(),anyList(),any(),anyString(),any());
    }

    private static void routeQueries(EntityManager em, Query count, Query plans, Query command) {
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            if (sql.startsWith("SELECT COUNT(*) FROM production_material_analysis_items")) {
                assertThat(sql).contains("analysis_id=:analysis AND id IN (:sources) AND NOT is_deleted");
                return count;
            }
            if (plans != null && sql.startsWith("SELECT id FROM ")
                    && sql.contains("material_analysis_item_id IN (:sources)")) {
                assertThat(sql)
                        .contains("(SELECT * FROM production_plans archive_origin WHERE"
                                + " NULLIF(to_jsonb(archive_origin)->>'legacy_id','') IS NULL"
                                + " AND NULLIF(to_jsonb(archive_origin)->>'legacy_import_run_id','') IS NULL"
                                + " AND NOT fn_imported_business_document('production_plans',archive_origin.id))")
                        .contains("WHERE material_analysis_id=:analysis")
                        .contains("AND NOT is_deleted")
                        .contains("status IN(0,1) AND NOT is_canceled ORDER BY id");
                return plans;
            }
            if (command != null && sql.equals("SELECT pg_advisory_xact_lock(hashtextextended(:key,0))")) {
                return command;
            }
            if (command != null && sql.startsWith("SELECT request_hash FROM production_material_analysis_commands")) {
                assertThat(sql).contains("analysis_id=:analysis AND operation='OVERPRODUCTION_RATE' AND idempotency_key=:key");
                return command;
            }
            throw new AssertionError("Unexpected rate-change SQL: " + sql);
        });
    }
}
