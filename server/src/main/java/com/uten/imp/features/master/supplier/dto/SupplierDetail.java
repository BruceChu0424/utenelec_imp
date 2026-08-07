package com.uten.imp.features.master.supplier.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 供应商详情：列表核心字段 + 关键业务字段（够看即可）。与 MouldDetail 同构。
 * category_name 由 @ManyToOne category 的 name 取。
 */
@Getter
@AllArgsConstructor
public class SupplierDetail {
    // ===== 列表核心 =====
    private UUID id;
    private String code;
    private String name;
    private String status;
    private String place;
    private String linkman;
    private Integer legacyId;

    // ===== 详情扩展 =====
    private UUID categoryId;
    private String categoryName;
    private String description;      // 描述/全称（Vend_Desc）
    private String empId;            // 业务员
    private String legalPerson;      // 法人
    private String mobile;
    private String phone;
    private String phone2;
    private String fax;
    private String postcode;
    private String address;
    private String email;
    private String website;
    private String shipVia;          // 运输方式
    private String shipAddress;      // 收货地址
    private String bank;             // 开户行
    private String bankAccount;      // 银行账号
    private String taxId;            // 税号
    private BigDecimal initTotal;    // 期初应付
    private Integer tday;            // 结算天数
    private String remark;           // 备注
    private Long version;            // 乐观锁版本（编辑回传，V231）
}
