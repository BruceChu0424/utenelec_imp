package com.uten.imp.features.master.client.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 客户主档新建/编辑请求（client:edit）。
 *
 * <p>开放业务核心字段；老库含义不明的遗留字段（price_style/exchange_rate/zj_id/init_total2/client_xz）
 * 暂不进表单。legacy_id/审计/软删不可改。新建与编辑共用本 DTO（主档无「创建后不可改」字段）。
 */
@Getter
@Setter
public class ClientSaveRequest {

    @NotNull
    private UUID categoryId;     // 所属客户分类（必填）

    // 标识
    @NotBlank
    private String name;         // Client_Name
    private String code;         // Number（客户编号）
    private String fullName;     // Full_Name（全称）
    private String clientRank;   // Client_Rank（等级）

    // 联系
    private String region;       // QYName（区域，如 外贸/内销南区）
    private String placeId;      // PlaceID（地区文本）
    private String empId;        // Emp_ID（业务员）
    private String legalPerson;  // Juri_Per（法人）
    private String linkman;      // Link_Man（联系人）
    private String mobile;
    private String phone;
    private String phone2;
    private String fax;
    private String postcode;     // Post
    private String address;      // Link_Addr
    private String email;
    private String website;      // Http

    // 收货
    private String shipVia;      // Shipvia
    private String shipAddress;  // Ship_Addr

    // 银行 / 税务
    private String bank;         // Client_Bank
    private String bankAccount;  // Client_BankNo
    private String taxId;        // Tax_ID

    // 财务
    private BigDecimal credit;   // Credit（信用额度）
    private BigDecimal initTotal;// InitTotal（期初应收）
    private Integer tday;        // TDay（结算天数）

    // 状态
    private String status;       // Status（使用/禁用）
    private String remark;       // Remark
}
