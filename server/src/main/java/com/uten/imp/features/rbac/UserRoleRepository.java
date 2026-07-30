package com.uten.imp.features.rbac;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.Collection;
import java.util.List;
import java.util.UUID;

public interface UserRoleRepository extends JpaRepository<UserRole, UserRoleId> {

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

    /** 按角色码反查用户（业务链通知广播：buyer/planner 等）。 */
    @Query(value = """
            SELECT ur.user_id FROM user_roles ur JOIN roles r ON r.id = ur.role_id
            WHERE r.code = :code
            """, nativeQuery = true)
    List<UUID> findUserIdsByRoleCode(@Param("code") String code);

    void deleteByIdUserId(UUID userId);
}
