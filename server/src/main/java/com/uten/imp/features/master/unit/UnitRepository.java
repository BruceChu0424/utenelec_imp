package com.uten.imp.features.master.unit;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;

import java.util.Collection;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

/**
 * 基本单位主档仓库。
 *
 * <p>列表查询用 {@link JpaSpecificationExecutor}（动态：keyword + 字段精确 + 空值白名单），
 * 范式同 {@code GoodsRepository}（无 categoryId——单位扁平无分类）。
 */
public interface UnitRepository extends JpaRepository<Unit, UUID>, JpaSpecificationExecutor<Unit> {

    /** 迁移/校验用：按老库主键反查。 */
    Optional<Unit> findByLegacyId(Integer legacyId);

    /** 批量按 legacy_id 取未软删记录（货品单位名称解析用）。 */
    List<Unit> findByLegacyIdInAndDeletedFalse(Collection<Integer> legacyIds);
}
