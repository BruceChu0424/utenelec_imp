package com.uten.imp.features.expenseclaim;

import jakarta.persistence.*;
import org.junit.jupiter.api.Test;
import com.uten.imp.security.*;
import com.uten.imp.features.expenseclaim.dto.ExpenseClaimFacetsDto;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class ExpenseFacetMetadataProjectionTest {
    private final EntityManager em=mock(EntityManager.class);
    private final Query query=mock(Query.class);
    private final AuthUser actor=new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"reader",Set.of("expense:view"),false,true,false);
    private final OwnerVisibility.OwnerScope scope=new OwnerVisibility.OwnerScope(true,Set.of());
    private ExpenseApplicantQuery producer() {
        when(em.createNativeQuery(anyString())).thenReturn(query);when(query.setParameter(anyString(),any())).thenReturn(query);when(query.getResultList()).thenReturn(List.of());
        return new ExpenseApplicantQuery(em);
    }
    @Test void legacyDefaultStillExecutesItsOriginalFourMetadataQueries() {
        producer().workflowFacets(actor,scope,"browse",null,null);
        verify(em,times(4)).createNativeQuery(anyString());verify(em).createNativeQuery(contains("SELECT c.claim_no,c.claim_no,count(*)"));
    }
    @Test void nativeCallerCanRequestOnlyTheThreeStillUsedMetadataFamiliesWithoutAClaimNumberQuery() {
        var result=producer().workflowFacets(actor,scope,"browse",null,null,false);
        assertThat(result.claimNos()).isEmpty();verify(em,times(3)).createNativeQuery(anyString());verify(em,never()).createNativeQuery(contains("SELECT c.claim_no"));
    }
    @Test void abandonedMetadataCanSkipOnlyTheUnusedNumberQueryAndRetainItsCategoryAuthority() {
        var result=producer().abandonedHistoryFacets(actor.getEmployeeId(),false,false,false);
        assertThat(result.claimNos()).isEmpty();verify(em,times(1)).createNativeQuery(anyString());verify(em).createNativeQuery(contains("count(DISTINCT c.id)"));
    }
    @Test void httpMetadataAdapterPreservesTheLegacyDefaultCallAndHasOneExplicitProjectionOptOut() {
        var service=mock(ExpenseClaimService.class);var original=new ExpenseClaimFacetsDto(List.of(),List.of(),List.of(),List.of());
        when(service.facets("pending",false,false,null,null,false)).thenReturn(original);
        var controller=new ExpenseClaimController(service,mock(ExpenseClaimSettingsService.class),mock(com.uten.imp.features.expenseclaim.ocr.InvoiceRecognitionService.class),mock(com.uten.imp.audit.AuditDetailViewRecorder.class));
        assertThat(controller.facetsMetadata("pending",false,false,null,null,false,true)).isSameAs(original);
        verify(service).facets("pending",false,false,null,null,false);verify(service,never()).facets("pending",false,false,null,null,false,true);
        controller.facetsMetadata("pending",false,false,null,null,false,false);verify(service).facets("pending",false,false,null,null,false,false);
    }
}
