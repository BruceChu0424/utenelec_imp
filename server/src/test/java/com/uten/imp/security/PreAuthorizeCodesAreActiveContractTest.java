package com.uten.imp.security;

import com.uten.imp.features.visitor.VisitorAuthorities;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;

import java.util.List;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * permissions-05：服务端每个 {@code hasAuthority / hasAnyAuthority} 引用的码都必须是目录里的活码
 * (V655 起停用即删除，所以「在目录里」就是「活码」)。唯一例外是访客令牌的
 * {@code visitor_portal:} 命名空间与首登改密的 {@code CHANGE_PASSWORD}，二者都不属于员工权限目录。
 *
 * <p>码从编译产物里反射读取：常量拼接的注解值在编译期已内联，不会漏掉
 * {@code "hasAuthority('" + X.VIEW + "')"} 这种写法。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class PreAuthorizeCodesAreActiveContractTest {

    @Test
    void everyPreAuthorizeCodeIsACatalogCode() throws Exception {
        Set<String> catalog = PermissionCatalogTestSupport.catalogCodes();
        List<PermissionCatalogTestSupport.Guard> guards = PermissionCatalogTestSupport.guards();

        assertThat(guards).as("反射扫描应找到全部端点守卫").hasSizeGreaterThan(800);
        List<String> violations = guards.stream()
                .flatMap(guard -> guard.codes().stream()
                        .filter(code -> !catalog.contains(code)
                                && !code.startsWith(VisitorAuthorities.NAMESPACE)
                                && !"CHANGE_PASSWORD".equals(code))
                        .map(code -> guard.where() + " -> " + code))
                .distinct()
                .sorted()
                .toList();
        assertThat(violations)
                .as("@PreAuthorize 引用了目录里不存在(已停用/已改名)的权限码")
                .isEmpty();
    }

    @Test
    void visitorPortalAuthoritiesNeverLeakIntoTheStaffCatalog() {
        assertThat(PermissionCatalogTestSupport.catalogCodes())
                .noneMatch(code -> code.startsWith(VisitorAuthorities.NAMESPACE));
        assertThat(VisitorAuthorities.ALL).allMatch(code -> code.startsWith(VisitorAuthorities.NAMESPACE));
    }
}
