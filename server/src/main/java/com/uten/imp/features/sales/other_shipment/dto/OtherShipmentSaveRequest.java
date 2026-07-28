package com.uten.imp.features.sales.other_shipment.dto;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** 其它出货新建/编辑请求。client_id 可空（内部领用）。 */
@Getter
@Setter
public class OtherShipmentSaveRequest {

    private String billNo;

    @NotNull
    private LocalDate billDate;

    private UUID clientId;
    private UUID warehouseId;
    private UUID currencyId;
    private BigDecimal exchangeRate;
    private BigDecimal taxRate;
    private Integer paymentStyleId;
    private UUID sellerId;
    private UUID senderId;
    private String shipAddr;
    private String linkPhone;
    private Integer parcelCount;
    private String outType;
    private String remark;

    @Valid
    @NotNull
    private List<OtherShipmentItemLine> items;
}
