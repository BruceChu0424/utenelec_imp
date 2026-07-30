package com.uten.imp.features.master.paymentstyle.dto;

import jakarta.validation.constraints.NotBlank;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 收付款类别编辑请求（payment_style:edit）。
 *
 * <p>code/category 不可改（影响 path 触发器与报表归类）；改 parent 触发子树 level 重算。
 */
@Getter
@Setter
public class PaymentStyleUpdateRequest {

    @NotBlank
    private String name;

    private UUID parentId;

    private Integer sortOrder;

    private Boolean departmental;
    private Boolean receipt;
    private Boolean payment;

    private Integer linkedAccountLegacyId;
    private BigDecimal initBalance;
    private String status;
}
