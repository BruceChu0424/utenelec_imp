package com.uten.imp.features.admin.systemsetting;

import com.uten.imp.security.*;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;
import static org.mockito.ArgumentMatchers.*;

class SystemSettingsWriteAuthorityTest {
    final SecurityContextCurrentUser current=mock(SecurityContextCurrentUser.class);
    final JdbcTemplate jdbc=mock(JdbcTemplate.class);
    final UUID actor=UUID.randomUUID();
    final SystemSettingsWriteAuthority authority=new SystemSettingsWriteAuthority(current,jdbc);
    void admin(){when(current.get()).thenReturn(Optional.of(new AuthUser(actor,UUID.randomUUID(),"settings-admin",Set.of("authorization:manage"),false,true,true)));}
    @Test void aStaleSuperadminJwtCannotSaveAfterTheAuthoritativeAccountWasDemoted() {
        admin();when(jdbc.query(anyString(),org.mockito.ArgumentMatchers.<RowMapper<UUID>>any(),eq(actor))).thenReturn(List.of());
        assertThatThrownBy(()->authority.require(actor,true)).isInstanceOf(com.uten.imp.common.web.ApiException.class);
    }
    @Test void aValidAdministratorIsLockedThroughTheBusinessCommit() {
        admin();when(jdbc.query(anyString(),org.mockito.ArgumentMatchers.<RowMapper<UUID>>any(),eq(actor))).thenReturn(List.of(actor));
        authority.require(actor,true);verify(jdbc).query(contains("FOR SHARE"),org.mockito.ArgumentMatchers.<RowMapper<UUID>>any(),eq(actor));
    }
    @Test void anActorMismatchFailsBeforeAnyDatabaseRead() {
        admin();assertThatThrownBy(()->authority.require(UUID.randomUUID(),true)).isInstanceOf(com.uten.imp.common.web.ApiException.class);verifyNoInteractions(jdbc);
    }
}
