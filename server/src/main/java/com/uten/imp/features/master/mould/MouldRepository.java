package com.uten.imp.features.master.mould;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.Collection;
import java.util.List;
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

    /** 货品列表历史回显用：批量按老库主键查未软删模具（编号/名称展示）。 */
    List<Mould> findByLegacyIdInAndDeletedFalse(Collection<Integer> legacyIds);

    /** 分类删除预览用：子树（含自身）下未软删的模具数。 */
    @Query(value = """
            SELECT count(*) FROM moulds
            WHERE is_deleted = false AND category_id IN (:ids)
            """, nativeQuery = true)
    long countByCategoryIds(@Param("ids") Collection<UUID> ids);

    /** 子树下未软删模具的 id：级联删分类时交给主档删除命令做引用检查(ADR-111)。 */
    @Query(value = """
            SELECT id FROM moulds
            WHERE is_deleted = false AND category_id IN (:ids)
            """, nativeQuery = true)
    List<UUID> findIdsByCategoryIds(@Param("ids") Collection<UUID> ids);

    /** 编号查重（仅未软删）—— 手动编号校验用。 */
    boolean existsByCodeAndDeletedFalse(String code);

    /** 编号查重排除自身（编辑改码用）。 */
    boolean existsByCodeAndDeletedFalseAndIdNot(String code, UUID id);
}
