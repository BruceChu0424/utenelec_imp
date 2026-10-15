package com.uten.imp.features.admin.serveroperations;

import java.time.Clock;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.Map;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.springframework.context.annotation.AnnotationConfigApplicationContext;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class ScheduledServerUpdateDispatcherTest {
    private final ServerOperationsService operations=mock(ServerOperationsService.class);
    private final HostOperationsClient client=mock(HostOperationsClient.class);
    private final ServerOperationsActorAuthority authority=mock(ServerOperationsActorAuthority.class);
    private final ServerOperationsRuntimeBinding runtimeBinding=mock(ServerOperationsRuntimeBinding.class);
    private final UUID actor=UUID.randomUUID(), id=UUID.randomUUID();
    private final Instant now=Instant.parse("2026-10-17T02:00:00Z");
    private final ScheduledServerUpdateDispatcher dispatcher=new ScheduledServerUpdateDispatcher(operations,client,authority,runtimeBinding,Clock.fixed(now,ZoneOffset.UTC));
    @Test void springCreatesTheProductionBeanWithoutAClockBeanOrAnyHostCall() {
        try (var context=new AnnotationConfigApplicationContext()) {
            context.registerBean(ServerOperationsService.class,()->operations);
            context.registerBean(HostOperationsClient.class,()->client);
            context.registerBean(ServerOperationsActorAuthority.class,()->authority);
            context.registerBean(ServerOperationsRuntimeBinding.class,()->runtimeBinding);
            context.register(ScheduledServerUpdateDispatcher.class);
            context.refresh();
            assertThat(context.getBean(ScheduledServerUpdateDispatcher.class)).isNotNull();
            assertThat(context.getBeansOfType(Clock.class)).isEmpty();
            verifyNoInteractions(operations,client,authority,runtimeBinding);
        }
    }
    @Test void onlyDueExplicitAppointmentsAreDispatchedAfterFreshAuthorityCheck() {
        when(operations.localSnapshot()).thenReturn(snapshot("SCHEDULED",now.minusSeconds(1)));
        when(authority.mayUpdate(actor)).thenReturn(true);when(runtimeBinding.capture()).thenReturn(Map.of("database","actual-db","postmasterStartedAt","2026-10-15T01:20:00.123456Z"));dispatcher.dispatchDue();
        verify(client).call(eq(HostOperationsClient.Operation.UPDATE_DISPATCH),eq(Map.of("jobId",id.toString(),"runtimeBinding",Map.of("database","actual-db","postmasterStartedAt","2026-10-15T01:20:00.123456Z"))),eq(actor),any());
    }
    @Test void revokedUserCancelsButDatabaseFailureHoldsRatherThanDispatchingOrCancelling() {
        when(operations.localSnapshot()).thenReturn(snapshot("SCHEDULED",now.minusSeconds(1)));
        when(authority.mayUpdate(actor)).thenReturn(false);dispatcher.dispatchDue();
        verify(client).call(eq(HostOperationsClient.Operation.UPDATE_CANCEL),eq(Map.of("jobId",id.toString(),"reason","AUTHORIZATION_REVOKED")),eq(actor),any());
        reset(client);when(authority.mayUpdate(actor)).thenThrow(new org.springframework.dao.DataAccessResourceFailureException("private-db"));
        dispatcher.dispatchDue();verifyNoInteractions(client);
    }
    @Test void futureAndAlreadyDispatchedJobsNeverStartOrContactCloud() {
        when(operations.localSnapshot()).thenReturn(snapshot("SCHEDULED",now.plusSeconds(1)));dispatcher.dispatchDue();
        when(operations.localSnapshot()).thenReturn(snapshot("RUNNING",now.minusSeconds(10)));dispatcher.dispatchDue();
        verifyNoInteractions(client,authority);
    }
    @Test void freshRuntimeIdentityFailureKeepsTheAppointmentUnknownAndNeverDispatchesAnOldDatabase() {
        when(operations.localSnapshot()).thenReturn(snapshot("SCHEDULED",now.minusSeconds(1)));
        when(authority.mayUpdate(actor)).thenReturn(true);
        when(runtimeBinding.capture()).thenThrow(new IllegalStateException("private diagnostics"));
        dispatcher.dispatchDue();verifyNoInteractions(client);
    }
    private ServerOperationsDto.Status snapshot(String state,Instant time){
        var job=new ServerOperationsDto.Job(id,id,actor,"SCHEDULE_UPDATE",state,"CHECKING",null,null,"v2.5.17","v2.5.18",null,null,null,null,OffsetDateTime.ofInstant(time,ZoneOffset.UTC),null);
        return new ServerOperationsDto.Status(true,true,false,false,"v2.5.17","rev",true,job,null,null,false,"UTC",null,null,false,false,false);
    }
}
