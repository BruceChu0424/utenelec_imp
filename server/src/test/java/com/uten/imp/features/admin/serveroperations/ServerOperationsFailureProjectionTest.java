package com.uten.imp.features.admin.serveroperations;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;

class ServerOperationsFailureProjectionTest {
    private final HostOperationsClient client=mock(HostOperationsClient.class);
    private final SecurityContextCurrentUser current=mock(SecurityContextCurrentUser.class);
    private final ObjectMapper mapper=new ObjectMapper().findAndRegisterModules();
    private final UUID actor=UUID.randomUUID(),id=UUID.randomUUID();
    private final ServerOperationsService service=new ServerOperationsService(client,current,mapper,
            mock(com.uten.imp.audit.AuditService.class),mock(ServerOperationsRuntimeBinding.class));
    ServerOperationsFailureProjectionTest() {
        when(current.get()).thenReturn(Optional.of(new AuthUser(actor,UUID.randomUUID(),"ops",Set.of("server:update"),false,true,false)));
    }

    @Test void actualHttpProjectionRebuildsFailureAndDropsEveryUnreviewedHelperDetail() throws Exception {
        var node=job("FAILED","CHECKING");
        node.put("message","RAW_LEGACY_SECRET".repeat(200));
        node.putObject("failure").put("code","HOST_IDENTITY_PERMISSION").put("phase","MIGRATING")
                .put("title","RAW_TITLE").put("reason","<Error>RAW_XML_SECRET</Error>")
                .put("suggestion","Bearer RAW_TOKEN https://private.invalid")
                .put("nextAction","REPLAY_UPDATE").put("retrySafe",true)
                .put("recoveryRequired",false).put("originalServicePreserved",true).put("exitCode",1)
                .put("rawStderr","PRIVATE_STDERR").put("password","PRIVATE_PASSWORD");
        when(client.call(eq(HostOperationsClient.Operation.UPDATE_JOB),anyMap(),eq(actor),any())).thenReturn(node);
        var mvc=MockMvcBuilders.standaloneSetup(new ServerOperationsController(service)).build();
        var result=mvc.perform(get("/api/admin/server-operations/updates/{id}",id)).andReturn();
        assertThat(result.getResponse().getStatus()).isEqualTo(200);
        String body=result.getResponse().getContentAsString(java.nio.charset.StandardCharsets.UTF_8);
        assertThat(body).doesNotContain("RAW_","private.invalid","PRIVATE_","REPLAY_UPDATE");
        var json=mapper.readTree(body);
        assertThat(json.path("id").asText()).isEqualTo(id.toString());
        assertThat(json.path("failure").path("phase").asText()).isEqualTo("CHECKING");
        assertThat(json.path("failure").path("code").asText()).isEqualTo("HOST_IDENTITY_PERMISSION");
        assertThat(json.path("failure").path("retrySafe").asBoolean()).isFalse();
        assertThat(json.path("message").asText()).contains("主机账号切换权限不足");
        assertThat(node.path("message").asText()).startsWith("RAW_LEGACY_SECRET");
    }

    @Test void unknownOrMalformedFailureKeepsTheDurableJobButCannotMakeItRetrySafe() throws Exception {
        for (var raw: new com.fasterxml.jackson.databind.JsonNode[]{mapper.createObjectNode().put("code","UNREVIEWED_PRIVATE_CODE").put("reason","SECRET"),mapper.getNodeFactory().textNode("PRIVATE_TRACE")}) {
            var node=job("FAILED","CHECKING");node.set("failure",raw);
            when(client.call(any(),anyMap(),any(),any())).thenReturn(node);
            var result=service.byId(id);
            assertThat(result.id()).isEqualTo(id);assertThat(result.state()).isEqualTo("FAILED");
            assertThat(result.failure().code()).isEqualTo("UNKNOWN");assertThat(result.failure().retrySafe()).isFalse();
            assertThat(mapper.writeValueAsString(result)).doesNotContain("PRIVATE", "SECRET", "UNREVIEWED");
        }
    }

