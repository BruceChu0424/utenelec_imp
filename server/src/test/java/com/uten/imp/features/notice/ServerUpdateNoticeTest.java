package com.uten.imp.features.notice;

import com.uten.imp.features.admin.serveroperations.ServerOperationsActorAuthority;
import com.uten.imp.features.admin.serveroperations.ServerOperationsDto;
import com.uten.imp.features.admin.serveroperations.ServerOperationsService;
import com.uten.imp.features.auth.PermissionResolver;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;
import static org.mockito.ArgumentMatchers.*;

class ServerUpdateNoticeTest {
    @Test void eventIsStableSourceBoundAndFitsExistingEightyCharacterColumn() {
        String event=ServerUpdateNoticePublisher.sourceEvent("rev1","v2.5.18");
        assertThat(event).hasSize(78).isEqualTo(ServerUpdateNoticePublisher.sourceEvent("rev1","v2.5.18"));
        assertThat(event).isNotEqualTo(ServerUpdateNoticePublisher.sourceEvent("rev2","v2.5.18"));
        assertThat(event).isNotEqualTo(ServerUpdateNoticePublisher.sourceEvent("rev1","v2.5.19"));
    }
    @Test void ordinaryAccountsAndRevokedNoticeReadersNeverGetTheUpdateNotification() {
        var authority=mock(ServerOperationsActorAuthority.class);var permissions=mock(PermissionResolver.class);
        var notices=mock(NoticeService.class);var jdbc=mock(JdbcTemplate.class);
        var publisher=new ServerUpdateNoticePublisher(authority,permissions,notices,jdbc);UUID user=UUID.randomUUID();
        publisher.publishOnce(user,"rev1","v2.5.18");verifyNoInteractions(permissions,notices,jdbc);
        when(authority.mayUpdate(user)).thenReturn(true);when(permissions.usersGrantedAll(List.of(user),Set.of("notice:read"))).thenReturn(List.of());
        publisher.publishOnce(user,"rev1","v2.5.18");verifyNoInteractions(notices,jdbc);
    }
    @Test void publishingUsesTheRealNoticeChainOnceRatherThanAUiOnlyCounter() {
        var authority=mock(ServerOperationsActorAuthority.class);var permissions=mock(PermissionResolver.class);
        var notices=mock(NoticeService.class);var jdbc=mock(JdbcTemplate.class);UUID user=UUID.randomUUID();
        when(authority.mayUpdate(user)).thenReturn(true);when(permissions.usersGrantedAll(List.of(user),Set.of("notice:read"))).thenReturn(List.of(user));
        String event=ServerUpdateNoticePublisher.sourceEvent("rev1","v2.5.18");
        when(jdbc.queryForObject(contains("count(*)"),eq(Integer.class),eq(user),eq(event))).thenReturn(0,1);
        var publisher=new ServerUpdateNoticePublisher(authority,permissions,notices,jdbc);
        publisher.publishOnce(user,"rev1","v2.5.18");publisher.publishOnce(user,"rev1","v2.5.18");
        verify(notices,times(1)).publishForUser(eq(user),contains("v2.5.18"),anyString(),eq("system"),eq("系统"),
                eq("/admin/server-operations"),eq(event),eq("normal"));
    }
    @Test void schedulerOnlyReadsLocalManuallyPopulatedCacheAndHasNoCloudClient() {
        var operations=mock(ServerOperationsService.class);var authority=mock(ServerOperationsActorAuthority.class);
        var publisher=mock(ServerUpdateNoticePublisher.class);var scheduler=new ServerUpdateNoticeScheduler(operations,authority,publisher);
        var noUpdate=new ServerOperationsDto.Status(true,true,false,false,"v2.5.17","rev1",true,null,
                null,null,false,"UTC",null,null,false,false,false);
        when(operations.localSnapshot()).thenReturn(noUpdate);scheduler.scan();verifyNoInteractions(authority,publisher);
        var update=new ServerOperationsDto.Status(true,true,false,false,"v2.5.17","rev1",true,null,
                "v2.5.18",null,true,"UTC",null,null,false,false,false);UUID user=UUID.randomUUID();
        when(operations.localSnapshot()).thenReturn(update);when(authority.currentUpdaters()).thenReturn(List.of(user));scheduler.scan();
        verify(publisher).publishOnce(user,"rev1","v2.5.18");
    }
}
