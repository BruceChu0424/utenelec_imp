package com.uten.imp.features.stock.dto;

/**
 * 货架图布局（GET /api/stock/shelf-labels/layout）：每个已分层库行一条——
 * 层数/位数上限由现有库位号推算，前端按 maxLevel × maxSlot 画格。
 *
 * <p>约定：{@code rack} 为空串的那条是「未分层」桶（库位号不符合三段格式的货品数），
 * 此时 maxLevel/maxSlot 为 null；只在残值数 > 0 时下发，且排在列表末尾。
 *
 * @param rack     库行（如 A31）；空串 = 未分层桶
 * @param maxLevel 该库行最大层号（未分层桶为 null）
 * @param maxSlot  该库行最大位号（未分层桶为 null）
 * @param count    该库行（或未分层桶）内货品行数
 */
public record ShelfLayoutRack(String rack, Integer maxLevel, Integer maxSlot, long count) {

    public boolean unparsedBucket() {
        return rack == null || rack.isEmpty();
    }
}
