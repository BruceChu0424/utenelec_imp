package com.uten.imp.features.ai.chat;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.AiFeatureDirectoryPort;
import com.uten.imp.features.rbac.directory.AiChatFeatureDirectory;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * P1-9 / P1-6: the modules and page names a user can open come from the feature directory (read through its port, with
 * the client route guard's rule) and their permissions only.
 */
class AiChatUserScopeTest {
    private static final ObjectMapper JSON = new ObjectMapper();

    static AiChatUserScope directory() {
        var features = List.of(
                Map.of("route", "/sales/orders/new", "module", "销售管理", "title", "销售订货单", "aliases", List.of("订货单"),
                        "paths", List.of(List.of("工作台", "销售管理", "销售订货单")), "anyOf", List.of("sales_order:view"), "allOf", List.of()),
                Map.of("route", "/production/reports", "module", "生产管理", "title", "生产报工", "aliases", List.of(),
                        "paths", List.of(List.of("工作台", "生产管理", "生产报工")), "anyOf", List.of("production_execution:view"),
                        "allOf", List.of()),
                // A module home page opens when one of its cards opens, whatever permissions it lists itself.
                Map.of("route", "/production", "module", "生产部", "title", "生产部", "aliases", List.of(), "paths", List.of(),
                        "anyOf", List.of("production_execution:view", "finance_report:view"), "allOf", List.of(),
                        "hubOf", List.of("/production/reports")),
                Map.of("route", "/finance/reports", "module", "钱流管理", "title", "财务报表", "aliases", List.of(), "paths", List.of(),
                        "anyOf", List.of(), "allOf", List.of("finance_report:view", "finance:view")),
                Map.of("route", "/settings", "module", "我的", "title", "设置", "aliases", List.of(), "paths", List.of(),
                        "allOf", List.of()));
        return new AiChatUserScope(AiChatFeatureDirectory.fromJson(JSON.valueToTree(Map.of("features", features))));
    }

    private static AuthUser user(Set<String> permissions, boolean superAdmin) {
        return new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "worker", permissions, false, true, superAdmin);
    }

    @Test void onlyThePagesTheUsersPermissionsOpenAreListed() {
        var scope = directory().of(user(Set.of("ai:use", "production_execution:view", "finance_report:view"), false));
        assertThat(scope.modules()).containsExactly("生产管理", "生产部", "我的");
        assertThat(scope.labels()).contains("生产报工", "工作台 > 生产管理 > 生产报工", "设置")
                .doesNotContain("销售订货单", "订货单", "财务报表");
        // allOf needs every permission; anyOf needs one; a module home page needs one of its cards.
        var finance = directory().of(user(Set.of("finance_report:view", "finance:view"), false));
        assertThat(finance.modules()).containsExactly("钱流管理", "我的");
        assertThat(directory().of(user(Set.of(), true)).modules()).containsExactly("销售管理", "生产管理", "生产部", "钱流管理", "我的");
    }

    @Test void theRealDirectoryLoadsAndAnEmptyOneNamesNothing() {
        var real = new AiChatUserScope(new AiChatFeatureDirectory(JSON)).of(user(Set.of(), true));
        assertThat(real.modules()).as("the generated directory is packaged").isNotEmpty();
        assertThat(AiChatUserScope.NONE.of(user(Set.of(), true))).isEqualTo(AiFeatureDirectoryPort.Openable.EMPTY);
        assertThat(AiChatUserScope.domainNames(Set.of("WAREHOUSE", "SELF", "SALES"))).containsExactly("个人事务", "销售", "仓库");
    }
}
