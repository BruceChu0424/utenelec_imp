package com.uten.imp.features.master.unit;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;
import org.springframework.data.jpa.repository.Query;

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

    /** 手工新建时分配合成 legacy_id（货品 unit_legacy_id 引用 legacy_id，新单位须有值才可选/可存）。 */
    @Query("select max(u.legacyId) from Unit u")
    Integer findMaxLegacyId();

    /** 名称查重（大小写不敏感，货品编辑内联新建单位用）。 */
    boolean existsByNameIgnoreCaseAndDeletedFalse(String name);

    /** 编号查重（仅未软删）—— 手动编号校验用。 */
    boolean existsByCodeAndDeletedFalse(String code);

    /** 编号查重排除自身（编辑改码用）。 */
    boolean existsByCodeAndDeletedFalseAndIdNot(String code, UUID id);

    /** 按名称查（大小写不敏感，仅未软删）——导入单位名→既有 legacyId 解析用。 */
    Optional<Unit> findFirstByNameIgnoreCaseAndDeletedFalse(String name);
}
