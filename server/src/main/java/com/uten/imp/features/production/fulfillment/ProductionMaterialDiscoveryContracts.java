package com.uten.imp.features.production.fulfillment;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

public final class ProductionMaterialDiscoveryContracts {
    private ProductionMaterialDiscoveryContracts() {}
    public record Request(Long expectedVersion,String idempotencyKey,List<RequestedMaterial> items) {
        public Request(Long expectedVersion,String idempotencyKey) {this(expectedVersion,idempotencyKey,null);}
    }
    /** Optional workshop intent; the warehouse supplies the physical stock source. */
    public record RequestedMaterial(UUID goodsId,UUID colorId,UUID unitId,BigDecimal qty) {}
    public record SuggestedItem(UUID goodsId,String goodsCode,String goodsName,UUID colorId,
                                String colorName,UUID unitId,String unitName,BigDecimal qty,
                                String spec,String stockPlace) {}
    public record Material(UUID goodsId,UUID colorId,UUID unitId,UUID warehouseId,BigDecimal qty) {}
    public record Configure(Long expectedVersion,String idempotencyKey,List<Material> items) {}
    public record Context(UUID segmentId,long expectedVersion,boolean materialDiscoveryRequired,
                          UUID requestId,String status,boolean canRequest) {}
    public record Item(UUID id,UUID demandId,UUID goodsId,String goodsCode,String goodsName,
                       UUID colorId,String colorName,UUID unitId,String unitName,UUID warehouseId,
                       String warehouseName,BigDecimal qty,String spec,String stockPlace) {}
    public record DrawDocument(UUID id,String billNo,UUID warehouseId,String warehouseName) {}
    public record Detail(UUID requestId,UUID segmentId,String segmentCode,String planNo,
                         String productCode,String productName,BigDecimal plannedQty,String productUnitName,
                         String workshopName,String status,long version,List<Item> items,List<UUID> drawDocIds,
                         List<SuggestedItem> suggestedItems,String requestNo,List<DrawDocument> drawDocuments) {}
}
