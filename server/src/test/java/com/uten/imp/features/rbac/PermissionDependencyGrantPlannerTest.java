package com.uten.imp.features.rbac;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Set;
import java.util.function.Predicate;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class PermissionDependencyGrantPlannerTest {
    @Test void aRevokedNavigationReadDoesNotPreventAnIndependentActionGrant() {
        var definitions = List.of(permission("goods:edit", "EDIT"), permission("goods:view", "VIEW"));
        assertThat(plan(definitions, "goods:edit", Set.of(), Set.of("goods:view"), ignored -> true)).isEmpty();
        var dependencies = new PermissionDependencyCatalog(definitions);
        assertThat(dependencies.missingDependencies("goods:edit", Set.of("goods:edit"))).containsExactly("goods:view");
        assertThat(dependencies.missingHardDependencies("goods:edit", Set.of("goods:edit"))).isEmpty();
    }

    @Test void navigationOutsideTheManagerCeilingIsSkippedWhileOtherOrdinaryReadsCanBeAdded() {
        var definitions = List.of(permission("goods:create", "CREATE"), permission("goods:view", "VIEW"),
                permission("material_category:view", "VIEW"));
        assertThat(plan(definitions, "goods:create", Set.of(), Set.of(),
                read -> !"material_category:view".equals(read.getCode()))).containsExactly("goods:view");
    }

    @Test void navigationNeverAutomaticallyExpandsSensitiveOrRestrictedReads() {
        Permission adjust = permission("account:balance:adjust", "EDIT");
        Permission account = permission("account:view", "VIEW");
        Permission balance = permission("account:balance:view", "VIEW");
        balance.setSensitivity("COMMERCIAL");
        assertThat(plan(List.of(adjust, account, balance), adjust.getCode(), Set.of(), Set.of(), ignored -> true))
                .containsExactly("account:view");
        for (GrantPolicy policy : List.of(GrantPolicy.BULK_EXCLUDED, GrantPolicy.INDIVIDUAL_ONLY,
                GrantPolicy.SUPERADMIN_ONLY, GrantPolicy.NON_DELEGABLE)) {
            account.setGrantPolicy(new String[]{policy.name()});
            assertThat(plan(List.of(adjust, account, balance), adjust.getCode(), Set.of(), Set.of(),
                    read -> GrantPolicy.delegable(read.grantPolicies()))).as(policy.name()).isEmpty();
        }
    }

    @Test void anExplicitRevokeOfAHardReadStillRejectsTheNewAction() {
        var definitions = List.of(permission("sales_order_finance:confirm", "APPROVE"),
                permission("sales_order_finance:view", "VIEW"));
        assertThatThrownBy(() -> plan(definitions, "sales_order_finance:confirm", Set.of(),
                Set.of("sales_order_finance:view"), ignored -> true)).isInstanceOf(ApiException.class)
                .hasMessageContaining("明确收回").hasMessageContaining("sales_order_finance:view");
    }

    @Test void aHardReadOutsideTheGrantCeilingStillRejectsTheNewAction() {
        var definitions = List.of(permission("sales_order_finance:confirm", "APPROVE"),
                permission("sales_order_finance:view", "VIEW"));
        assertThatThrownBy(() -> plan(definitions, "sales_order_finance:confirm", Set.of(), Set.of(), ignored -> false))
                .isInstanceOf(ApiException.class).hasMessageContaining("单独确认");
    }

    @Test void anAlreadyHeldSensitiveHardReadIsPreservedAndNoNavigationRevokeIsOverridden() {
        Permission cost = permission("goods:cost:view", "VIEW"); cost.setSensitivity("COMMERCIAL");
        cost.setGrantPolicy(new String[]{GrantPolicy.BULK_EXCLUDED.name()});
        var definitions = List.of(permission("goods:cost:edit", "EDIT"), cost, permission("goods:view", "VIEW"));
        assertThat(plan(definitions, "goods:cost:edit", Set.of("goods:cost:view"), Set.of("goods:view"), ignored -> true))
                .isEmpty();
        assertThatThrownBy(() -> plan(definitions, "goods:cost:edit", Set.of(), Set.of("goods:view"), ignored -> true))
                .isInstanceOf(ApiException.class).hasMessageContaining("goods:cost:view");
    }

    @Test void aHardOrDependencyUsesTheOtherLegalReadWhenTheDefaultWasRevoked() {
        var definitions = returnDefinitions();
        assertThat(plan(definitions, "procurement_iqc_rejection:record_return", Set.of(),
                Set.of("warehouse_iqc_return:view"), ignored -> true)).containsExactly("procurement_iqc_rejection:view");
    }

    @Test void aHardOrDependencyUsesTheOtherLegalReadWhenTheDefaultCannotBeGranted() {
        var definitions = returnDefinitions();
        assertThat(plan(definitions, "procurement_iqc_rejection:record_return", Set.of(), Set.of(),
                read -> !"warehouse_iqc_return:view".equals(read.getCode())))
                .containsExactly("procurement_iqc_rejection:view");
    }

    @Test void aHardOrDependencyCannotWidenSensitiveOrCompletelyBlockedAlternatives() {
        var definitions = returnDefinitions();
        definitions.get(2).setSensitivity("COMMERCIAL");
        assertThatThrownBy(() -> plan(definitions, "procurement_iqc_rejection:record_return", Set.of(),
                Set.of("warehouse_iqc_return:view"), ignored -> true)).isInstanceOf(ApiException.class);
    }

    @Test void aHardOrDependencyRetainsAnAlreadyHeldAlternativeWithoutAddingTheOtherArea() {
        var definitions = returnDefinitions();
        assertThat(plan(definitions, "procurement_iqc_rejection:record_return",
                Set.of("procurement_iqc_rejection:view"), Set.of("warehouse_iqc_return:view"), ignored -> false)).isEmpty();
    }

    private List<Permission> returnDefinitions() {
        return List.of(permission("procurement_iqc_rejection:record_return", "EXECUTE"),
                permission("warehouse_iqc_return:view", "VIEW"), permission("procurement_iqc_rejection:view", "VIEW"));
    }

    private Set<String> plan(List<Permission> definitions, String enabled, Set<String> available,
            Set<String> blocked, Predicate<Permission> grantable) {
        return PermissionDependencyGrantPlanner.additions(definitions, Set.of(enabled), available, blocked,
                grantable, "测试授权入口");
    }

    private Permission permission(String code, String actionType) {
        Permission permission = new Permission(); permission.setCode(code); permission.setName(code);
        permission.setActionType(actionType); return permission;
    }
}
