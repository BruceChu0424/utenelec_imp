package com.uten.imp.features.rbac;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.Collection;
import java.util.List;
import java.util.UUID;

public interface UserRoleRepository extends JpaRepository<UserRole, UserRoleId> {

    List<UserRole> findByIdUserId(UUID userId);

    @Query(value = """
            SELECT r.code
            FROM user_roles ur
            JOIN roles r ON r.id = ur.role_id
            WHERE ur.user_id = :userId
            """, nativeQuery = true)
    List<String> findRoleCodesByUserId(@Param("userId") UUID userId);

    /** 取这些用户对应的角色 id（用于批量鉴权/审计）。 */
    @Query(value = """
            SELECT ur.role_id FROM user_roles ur WHERE ur.user_id IN (:userIds)
            """, nativeQuery = true)
    List<UUID> findRoleIdsByUserIds(@Param("userIds") Collection<UUID> userIds);

    void deleteByIdUserId(UUID userId);
}
