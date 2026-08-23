package com.uten.imp.features.org.department.staffpermission;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.springframework.boot.sql.init.dependency.DependsOnDatabaseInitialization;
import org.springframework.stereotype.Component;

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
                            row.surfaceId(), row.surfaceName()));
            if (!surface.id().equals(row.surfaceId())
                    || !surface.name().equals(row.surfaceName())) {
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
                        value.id(),
                        value.name(),
                        Collections.unmodifiableSet(
                                new LinkedHashSet<>(value.permissionCodes())))));
        return Collections.unmodifiableMap(snapshot);
    }

    private record Surface(
            UUID id,
            String name,
            Set<String> permissionCodes) {
    }

    private record MutableSurface(
            UUID id,
            String name,
            LinkedHashSet<String> permissionCodes) {
        private MutableSurface(UUID id, String name) {
            this(id, name, new LinkedHashSet<>());
        }
    }
}
