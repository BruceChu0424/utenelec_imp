package com.uten.imp.security;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;

import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class AiChatAccessPolicyTest {
    private final JdbcTemplate jdbc = mock(JdbcTemplate.class);
    private final SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
    private final AiChatAccessPolicy policy = new AiChatAccessPolicy(current, jdbc);
    private final UUID actor = UUID.randomUUID();
    private final UUID employee = UUID.randomUUID();
    @BeforeEach void before() { when(jdbc.queryForList(anyString(), eq(String.class), any(), any())).thenReturn(List.of("dept:DEPT_PROD")); }
    private void actor(Set<String> permissions, boolean admin) {
        when(current.get()).thenReturn(Optional.of(new AuthUser(actor, employee, "worker", permissions, false, true, admin)));
    }
    @Test void productionMembershipCannotUseStrayFinanceOrGrantPermission() {
        actor(Set.of("ai:use", "production_execution:view", "goods:cost:view", "finance:view:all", "admin:permission:edit"), false);
        assertThat(policy.domains()).containsExactlyInAnyOrder("SELF", "PRODUCTION");
        assertThatThrownBy(() -> policy.requireDomain("FINANCE")).isInstanceOf(ApiException.class);
        assertThat(policy.hasDomain("ADMIN")).isFalse();
    }
    @Test void departmentAloneNeverConfersBusinessAccess() {
        actor(Set.of("ai:use"), false);
        assertThat(policy.domains()).containsExactly("SELF");
    }
    @Test void secondaryFinanceDepartmentStillRequiresFinancePermission() {
        actor(Set.of("ai:use", "production_execution:view", "goods:cost:view"), false);
        when(jdbc.queryForList(anyString(), eq(String.class), any(), any())).thenReturn(List.of("p:DEPT_PROD", "f:DEPT_FIN"));
        assertThat(policy.domains()).contains("FINANCE", "PRODUCTION");
    }
    @Test void superAdminCanUseRegisteredDomainsWithoutDepartmentBypassForOthers() {
        actor(Set.of(), true);
        assertThat(policy.domains()).contains("ADMIN", "FINANCE", "SALES");
        verifyNoInteractions(jdbc);
    }
    @Test void impersonationCannotOpenChat() {
        when(current.get()).thenReturn(Optional.of(new AuthUser(actor, employee, "worker", Set.of("ai:use"), false, true, false, false, UUID.randomUUID())));
        assertThatThrownBy(policy::requireChat).isInstanceOf(ApiException.class);
    }
    @Test void researchDomainRequiresEngineeringMembershipAndExactTaskReadPermission() {
        actor(Set.of("ai:use","rd_task:view"),false);
        assertThat(policy.domains()).doesNotContain("RD");
        when(jdbc.queryForList(anyString(),eq(String.class),any(),any())).thenReturn(List.of("eng:DEPT_ENG"));
        assertThat(policy.domains()).contains("RD");
        actor(Set.of("ai:use","rd_task:resolve"),false);
        assertThat(policy.domains()).doesNotContain("RD");
    }
}
