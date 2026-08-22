package com.uten.imp.features.rbac;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Lock;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import jakarta.persistence.LockModeType;
import java.util.Collection;
import java.util.List;
import java.util.UUID;

public interface UserPermissionOverrideRepository extends JpaRepository<UserPermissionOverride, UserPermissionOverrideId> {

    /** 取某用户的全部覆盖（permission_code, effect, authority_source）。 */
    @Query(value = """
            SELECT p.code, o.effect, o.authority_source
            FROM user_permission_overrides o
            JOIN permissions p ON p.id = o.permission_id
            WHERE o.user_id = :userId
              AND o.active = TRUE
              AND p.active = TRUE
            """, nativeQuery = true)
    List<Object[]> findCodeAndEffectByUserId(@Param("userId") UUID userId);

    List<UserPermissionOverride> findAllByIdUserId(UUID userId);

    @Lock(LockModeType.PESSIMISTIC_WRITE)
    @Query("""
            SELECT permissionOverride
            FROM UserPermissionOverride permissionOverride
            WHERE permissionOverride.id IN :ids
            ORDER BY permissionOverride.id.userId,
                     permissionOverride.id.permissionId
            """)
    List<UserPermissionOverride> findAllByIdForUpdate(
            @Param("ids") Collection<UserPermissionOverrideId> ids);

    @Lock(LockModeType.PESSIMISTIC_WRITE)
    @Query("""
            SELECT permissionOverride
            FROM UserPermissionOverride permissionOverride
            WHERE permissionOverride.id.userId = :userId
            ORDER BY permissionOverride.id.permissionId
            """)
    List<UserPermissionOverride> findAllByUserIdForUpdate(
            @Param("userId") UUID userId);

}
