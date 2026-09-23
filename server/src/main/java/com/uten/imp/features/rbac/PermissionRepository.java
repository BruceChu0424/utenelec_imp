package com.uten.imp.features.rbac;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.Collection;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

/** 权限目录。目录里只有活码(停用即删除)，所以这里不再有 active 过滤。 */
public interface PermissionRepository extends JpaRepository<Permission, UUID> {

    Optional<Permission> findByCode(String code);

    List<Permission> findByCodeIn(Collection<String> codes);

    /** 超级管理员的有效权限 = 全部目录码(含超管专属码)。 */
    @Query(value = "SELECT code FROM permissions", nativeQuery = true)
    List<String> findAllCodes();

    /** 全员基础包(permissions.baseline)。 */
    @Query(value = "SELECT code FROM permissions WHERE baseline", nativeQuery = true)
    List<String> findBaselineCodes();

    /** 事务级互斥：同一时刻只有一次基础包保存在读-算差量-写。 */
    @Query(value = "SELECT CAST(pg_advisory_xact_lock(hashtextextended('PERMISSION_BASELINE', 0)) AS text)",
            nativeQuery = true)
    String lockBaseline();

    /** 只改真正变化的行：基础包无改动时 0 行写入、0 行审计。 */
    @Modifying(flushAutomatically = true, clearAutomatically = true)
    @Query(value = """
            UPDATE permissions
            SET baseline = :baseline, updated_at = now(), updated_by = :actor
            WHERE code IN (:codes) AND baseline <> :baseline
            """, nativeQuery = true)
    int updateBaseline(@Param("codes") Collection<String> codes,
                       @Param("baseline") boolean baseline,
                       @Param("actor") UUID actor);
}
