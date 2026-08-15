package com.uten.imp.features.master.paymentstyle.dto;

import jakarta.validation.constraints.NotBlank;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 收付款类别新建请求（payment_style:edit）。
 *
 * <p>code/name 必填；category 必填（ACCOUNT/LIABILITY/EQUITY/EXPENSE/INCOME/METHOD）。
 * parentId 为空 = 顶级根。direction flags / departmental 默认 false。
 */
@Getter
@Setter
public class PaymentStyleSaveRequest {

    private String code;

    @NotBlank
    private String name;

    @NotBlank
    private String category;

    private UUID parentId;

    private Integer sortOrder = 0;

    private boolean departmental;
    private boolean receipt;
    private boolean payment;

    /** 迁移兼容影子；普通 API 不按该字段反查账户。 */
    private Integer linkedAccountLegacyId;
    /** 关联账户 UUID 真源；与 legacy 影子同时提交时必须一致。 */
    private UUID linkedAccountId;
    private BigDecimal initBalance;
    private String status;
}
