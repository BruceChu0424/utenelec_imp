package com.uten.imp.features.purchase.request.dto;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

@Getter @Setter
public class RequestSaveRequest {
    private String billNo;
    @NotNull private LocalDate billDate;
    private UUID warehouseId;
    private UUID applicantId;
    private LocalDate needDate;
    private String remark;
    @Valid @NotNull private List<RequestItemLine> items;
}
