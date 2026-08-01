package com.uten.imp.features.master.color;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;
import org.springframework.data.jpa.repository.Query;

import java.util.Collection;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

/**
 * 颜色主档仓库。
 *
 * <p>列表查询用 {@link JpaSpecificationExecutor}（动态：keyword + 字段精确 + 空值白名单），
 * 范式同 {@code GoodsRepository}（无 categoryId——颜色扁平无分类）。
 */
public interface ColorRepository extends JpaRepository<Color, UUID>, JpaSpecificationExecutor<Color> {

    /** 迁移/校验用：按老库主键反查。 */
    Optional<Color> findByLegacyId(Integer legacyId);

    /** 批量按 legacy_id 取未软删记录（货品颜色名称解析用）。 */
    List<Color> findByLegacyIdInAndDeletedFalse(Collection<Integer> legacyIds);

    /** 手工新建时分配合成 legacy_id（货品 color_legacy_id 引用 legacy_id，新颜色须有值才可选/可存）。 */
    @Query("select max(c.legacyId) from Color c")
    Integer findMaxLegacyId();

    /** 名称查重（大小写不敏感，货品编辑内联新建颜色用）。 */
    boolean existsByNameIgnoreCaseAndDeletedFalse(String name);
}
