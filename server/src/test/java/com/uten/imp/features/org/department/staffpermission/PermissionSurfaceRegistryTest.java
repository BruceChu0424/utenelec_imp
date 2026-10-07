package com.uten.imp.features.org.department.staffpermission;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class PermissionSurfaceRegistryTest {

    @Test
    void loadsRepositoryOnceAndPublishesAnImmutableExactSnapshot() {
        PermissionSurfaceCatalogRepository repository =
                mock(PermissionSurfaceCatalogRepository.class);
        UUID orderSurfaceId = UUID.randomUUID();
        when(repository.loadEnabledCatalog()).thenReturn(List.of(
                row(orderSurfaceId, "sales.order", "销售订货", "sales_order:view"),
                row(orderSurfaceId, "sales.order", "销售订货", "sales_order:edit"),
                empty(UUID.randomUUID(), "quality.lab-test", "检测记录")));

        PermissionSurfaceRegistry registry =
                new PermissionSurfaceRegistry(repository);

        assertEquals(
                Set.of("sales_order:view", "sales_order:edit"),
                registry.permissionsFor("sales.order"));
        assertTrue(registry.contains("sales.order", "sales_order:view"));
        assertFalse(registry.contains("sales.order", "sales_order:create"));
        assertEquals(Set.of(), registry.permissionsFor("quality.lab-test"));
        assertThrows(
                UnsupportedOperationException.class,
                () -> registry.permissionsFor("sales.order").add("sales_order:create"));
        assertThrows(
                UnsupportedOperationException.class,
                () -> registry.knownKeys().remove("sales.order"));

        registry.contains("sales.order", "sales_order:edit");
        registry.requireKnown("quality.lab-test");
        verify(repository, times(1)).loadEnabledCatalog();
    }

    @Test
    void rejectsUnknownBlankAndCrossSurfaceCodesFailClosed() {
        PermissionSurfaceCatalogRepository repository =
                mock(PermissionSurfaceCatalogRepository.class);
        when(repository.loadEnabledCatalog()).thenReturn(List.of(
                row(
                        UUID.randomUUID(),
                        "warehouse.stock-movement",
                        "出入库流水",
                        "stock:view")));
        PermissionSurfaceRegistry registry =
                new PermissionSurfaceRegistry(repository);

        ApiException blank = assertThrows(
                ApiException.class,
                () -> registry.permissionsFor(" "));
        assertEquals(ErrorCode.VALIDATION_FAILED, blank.getCode());

        ApiException unknown = assertThrows(
                ApiException.class,
                () -> registry.permissionsFor("warehouse.inventory"));
        assertEquals(ErrorCode.VALIDATION_FAILED, unknown.getCode());

        ApiException crossSurface = assertThrows(
                ApiException.class,
                () -> registry.requireContains(
                        "warehouse.stock-movement",
                        "stock:balance:adjust"));
        assertEquals(ErrorCode.FORBIDDEN, crossSurface.getCode());
    }

    @Test
    void inconsistentOrIncompleteRowsAbortSnapshotConstruction() {
        PermissionSurfaceCatalogRepository inconsistent =
                mock(PermissionSurfaceCatalogRepository.class);
        when(inconsistent.loadEnabledCatalog()).thenReturn(List.of(
                row(
                        UUID.randomUUID(),
                        "sales.order",
                        "销售订货",
                        "sales_order:view"),
                row(
                        UUID.randomUUID(),
                        "sales.order",
                        "销售订货",
                        "sales_order:edit")));
        assertThrows(
                IllegalStateException.class,
                () -> new PermissionSurfaceRegistry(inconsistent));

        PermissionSurfaceCatalogRepository incomplete =
                mock(PermissionSurfaceCatalogRepository.class);
        when(incomplete.loadEnabledCatalog()).thenReturn(List.of(
                new PermissionSurfaceCatalogRepository.CatalogRow(
                        UUID.randomUUID(),
                        "sales.order",
                        "销售订货",
                        null,
                        UUID.randomUUID(),
                        null,
                        null,
                        null,
                        null,
                        null,
                        null,
                        null)));
        assertThrows(
                IllegalStateException.class,
                () -> new PermissionSurfaceRegistry(incomplete));
    }

    @Test
    void surfaceTreeWalksRootFirstThenChildrenInCatalogOrder() {
        UUID hubId = UUID.randomUUID();
        PermissionSurfaceCatalogRepository repository =
                mock(PermissionSurfaceCatalogRepository.class);
        when(repository.loadEnabledCatalog()).thenReturn(List.of(
                childRow(hubId, "sales.hub", "销售管理", null, "sales_order:priority"),
                childRow(UUID.randomUUID(), "sales.quote", "销售报价", "sales.hub", "sales_quote:view"),
                childRow(UUID.randomUUID(), "sales.order", "销售订货", "sales.hub", "sales_order:view"),
                childRow(UUID.randomUUID(), "sales.tasks", "销售任务中心", "sales.hub", "sales_quote:view")));

        PermissionSurfaceRegistry registry =
                new PermissionSurfaceRegistry(repository);

        List<PermissionSurfaceRegistry.Surface> tree =
                registry.surfaceTree("sales.hub");
        assertEquals(
                List.of("sales.hub", "sales.quote", "sales.order", "sales.tasks"),
                tree.stream().map(PermissionSurfaceRegistry.Surface::key).toList());
        assertEquals("销售管理", registry.nameOf("sales.hub"));

        // 树全集 = 根 + 子面；子面优先归属（目录序第一个含码的子面）。
        assertEquals(
                Set.of("sales_order:priority", "sales_quote:view", "sales_order:view"),
                registry.treePermissions("sales.hub"));
        assertTrue(registry.treeContains("sales.hub", "sales_quote:view"));
        assertFalse(registry.treeContains("sales.hub", "stock:view"));
        assertEquals(
                "sales.quote",
                registry.treeOwnerSurface("sales.hub", "sales_quote:view"));
        assertEquals(
                "sales.hub",
                registry.treeOwnerSurface("sales.hub", "sales_order:priority"));
        assertNull(registry.treeOwnerSurface("sales.hub", "stock:view"));

        // 平级页面（无子面）的树就是自己。
        assertEquals(
                List.of("sales.quote"),
                registry.surfaceTree("sales.quote").stream()
                        .map(PermissionSurfaceRegistry.Surface::key)
                        .toList());
    }

    @Test
    void hierarchySnapshotRejectsMissingParentsAndSecondLevels() {
        // 父面不存在于启用目录。
        PermissionSurfaceCatalogRepository orphanParent =
                mock(PermissionSurfaceCatalogRepository.class);
        when(orphanParent.loadEnabledCatalog()).thenReturn(List.of(
                childRow(UUID.randomUUID(), "sales.quote", "销售报价", "sales.hub", "sales_quote:view")));
        assertThrows(
                IllegalStateException.class,
                () -> new PermissionSurfaceRegistry(orphanParent));

        // 第二层子面（孙面）拒绝加载：层级只允许一层。
        UUID hubId = UUID.randomUUID();
        PermissionSurfaceCatalogRepository grandChild =
                mock(PermissionSurfaceCatalogRepository.class);
        when(grandChild.loadEnabledCatalog()).thenReturn(List.of(
                childRow(hubId, "sales.hub", "销售管理", null, "sales_order:priority"),
                childRow(UUID.randomUUID(), "sales.quote", "销售报价", "sales.hub", "sales_quote:view"),
                childRow(UUID.randomUUID(), "sales.quote.edit", "报价编辑", "sales.quote", "sales_quote:edit")));
        assertThrows(
                IllegalStateException.class,
                () -> new PermissionSurfaceRegistry(grandChild));
    }

    private static PermissionSurfaceCatalogRepository.CatalogRow row(
            UUID surfaceId,
            String surfaceKey,
            String surfaceName,
            String permissionCode) {
        return new PermissionSurfaceCatalogRepository.CatalogRow(
                surfaceId,
                surfaceKey,
                surfaceName,
                null,
                UUID.randomUUID(),
                permissionCode,
                permissionCode,
                "test",
                "test",
                "VIEW",
                permissionCode,
                1);
    }

    private static PermissionSurfaceCatalogRepository.CatalogRow childRow(
            UUID surfaceId,
            String surfaceKey,
            String surfaceName,
            String parentSurfaceKey,
            String permissionCode) {
        return new PermissionSurfaceCatalogRepository.CatalogRow(
                surfaceId,
                surfaceKey,
                surfaceName,
                parentSurfaceKey,
                UUID.randomUUID(),
                permissionCode,
                permissionCode,
                "test",
                "test",
                "VIEW",
                permissionCode,
                1);
    }

    private static PermissionSurfaceCatalogRepository.CatalogRow empty(
            UUID surfaceId,
            String surfaceKey,
            String surfaceName) {
        return new PermissionSurfaceCatalogRepository.CatalogRow(
                surfaceId,
                surfaceKey,
                surfaceName,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null);
    }
}
