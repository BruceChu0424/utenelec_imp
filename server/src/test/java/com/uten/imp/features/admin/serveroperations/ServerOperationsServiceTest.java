package com.uten.imp.features.admin.serveroperations;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.validation.Validation;
import java.time.OffsetDateTime;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class ServerOperationsServiceTest {
    private final HostOperationsClient client=mock(HostOperationsClient.class);
    private final SecurityContextCurrentUser current=mock(SecurityContextCurrentUser.class);
    private final ObjectMapper mapper=new ObjectMapper().findAndRegisterModules();
    private final UUID user=UUID.randomUUID();
    private final ServerOperationsRuntimeBinding runtimeBinding=mock(ServerOperationsRuntimeBinding.class);
    private final ServerOperationsService service=new ServerOperationsService(client,current,mapper,mock(com.uten.imp.audit.AuditService.class),runtimeBinding);
    ServerOperationsServiceTest(){ when(runtimeBinding.capture()).thenReturn(Map.of("database","actual-db","postmasterStartedAt","2026-10-15T01:20:00.123456Z")); when(current.get()).thenReturn(Optional.of(new AuthUser(user,UUID.randomUUID(),"ops",
            Set.of("server:update"),false,true,false))); }

    @Test void statusIsOnlyALocalReadAndCarriesTheSourceBoundCacheAndActualTimerFacts() {
        var data=status(); data.put("latestVersion","v2.5.18").put("updateAvailable",true).put("lastCheckedAt","2026-10-16T08:00:00Z");
        when(client.call(eq(HostOperationsClient.Operation.STATUS),anyMap(),eq(user),any())).thenReturn(data);
        var view=service.status();
        assertThat(view.available()).isTrue();assertThat(view.canUpdate()).isTrue();assertThat(view.canConfigureSource()).isFalse();
        assertThat(view.latestVersion()).isEqualTo("v2.5.18");assertThat(view.updateAvailable()).isTrue();
        assertThat(view.timerEnabled()).isFalse();assertThat(view.serverTimeZone()).isEqualTo("Asia/Shanghai");
        verify(client,times(1)).call(eq(HostOperationsClient.Operation.STATUS),eq(Map.of()),eq(user),any());
        verifyNoMoreInteractions(client);
    }
    @Test void unavailablePreservesPermissionButNeverInventsHealthyHostFacts() {
        when(client.call(any(),anyMap(),any(),any())).thenThrow(new HostOperationsException("UNAVAILABLE"));
        var view=service.status();assertThat(view.available()).isFalse();assertThat(view.canUpdate()).isTrue();
        assertThat(view.manualOnly()).isNull();assertThat(view.timerActive()).isNull();assertThat(view.currentVersion()).isNull();
    }
    @Test void rootPrefixIsValidAndConfigResponseCannotReturnWriteOnlySecrets() throws Exception {
        var request=new ServerOperationsDto.SourceSave(UUID.randomUUID(),"rev1","oss-cn-hangzhou.aliyuncs.com","bucket","",
                "key-id","TOP-SECRET",false,null);
        try(var validator=Validation.buildDefaultValidatorFactory()) {assertThat(validator.getValidator().validate(request)).isEmpty();}
        var response=mapper.createObjectNode().put("revision","rev2").put("endpoint",request.endpoint())
                .put("bucket","bucket").put("objectPrefix","").put("accessKeyConfigured",true)
                .put("accessKeyIdHint","key…id").put("accessKeySecret","SHOULD-NOT-RETURN").put("accessKeyId","RAW-ID");
        when(client.call(eq(HostOperationsClient.Operation.CONFIG_SAVE),anyMap(),eq(user),eq(request.requestId()))).thenReturn(response);
        var saved=service.saveSource(request);assertThat(saved.applied()).isTrue();assertThat(saved.revision()).isEqualTo("rev2");
        assertThat(mapper.writeValueAsString(saved)).doesNotContain("TOP-SECRET","SHOULD-NOT-RETURN","RAW-ID");
        assertThat(request.toString()).doesNotContain("TOP-SECRET","key-id");
        verify(client).call(eq(HostOperationsClient.Operation.CONFIG_SAVE),argThat(p->"".equals(p.get("objectPrefix"))
                && "rev1".equals(p.get("expectedRevision")) && "TOP-SECRET".equals(p.get("accessKeySecret"))),eq(user),eq(request.requestId()));
    }
    @Test void checkHasFixedModeAndDoesNotExposeTheInternalRequest() throws Exception {
        UUID request=UUID.randomUUID();var job=job(request,"CHECK_ONLY","QUEUED");
        job.set("request",mapper.createObjectNode().put("private","hidden"));
        when(client.call(eq(HostOperationsClient.Operation.UPDATE_START),anyMap(),eq(user),eq(request))).thenReturn(job);
        var result=service.check(new ServerOperationsDto.Check(request,"rev1","v2.5.17"));
        assertThat(result.mode()).isEqualTo("CHECK_ONLY"); verifyNoInteractions(runtimeBinding);
        assertThat(mapper.writeValueAsString(result)).doesNotContain("private","hidden");
        verify(client).call(eq(HostOperationsClient.Operation.UPDATE_START),argThat(p->p.size()==3
                && "CHECK_ONLY".equals(p.get("mode")) && "rev1".equals(p.get("expectedSourceRevision"))),eq(user),eq(request));
    }
    @Test void scheduleRetainsPreviewInstantAndTargetAndRejectsInvalidModesBeforeRpc() {
        UUID request=UUID.randomUUID();var instant=OffsetDateTime.parse("2026-10-17T02:00:00+08:00");
        var job=job(request,"SCHEDULE_UPDATE","SCHEDULED").put("scheduledAt",instant.toString());
        when(client.call(eq(HostOperationsClient.Operation.UPDATE_START),anyMap(),eq(user),eq(request))).thenReturn(job);
        assertThat(service.start(new ServerOperationsDto.UpdateStart(request,"SCHEDULE_UPDATE","rev1","v2.5.17","v2.5.18",instant)).scheduledAt()).isEqualTo(instant);
        verify(client).call(eq(HostOperationsClient.Operation.UPDATE_START),argThat(p->instant.toInstant().toString().equals(p.get("scheduledAt"))
                && "v2.5.18".equals(p.get("targetVersion")) && Map.of("database","actual-db","postmasterStartedAt","2026-10-15T01:20:00.123456Z").equals(p.get("runtimeBinding"))),eq(user),eq(request));
        reset(client);
        assertThatThrownBy(()->service.start(new ServerOperationsDto.UpdateStart(request,"CHECK_ONLY","rev1",null,null,null))).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->service.start(new ServerOperationsDto.UpdateStart(request,"SCHEDULE_UPDATE","rev1",null,null,instant))).isInstanceOf(ApiException.class);
        verifyNoInteractions(client);
    }
    @Test void malformedDurableAckIsUncertainAndRootConflictUsesSafeMessage() {
        UUID request=UUID.randomUUID();
        when(client.call(any(),anyMap(),any(),any())).thenReturn(mapper.createObjectNode());
        var failure=catchThrowableOfType(ApiException.class,()->service.check(new ServerOperationsDto.Check(request,"rev1",null)));
        assertThat(failure.getCode()).isEqualTo(ErrorCode.SERVER_OPERATION_OUTCOME_UNCERTAIN);
        when(client.call(any(),anyMap(),any(),any())).thenThrow(new HostOperationsException("STALE_CONFIG"));
        assertThat(catchThrowableOfType(ApiException.class,()->service.check(new ServerOperationsDto.Check(request,"rev1",null))).getCode()).isEqualTo(ErrorCode.CONFLICT);
    }
    @Test void onlyAppointmentOwnerOrSuperAdminCanCancelEvenIfAnotherOperatorHasUpdateGrant() {
        UUID id=UUID.randomUUID();var job=job(id,"SCHEDULE_UPDATE","SCHEDULED")
                .put("scheduledAt","2026-10-17T02:00:00Z").put("actorId",UUID.randomUUID().toString());
        when(client.call(eq(HostOperationsClient.Operation.UPDATE_JOB),anyMap(),any(),any())).thenReturn(job);
        var rejected=catchThrowableOfType(ApiException.class,()->service.cancel(id,new ServerOperationsDto.Cancel(UUID.randomUUID())));
        assertThat(rejected.getCode()).isEqualTo(ErrorCode.FORBIDDEN);
        verify(client,never()).call(eq(HostOperationsClient.Operation.UPDATE_CANCEL),anyMap(),any(),any());
    }
    @Test void schedulePreviewUsesRootZoneAndNeverJvmConversion() {
        when(client.call(eq(HostOperationsClient.Operation.SCHEDULE_PREVIEW),anyMap(),any(),any())).thenReturn(mapper.createObjectNode()
                .put("scheduledAt","2026-10-16T18:00:00Z").put("serverTimeZone","Asia/Shanghai").put("displayLocalTime","2026-10-17T02:00:00+08:00"));
        var slot=service.schedulePreview(new ServerOperationsDto.SchedulePreview(java.time.LocalDate.of(2026,10,17),2));
        assertThat(slot.displayLocalTime()).isEqualTo("2026-10-17T02:00:00+08:00");
        assertThat(slot.serverTimeZone()).isEqualTo("Asia/Shanghai");
        assertThatThrownBy(()->service.schedulePreview(new ServerOperationsDto.SchedulePreview(java.time.LocalDate.now(),4))).isInstanceOf(ApiException.class);
    }
    @Test void anUnknownRuntimeBindingCannotEnqueueAnImmediateOrScheduledUpdate() {
        when(runtimeBinding.capture()).thenThrow(new ApiException(ErrorCode.SERVER_OPERATIONS_UNAVAILABLE));
        assertThatThrownBy(()->service.start(new ServerOperationsDto.UpdateStart(UUID.randomUUID(),"CHECK_AND_UPDATE","rev1",null,null,null)))
                .isInstanceOf(ApiException.class);
        verifyNoInteractions(client);
    }
    private ObjectNode status(){return mapper.createObjectNode().put("available",true).put("manualOnly",true)
            .put("timerActive",false).put("timerEnabled",false).put("currentVersion","v2.5.17").put("sourceRevision","rev1")
            .put("sourceConfigured",true).put("serverTimeZone","Asia/Shanghai").put("serverTime","2026-10-16T10:00:00+08:00");}
    private ObjectNode job(UUID id,String mode,String state){return mapper.createObjectNode().put("id",id.toString())
            .put("requestId",id.toString()).put("actorId",user.toString()).put("mode",mode).put("state",state).put("phase","CHECKING");}
}
