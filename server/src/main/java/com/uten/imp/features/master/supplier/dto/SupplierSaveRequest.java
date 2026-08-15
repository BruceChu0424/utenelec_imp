package com.uten.imp.features.master.supplier.dto;

import com.fasterxml.jackson.annotation.JsonIgnore;
import com.fasterxml.jackson.annotation.JsonSetter;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 供应商主档新建/编辑请求（supplier:edit）。
 *
 * <p>开放业务核心字段；老库含义不明的遗留字段（price_style/exchange_rate/init_total2）
 * 暂不进表单。legacy_id/审计/软删不可改。新建与编辑共用本 DTO。
 */
@Getter
@Setter
public class SupplierSaveRequest {

    @NotNull
    private UUID categoryId;     // 所属供应商分类（必填）

    // 标识
    @NotBlank
    private String name;         // Vend_Name
    private String code;         // Number（编号）
    private String description;  // Vend_Desc（描述/全称）
    private String place;        // Vend_Place（地区）

    // 联系
    private String empId;        // Emp_ID（业务员）
    private UUID ownerEmployeeId;
    @JsonIgnore
    private boolean ownerEmployeeReferencePresent;

    @JsonSetter("ownerEmployeeId")
    public void setOwnerEmployeeId(UUID value) {
        ownerEmployeeId = value;
        ownerEmployeeReferencePresent = true;
    }

    public boolean hasOwnerEmployeeReference() {
        return ownerEmployeeReferencePresent;
    }
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
    private String bank;         // Vend_Bank
    private String bankAccount;  // Vend_BankNo
    private String taxId;        // Tax_ID

    // 财务
    private BigDecimal initTotal;// InitTotal（期初应付）
    private Integer tday;        // TDay（结算天数）

    // 状态
    private String status;       // Status（使用/禁用）
    private String remark;       // Remark

    /** 乐观锁版本（编辑时回传详情读到的 version；新建忽略。不符即 409）。 */
    private Long version;
}
