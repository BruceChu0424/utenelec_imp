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
 * <p>itemIds 是勾选的组装行 id(goods_bom_items.id)，不是组件货品 id；可以横跨组装树的
 * 多层(ADR-111：一次请求、一个事务，不再按父件分组逐组提交)，服务端核对每行的父件都在
 * 路径货品的组装树里后整批软删。
 *
 * <p>上限 500：与主档批量命令同一上限；定死上限是为了让越界请求在 HTTP 边界
 * 就被挡掉，不进入服务层分配集合、开数据库事务。
 */
@Getter
@Setter
public class BomBatchDeleteRequest {

    @NotEmpty
    @Size(max = 500)
    private List<@NotNull UUID> itemIds;
}
