package com.uten.imp.features.rbac;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.UUID;

public interface UserPermissionOverrideRepository extends JpaRepository<UserPermissionOverride, UserPermissionOverrideId> {

    /** 取某用户的全部覆盖（permission_code, effect），权限合成与管理端列表共用。 */
    @Query(value = """
            SELECT p.code, o.effect
            FROM user_permission_overrides o
            JOIN permissions p ON p.id = o.permission_id
            WHERE o.user_id = :userId
            """, nativeQuery = true)
    List<Object[]> findCodeAndEffectByUserId(@Param("userId") UUID userId);

    void deleteByIdUserId(UUID userId);
}
