package com.uten.imp.features.production.fulfillment;

import com.uten.imp.features.stock.dto.StockDocIssueBatchRequest;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static com.uten.imp.features.production.fulfillment.ProductionMaterialDiscoveryContracts.Material;

public final class ProductionDrawDiscoveryBatchContracts {
    private ProductionDrawDiscoveryBatchContracts() {}

    /**
     * weights(选填, ADR-135 §3.6): 本申请各实际材料(货品 + 颜色 + 实际仓)本次出库的实称重量;
     * 领料单在确认材料时才生成, 服务端在生成后按同一维度对到新领料明细。
     */
    public record Discovery(UUID requestId, Long expectedVersion, List<Material> items, List<IssueWeight> weights) {
        public Discovery(UUID requestId, Long expectedVersion, List<Material> items) {
            this(requestId, expectedVersion, items, null);
        }
    }

    /** 一种实际材料本次出库的实称重量(千克, 空或 0 = 没称)与「数量按称重推算」标记。 */
    public record IssueWeight(UUID goodsId, UUID colorId, UUID warehouseId, BigDecimal weightKg,
                              Boolean qtyFromWeight) {}

    /** weights(选填): 已有领料单(docIds)各明细本次出库的实称重量, 口径同 {@code /issue-batch}。 */
    public record Request(String idempotencyKey, List<UUID> docIds,
                          List<Discovery> discoveries, String reason,
                          List<StockDocIssueBatchRequest.ItemWeight> weights) {
        public Request(String idempotencyKey, List<UUID> docIds, List<Discovery> discoveries, String reason) {
            this(idempotencyKey, docIds, discoveries, reason, null);
        }
    }
}
