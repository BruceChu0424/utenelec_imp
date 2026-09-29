package com.uten.imp.features.sales.quote.dto;

import com.uten.imp.common.validation.RequestLimits;
import com.uten.imp.features.sales.SalesAiIntakeRequest;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import lombok.Getter;
import lombok.Setter;

import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/**
 * 销售报价新建/编辑请求(只在草稿状态可保存, 含财务退回的草稿)。
 *
 * <p>ADR-134: 表头补齐币种/业务员/交货日期/结账方式/合同号(转订货单时带入); clientFileCurrency 是客户文件
 * 上单价的币种, 只用于阅读文件单价; aiIntake 说明这次保存采用了哪次客户文件识别。
 */
@Getter
@Setter
public class QuoteSaveRequest {

    private String billNo;

    @NotNull
    private LocalDate billDate;

    @NotNull
    private UUID clientId;
    private LocalDate validUntil;
    private String remark;

    private UUID currencyId;
    private UUID sellerId;
    private LocalDate deliverDate;
    private UUID settlementMethodId;

    @Size(max = 64, message = "合同号不能超过 64 个字符")
    private String contractNo;

    @Size(max = 8, message = "文件币种不能超过 8 个字符")
    private String clientFileCurrency;

    @Valid
    private SalesAiIntakeRequest aiIntake;

    @Valid
    @NotNull
    @Size(max = RequestLimits.DOCUMENT_LINES)
    private List<QuoteItemLine> items;
}
