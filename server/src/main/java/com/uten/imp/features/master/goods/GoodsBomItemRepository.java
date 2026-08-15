package com.uten.imp.features.master.goods;

import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

/**
 * 货品组装信息（BOM）行仓库。
 */
public interface GoodsBomItemRepository extends JpaRepository<GoodsBomItem, UUID> {

    /** 某成品的全部组件行（未软删，按展示序号）。 */
    List<GoodsBomItem> findByGoods_IdAndDeletedFalseOrderBySortOrderAscIdAsc(UUID goodsId);

    /** 批量查「哪些货品自身有 BOM」（组装树展开箭头用）。 */
    List<GoodsBomItem> findByGoods_IdInAndDeletedFalse(Set<UUID> goodsIds);

    /** 查某成品 UUID 下某组件 UUID 的现存行（关系唯一校验用）。 */
    Optional<GoodsBomItem> findByGoods_IdAndComponent_IdAndDeletedFalse(UUID goodsId, UUID componentId);
}
