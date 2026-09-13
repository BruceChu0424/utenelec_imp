package com.uten.imp.features.sales.shipment.dto;

import com.uten.imp.common.validation.RequestLimits;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** 销售出货新建/编辑请求。 */
@Getter
@Setter
public class ShipmentSaveRequest {

    @com.fasterxml.jackson.annotation.JsonIgnore private String batchRequestKey;
    @com.fasterxml.jackson.annotation.JsonIgnore private String batchRequestHash;
    @com.fasterxml.jackson.annotation.JsonIgnore private Integer batchPosition;
    private String billNo;
    private String shipmentKind;
    private String billingMode;
    @Size(max=32) private String directPurpose;
    @Size(max=500) private String freeReason;
    private Long expectedRevision;

    @NotNull
    private LocalDate billDate;

    @NotNull
    private UUID clientId;

    private UUID warehouseId;
    /** Internal batch allocation may suggest a proven source while warehouse staff confirm the physical selection. */
    @com.fasterxml.jackson.annotation.JsonIgnore
    private boolean warehouseChoiceByWarehouse;
    private UUID currencyId;
    private BigDecimal exchangeRate;
    private BigDecimal taxRate;
    private Integer paymentStyleId;
    private UUID settlementMethodId;
    private UUID sellerId;
    private UUID senderId;
    private String shipAddr;
    private String linkPhone;
    private Integer parcelCount;
    private String logisticsNo;
    private String remark;

    @Valid
    @NotNull
    @Size(max = RequestLimits.DOCUMENT_LINES)
    private List<ShipmentItemLine> items;
}
