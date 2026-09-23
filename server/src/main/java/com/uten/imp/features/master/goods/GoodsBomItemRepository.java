package com.uten.imp.features.master.goods;

import org.springframework.data.jpa.repository.EntityGraph;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.Collection;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

/**
 * 货品组装信息（BOM）行仓库。
 */
public interface GoodsBomItemRepository extends JpaRepository<GoodsBomItem, UUID> {

    /**
     * 某成品的全部组件行(未软删，按展示序号)。父件、组件、组件单位/颜色、行颜色/默认供应商
     * 一条语句取齐：组装信息页签每展开一层、每次改 BOM 后重算材料合计都走这里，不能按组件逐个懒加载。
     */
    @EntityGraph(attributePaths = {
            "goods", "component", "component.unit", "component.color", "color", "defaultSupplier"})
    List<GoodsBomItem> findByGoods_IdAndDeletedFalseOrderBySortOrderAscIdAsc(UUID goodsId);

    /**
     * 这些货品里哪些自己有可运营组装行(组装树展开箭头、材料合计里的半成品判定)：一次查询、
     * 不加载实体；迁移占位货品不算可运营边(口径同 {@link #findOperationalEdges})。
     */
    @Query(value = """
            SELECT DISTINCT b.goods_id
            FROM goods_bom_items b
            JOIN goods p ON p.id = b.goods_id
            JOIN goods c ON c.id = b.component_goods_id
            WHERE b.goods_id IN (:ids) AND b.is_deleted = FALSE
              AND p.auto_created = FALSE AND c.auto_created = FALSE
            """, nativeQuery = true)
    List<UUID> findGoodsWithOperationalRows(@Param("ids") Collection<UUID> ids);

    /**
     * 一批父件的可运营组装边 [行 id, 父件 id, 组件 id, 序号]：一次查询、不加载实体，
     * 组装树逐层下探(批量删除范围、粘贴成环检查)用；迁移占位货品不算可运营边。
     */
    @Query(value = """
            SELECT b.id, b.goods_id, b.component_goods_id, b.sort_order
            FROM goods_bom_items b
            JOIN goods p ON p.id = b.goods_id
            JOIN goods c ON c.id = b.component_goods_id
            WHERE b.goods_id IN (:parentIds) AND b.is_deleted = FALSE
              AND p.auto_created = FALSE AND c.auto_created = FALSE
            ORDER BY b.goods_id, b.sort_order, b.id
            """, nativeQuery = true)
    List<Object[]> findOperationalEdges(@Param("parentIds") Collection<UUID> parentIds);

    /** 一批组装行里仍有效的 [行 id, 父件 id]：批量删除一次取齐，不逐行加载实体。 */
    @Query(value = """
            SELECT b.id, b.goods_id FROM goods_bom_items b
            WHERE b.id IN (:ids) AND b.is_deleted = FALSE
            """, nativeQuery = true)
    List<Object[]> findLiveItemParents(@Param("ids") Collection<UUID> ids);

    /** 一条语句软删一批仍有效的组装行，返回实际删掉的行数(并发删掉的不算)。 */
    @Modifying
    @Query(value = """
            UPDATE goods_bom_items
            SET is_deleted = TRUE, deleted_at = now(), updated_at = now(),
                updated_by = COALESCE(CAST(NULLIF(current_setting('app.actor_id', true), '') AS uuid), updated_by)
            WHERE id IN (:ids) AND is_deleted = FALSE
            """, nativeQuery = true)
    int softDeleteLive(@Param("ids") Collection<UUID> ids);

    /** 查某成品 UUID 下某组件 UUID 的现存行（关系唯一校验用）。 */
    Optional<GoodsBomItem> findByGoods_IdAndComponent_IdAndDeletedFalse(UUID goodsId, UUID componentId);
}
