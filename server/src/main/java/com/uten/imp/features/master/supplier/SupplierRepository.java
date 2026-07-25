package com.uten.imp.features.master.supplier;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;

import java.util.Optional;
import java.util.UUID;

/**
 * 供应商主档仓库。
 *
 * <p>列表查询改用 {@link JpaSpecificationExecutor}（动态：子树 + keyword 多字段 OR + 字段精确 +
 * 空值白名单），范式同 {@code GoodsRepository} / {@code GoodsService}。
 */
public interface SupplierRepository extends JpaRepository<Supplier, UUID>, JpaSpecificationExecutor<Supplier> {

    /** 迁移/校验用：按老库主键反查。 */
    Optional<Supplier> findByLegacyId(Integer legacyId);
}
