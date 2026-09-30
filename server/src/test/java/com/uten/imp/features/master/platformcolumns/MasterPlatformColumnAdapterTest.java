package com.uten.imp.features.master.platformcolumns;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.platformcolumns.PlatformColumnResourceAdapter;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.*;
import java.util.function.Function;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class MasterPlatformColumnAdapterTest {
    private final SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
    private final EntityManager em = mock(EntityManager.class);
    private final UUID id = UUID.randomUUID();
    @BeforeEach void auth() { authenticate(Set.of("client:view", "client:edit"), false); }
    @Test void aSharedCustomerIsReadableButNeverWritableEvenWithFunctionalEditPermission() {
        var adapter = adapter(value -> Map.of("id", value, "writable", false, "amount", "123.45"));
        assertThat(adapter.authorize(Set.of(id), false).get(id).canWrite()).isFalse();
        Object entity = new Object(); when(em.find(Object.class, id, LockModeType.PESSIMISTIC_WRITE)).thenReturn(entity);
        assertThatThrownBy(() -> adapter.authorize(Set.of(id), true)).isInstanceOf(ApiException.class).hasMessageContaining("无权修改");
        verify(em).refresh(entity, LockModeType.PESSIMISTIC_WRITE);
    }
    @Test void locksAndRefreshesAuthoritativeMasterBeforeReadingItsCapability() {
        Object entity = new Object(); when(em.find(Object.class, id, LockModeType.PESSIMISTIC_WRITE)).thenReturn(entity);
        Function<UUID, Map<String, Object>> detail = requestedId -> {
            assertThat(requestedId).isEqualTo(id);
            verify(em).refresh(entity, LockModeType.PESSIMISTIC_WRITE);
            return Map.of("id", id, "writable", true, "amountExact", "999999999999999.12345", "qty", "2.5");
        };
        var adapter = adapter(detail);
        var access = adapter.authorize(Set.of(id), true).get(id);
        assertThat(access.canWrite()).isTrue();
        assertThat(access.facts()).containsEntry("qty", new BigDecimal("2.5")).doesNotContainKey("amount");
        assertThat(adapter.preserveValuesOnReset()).isTrue();
    }
    @Test void priceFactsNeedTheirOwnPermissionAndMissingValuesAreNotZero() {
        authenticate(Set.of("client:view", "client:edit", "account:balance:view"), false);
        var adapter = adapter(value -> Map.of("id", value, "writable", true, "amountExact", "999999999999999.12345"));
        assertThat(adapter.authorize(Set.of(id), false).get(id).facts())
                .containsEntry("amount", new BigDecimal("999999999999999.12345")).doesNotContainKey("qty");
    }
    @Test void editDoesNotImplyViewAndSimulatedUsersCannotWrite() {
        authenticate(Set.of("client:edit"), false);
        assertThatThrownBy(() -> adapter(value -> Map.of()).authorize(Set.of(id), true)).isInstanceOf(ApiException.class);
        authenticate(Set.of("client:view", "client:edit"), true);
        assertThat(adapter(value -> Map.of("id", value, "writable", true)).canWrite()).isFalse();
        verifyNoInteractions(em);
    }
    @Test void missingOrWrongIdentityFailsClosedAndImmutableEmptySetIsSafe() {
        assertThat(adapter(value -> Map.of()).authorize(Set.of(), false)).isEmpty();
        assertThatThrownBy(() -> adapter(value -> Map.of("id", UUID.randomUUID())).authorize(Set.of(id), false)).hasMessageContaining("不存在");
        assertThatThrownBy(() -> adapter(value -> null).authorize(Set.of(id), false)).hasMessageContaining("不存在");
    }
    private MasterPlatformColumnAdapter adapter(Function<UUID, ?> detail) {
        return new MasterPlatformColumnAdapter("master_client", "客户", "client", Set.of("account:balance:view"), Object.class,
                detail, row -> row.path("writable").asBoolean(false), List.of(
                    new PlatformColumnResourceAdapter.FactDefinition("amount", "金额", true),
                    new PlatformColumnResourceAdapter.FactDefinition("qty", "数量", false)), current, em, new ObjectMapper());
    }
    private void authenticate(Set<String> permissions, boolean impersonated) {
        when(current.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "master-user", permissions,
                false, true, false, false, impersonated ? UUID.randomUUID() : null)));
    }
}
