package com.uten.imp.features.master.supplier;

import com.uten.imp.common.domain.SoftDeletableEntity;
import com.uten.imp.features.master.suppliercategory.SupplierCategory;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.FetchType;
import jakarta.persistence.JoinColumn;
import jakarta.persistence.ManyToOne;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.math.BigDecimal;

/**
 * 供应商主档（基础资料-供应商资料）。
 *
 * 逐字段照抄 V38 suppliers 表（id/审计/软删来自 {@link SoftDeletableEntity}）。
 * 老库 B_Provider 全字段迁移：legacy_id=B_Provider.ID（溯源+重跑幂等），
 * category_id 源自 B_Provider.ParentID→SystemItem.ItemID（ItemclassID=3）。
 *
 * 字段语义（老库字段名起清晰列名，见 V38）：
 *   code←Number、name←Vend_Name、description←Vend_Desc(避保留字)、place←Vend_Place、
 *   empId←Emp_ID(业务员)、legalPerson←Juri_Per(法人)、linkman←Link_Man、
 *   postcode←Post、address←Link_Addr、website←Http、shipVia←Shipvia、shipAddress←Ship_Addr、
 *   bank←Vend_Bank、bankAccount←Vend_BankNo、taxId←Tax_ID、
 *   initTotal/initTotal2←InitTotal/InitTotal2、exchangeRate←CRate(疑似汇率)、
 *   tday←TDay、priceStyle←PStyle、status←Status、remark←Remark。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "suppliers")
public class Supplier extends SoftDeletableEntity {

    /** 老库 B_Provider.ID（迁移溯源+重跑幂等）；手工新建的为 null。 */
    @Column(name = "legacy_id", unique = true)
    private Integer legacyId;

    /** 所属供应商分类（supplier_categories.id）。@ManyToOne LAZY，仿 Mould category 写法。 */
    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "category_id")
    private SupplierCategory category;

    // ===== 标识 / 名称 =====
    private String name;                // Vend_Name（供应商名称，如 洪武）
    private String code;                // Number（编号，如 WJ0001 / SL0003）
    private String description;         // Vend_Desc（描述/全称，避保留字 desc）
    private String place;               // Vend_Place（地区）

    // ===== 联系 =====
    @Column(name = "emp_id")
    private String empId;               // Emp_ID（业务员 legacy id，文本保原值）
    @Column(name = "legal_person")
    private String legalPerson;         // Juri_Per（法人）
    private String linkman;             // Link_Man（联系人）
    private String mobile;              // Mobile
    private String phone;               // Phone
    @Column(name = "phone2")
    private String phone2;              // Phone2
    private String fax;                 // Fax
    private String postcode;            // Post（邮编）
    private String address;             // Link_Addr（地址）
    private String email;               // Email
    private String website;             // Http（网址）

    // ===== 收货 =====
    @Column(name = "ship_via")
    private String shipVia;             // Shipvia（运输方式）
    @Column(name = "ship_address")
    private String shipAddress;         // Ship_Addr（收货地址）

    // ===== 银行 / 税务 =====
    private String bank;                // Vend_Bank（开户行）
    @Column(name = "bank_account")
    private String bankAccount;         // Vend_BankNo（银行账号）
    @Column(name = "tax_id")
    private String taxId;               // Tax_ID（税号）

    // ===== 财务 =====
    @Column(name = "init_total")
    private BigDecimal initTotal;       // InitTotal（期初应付）
    @Column(name = "init_total2")
    private BigDecimal initTotal2;      // InitTotal2（期初应付2）
    @Column(name = "exchange_rate")
    private BigDecimal exchangeRate;    // CRate（疑似汇率，含义待确认）
    private Integer tday;               // TDay（结算天数）
    @Column(name = "price_style")
    private Integer priceStyle;         // PStyle（价格样式）

    // ===== 状态 / 备注 =====
    private String status;              // Status（使用/禁用）
    private String remark;              // Remark（备注）
}
