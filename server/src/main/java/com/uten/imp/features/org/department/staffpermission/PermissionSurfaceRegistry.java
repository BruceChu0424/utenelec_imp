package com.uten.imp.features.org.department.staffpermission;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.springframework.boot.sql.init.dependency.DependsOnDatabaseInitialization;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/**
 * Immutable runtime snapshot of the migration-owned page-permission catalog.
 *
 * <p>The database is the only page/surface directory. The repository is read
 * exactly once while this component is constructed; requests never expand
 * permission-code prefixes and never fall back to a compiled-in catalog.</p>
 *
 * <p>Surfaces form an optional one-level hierarchy (V812): a hub surface
 * points at its card surfaces through {@code parent_surface_key}. The hub
 * permission drawer then works on the whole tree, while a code belongs to
 * the first surface of the tree that registers it (children win over the
 * root; sibling order follows the catalog sort order).</p>
 */
@Component
@DependsOnDatabaseInitialization
public class PermissionSurfaceRegistry {

    private final Map<String, Surface> surfaces;

    public PermissionSurfaceRegistry(
            PermissionSurfaceCatalogRepository catalogRepository) {
        this.surfaces = immutableSnapshot(
                Objects.requireNonNull(catalogRepository, "catalogRepository")
                        .loadEnabledCatalog());
    }

    public boolean isKnown(String surfaceKey) {
        return surfaceKey != null && surfaces.containsKey(surfaceKey);
    }

    public Set<String> knownKeys() {
        return surfaces.keySet();
    }

    /** Returns the exact active permission codes registered for one surface. */
    public Set<String> permissionsFor(String surfaceKey) {
        return require(surfaceKey).permissionCodes();
    }

    /** One surface's display name (drawer section title source). */
    public String nameOf(String surfaceKey) {
        return require(surfaceKey).name();
    }

    public boolean contains(String surfaceKey, String permissionCode) {
        return permissionCode != null
                && permissionsFor(surfaceKey).contains(permissionCode);
    }

    public void requireContains(String surfaceKey, String permissionCode) {
        if (!contains(surfaceKey, permissionCode)) {
            throw new ApiException(
                    ErrorCode.FORBIDDEN,
                    "该权限不属于当前页面: " + permissionCode);
        }
    }

    public void requireKnown(String surfaceKey) {
        permissionsFor(surfaceKey);
    }

    /**
     * The surface plus its descendant card surfaces, root first and children
     * in catalog sort order. Flat surfaces return a single-element list.
     */
    public List<Surface> surfaceTree(String rootKey) {
        Surface root = require(rootKey);
        List<Surface> tree = new ArrayList<>();
        tree.add(root);
        tree.addAll(childrenOf(rootKey));
        return List.copyOf(tree);
    }

    /** All permission codes reachable from the root surface (self + children). */
    public Set<String> treePermissions(String rootKey) {
        Set<String> codes = new LinkedHashSet<>();
        for (Surface surface : surfaceTree(rootKey)) {
            codes.addAll(surface.permissionCodes());
        }
        return Collections.unmodifiableSet(codes);
    }

    public boolean treeContains(String rootKey, String permissionCode) {
        return permissionCode != null
                && treePermissions(rootKey).contains(permissionCode);
    }

    /**
     * The surface of the tree a permission write should be attributed to:
     * the first child that registers the code wins, otherwise the root.
     * Delegation rows keep validating "surface contains code" this way.
     */
    public String treeOwnerSurface(String rootKey, String permissionCode) {
        if (permissionCode == null) {
            return null;
        }
        for (Surface surface : childrenOf(rootKey)) {
            if (surface.permissionCodes().contains(permissionCode)) {
                return surface.key();
            }
        }
        return require(rootKey).permissionCodes().contains(permissionCode)
                ? rootKey
                : null;
    }

    private List<Surface> childrenOf(String rootKey) {
        List<Surface> children = new ArrayList<>();
        for (Surface surface : surfaces.values()) {
            if (rootKey.equals(surface.parentKey())) {
                children.add(surface);
            }
        }
        return children;
    }

    private Surface require(String surfaceKey) {
        if (surfaceKey == null || surfaceKey.isBlank()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "surfaceKey 不能为空");
        }
        Surface surface = surfaces.get(surfaceKey);
        if (surface == null) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "未知页面权限范围: " + surfaceKey);
        }
        return surface;
    }

    private static Map<String, Surface> immutableSnapshot(
            List<PermissionSurfaceCatalogRepository.CatalogRow> rows) {
        if (rows == null) {
            throw new IllegalStateException("页面权限目录查询返回 null");
        }

        Map<String, MutableSurface> accumulated = new LinkedHashMap<>();
        for (PermissionSurfaceCatalogRepository.CatalogRow row : rows) {
            if (row == null
                    || row.surfaceId() == null
                    || row.surfaceKey() == null
                    || row.surfaceKey().isBlank()
                    || row.surfaceName() == null
                    || row.surfaceName().isBlank()) {
                throw new IllegalStateException("页面权限目录包含不完整的页面行");
            }
            MutableSurface surface = accumulated.computeIfAbsent(
                    row.surfaceKey(),
                    ignored -> new MutableSurface(
                            row.surfaceId(),
                            row.surfaceName(),
                            row.parentSurfaceKey()));
            if (!surface.id().equals(row.surfaceId())
                    || !surface.name().equals(row.surfaceName())
                    || !Objects.equals(surface.parentKey(), row.parentSurfaceKey())) {
                throw new IllegalStateException(
                        "页面权限目录键映射到多个页面身份: " + row.surfaceKey());
            }

            if (row.permissionId() == null && row.permissionCode() == null) {
                continue;
            }
            if (row.permissionId() == null
                    || row.permissionCode() == null
                    || row.permissionCode().isBlank()) {
                throw new IllegalStateException(
                        "页面权限目录包含不完整的权限关联: " + row.surfaceKey());
            }
            surface.permissionCodes().add(row.permissionCode());
        }

        Map<String, Surface> snapshot = new LinkedHashMap<>();
        accumulated.forEach((key, value) -> snapshot.put(
                key,
                new Surface(
                        key,
                        value.id(),
                        value.name(),
                        value.parentKey(),
                        Collections.unmodifiableSet(
                                new LinkedHashSet<>(value.permissionCodes())))));

        // 层级快照校验：父必须存在，且只允许一层(hub → 卡片面)。
        // 多层/环属于迁移种子错误，宁可启动失败也不带病运行。
        for (Surface surface : snapshot.values()) {
            String parentKey = surface.parentKey();
            if (parentKey == null) {
                continue;
            }
            Surface parent = snapshot.get(parentKey);
            if (parent == null) {
                throw new IllegalStateException(
                        "权限面的父面不存在于启用目录: " + surface.key());
            }
            if (parent.parentKey() != null) {
                throw new IllegalStateException(String.format(
                        "权限面层级只允许一层，%s 的父面 %s 也有父面",
                        surface.key(), parentKey));
            }
            if (parent.key().equals(surface.key())) {
                throw new IllegalStateException("权限面不能以自己为父面: " + surface.key());
            }
        }
        return Collections.unmodifiableMap(snapshot);
    }

    /** One page surface: identity plus its registered permission codes. */
    public record Surface(
            String key,
            UUID id,
            String name,
            String parentKey,
            Set<String> permissionCodes) {
    }

    private record MutableSurface(
            UUID id,
            String name,
            String parentKey,
            LinkedHashSet<String> permissionCodes) {
        private MutableSurface(UUID id, String name, String parentKey) {
            this(id, name, parentKey, new LinkedHashSet<>());
        }
    }
}
