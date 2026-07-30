package com.uten.imp.features.master.goods;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;

import java.util.Optional;
import java.util.UUID;

/**
 * 货品主档仓库。
 *
 * <p>列表查询改用 {@link JpaSpecificationExecutor}（动态：子树 + keyword + 字段精确 + 空值白名单），
 * 范式同 {@code EmployeeRepository} / {@code EmployeeQueryService}。
 */
public interface GoodsRepository extends JpaRepository<Goods, UUID>, JpaSpecificationExecutor<Goods> {

    /** 迁移/校验用：按老库主键反查。 */
    Optional<Goods> findByLegacyId(Integer legacyId);
}
