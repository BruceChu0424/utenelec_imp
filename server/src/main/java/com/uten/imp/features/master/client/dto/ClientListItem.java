package com.uten.imp.features.master.client.dto;

import com.fasterxml.jackson.annotation.JsonProperty;
import lombok.Getter;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.UUID;

/**
 * 客户列表项。
 *
 * <p>覆盖前端表格字段；主结账方式由 UUID 关联解析，总监仍无对应列。
 * 驼峰转 snake 物理列名见 clients；为防 Jackson 连续大写 / 非标 bean 命名带来的
 * 序列化歧义，对 fullName / legalPerson / bankAccount / taxId / placeId / empId / clientXz
 * 显式 {@code @JsonProperty} 钉死 key——前端 fromJson 同名读取（兼容小写兜底）。
 *
 * <p>credit 在 entity 是 BigDecimal（NUMERIC(18,4)），DTO 同型透传。
 * tday 为 Integer（TDay 结算天数）。
 */
@Getter
public class ClientListItem {
    public String getCreditDisplayText() { return credit==null?null:credit.setScale(2,java.math.RoundingMode.HALF_UP).toPlainString(); }
    public String getCreditFloorDisplayText() { return (creditFloor==null?java.math.BigDecimal.ZERO:creditFloor).setScale(2,java.math.RoundingMode.HALF_UP).toPlainString(); }
    private UUID id;
    private String code;                // 客户编码（Number）
    private String name;                // 客户简称（Client_Name）
    @JsonProperty("fullName")
    private String fullName;            // 客户全称（Full_Name）
    @JsonProperty("clientXz")
    private String clientXz;            // 客户性质（ClientXZ）
    private Integer tday;               // 信用天数（TDay）
    private String region;              // 区域（QYName）
    @JsonProperty("placeId")
    private String placeId;             // 所属地区（PlaceID）
    @JsonProperty("empId")
    private String empId;               // 业务员（Emp_ID）
    @JsonProperty("legalPerson")
    private String legalPerson;         // 法人代表（Juri_Per）
    private String linkman;             // 联系人（Link_Man）
    private String mobile;              // 手机（Mobile）
    private String phone;               // 联系电话（Phone）
    private String phone2;              // 备用电话（Phone2）
    private String fax;                 // 传真（Fax）
    private String postcode;            // 邮编（Post）
    private String address;             // 地址（Link_Addr）
    private String bank;                // 开户银行（Client_Bank）
    @JsonProperty("bankAccount")
    private String bankAccount;         // 银行账号（Client_BankNo）
    @JsonProperty("taxId")
    private String taxId;               // 纳税号（Tax_ID）
    private BigDecimal credit;          // 信誉额度（Credit）
    private BigDecimal creditFloor;     // 铺底额；未配置按 0
    private String website;             // 网址（Http）
    private String status;              // 状态（使用/禁用，详情用，不进表格列）
    private Integer legacyId;
    private UUID categoryId;            // 所属分类 id（客户资料页"搜客户定位分类"用）
    private UUID ownerEmployeeId;
    private String ownerEmployeeName;
    private UUID defaultSettlementMethodId;
    private String defaultSettlementMethodName;
    private boolean writable;
    private boolean accessManageable;

    /**
     * 乐观锁版本(ADR-111)：列表行带上它，批量启停/删除与单行启停直接回传比对，
     * 不必为拿版本先逐条拉详情。
     */
    private Long version;

    /** 外文名称(ADR-134, V742): 列表「外文名称」列; 关键字搜索同样命中。 */
    private String nameEn;

    private List<UUID> ownerEmployeeIds = List.of();
    private List<String> ownerEmployeeNames = List.of();
    @lombok.Setter private boolean financialWritable;

    public ClientListItem(
            UUID id,
            String code,
            String name,
            String fullName,
            String clientXz,
            Integer tday,
            String region,
            String placeId,
            String empId,
            String legalPerson,
            String linkman,
            String mobile,
            String phone,
            String phone2,
            String fax,
            String postcode,
            String address,
            String bank,
            String bankAccount,
            String taxId,
            BigDecimal credit,
            BigDecimal creditFloor,
            String website,
            String status,
            Integer legacyId,
            UUID categoryId,
            UUID ownerEmployeeId,
            String ownerEmployeeName,
            UUID defaultSettlementMethodId,
            String defaultSettlementMethodName,
            boolean writable,
            boolean accessManageable,
            Long version,
            String nameEn,
            List<UUID> ownerEmployeeIds,
            List<String> ownerEmployeeNames,
            boolean financialWritable) {
        this.id = id;
        this.code = code;
        this.name = name;
        this.fullName = fullName;
        this.clientXz = clientXz;
        this.tday = tday;
        this.region = region;
        this.placeId = placeId;
        this.empId = empId;
        this.legalPerson = legalPerson;
        this.linkman = linkman;
        this.mobile = mobile;
        this.phone = phone;
        this.phone2 = phone2;
        this.fax = fax;
        this.postcode = postcode;
        this.address = address;
        this.bank = bank;
        this.bankAccount = bankAccount;
        this.taxId = taxId;
        this.credit = credit;
        this.creditFloor = creditFloor;
        this.website = website;
        this.status = status;
        this.legacyId = legacyId;
        this.categoryId = categoryId;
        this.ownerEmployeeId = ownerEmployeeId;
        this.ownerEmployeeName = ownerEmployeeName;
        this.defaultSettlementMethodId = defaultSettlementMethodId;
        this.defaultSettlementMethodName = defaultSettlementMethodName;
        this.writable = writable;
        this.accessManageable = accessManageable;
        this.version = version;
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
