package com.uten.imp.features.master.supplier.dto;

import com.fasterxml.jackson.annotation.JsonProperty;
import lombok.AllArgsConstructor;
import lombok.Getter;

import java.util.UUID;

/**
 * 供应商列表项。
 *
 * <p>覆盖用户指定的 21 列展示字段中的 19 个有物理列的字段（编号 code 不在用户列表内；
 * 主结账方式/损耗率无对应物理列，不进 DTO，前端单元格恒显示"—"）。
 * 与 {@code com.uten.imp.features.master.goods.dto.GoodsListItem} 同构。
 *
 * <p>连续大写/驼峰边界字段（legalPerson/bankAccount/taxId/empId/shipVia/shipAddress）
 * 显式 {@code @JsonProperty} 钉死 key，防 Jackson 连续大写 decapitalize 坑
 * （参考 MEMORY: java-jackson-consecutive-uppercase 前车之鉴 mWeight→mweight），
 * 前端 fromJson 同名读取。
 */
@Getter
@AllArgsConstructor
public class SupplierListItem {
    private UUID id;
    private Integer legacyId;       // 老库 B_Provider.ID（溯源用，前端表格不展示）

    // ===== 用户指定的 21 列（19 个有数据列）=====
    private String name;            // 供应商简称（Vend_Name）
    private String description;     // 全称（Vend_Desc）
    // 主结账方式：price_style 语义为"价格样式"，与"主结账方式"对不上 → 不在 DTO，前端恒显示"—"
    private Integer tday;           // 信用天数（TDay，INT）
    // 损耗率(%)：V38 suppliers 无对应列 → 不在 DTO，前端恒显示"—"
    private String place;           // 所属地区（Vend_Place）
    @JsonProperty("empId")
    private String empId;           // 业务员（Emp_ID，文本保原值）
    @JsonProperty("legalPerson")
    private String legalPerson;     // 法人代表（Juri_Per）
    private String linkman;         // 联系人（Link_Man）
    private String mobile;          // 手机（Mobile）
    private String phone;           // 联系电话（Phone）
    private String phone2;          // 备用电话（Phone2）
    private String fax;             // 传真（Fax）
    private String postcode;        // 邮编（Post）
    private String address;         // 地址（Link_Addr）
    private String bank;            // 开户银行（Vend_Bank）
    @JsonProperty("bankAccount")
    private String bankAccount;     // 银行账号（Vend_BankNo）
    @JsonProperty("taxId")
    private String taxId;           // 纳税号（Tax_ID）
    private String website;         // 网址（Http）
    @JsonProperty("shipVia")
    private String shipVia;         // 运输方式（Shipvia）
    @JsonProperty("shipAddress")
    private String shipAddress;     // 送货地址（Ship_Addr）
}
