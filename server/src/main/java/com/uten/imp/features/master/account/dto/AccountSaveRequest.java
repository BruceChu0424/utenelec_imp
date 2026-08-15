package com.uten.imp.features.master.account.dto;

import jakarta.validation.constraints.NotBlank;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 账户新建/编辑请求（account:edit）。
 *
 * <p>name 必填 / account_type 必填（前端枚举下拉）；init_balance 可改，运行时由 Service 重算余额。
 * receipts_total/payments_total 由收付款审核维护，不通过本 DTO 修改。新建与编辑共用本 DTO。
 */
@Getter
@Setter
public class AccountSaveRequest {

    @NotBlank
    private String name;

    private String code;

    private String bankAccountNo;

    /** BANK/CASH/CHECK/FOREIGN_CHECK/THIRD_PARTY/OFFSHORE/GENERAL；默认 BANK。 */
    private String accountType;

    private UUID currencyId;

    private BigDecimal initBalance;

    private Integer parentLegacyId;

    /** 迁移兼容影子；普通 API 不能只提交该字段，也不能与 styleId 冲突。 */
    private Integer styleLegacyId;

    /** 会计科目 UUID 真源；使用中的账户必填，普通 API 不按 legacy id 反查。 */
    private UUID styleId;

    private String status;
}
