package com.uten.imp.features.rbac;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.Collection;
import java.util.List;
import java.util.UUID;

public interface RolePermissionRepository extends JpaRepository<RolePermission, RolePermissionId> {

    /** 取这些角色对应的所有权限 code（去重）。 */
    @Query(value = """
            SELECT DISTINCT p.code
            FROM role_permissions rp
            JOIN permissions p ON p.id = rp.permission_id
            WHERE rp.role_id IN (:roleIds)
            """, nativeQuery = true)
    List<String> findPermissionCodesByRoleIds(@Param("roleIds") Collection<UUID> roleIds);

    void deleteByIdRoleId(UUID roleId);
}
