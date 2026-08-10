package com.uten.imp.features.master.mould;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.time.OffsetDateTime;
import java.util.Collection;
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

    /** 分类删除预览用：子树（含自身）下未软删的模具数。 */
    @Query(value = """
            SELECT count(*) FROM moulds
            WHERE is_deleted = false AND category_id IN (:ids)
            """, nativeQuery = true)
    long countByCategoryIds(@Param("ids") Collection<UUID> ids);

    /** 级联删分类：批量软删子树下模具（同 MaterialCategoryRepository.softDeleteGoodsByCategoryIds 范式）。 */
    @Query(value = """
            UPDATE moulds SET is_deleted = true, deleted_at = :now
            WHERE is_deleted = false AND category_id IN (:ids)
            """, nativeQuery = true)
    @Modifying
    int softDeleteByCategoryIds(@Param("ids") Collection<UUID> ids, @Param("now") OffsetDateTime now);

    /** 编号查重（仅未软删）—— 手动编号校验用。 */
    boolean existsByCodeAndDeletedFalse(String code);

    /** 编号查重排除自身（编辑改码用）。 */
    boolean existsByCodeAndDeletedFalseAndIdNot(String code, UUID id);
}
