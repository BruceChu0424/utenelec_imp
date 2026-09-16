package com.uten.imp.features.sales.shipment.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;
import lombok.Getter;
import lombok.Setter;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotNull;
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

    /** 本次实际发货仓；无仓提交的单据由仓库在确认出库时指定。 */
    private UUID warehouseId;

    @Valid
    @Size(max = 500)
    private List<StockPlace> stockPlaces;

    public record StockPlace(@NotNull UUID shipmentItemId, @Size(max = 200) String stockPlace) {}
}
