package com.uten.imp.features.master.warehouse;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;
import org.springframework.data.jpa.repository.Lock;
import org.springframework.data.jpa.repository.Query;
import jakarta.persistence.LockModeType;

import java.util.Collection;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

/**
 * 仓库主档仓库。
 *
 * <p>列表查询用 {@link JpaSpecificationExecutor}（动态：keyword + 字段精确 + 空值白名单），
 * 范式同 {@code CurrencyRepository}（扁平表，无 categoryId）。
 */
public interface WarehouseRepository extends JpaRepository<Warehouse, UUID>, JpaSpecificationExecutor<Warehouse> {

    /** Keep warehouse status and ancestry stable until the new document transaction completes. */
    @Lock(LockModeType.PESSIMISTIC_READ)
    @Query("select w from Warehouse w where w.deleted = false and w.id in :ids order by w.id")
    List<Warehouse> findAllForNewSelection(@org.springframework.data.repository.query.Param("ids") Collection<UUID> ids);

    /** 迁移/校验用：按老库主键反查。 */
    Optional<Warehouse> findByLegacyId(Integer legacyId);

    /** 批量按 legacy_id 取未软删记录（单据仓库解析用）。 */
    List<Warehouse> findByLegacyIdInAndDeletedFalse(Collection<Integer> legacyIds);
}
