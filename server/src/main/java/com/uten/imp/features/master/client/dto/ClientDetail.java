package com.uten.imp.features.master.client.dto;

import lombok.Getter;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.UUID;

/**
 * 客户详情：列表核心字段 + 关键业务字段（够看即可）。与 MouldDetail 同构。
 * category_name 由 @ManyToOne category 的 name 取。
 */
@Getter
public class ClientDetail {
    // ===== 列表核心 =====
    private UUID id;
    private String code;
    private String name;
    private String status;
    private String region;
    private String linkman;
    private Integer legacyId;

    // ===== 详情扩展 =====
    private UUID categoryId;
    private String categoryName;
    private String fullName;        // 全称
    private String clientRank;      // 等级
    private String placeId;         // 地区文本
    private String empId;           // 业务员
    private String legalPerson;     // 法人
    private String mobile;
    private String phone;
    private String phone2;
    private String fax;
    private String postcode;
    private String address;
    private String email;
    private String website;
    private String shipVia;         // 运输方式
    private String shipAddress;     // 收货地址
    private String bank;            // 开户行
    private String bankAccount;     // 银行账号
    private String taxId;           // 税号
    private BigDecimal credit;      // 信用额度
    private BigDecimal initTotal;   // 期初应收
    private Integer tday;           // 结算天数
    private BigDecimal creditFloor; // 铺底额（应收管控下限）
    private String remark;          // 备注
    private Long version;           // 乐观锁版本（编辑回传）
    private UUID ownerEmployeeId;   // 业务员 UUID 真源
    private String ownerEmployeeName;
    private UUID defaultSettlementMethodId;
    private String defaultSettlementMethodName;
    private boolean writable;
    private boolean accessManageable;
    private String accessReason;
    // ===== 默认销售条款（V592 单一事实源：基础资料可维护 + 下单自动写回） =====
    private String defaultShipmentPolicy;
    private UUID defaultCurrencyId;
    private String defaultCurrencyName;
    // ===== 外文名称(ADR-134, V742) =====
    private String nameEn;

    private List<UUID> ownerEmployeeIds = List.of();
    private List<String> ownerEmployeeNames = List.of();
    @lombok.Setter private boolean financialWritable;

    public ClientDetail(
            UUID id,
            String code,
            String name,
            String status,
            String region,
            String linkman,
            Integer legacyId,
            UUID categoryId,
            String categoryName,
            String fullName,
            String clientRank,
            String placeId,
            String empId,
            String legalPerson,
            String mobile,
            String phone,
            String phone2,
            String fax,
            String postcode,
            String address,
            String email,
            String website,
            String shipVia,
            String shipAddress,
            String bank,
            String bankAccount,
            String taxId,
            BigDecimal credit,
            BigDecimal initTotal,
            Integer tday,
            BigDecimal creditFloor,
            String remark,
            Long version,
            UUID ownerEmployeeId,
            String ownerEmployeeName,
            UUID defaultSettlementMethodId,
            String defaultSettlementMethodName,
            boolean writable,
            boolean accessManageable,
            String accessReason,
            String defaultShipmentPolicy,
            UUID defaultCurrencyId,
            String defaultCurrencyName,
            String nameEn,
            List<UUID> ownerEmployeeIds,
            List<String> ownerEmployeeNames,
            boolean financialWritable) {
        this.id = id;
        this.code = code;
        this.name = name;
        this.status = status;
        this.region = region;
        this.linkman = linkman;
        this.legacyId = legacyId;
        this.categoryId = categoryId;
        this.categoryName = categoryName;
        this.fullName = fullName;
        this.clientRank = clientRank;
        this.placeId = placeId;
        this.empId = empId;
        this.legalPerson = legalPerson;
        this.mobile = mobile;
        this.phone = phone;
        this.phone2 = phone2;
        this.fax = fax;
        this.postcode = postcode;
        this.address = address;
        this.email = email;
        this.website = website;
        this.shipVia = shipVia;
        this.shipAddress = shipAddress;
        this.bank = bank;
        this.bankAccount = bankAccount;
        this.taxId = taxId;
        this.credit = credit;
        this.initTotal = initTotal;
        this.tday = tday;
        this.creditFloor = creditFloor;
        this.remark = remark;
        this.version = version;
        this.ownerEmployeeId = ownerEmployeeId;
        this.ownerEmployeeName = ownerEmployeeName;
        this.defaultSettlementMethodId = defaultSettlementMethodId;
        this.defaultSettlementMethodName = defaultSettlementMethodName;
        this.writable = writable;
        this.accessManageable = accessManageable;
        this.accessReason = accessReason;
        this.defaultShipmentPolicy = defaultShipmentPolicy;
        this.defaultCurrencyId = defaultCurrencyId;
        this.defaultCurrencyName = defaultCurrencyName;
        this.nameEn = nameEn;
        this.ownerEmployeeIds = ownerEmployeeIds == null ? null
                : Collections.unmodifiableList(new ArrayList<>(ownerEmployeeIds));
        this.ownerEmployeeNames = ownerEmployeeNames == null ? null
                : Collections.unmodifiableList(new ArrayList<>(ownerEmployeeNames));
        this.financialWritable = financialWritable;
    }

    public List<UUID> getOwnerEmployeeIds() {
        return ownerEmployeeIds == null ? null : Collections.unmodifiableList(ownerEmployeeIds);
    }

    public void setOwnerEmployeeIds(List<UUID> ownerEmployeeIds) {
        this.ownerEmployeeIds = ownerEmployeeIds == null ? null
                : Collections.unmodifiableList(new ArrayList<>(ownerEmployeeIds));
    }

    public List<String> getOwnerEmployeeNames() {
        return ownerEmployeeNames == null ? null : Collections.unmodifiableList(ownerEmployeeNames);
    }

    public void setOwnerEmployeeNames(List<String> ownerEmployeeNames) {
        this.ownerEmployeeNames = ownerEmployeeNames == null ? null
                : Collections.unmodifiableList(new ArrayList<>(ownerEmployeeNames));
    }
}
