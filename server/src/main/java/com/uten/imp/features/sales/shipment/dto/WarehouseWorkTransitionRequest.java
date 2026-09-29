package com.uten.imp.features.sales.shipment.dto;

import jakarta.validation.Valid;
import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.Digits;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

/** 仓库一步确认出库请求（V582：targetStatus 只接受 SHIPPED）。 */
@Getter
@Setter
public class WarehouseWorkTransitionRequest {
    @NotBlank
    @Size(max = 32)
    private String targetStatus;
    /** 选填出库备注，随事件账留证。 */
    @Size(max = 500)
    private String reason;
    /**
     * 本次默认发出仓：行上没有单独指定发出仓时用它；推迟选仓（无仓提交）的单据表头仓也由它
     * 或第一行的发出仓落定。V631 起发出仓按行选，这里只是缺省值。
     */
    private UUID warehouseId;
    @Valid
    @Size(max = 500)
    private List<StockPlace> stockPlaces;

    /**
     * 逐行出库证据：实际库位 + 实际发出仓(V631) + 出库实称净重(ADR-135)。warehouseId 为空时依次取
     * 本次默认仓、行上已落定的仓、单据表头仓；各行可以分别从不同叶仓发出。
     *
     * <p>weightKg 是仓库出库时实称的本行净重(千克, 4 位小数; 空或 0 = 没称): 只进库存重量账
     * (销售出库流水记实称)与出库事件证据, 从不写回销售明细(那是财务放行时冻结的商业快照)。
     */
    public record StockPlace(
            @NotNull UUID shipmentItemId,
            @Size(max = 200) String stockPlace,
            UUID warehouseId,
            @DecimalMin(value = "0", inclusive = true)
            @Digits(integer = 14, fraction = 4) BigDecimal weightKg) {
        public StockPlace(UUID shipmentItemId, String stockPlace, UUID warehouseId) {
            this(shipmentItemId, stockPlace, warehouseId, null);
        }

        public StockPlace(UUID shipmentItemId, String stockPlace) {
            this(shipmentItemId, stockPlace, null, null);
        }
    }
}
