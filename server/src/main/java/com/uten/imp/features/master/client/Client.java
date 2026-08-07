package com.uten.imp.features.master.client;

import com.uten.imp.common.domain.SoftDeletableEntity;
import com.uten.imp.features.master.clientcategory.ClientCategory;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.FetchType;
import jakarta.persistence.JoinColumn;
import jakarta.persistence.ManyToOne;
import jakarta.persistence.Table;
import jakarta.persistence.Version;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.math.BigDecimal;

/**
 * 客户主档（基础资料-客户资料）。
 *
 * 逐字段照抄 V36 clients 表（id/审计/软删来自 {@link SoftDeletableEntity}）。
 * 老库 B_Client 全字段迁移：legacy_id=B_Client.ID（溯源+重跑幂等），
 * category_id 源自 B_Client.ParentID→SystemItem.ItemID（ItemclassID=2）。
 *
 * 字段语义（老库字段名起清晰列名，见 V36）：
 *   code←Number、name←Client_Name、fullName←Full_Name、clientRank←Client_Rank、
 *   placeId←PlaceID(地区文本)、empId←Emp_ID(业务员)、legalPerson←Juri_Per(法人)、
 *   linkman←Link_Man、postcode←Post、address←Link_Addr、website←Http、
 *   shipVia←Shipvia、shipAddress←Ship_Addr、bank←Client_Bank、bankAccount←Client_BankNo、
 *   taxId←Tax_ID、credit←Credit、initTotal/initTotal2←InitTotal/InitTotal2、
 *   exchangeRate←CRate(疑似汇率)、tday←TDay、priceStyle←PStyle、zjId←ZJID、
 *   region←QYName(区域)、clientXz←ClientXZ(性质)、status←Status、remark←Remark。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "clients")
public class Client extends SoftDeletableEntity {

    /** 乐观锁版本（JPA @Version，每次写自增；编辑表单回传比对防丢失更新，V231）。 */
    @Version
    private long version;

    /** 老库 B_Client.ID（迁移溯源+重跑幂等）；手工新建的为 null。 */
    @Column(name = "legacy_id", unique = true)
    private Integer legacyId;

    /** 所属客户分类（client_categories.id）。@ManyToOne LAZY，仿 Mould category 写法。 */
    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "category_id")
    private ClientCategory category;

    // ===== 标识 / 名称 =====
    private String name;                // Client_Name（客户名称）
    private String code;                // Number（客户编号，如 WM001 / 川0002）
    @Column(name = "full_name")
    private String fullName;            // Full_Name（全称）
    @Column(name = "client_rank")
    private String clientRank;          // Client_Rank（等级）

    // ===== 联系 =====
    @Column(name = "place_id")
    private String placeId;             // PlaceID（地区文本，如"四川省"）
    @Column(name = "emp_id")
    private String empId;               // Emp_ID（业务员 legacy id，文本保原值）

    /** 归属业务员（每个销售只看自己的客户；NULL=公共客户全员可见）。V86 新增。 */
    @Column(name = "owner_employee_id")
    private java.util.UUID ownerEmployeeId;
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
    private String bank;                // Client_Bank（开户行）
    @Column(name = "bank_account")
    private String bankAccount;         // Client_BankNo（银行账号）
    @Column(name = "tax_id")
    private String taxId;               // Tax_ID（税号）

    // ===== 财务 =====
    private BigDecimal credit;          // Credit（信用额度）
    @Column(name = "init_total")
    private BigDecimal initTotal;       // InitTotal（期初应收）
    @Column(name = "init_total2")
    private BigDecimal initTotal2;      // InitTotal2（期初应收2）
    @Column(name = "exchange_rate")
    private BigDecimal exchangeRate;    // CRate（疑似汇率，含义待确认）
    private Integer tday;               // TDay（结算天数）
    @Column(name = "price_style")
    private Integer priceStyle;         // PStyle（价格样式）
    @Column(name = "zj_id")
    private Integer zjId;               // ZJID（含义待确认，样本 545/546）

    // ===== 分类 / 性质（文本冗余，与 ParentID 分组并存的另一种业务表达）=====
    private String region;              // QYName（区域，如 外贸/内销南区/OEM）
    @Column(name = "client_xz")
    private String clientXz;            // ClientXZ（客户性质）

    // ===== 状态 / 备注 =====
    private String status;              // Status（使用/禁用）
    private String remark;              // Remark（备注）

    /** 铺底额（V121，元）：应收管控下限；应收汇总表「超出铺底额」= 应收余额−铺底额。 */
    @Column(name = "credit_floor", precision = 18, scale = 4)
    private java.math.BigDecimal creditFloor;
}
