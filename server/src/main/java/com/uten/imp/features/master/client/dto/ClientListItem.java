package com.uten.imp.features.master.client.dto;

import com.fasterxml.jackson.annotation.JsonProperty;
import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 客户列表项。
 *
 * <p>覆盖前端表格 23 列中 21 个有 DB 列的字段（主结账方式 / 总监 V36 无对应列，表格显空）。
 * 驼峰转 snake 物理列名见 V36 clients；为防 Jackson 连续大写 / 非标 bean 命名带来的
 * 序列化歧义，对 fullName / legalPerson / bankAccount / taxId / placeId / empId / clientXz
 * 显式 {@code @JsonProperty} 钉死 key——前端 fromJson 同名读取（兼容小写兜底）。
 *
 * <p>credit 在 entity 是 BigDecimal（NUMERIC(18,4)），DTO 同型透传。
 * tday 为 Integer（TDay 结算天数）。
 */
@Getter
@AllArgsConstructor
public class ClientListItem {
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
    private String website;             // 网址（Http）
    private String status;              // 状态（使用/禁用，详情用，不进表格列）
    private Integer legacyId;
    private UUID categoryId;            // 所属分类 id（客户资料页"搜客户定位分类"用）
}
