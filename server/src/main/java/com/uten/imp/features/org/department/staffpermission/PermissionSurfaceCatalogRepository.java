package com.uten.imp.features.org.department.staffpermission;

import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

import java.util.List;
import java.util.UUID;

/**
 * One-query read model for the migration-owned page-permission catalog.
 *
 * <p>The left joins intentionally retain enabled surfaces that currently have
 * no permission rows. Such a surface remains known but exposes an empty,
 * fail-closed catalog.</p>
 */
@Repository
@RequiredArgsConstructor
public class PermissionSurfaceCatalogRepository {

    private final JdbcTemplate jdbc;

    public List<CatalogRow> loadEnabledCatalog() {
        return jdbc.query("""
                SELECT surface.id AS surface_id,
                       surface.surface_key,
                       surface.name AS surface_name,
                       permission.id AS permission_id,
                       permission.code AS permission_code,
                       permission.name AS permission_name,
                       permission.module AS permission_module,
                       permission.category AS permission_category,
                       permission.action_type,
                       permission.description,
                       permission.sort_order
                FROM permission_surfaces surface
                LEFT JOIN permission_surface_permissions link
                  ON link.surface_id = surface.id
                LEFT JOIN permissions permission
                  ON permission.id = link.permission_id
                 AND permission.active = TRUE
                WHERE surface.enabled = TRUE
                ORDER BY surface.sort_order,
                         surface.surface_key,
                         permission.sort_order,
                         permission.code
                """, (rs, rowNum) -> new CatalogRow(
                rs.getObject("surface_id", UUID.class),
                rs.getString("surface_key"),
                rs.getString("surface_name"),
                rs.getObject("permission_id", UUID.class),
                rs.getString("permission_code"),
                rs.getString("permission_name"),
                rs.getString("permission_module"),
                rs.getString("permission_category"),
                rs.getString("action_type"),
                rs.getString("description"),
                rs.getObject("sort_order", Integer.class)));
    }

    public record CatalogRow(
            UUID surfaceId,
            String surfaceKey,
            String surfaceName,
            UUID permissionId,
            String permissionCode,
            String permissionName,
            String permissionModule,
            String permissionCategory,
            String actionType,
            String description,
            Integer sortOrder) {
    }
}
