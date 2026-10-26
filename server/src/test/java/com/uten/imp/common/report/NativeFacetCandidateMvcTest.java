package com.uten.imp.common.report;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.web.*;
import com.uten.imp.features.warehouse.inbound.*;
import com.uten.imp.security.*;
import jakarta.persistence.*;
import org.junit.jupiter.api.*;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.*;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

class NativeFacetCandidateMvcTest {
    private final EntityManager em=mock(EntityManager.class);
    private final Query query=mock(Query.class);
    private final ProcurementInspectionRecordQueryService service=mock(ProcurementInspectionRecordQueryService.class);
    private final ReadScopeVersionAuthority authority=mock(ReadScopeVersionAuthority.class);
    private final SecurityContextCurrentUser users=mock(SecurityContextCurrentUser.class);
    private final AuthUser actor=new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"reader",Set.of("procurement_inspection:view"),false,true,false);
    private MockMvc mvc;
    @BeforeEach void setup() {
        when(users.get()).thenReturn(Optional.of(actor));when(authority.scopeFor("native_feature",actor,false)).thenReturn("fresh-scope");
        when(em.createNativeQuery(anyString())).thenReturn(query);when(query.getParameters()).thenReturn(Set.of());
        when(query.getResultList()).thenReturn(Collections.singletonList(new Object[]{"原始单号%_",3L}));
        when(service.facets(anyString(),anyString(),any(),any(),any(),any(),any())).thenAnswer(call->{
            if(!NativeFacetCandidates.active())return Map.of("sourceNo",List.of(NativeFacets.bucket("原始单号%_",3)));
            return Map.of("sourceNo",NativeFacets.rowsOf(NativeFacets.query(em,"sourceNo","SELECT source_no,COUNT(*) FROM business_facts GROUP BY 1")));
        });
        mvc=MockMvcBuilders.standaloneSetup(new ProcurementInspectionRecordController(service,mock(AuditDetailViewRecorder.class)))
                .addInterceptors(new NativeFacetCandidateInterceptor(authority,users))
                .setControllerAdvice(new NativeFacetCandidateAdvice(),new ReportReadScopeAdvice(authority),new GlobalExceptionHandler()).build();
    }
    @Test void actualTypedHandlerAcceptsBodyFiltersReturnsOneCandidatePageAndLeavesGetShapeCompatible() throws Exception {
        mvc.perform(post("/api/procurement/inspection/records/facets").contentType(MediaType.APPLICATION_FORM_URLENCODED)
                .param("decision","FAIL").param("keyword","来源 %_ 中文").param("sourceType","PURCHASE")
                .param("__facetField","sourceNo").param("__facetKeyword","%_").param("__facetPage","2").param("__facetSize","100"))
                .andExpect(status().isOk()).andExpect(jsonPath("$.field").value("sourceNo"))
                .andExpect(jsonPath("$.items[0].value").value("原始单号%_"))
                .andExpect(jsonPath("$.items[0].count").value(3)).andExpect(jsonPath("$.page").value(2))
                .andExpect(jsonPath("$.hasMore").value(false)).andExpect(jsonPath("$.readScopeVersion").value("fresh-scope"))
                .andExpect(header().string("X-Uten-Read-Scope-Domain","native_feature:browse"));
        verify(service).facets("FAIL","来源 %_ 中文",null,null,"PURCHASE",null,null);
        assertThat(NativeFacetCandidates.active()).isFalse();
        mvc.perform(get("/api/procurement/inspection/records/facets"))
                .andExpect(status().isOk()).andExpect(jsonPath("$.sourceNo[0].value").value("原始单号%_"))
                .andExpect(jsonPath("$.items").doesNotExist());
    }
    @Test void lateRevocationReturnsTheExistingStructuredScopeErrorWithoutRecursiveAdviceOrScopeLeak() throws Exception {
        when(authority.scopeFor("native_feature",actor,false)).thenReturn("opening","revoked");
        mvc.perform(post("/api/procurement/inspection/records/facets").contentType(MediaType.APPLICATION_FORM_URLENCODED)
                .param("__facetField","sourceNo"))
                .andExpect(status().is(ErrorCode.READ_SCOPE_CHANGED.getHttpStatus())).andExpect(jsonPath("$.code").value("READ_SCOPE_CHANGED"));
        assertThat(NativeFacetCandidates.active()).isFalse();
        mvc.perform(post("/api/procurement/inspection/records/facets?keyword=private").contentType(MediaType.APPLICATION_FORM_URLENCODED).param("__facetField","sourceNo"))
                .andExpect(status().is(ErrorCode.VALIDATION_FAILED.getHttpStatus())).andExpect(jsonPath("$.code").value("VALIDATION_FAILED"));
        assertThat(NativeFacetCandidates.active()).isFalse();
    }
}
