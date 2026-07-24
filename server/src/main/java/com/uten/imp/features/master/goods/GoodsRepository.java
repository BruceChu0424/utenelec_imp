package com.uten.imp.features.master.goods;

import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.Optional;
import java.util.UUID;

/**
 * 货品主档仓库。分类下的货品分页（未软删，按 id 升序保证迁移拓扑序）。
 */
public interface GoodsRepository extends JpaRepository<Goods, UUID> {

    /** 某分类下的货品（未软删），按 id 升序。category 为 @ManyToOne，findByCategoryId 解析 join 列。 */
    Page<Goods> findByCategoryIdAndDeletedFalseOrderById(UUID categoryId, Pageable pageable);

    /** 全部货品（未软删，categoryId 为 null 时用）。 */
    Page<Goods> findByDeletedFalseOrderById(Pageable pageable);

    /** 迁移/校验用：按老库主键反查。 */
    Optional<Goods> findByLegacyId(Integer legacyId);
}
