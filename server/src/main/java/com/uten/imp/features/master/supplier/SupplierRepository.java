package com.uten.imp.features.master.supplier;

import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

/**
 * 供应商主档仓库。与 MouldRepository 同构，额外提供子树汇总查询（与 ClientRepository 一致；
 * 供应商分类当前为扁平根，子树=自身，行为不变，保留以兼容将来加嵌套子分类）。
 */
public interface SupplierRepository extends JpaRepository<Supplier, UUID> {

    /** 某分类下的供应商（未软删），按 id 升序。 */
    Page<Supplier> findByCategoryIdAndDeletedFalseOrderById(UUID categoryId, Pageable pageable);

    /** 多分类下的供应商（未软删）——子树汇总用。 */
    Page<Supplier> findByCategoryIdInAndDeletedFalseOrderById(
            List<UUID> categoryIds, Pageable pageable);

    /** 全部供应商（未软删，categoryId 为 null 时用）。 */
    Page<Supplier> findByDeletedFalseOrderById(Pageable pageable);

    /** 迁移/校验用：按老库主键反查。 */
    Optional<Supplier> findByLegacyId(Integer legacyId);
}
