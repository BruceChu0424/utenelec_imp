package com.uten.imp.security;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;

import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.stream.Collectors;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * permissions-06：权限目录与服务端代码双向相等。
 * <ul>
 *   <li>目录里每个码都至少在服务端被引用一次(端点守卫或服务层显式判断)，不存在
 *       「只有前端认、服务端不认」的码；</li>
 *   <li>服务端代码里凡是形如「目录资源:动作」的字符串都必须是目录码，停用/改名后的旧码
 *       不能残留在服务层判断里；</li>
 *   <li>前端 Perm 常量必须全部是目录码。</li>
 * </ul>
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class PermissionCatalogBidirectionalContractTest {

    /** 形状像权限码、但不是权限码的服务端字面量(联系方式类型键等)。 */
    private static final Set<String> NON_PERMISSION_LITERALS = Set.of(
            "clients:email", "clients:fax", "clients:mobile", "clients:phone", "clients:website",
            "suppliers:email", "suppliers:fax", "suppliers:mobile", "suppliers:phone", "suppliers:website",
            "reason:null");

    @Test
    void everyCatalogCodeIsReferencedByServerCode() throws Exception {
        Set<String> catalog = PermissionCatalogTestSupport.catalogCodes();
        Set<String> referenced = new LinkedHashSet<>(PermissionCatalogTestSupport.javaLiterals());
        PermissionCatalogTestSupport.guards().forEach(guard -> referenced.addAll(guard.codes()));

        Set<String> unreferenced = new LinkedHashSet<>(catalog);
        unreferenced.removeAll(referenced);
        assertThat(unreferenced)
                .as("目录码没有任何服务端引用(只在前端生效的码必须删除或补服务端强制)")
                .isEmpty();
    }

    @Test
    void serverCodeLiteralsNeverPointAtRetiredOrRenamedCodes() throws Exception {
        Set<String> catalog = PermissionCatalogTestSupport.catalogCodes();
        Set<String> resources = catalog.stream()
                .map(code -> code.substring(0, code.indexOf(':')))
                .collect(Collectors.toSet());
        List<String> stale = PermissionCatalogTestSupport.javaLiterals().stream()
                .filter(literal -> !NON_PERMISSION_LITERALS.contains(literal))
                .filter(literal -> resources.contains(literal.substring(0, literal.indexOf(':'))))
                .filter(literal -> !catalog.contains(literal))
                .sorted()
                .toList();
        assertThat(stale)
                .as("服务端字面量引用了目录里不存在的权限码")
                .isEmpty();
    }

    @Test
    void frontendPermConstantsAreCatalogCodes() throws Exception {
        Set<String> catalog = PermissionCatalogTestSupport.catalogCodes();
        List<String> unknown = PermissionCatalogTestSupport.frontendPermConstants().stream()
                .filter(code -> !catalog.contains(code))
                .sorted()
                .toList();
        assertThat(unknown)
                .as("前端 Perm 常量里有目录不存在的码(停用码或只在前端生效的码)")
                .isEmpty();
    }
}
