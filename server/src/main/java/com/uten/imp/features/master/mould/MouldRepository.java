package com.uten.imp.features.master.mould;

import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.Optional;
import java.util.UUID;

/**
 * 模具主档仓库。分类下的模具分页（未软删，按 id 升序保证迁移拓扑序）。与 GoodsRepository 同构。
 */
public interface MouldRepository extends JpaRepository<Mould, UUID> {

    /** 某分类下的模具（未软删），按 id 升序。category 为 @ManyToOne，findByCategoryId 解析 join 列。 */
    Page<Mould> findByCategoryIdAndDeletedFalseOrderById(UUID categoryId, Pageable pageable);

    /** 全部模具（未软删，categoryId 为 null 时用）。 */
    Page<Mould> findByDeletedFalseOrderById(Pageable pageable);

    /** 迁移/校验用：按老库主键反查。 */
    Optional<Mould> findByLegacyId(Integer legacyId);
}
