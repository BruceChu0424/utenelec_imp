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
    @Test void superAdminAuthorityDoesNotInventSalesDepartmentContext() {
        actor(Set.of(), true);
        assertThat(policy.domains()).contains("SALES", "FINANCE", "ADMIN");
        assertThat(policy.contextualDomains()).containsExactly("PRODUCTION");
        verify(jdbc).queryForList(anyString(), eq(String.class), eq(employee), eq(actor));
        when(jdbc.queryForList(anyString(), eq(String.class), any(), any())).thenReturn(List.of());
        assertThat(policy.contextualDomains()).isEmpty();
        assertThat(policy.domains()).contains("SALES", "ADMIN");
    }
    @Test void realPrimarySalesMembershipIsContextEvenWithoutASalesFunctionGrant() {
        actor(Set.of("ai:use"), false);
        when(jdbc.queryForList(anyString(), eq(String.class), any(), any()))
                .thenReturn(List.of("sales:DEPT_SALES", "company:ROOT"));
        assertThat(policy.contextualDomains()).contains("SALES").doesNotContain("SELF", "ADMIN", "FINANCE");
        assertThat(policy.domains()).containsExactly("SELF");
        assertThat(policy.hasDomain("SALES")).isFalse();
    }
    @Test void currentSecondarySalesMembershipChangesContextWithoutInventingAuthority() {
        actor(Set.of("ai:use", "production_execution:view"), false);
        assertThat(policy.contextualDomains()).containsExactly("PRODUCTION");
        when(jdbc.queryForList(anyString(), eq(String.class), any(), any()))
                .thenReturn(List.of("workshop:WS_ZHUSU", "primary:DEPT_PROD", "secondary:DEPT_RAIL"));
        assertThat(policy.contextualDomains()).containsExactlyInAnyOrder("PRODUCTION", "SALES");
        assertThat(policy.domains()).containsExactlyInAnyOrder("SELF", "PRODUCTION");
        actor(Set.of("ai:use", "production_execution:view", "sales_order:view"), false);
        assertThat(policy.domains()).containsExactlyInAnyOrder("SELF", "PRODUCTION", "SALES");
    }
    @Test void allDepartmentMappingsKeepTheirOriginalFunctionalIntersection() {
        actor(Set.of("ai:use"), false);
        when(jdbc.queryForList(anyString(), eq(String.class), any(), any())).thenReturn(List.of(
                "s:DEPT_SALES", "p:SUB_PLAN", "b:SUB_PURCHASE", "w:SUB_WH", "f:DEPT_FIN", "q:DEPT_QA", "h:DEPT_HR", "r:DEPT_ENG"));
        assertThat(policy.contextualDomains()).containsExactlyInAnyOrder("SALES", "PRODUCTION", "PURCHASE", "WAREHOUSE", "FINANCE", "QUALITY", "SUBCONTRACT", "HR", "RD");
        assertThat(policy.domains()).containsExactly("SELF");
        actor(Set.of("ai:use", "sales_quote:view", "production_execution:view", "purchase_order:view", "stock:view",
                "goods:cost:view", "procurement_inspection:view", "subcontract_order:view", "employee:view", "rd_task:view"), false);
        assertThat(policy.domains()).containsExactlyInAnyOrder("SELF", "SALES", "PRODUCTION", "PURCHASE", "WAREHOUSE", "FINANCE", "QUALITY", "SUBCONTRACT", "HR", "RD");
    }
    @Test void claimsAndStrayPermissionsDoNotCreateAContextualMembership() {
        actor(Set.of("ai:use", "sales_quote:view", "goods:cost:view", "finance:view:all"), false);
        assertThat(policy.contextualDomains()).containsExactly("PRODUCTION");
        assertThat(policy.domains()).containsExactly("SELF");
    }
    @Test void invalidOrImpersonatedActorsCannotReadDepartmentContext() {
        for (AuthUser rejected : List.of(
                AuthUser.visitor(UUID.randomUUID(), "visitor", "V1", Set.of("ai:use")),
                new AuthUser(actor, employee, "worker", Set.of("ai:use"), false, false, false),
                new AuthUser(actor, employee, "worker", Set.of("ai:use"), false, true, true, false, UUID.randomUUID()))) {
            when(current.get()).thenReturn(Optional.of(rejected));
            assertThatThrownBy(policy::contextualDomains).isInstanceOf(ApiException.class);
        }
        verifyNoInteractions(jdbc);
    }
    @Test void superAdminDepartmentMoveChangesContextFingerprintEvenWithinTheSameDomain() {
        actor(Set.of(), true);
        when(jdbc.queryForList(anyString(), eq(String.class), any(), any()))
                .thenReturn(List.of("sales-a:DEPT_SALES", "company:ROOT"));
        Set<String> before = policy.contextualDomains();
        String fingerprint = policy.contextualMembershipFingerprint();
        assertThat(fingerprint).isEqualTo("company:ROOT|sales-a:DEPT_SALES");
        when(jdbc.queryForList(anyString(), eq(String.class), any(), any()))
                .thenReturn(List.of("company:ROOT", "sales-b:DEPT_SALES"));
        assertThat(policy.contextualDomains()).isEqualTo(before);
        assertThat(policy.contextualMembershipFingerprint()).isNotEqualTo(fingerprint);
        assertThat(policy.membershipFingerprint()).isEqualTo("SUPER_ADMIN");
    }
}
