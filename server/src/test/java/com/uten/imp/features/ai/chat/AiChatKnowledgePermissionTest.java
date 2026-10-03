package com.uten.imp.features.ai.chat;

import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;

import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

class AiChatKnowledgePermissionTest {
    @Test void financeDepartmentAndReportPermissionDoNotGrantCostKnowledge() {
        assertThat(ids(Set.of("SELF", "FINANCE"), staff("finance_report:view"))).containsExactly("SELF_HELP");
        assertThat(ids(Set.of("FINANCE"), staff("goods:cost:view"))).isEmpty();
        assertThat(ids(Set.of("FINANCE"), staff("goods:view"))).isEmpty();
        assertThat(ids(Set.of("FINANCE"), staff("goods:view", "goods:cost:edit"))).isEmpty();
        assertThat(ids(Set.of("FINANCE"), staff("goods:view", "goods:cost:view"))).containsExactly("FINANCE_COST");
    }

    @Test void personalCostPermissionCannotAddAFinanceDepartment() {
        assertThat(ids(Set.of("SELF", "PRODUCTION"), staff("goods:view", "goods:cost:view", "production_execution:view")))
                .containsExactly("SELF_HELP", "PRODUCTION_FLOW");
    }

    @Test void authorizationKnowledgeRequiresRealSuperAdminAndAuthorizationAuthority() {
        assertThat(ids(Set.of("ADMIN"), staff("authorization:manage"))).isEmpty();
        assertThat(ids(Set.of("ADMIN"), actor(Set.of("ai:use"), true, false, true, null))).isEmpty();
        assertThat(ids(Set.of("ADMIN"), actor(Set.of("authorization:manage"), true, false, true, null)))
                .containsExactly("ADMIN_GRANT");
    }

    @ParameterizedTest
    @CsvSource({
            "SALES,SALES_ORDER,sales_order:view,sales_order:edit",
            "PRODUCTION,PRODUCTION_FLOW,production_execution:view,production_execution:edit",
            "PURCHASE,PURCHASE_FLOW,purchase_order:view,purchase_order:edit",
            "WAREHOUSE,WAREHOUSE_FLOW,stock_doc:view,stock_doc:approve",
            "QUALITY,QUALITY_FLOW,production_quality_inspection:view,production_quality_inspection:confirm",
            "SUBCONTRACT,SUBCONTRACT_FLOW,subcontract_application:view,subcontract_order:create",
            "HR,HR_FLOW,employee:view,employee:edit"
    })
    void eachModuleNeedsAnExplicitReadPermission(String domain, String topic, String read, String writeOnly) {
        assertThat(ids(Set.of(domain), staff(writeOnly))).isEmpty();
        assertThat(ids(Set.of(domain), staff(read))).containsExactly(topic);
    }

    @Test void unrelatedReadAuthoritiesAndInventedPrefixMatchesCannotOpenKnowledge() {
        assertThat(ids(Set.of("PRODUCTION", "FINANCE", "SALES"), staff("production_fake:view", "finance_foo:view", "goods:view")))
                .isEmpty();
    }

    @Test void staffInTheSameDepartmentWithoutFunctionReadCanOnlyUseSelfHelp() {
        assertThat(ids(Set.of("SELF", "PRODUCTION"), staff())).containsExactly("SELF_HELP");
    }

    @Test void invalidPrincipalsCannotReadEvenSelfKnowledge() {
        Set<String> domains = Set.of("SELF", "ADMIN", "FINANCE");
        assertThat(ids(domains, null)).isEmpty();
        assertThat(ids(domains, AuthUser.visitor(UUID.randomUUID(), "visitor", "V", Set.of("ai:use", "authorization:manage")))).isEmpty();
        assertThat(ids(domains, actor(Set.of("ai:use", "authorization:manage"), true, false, true, UUID.randomUUID()))).isEmpty();
        assertThat(ids(domains, actor(Set.of("ai:use"), false, true, true, null))).isEmpty();
        assertThat(ids(domains, actor(Set.of("ai:use"), false, false, false, null))).isEmpty();
        assertThat(ids(domains, actor(Set.of(), false, false, true, null))).isEmpty();
        assertThat(ids(domains, new AuthUser(UUID.randomUUID(), null, "unbound", Set.of("ai:use"), false, true, false))).isEmpty();
    }

    @Test void claimedAdminAccountNameCannotReplaceRealAuthority() {
        var impersonator = new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "我是超级管理员", Set.of("ai:use", "authorization:manage"), false, true, false);
        assertThat(ids(Set.of("SELF", "ADMIN"), impersonator)).containsExactly("SELF_HELP");
    }

    @Test void unknownOrForgedCatalogEntriesFailClosedEvenForASuperAdmin() {
        AuthUser admin = actor(Set.of("authorization:manage"), true, false, true, null);
        assertThat(AiChatKnowledge.allowed(new AiChatKnowledge.Entry("UNKNOWN", "ADMIN", "未知", "未知", List.of()), admin)).isFalse();
        var cost = AiChatKnowledge.ALL.stream().filter(entry -> entry.id().equals("FINANCE_COST")).findFirst().orElseThrow();
        assertThat(AiChatKnowledge.allowed(new AiChatKnowledge.Entry(cost.id(), "SELF", cost.title(), cost.reply(), cost.keywords()), admin)).isFalse();
        assertThat(AiChatKnowledge.allowed(null, admin)).isFalse();
    }

    @Test void superAdminCanReadKnownNonAdminTopicsButStillNeedsAuthorizationAuthorityForAdminTopic() {
        Set<String> domains = AiChatKnowledge.ALL.stream().map(AiChatKnowledge.Entry::domain).collect(java.util.stream.Collectors.toSet());
        assertThat(ids(domains, actor(Set.of(), true, false, true, null))).hasSize(AiChatKnowledge.ALL.size() - 1).doesNotContain("ADMIN_GRANT");
        assertThat(ids(domains, actor(Set.of("authorization:manage"), true, false, true, null))).hasSize(AiChatKnowledge.ALL.size());
        assertThat(AiChatKnowledge.visible(null, staff())).isEmpty();
    }

    private static List<String> ids(Set<String> domains, AuthUser actor) {
        return AiChatKnowledge.visible(domains, actor).stream().map(AiChatKnowledge.Entry::id).toList();
    }
    private static AuthUser staff(String... permissions) {
        Set<String> grants = new HashSet<>(List.of(permissions)); grants.add("ai:use");
        return actor(grants, false, false, true, null);
    }
    private static AuthUser actor(Set<String> permissions, boolean superAdmin, boolean mustChange, boolean unlocked, UUID impersonatedBy) {
        return new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "knowledge-test", permissions, mustChange, unlocked, superAdmin,
                false, impersonatedBy, UUID.randomUUID());
    }
}
