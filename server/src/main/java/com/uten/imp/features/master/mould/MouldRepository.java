package com.uten.imp.features.master.mould;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;

import java.util.Optional;
import java.util.UUID;

/**
 * 模具主档仓库。
 *
 * <p>列表查询改用 {@link JpaSpecificationExecutor}（动态：子树 + keyword + 字段精确 + 空值白名单），
 * 范式同 {@code GoodsRepository} / {@code GoodsService}。
 */
public interface MouldRepository extends JpaRepository<Mould, UUID>, JpaSpecificationExecutor<Mould> {

    /** 迁移/校验用：按老库主键反查。 */
    Optional<Mould> findByLegacyId(Integer legacyId);
}
