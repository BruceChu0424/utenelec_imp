package com.uten.imp.features.master.goods.dto;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import lombok.Getter;
import lombok.Setter;

import java.util.List;
import java.util.UUID;

/**
 * 组装信息行拖拽移动请求(goods:bom:edit，2026-10-19 长按拖拽排序/移层)。
 *
 * <p>一条 move = 把某条组装行挂到 targetParentGoodsId 下、插到 anchorItemId 的
 * 前/后(anchor 省略 = 追加到该层末尾)。同层换位(target = 原父件)只重排 sort_order；
 * 跨层移动换 goods_id，服务端校验成环与(父件, 组件)唯一后落库。整批原子：
 * 任何一条不合法全部回滚。
 *
 * <p>上限 500：与批量删除同一上限口径，越界请求在 HTTP 边界被挡掉。
 */
@Getter
@Setter
public class BomMoveRequest {

    @NotEmpty
    @Size(max = 500)
    private List<@Valid @NotNull Move> moves;

    /** 单条移动指令。 */
    @Getter
    @Setter
    public static class Move {

        /** 要移动的组装行 id(goods_bom_items.id)。 */
        @NotNull
        private UUID itemId;

        /** 落点父件：本货品自身(顶层)或组装树里任一可见组件的货品 id。 */
        @NotNull
        private UUID targetParentGoodsId;

        /** 同层参照行(插到它前/后)；null = 追加到该层末尾。 */
        private UUID anchorItemId;

        /** true = 插到参照行之后；false/省略 = 插到参照行之前。 */
        private boolean afterAnchor;
    }
}