    @Test void lateFailedReceiptsBecomeRecoveryRequiredForLegacyClientsWithoutWritingTheHost() {
        for(String phase:Set.of("MIGRATING","ACTIVATING","HEALTH_CHECK","DONE")) {
            var node=job("FAILED",phase);
            node.putObject("failure").put("code","SOURCE_NETWORK_FAILED").put("retrySafe",true)
                    .put("originalServicePreserved",true).put("recoveryRequired",false);
            when(client.call(any(),anyMap(),any(),any())).thenReturn(node);
            var result=service.byId(id);
            assertThat(result.state()).isEqualTo("RECOVERY_REQUIRED");
            assertThat(result.failure().nextAction()).isEqualTo("VERIFY_RECOVERY");
            assertThat(result.failure().originalServicePreserved()).isFalse();
            assertThat(node.path("state").asText()).isEqualTo("FAILED");
        }
        verify(client,times(4)).call(eq(HostOperationsClient.Operation.UPDATE_JOB),anyMap(),eq(actor),any());
        verifyNoMoreInteractions(client);
    }

    @Test void explicitRecoveredPreconditionsAndLegacyReceiptsKeepTheirOriginalMeaning() throws Exception {
        for(String code:Set.of("CURRENT_VERSION_CHANGED","CUTOVER_BACKUP_FAILED_RECOVERED")) {
            var node=job("FAILED","ACTIVATING");node.putObject("failure").put("code",code).put("originalServicePreserved",true);
            when(client.call(any(),anyMap(),any(),any())).thenReturn(node);
            var result=service.byId(id);
            assertThat(result.state()).isEqualTo("FAILED");assertThat(result.failure().recoveryRequired()).isFalse();
            assertThat(result.failure().originalServicePreserved()).isTrue();
        }
        var legacy=job("FAILED","ACTIVATING").put("message","legacy administrator guidance");
        when(client.call(any(),anyMap(),any(),any())).thenReturn(legacy);
        var result=service.byId(id);
        assertThat(result.failure()).isNull();assertThat(result.state()).isEqualTo("FAILED");
        assertThat(result.message()).isEqualTo("legacy administrator guidance");
        assertThat(mapper.writeValueAsString(result)).doesNotContain("\"failure\"");
        var oldConstructor=new ServerOperationsDto.Job(id,id,actor,"CHECK_ONLY","FAILED","CHECKING",null,null,null,null,"legacy",null,null,null,null,null);
        assertThat(oldConstructor.failure()).isNull();
        var oldStatus=new ServerOperationsDto.Status(false,null,null,null,null,null,null,null,null,null,null,null,null,"legacy",true,false,false);
        assertThat(oldStatus.failure()).isNull();
    }

    @Test void unavailableAndInvalidProtocolStatusHaveDifferentCuratedFailuresAndPreservePermissions() throws Exception {
        for(String code:Set.of("UNAVAILABLE","INVALID_RESPONSE")) {
            doThrow(new HostOperationsException(code)).when(client).call(any(),anyMap(),any(),any());
            var view=service.status();
            assertThat(view.available()).isFalse();assertThat(view.canUpdate()).isTrue();assertThat(view.canConfigureSource()).isFalse();
            assertThat(view.currentVersion()).isNull();assertThat(view.timerActive()).isNull();
            assertThat(view.failure().code()).isEqualTo(code.equals("INVALID_RESPONSE")?"HOST_RESPONSE_INVALID":"HOST_HELPER_UNAVAILABLE");
            assertThat(view.message()).doesNotContain("尚未安装");
            assertThat(mapper.writeValueAsString(view)).doesNotContain("password", "rawStderr");
        }
    }

    @Test void localStatusNestedJobUsesTheSameProjectionAndDoesNotBorrowMutationAuthority() {
        var status=mapper.createObjectNode().put("available",true).put("manualOnly",true).put("timerActive",false).put("timerEnabled",false);
        var nested=job("RECOVERY_REQUIRED","MIGRATING");nested.putObject("failure").put("code","HOST_IDENTITY_PERMISSION").put("retrySafe",true);
        status.set("latestJob",nested);
        when(client.call(any(),anyMap(),any(),any())).thenReturn(status);
        var view=service.localSnapshot();
        assertThat(view.canUpdate()).isFalse();assertThat(view.canCleanup()).isFalse();assertThat(view.canConfigureSource()).isFalse();
        assertThat(view.latestJob().failure().recoveryRequired()).isTrue();
        assertThat(view.latestJob().failure().nextAction()).isEqualTo("VERIFY_RECOVERY");
        verify(client).call(eq(HostOperationsClient.Operation.STATUS),eq(Map.of()),eq(new UUID(0,0)),any());
        verifyNoMoreInteractions(client);
    }

    private ObjectNode job(String state,String phase) {
        return mapper.createObjectNode().put("id",id.toString()).put("requestId",id.toString())
                .put("actorId",actor.toString()).put("mode","CHECK_AND_UPDATE").put("state",state).put("phase",phase);
    }
}
