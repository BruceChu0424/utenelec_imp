package com.uten.imp.features.finance.gl;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import com.uten.imp.support.FinanceReportTestAccess;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;

import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class FinanceChartMetadataTest {
    private static final UUID ACTOR=UUID.fromString("00000000-0000-0000-0000-000000000001");
    private final JdbcTemplate db=mock(JdbcTemplate.class);
    private final ObjectMapper json=new ObjectMapper();
    private final SecurityContextCurrentUser current=mock(SecurityContextCurrentUser.class);
    private final TxSessionVars tx=mock(TxSessionVars.class);
    private FinanceChartService chart;
    private final FinanceChartContracts.UpdateAccount request=new FinanceChartContracts.UpdateAccount(
            UUID.fromString("00000000-0000-0000-0000-000000000002"),7,"库存现金（人民币）","财务核对原科目名称");
    @BeforeEach void setup() {
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken("finance","test",List.of(
                new SimpleGrantedAuthority("finance_report:view"),new SimpleGrantedAuthority("payment_style:edit"))));
        when(current.requireId()).thenReturn(ACTOR);
        chart=new FinanceChartService(db,null,json,null,current,FinanceReportTestAccess.company(),null,tx,null,null);
        when(db.queryForList("SELECT actor_id,fingerprint,result::text FROM finance_chart_manual_operations WHERE request_id=?",request.requestId())).thenReturn(List.of());
        when(db.queryForList("SELECT name,row_version FROM finance_chart_codes WHERE code=? FOR UPDATE","1001"))
                .thenReturn(List.of(Map.of("name","库存现金","row_version",7L)));
    }
    @AfterEach void logout(){SecurityContextHolder.clearContext();}
    @Test void ownerCanReadTheMatchingUpdatedReceiptAfterLosingWriteAuthority()throws Exception {
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken("reader","test",List.of(new SimpleGrantedAuthority("finance_report:view"))));
        var result=new FinanceChartContracts.UpdateAccountResult(request.requestId(),"1001","UPDATED","库存现金",request.name(),request.sourceReference());
        when(db.queryForList("SELECT result::text FROM finance_chart_manual_operations WHERE request_id=? AND actor_id=?",request.requestId(),ACTOR))
                .thenReturn(List.of(Map.of("result",json.writeValueAsString(result))));
        assertThat(chart.metadataReceipt("1001",request.requestId())).containsEntry("found",true).containsEntry("actorId",ACTOR).containsEntry("result",result);
        assertThat(chart.metadataReceipt("1002",request.requestId())).containsEntry("found",false);
        UUID another=UUID.fromString("00000000-0000-0000-0000-000000000003");when(current.requireId()).thenReturn(another);
        assertThat(chart.metadataReceipt("1001",request.requestId())).containsEntry("found",false);
        verify(db).queryForList("SELECT result::text FROM finance_chart_manual_operations WHERE request_id=? AND actor_id=?",request.requestId(),another);
        verify(db,never()).update(anyString(),any(Object[].class));
    }
    @Test void creationReceiptsAndMismatchedRequestIdentitiesCannotAcknowledgeAMetadataWrite()throws Exception {
        var unrelated=new FinanceChartContracts.UpdateAccountResult(request.requestId(),"1001","CREATED",null,null,null);
        when(db.queryForList("SELECT result::text FROM finance_chart_manual_operations WHERE request_id=? AND actor_id=?",request.requestId(),ACTOR))
                .thenReturn(List.of(Map.of("result",json.writeValueAsString(unrelated))));
        assertThat(chart.metadataReceipt("1001",request.requestId())).containsEntry("found",false);
        var wrongRequest=new FinanceChartContracts.UpdateAccountResult(UUID.randomUUID(),"1001","UPDATED","库存现金",request.name(),request.sourceReference());
        when(db.queryForList("SELECT result::text FROM finance_chart_manual_operations WHERE request_id=? AND actor_id=?",request.requestId(),ACTOR))
                .thenReturn(List.of(Map.of("result",json.writeValueAsString(wrongRequest))));
        assertThat(chart.metadataReceipt("1001",request.requestId())).containsEntry("found",false);
    }
    @Test void metadataEndpointKeepsAllThreeAuthoritiesAndAutomaticWriteAuditAction()throws Exception {
        var endpoint=FinanceChartController.class.getDeclaredMethod("updateAccount",String.class,com.fasterxml.jackson.databind.JsonNode.class);
        assertThat(endpoint.getAnnotation(org.springframework.security.access.prepost.PreAuthorize.class).value())
                .isEqualTo("hasAuthority('finance_report:view') and hasAuthority('finance:view:all') and hasAuthority('payment_style:edit')");
        assertThat(com.uten.imp.audit.AuditActionNames.semanticAction(FinanceChartController.class,endpoint.getName()))
                .isEqualTo("finance_chart.update_account");
    }
    @Test void readOnlyAndRestrictedReadersCannotRenameBeforeAnyDatabaseCall() {
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken("reader","test",List.of(new SimpleGrantedAuthority("finance_report:view"))));
        assertThatThrownBy(()->chart.updateAccount("1001",request)).isInstanceOf(ApiException.class).hasMessageContaining("payment_style:edit");
        verifyNoInteractions(db,tx);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken("editor","test",List.of(
                new SimpleGrantedAuthority("finance_report:view"),new SimpleGrantedAuthority("payment_style:edit"))));
        var restricted=mock(com.uten.imp.features.finance.FinanceDocumentAccessPolicy.class);
        when(restricted.scope()).thenReturn(new com.uten.imp.security.OwnerVisibility.OwnerScope(false,java.util.Set.of()));
        var restrictedService=new FinanceChartService(db,null,json,null,current,restricted,null,tx,null,null);
        assertThatThrownBy(()->restrictedService.updateAccount("1001",request)).isInstanceOf(ApiException.class).hasMessageContaining("公司级完整财务事实");
        verifyNoInteractions(db,tx);
    }
    @Test void renameOnlyWritesTheNameVersionAndActorWhileKeepingItsEvidenceInThePrivateOperation() {
        var result=chart.updateAccount("1001",request);
        assertThat(result.previousName()).isEqualTo("库存现金");
        assertThat(result.name()).isEqualTo(request.name());
        assertThat(result.sourceReference()).isEqualTo(request.sourceReference());
        verify(db).update("UPDATE finance_chart_codes SET name=?,row_version=row_version+1,updated_at=now(),updated_by=? WHERE code=?",
                request.name(),ACTOR,"1001");
        verify(db).update(eq("INSERT INTO finance_chart_manual_operations(request_id,actor_id,fingerprint,result) VALUES(?,?,?,?::jsonb)"),
                eq(request.requestId()),eq(ACTOR),matches("[0-9a-f]{64}"),contains("财务核对原科目名称"));
        verify(tx).bind();
        verify(current,times(2)).requireId();
    }
    @Test void staleVersionAndMissingReasonNeverUpdateTheAccount() {
        assertThatThrownBy(()->chart.updateAccount("1001",new FinanceChartContracts.UpdateAccount(request.requestId(),6,request.name(),request.sourceReference())))
                .isInstanceOf(ApiException.class).hasMessageContaining("已变化");
        assertThatThrownBy(()->chart.updateAccount("1001",new FinanceChartContracts.UpdateAccount(request.requestId(),7,request.name(),"")))
                .isInstanceOf(ApiException.class).hasMessageContaining("修改依据");
        verify(db,never()).update(anyString(),any(Object[].class));
    }
    @Test void lostReplyReplaysTheOriginalReceiptWithoutRewritingOrTakingTheCurrentVersion()throws Exception {
        var saved=new FinanceChartContracts.UpdateAccountResult(request.requestId(),"1001","UPDATED","库存现金",request.name(),request.sourceReference());
        String fingerprint=com.uten.imp.common.storage.ImmutableDocumentStore.digest(("UPDATE_METADATA:1001:"+json.writeValueAsString(request)).getBytes(java.nio.charset.StandardCharsets.UTF_8));
        when(db.queryForList("SELECT actor_id,fingerprint,result::text FROM finance_chart_manual_operations WHERE request_id=?",request.requestId()))
                .thenReturn(List.of(Map.of("actor_id",ACTOR,"fingerprint",fingerprint,"result",json.writeValueAsString(saved))));
        assertThat(chart.updateAccount("1001",request)).isEqualTo(saved);
        verify(db,never()).queryForList("SELECT name,row_version FROM finance_chart_codes WHERE code=? FOR UPDATE","1001");
        verify(db,never()).update(anyString(),any(Object[].class));
        assertThatThrownBy(()->chart.updateAccount("1002",request)).isInstanceOf(ApiException.class).hasMessageContaining("同一修改请求");
    }
}
