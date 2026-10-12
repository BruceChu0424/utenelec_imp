package com.uten.imp.features.documents;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.DocumentUnapprovalPort;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.history.DocumentHistoryMetadata;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class DocumentUnapprovalCapabilityTest {
    private final UUID original=UUID.randomUUID(),successor=UUID.randomUUID(),userId=UUID.randomUUID();
    private final DocumentUnapprovalPort adapter=mock(DocumentUnapprovalPort.class);
    private final EntityManager em=mock(EntityManager.class);
    private final SecurityContextCurrentUser user=mock(SecurityContextCurrentUser.class);
    private final DocNumberService numbers=mock(DocNumberService.class);
    private final TxSessionVars tx=mock(TxSessionVars.class);
    private final Query header=mock(Query.class),links=mock(Query.class),advisory=mock(Query.class),lineage=mock(Query.class);
    private DocumentUnapprovalService service;

    @BeforeEach void setup(){
        when(adapter.family()).thenReturn("purchaseOrder");when(adapter.permission()).thenReturn("purchase_order");
        when(adapter.header()).thenReturn(new DocumentUnapprovalPort.TableSnapshot("purchase_orders",null,List.of(),true,false));
        when(adapter.detail(any(UUID.class))).thenAnswer(call->new DocumentHistoryMetadata());
        when(adapter.eligibility(any())).thenReturn(DocumentUnapprovalPort.Eligibility.ready("a".repeat(64)));
        actor(true,false,null);
        for(Query query:List.of(header,links,advisory,lineage))when(query.setParameter(anyString(),any())).thenReturn(query);
        when(header.getSingleResult()).thenReturn(new Object[]{(short)1,null,"{\"status\":1}"});
        when(links.getResultList()).thenReturn(List.of());when(lineage.getResultList()).thenReturn(List.of());
        when(em.createNativeQuery(anyString())).thenAnswer(call->{
            String sql=call.getArgument(0);
            if(sql.startsWith("SELECT header.status"))return header;
            if(sql.startsWith("SELECT draft_id"))return links;
            if(sql.startsWith("SELECT original_id"))return lineage;
            return advisory;
        });
        when(advisory.getSingleResult()).thenReturn(false);
        service=new DocumentUnapprovalService(List.of(adapter),em,user,numbers,tx,new ObjectMapper());
    }

    private void actor(boolean reverse,boolean mustChange,UUID impersonatedBy){
        Set<String> permissions=reverse?Set.of("purchase_order:view","purchase_order:reverse"):Set.of("purchase_order:view");
        when(user.get()).thenReturn(Optional.of(new AuthUser(userId,UUID.randomUUID(),"capability-test",permissions,mustChange,true,false,false,impersonatedBy)));
    }
    private void noEffects(){verify(adapter,never()).reverse(any());verifyNoInteractions(numbers);for(Query q:List.of(header,links,advisory,lineage))verify(q,never()).executeUpdate();}

    @Test void draftNeverCallsDomainReversalEligibility(){
        when(header.getSingleResult()).thenReturn(new Object[]{(short)0,null,"draft"});
        var result=service.capability("purchaseOrder",original);
        assertThat(result.eligible()).isFalse();assertThat(result.reasons().getFirst().code()).isEqualTo("DRAFT_NOT_APPROVED");
        verify(adapter,never()).eligibility(any());noEffects();
    }
    @Test void viewOnlyIdentityCannotGainAReverseAction(){
        actor(false,false,null);var result=service.capability("purchaseOrder",original);
        assertThat(result.permitted()).isFalse();assertThat(result.eligible()).isFalse();
        assertThat(result.reasons().getFirst().code()).isEqualTo("REVERSE_PERMISSION_REQUIRED");verify(adapter,never()).eligibility(any());noEffects();
    }
    @Test void downstreamBusinessRefusalStaysSupportedAndUsesUnapprovalWording(){
        when(adapter.eligibility(original)).thenReturn(DocumentUnapprovalPort.Eligibility.blocked("DOWNSTREAM_ACTIVE","请先红冲下游收货","b".repeat(64)));
        var result=service.capability("purchaseOrder",original);
        assertThat(result.supported()).isTrue();assertThat(result.eligible()).isFalse();
        assertThat(result.reasons().getFirst().message()).isEqualTo("请先反审下游收货");noEffects();
    }
    @Test void dedicatedWorkflowIsUnsupportedEvenWhenItsDocumentIsStillADraft(){
        when(header.getSingleResult()).thenReturn(new Object[]{(short)0,null,"draft"});
        doThrow(new ApiException(ErrorCode.CONFLICT,"请从来源工作台撤回")).when(adapter).requireSupported(original);
        var result=service.capability("purchaseOrder",original);assertThat(result.supported()).isFalse();assertThat(result.eligible()).isFalse();noEffects();
    }
    @Test void exactDomainFactsChangeTheOpaqueConfirmationSnapshotWithoutAnyWrite(){
        var before=service.capability("purchaseOrder",original);assertThat(before.eligible()).isTrue();assertThat(before.factsSnapshot()).matches("[a-f0-9]{64}");
        when(adapter.eligibility(original)).thenReturn(DocumentUnapprovalPort.Eligibility.ready("c".repeat(64)));
        var after=service.capability("purchaseOrder",original);assertThat(after.factsSnapshot()).isNotEqualTo(before.factsSnapshot());noEffects();
    }
    @Test void staleSnapshotCannotReachDomainMutationOrConsumeANumber(){
        assertThatThrownBy(()->service.unapprove("purchaseOrder",original,new DocumentUnapprovalService.UnapproveRequest("capability-stale-key","修改后再审核","0".repeat(64))))
                .isInstanceOf(ApiException.class).hasMessageContaining("确认期间已变化");noEffects();
    }
    @Test void alreadyCommittedRetryReturnsKnownSuccessorBeforeSnapshotRevalidation(){
        when(links.getResultList()).thenReturn(List.of(successor));
        var result=(DocumentHistoryMetadata)service.unapprove("purchaseOrder",original,
                new DocumentUnapprovalService.UnapproveRequest("known-successor-retry","响应丢失后核对","0".repeat(64)));
        assertThat(result.getUnapprovalOriginalId()).isEqualTo(original);verify(adapter,never()).eligibility(any());noEffects();
    }
    @Test void impersonatedAndPasswordChangeIdentitiesCannotSubmitEvenWithReverseAuthority(){
        actor(true,false,UUID.randomUUID());
        assertThatThrownBy(()->service.unapprove("purchaseOrder",original,new DocumentUnapprovalService.UnapproveRequest("readonly-actor-key","核对")))
                .isInstanceOf(ApiException.class).extracting(error->((ApiException)error).getCode()).isEqualTo(ErrorCode.FORBIDDEN);
        actor(true,true,null);
        assertThatThrownBy(()->service.unapprove("purchaseOrder",original,new DocumentUnapprovalService.UnapproveRequest("password-actor-key","核对")))
                .isInstanceOf(ApiException.class).extracting(error->((ApiException)error).getCode()).isEqualTo(ErrorCode.FORBIDDEN);noEffects();
    }
    @Test void hiddenSuccessorDoesNotRevealItsIdentityOrCreateAnotherDraft(){
        when(links.getResultList()).thenReturn(List.of(successor));
        when(adapter.detail(successor)).thenThrow(new ApiException(ErrorCode.FORBIDDEN));
        var result=service.capability("purchaseOrder",original);assertThat(result.successorId()).isNull();
        assertThat(result.nextAction()).isEqualTo("BLOCKED");assertThat(result.reasons().getFirst().code()).isEqualTo("ALREADY_UNAPPROVED");noEffects();
    }
    @Test void lineageOmitsAHiddenRelatedNumberAndReason(){
        when(lineage.getResultList()).thenReturn(Collections.singletonList(new Object[]{original,successor,"PRIVATE-1001","private reason","2026-10-11"}));
        when(adapter.detail(successor)).thenThrow(new ApiException(ErrorCode.NOT_FOUND));
        var result=service.lineage("purchaseOrder",original);assertThat((List<?>)result.get("links")).isEmpty();
        assertThat(result.toString()).doesNotContain("PRIVATE-1001","private reason",successor.toString());noEffects();
    }
    @Test void missingStatusAndImportedGenerationFailClosed(){
        when(header.getSingleResult()).thenReturn(new Object[]{null,null,"unknown"});
        assertThat(service.capability("purchaseOrder",original).eligible()).isFalse();
        when(header.getSingleResult()).thenReturn(new Object[]{(short)1,42,"imported"});
        var result=service.capability("purchaseOrder",original);assertThat(result.reasons().getFirst().code()).isEqualTo("IMPORTED_HISTORY");noEffects();
    }
}
