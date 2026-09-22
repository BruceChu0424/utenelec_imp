package com.uten.imp.features.master.goods.dto;

import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import lombok.Getter;
import lombok.Setter;

import java.util.List;
import java.util.UUID;

/**
 * 组装信息行批量删除请求(goods:bom:delete)。
 *
 * <p>itemIds 是勾选的组装行 id(goods_bom_items.id)，不是组件货品 id；
 * 服务端逐条按 (goodsId, itemId) 核对归属后整批软删。
 *
 * <p>上限 200：组装树一屏勾选远达不到这个量，定死上限是为了让越界请求在 HTTP 边界
 * 就被挡掉，不进入服务层分配集合、开数据库事务。
 */
@Getter
@Setter
public class BomBatchDeleteRequest {

    @NotEmpty
    @Size(max = 200)
    private List<@NotNull UUID> itemIds;
}
