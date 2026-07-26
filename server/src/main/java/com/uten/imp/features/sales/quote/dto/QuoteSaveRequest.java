package com.uten.imp.features.sales.quote.dto;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** 销售报价新建/编辑请求。 */
@Getter
@Setter
public class QuoteSaveRequest {

    @NotBlank
    private String billNo;

    @NotNull
    private LocalDate billDate;

    private UUID clientId;
    private LocalDate validUntil;
    private String remark;

    @Valid
    @NotNull
    private List<QuoteItemLine> items;
}
