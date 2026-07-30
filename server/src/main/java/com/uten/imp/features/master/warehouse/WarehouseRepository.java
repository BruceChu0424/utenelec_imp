package com.uten.imp.features.master.warehouse;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;

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

    /** 迁移/校验用：按老库主键反查。 */
    Optional<Warehouse> findByLegacyId(Integer legacyId);

    /** 批量按 legacy_id 取未软删记录（单据仓库解析用）。 */
    List<Warehouse> findByLegacyIdInAndDeletedFalse(Collection<Integer> legacyIds);
}
