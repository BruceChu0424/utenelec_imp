package com.uten.imp.features.master.goods.dto;

import com.fasterxml.jackson.annotation.JsonIgnore;
import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.annotation.JsonSetter;
import jakarta.validation.constraints.DecimalMax;
import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.Digits;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 货品主档新建/编辑请求（goods:edit）。
 *
 * <p>只开放「标识 + 物理 + 价格」核心字段；legacy_id/审计/软删不可改。所有在线关系只接受
 * UUID；请求中的各 legacyId 字段仅是旧客户端一致性影子，不能单独反查并建立关系。
 * 新建与编辑共用本 DTO（主档无「创建后不可改」字段、无父子约束）。
 *
 * <p>{@code mWeight} 加 {@link JsonProperty}：Jackson 对连续大写 getter（getMWeight）
 * 默认推导成 {@code MWeight}，与字段名不符，显式锁定为 {@code mWeight} 保证前后端一致。
 */
@Getter
@Setter
public class GoodsSaveRequest {

    @NotNull
    private UUID categoryId;     // 所属分类 UUID（必填；编号不能代替）

    @NotBlank
    private String name;         // Goods_Name 名称
    private String code;         // 显示编号；留空按分类前缀生成，手填也全局唯一且终身占用
    private String series;       // Series 物料系列（如塑胶件/五金件）
    private String stockPlace;   // StockPlace 库位号（仓库摆放位置）
    private String shortName;    // Short_Name 简称
    private String model;        // Number 型号
    private String spec;         // Standard 规格
    @Digits(integer = 14, fraction = 4)
    private BigDecimal price;    // Price（NUMERIC(18,4)）
    @Digits(integer = 14, fraction = 4)
    private BigDecimal discount; // 折扣倍率 1.00=原价 0.90=9折（复用老库 B_Goods.zk；改需 goods:price:edit 权限）
    private String material;     // Material 材质
    private BigDecimal thickness;
    private UUID thicknessUnitId;
    private Integer thicknessUnitLegacyId; // 旧库厚度单位主键快照；不能单独建立关系
    @JsonProperty("mWeight")
    private BigDecimal mWeight;  // MWeight 单重（防 Jackson 连续大写 quirk）
    private UUID mWeightUnitId;
    private Integer mWeightUnitLegacyId;   // 旧库单重单位主键快照；不能单独建立关系
    private String pack;         // Pack 包装
    private Integer pieces;      // Pieces 件数
    private String status;       // Status（使用/禁用）
    private UUID colorId;
    private Integer colorLegacyId;  // MColorID 旧库快照；颜色下拉只提交 colorId UUID
    private UUID unitId;
    private Integer unitLegacyId;   // UnitID 旧库快照；单位下拉只提交 unitId UUID
    private UUID mouldId;
    private Integer mouldLegacyId; // 旧库模具主键快照；不能单独建立关系
    @Size(max = 100)
    private String rearInsertCode; // 后模镶件编号（V457）：生产该货品需使用的后模镶件标识
    @Size(max = 5000)
    private String paper;          // Paper 备注（老系统备注列的真身；require_remark 仅迁移残值）
    private UUID clientId;
    private Integer clientLegacyId; // 旧库客户主键快照；不能单独建立关系
    private UUID defaultSupplierId;
    private Integer vendLegacyId; // 旧库默认供应商主键快照；不能单独建立关系
    private UUID secondarySupplierId;
    private Integer vend2LegacyId; // 旧库次供应商主键快照；不能单独建立关系

    @JsonIgnore
    private boolean colorReferencePresent;
    @JsonIgnore
    private boolean unitReferencePresent;
    @JsonIgnore
    private boolean mouldReferencePresent;
    @JsonIgnore
    private boolean clientReferencePresent;
    @JsonIgnore
    private boolean defaultSupplierReferencePresent;
    @JsonIgnore
    private boolean secondarySupplierReferencePresent;
    @JsonIgnore
    private boolean thicknessUnitReferencePresent;
    @JsonIgnore
    private boolean mWeightUnitReferencePresent;

    @JsonSetter("thicknessUnitId")
    public void setThicknessUnitId(UUID value) {
        thicknessUnitId = value;
        thicknessUnitReferencePresent = true;
    }

    @JsonSetter("thicknessUnitLegacyId")
    public void setThicknessUnitLegacyId(Integer value) {
        thicknessUnitLegacyId = value;
        thicknessUnitReferencePresent = true;
    }

    @JsonSetter("mWeightUnitId")
    public void setMWeightUnitId(UUID value) {
        mWeightUnitId = value;
        mWeightUnitReferencePresent = true;
    }

    @JsonSetter("mWeightUnitLegacyId")
    public void setMWeightUnitLegacyId(Integer value) {
        mWeightUnitLegacyId = value;
        mWeightUnitReferencePresent = true;
    }

    @JsonSetter("colorId")
    public void setColorId(UUID value) {
        colorId = value;
        colorReferencePresent = true;
    }

    @JsonSetter("colorLegacyId")
    public void setColorLegacyId(Integer value) {
        colorLegacyId = value;
        colorReferencePresent = true;
    }

    @JsonSetter("unitId")
    public void setUnitId(UUID value) {
        unitId = value;
        unitReferencePresent = true;
    }

    @JsonSetter("unitLegacyId")
    public void setUnitLegacyId(Integer value) {
        unitLegacyId = value;
        unitReferencePresent = true;
    }

    @JsonSetter("mouldId")
    public void setMouldId(UUID value) {
        mouldId = value;
        mouldReferencePresent = true;
    }

    @JsonSetter("mouldLegacyId")
    public void setMouldLegacyId(Integer value) {
        mouldLegacyId = value;
        mouldReferencePresent = true;
    }

    @JsonSetter("clientId")
    public void setClientId(UUID value) {
        clientId = value;
        clientReferencePresent = true;
    }

    @JsonSetter("clientLegacyId")
    public void setClientLegacyId(Integer value) {
        clientLegacyId = value;
        clientReferencePresent = true;
    }

    @JsonSetter("defaultSupplierId")
    public void setDefaultSupplierId(UUID value) {
        defaultSupplierId = value;
        defaultSupplierReferencePresent = true;
    }

    @JsonSetter("vendLegacyId")
    public void setVendLegacyId(Integer value) {
        vendLegacyId = value;
        defaultSupplierReferencePresent = true;
    }

    @JsonSetter("secondarySupplierId")
    public void setSecondarySupplierId(UUID value) {
        secondarySupplierId = value;
        secondarySupplierReferencePresent = true;
    }

    @JsonSetter("vend2LegacyId")
    public void setVend2LegacyId(Integer value) {
        vend2LegacyId = value;
        secondarySupplierReferencePresent = true;
    }

    public boolean hasColorReference() { return colorReferencePresent; }
    public boolean hasUnitReference() { return unitReferencePresent; }
    public boolean hasMouldReference() { return mouldReferencePresent; }
    public boolean hasClientReference() { return clientReferencePresent; }
    public boolean hasDefaultSupplierReference() { return defaultSupplierReferencePresent; }
    public boolean hasSecondarySupplierReference() { return secondarySupplierReferencePresent; }
    public boolean hasThicknessUnitReference() { return thicknessUnitReferencePresent; }
    public boolean hasMWeightUnitReference() { return mWeightUnitReferencePresent; }

    // ===== 成本预算（「成本预算」页签；可空，留空不清已有值时传 null 即覆盖为 null，前端表单始终全量回传） =====
    @DecimalMin("0.0000") @DecimalMax("99999999999999.9999") @Digits(integer = 14, fraction = 4)
    private BigDecimal sourceE;      // SourceE 材料合计
    @DecimalMin("0.0000") @DecimalMax("99999999999999.9999") @Digits(integer = 14, fraction = 4)
    private BigDecimal machiningE;   // MachiningE 加工费
    @DecimalMin("0.0000") @DecimalMax("99999999999999.9999") @Digits(integer = 14, fraction = 4)
    private BigDecimal incidentalE;  // IncidentalE 杂费
    @DecimalMin("0.0000") @DecimalMax("99999999999999.9999") @Digits(integer = 14, fraction = 4)
    private BigDecimal lacquerE;     // LacquerE 喷漆、朔费
    @DecimalMin("0.0000") @DecimalMax("99999999999999.9999") @Digits(integer = 14, fraction = 4)
    private BigDecimal platingE;     // PlatingE 电镀费
    @DecimalMin("0.0000") @DecimalMax("99999999999999.9999") @Digits(integer = 14, fraction = 4)
    private BigDecimal casingE;      // CasingE 包装费
    @DecimalMin("0.0000") @DecimalMax("99999999999999.9999") @Digits(integer = 14, fraction = 4)
    private BigDecimal polishE;      // PolishE 抛光费
    @DecimalMin("0.0000") @DecimalMax("99999999999999.9999") @Digits(integer = 14, fraction = 4)
    private BigDecimal total;        // Total 成品价
    @DecimalMin("0.0000") @DecimalMax("100.0000") @Digits(integer = 3, fraction = 4)
    private BigDecimal workRate;     // WorkRate 人工比率(%)
    @DecimalMin("0.0000") @DecimalMax("99999999999999.9999") @Digits(integer = 14, fraction = 4)
    private BigDecimal workE;        // WorkE 人工费
    @DecimalMin("0.0000") @DecimalMax("100.0000") @Digits(integer = 3, fraction = 4)
    private BigDecimal lostRate;     // LostRate 损耗比率(%)
    @DecimalMin("0.0000") @DecimalMax("99999999999999.9999") @Digits(integer = 14, fraction = 4)
    private BigDecimal lostE;        // LostE 损耗费
    @DecimalMin("0.0000") @DecimalMax("100.0000") @Digits(integer = 3, fraction = 4)
    private BigDecimal rentRate;     // RentRate 厂租比率(%)
    @DecimalMin("0.0000") @DecimalMax("99999999999999.9999") @Digits(integer = 14, fraction = 4)
    private BigDecimal rentE;        // RentE 厂房租金
    @DecimalMin("0.0000") @DecimalMax("100.0000") @Digits(integer = 3, fraction = 4)
    private BigDecimal makeRate;     // MakeRate 生产利率(%)
    @DecimalMin("0.0000") @DecimalMax("99999999999999.9999") @Digits(integer = 14, fraction = 4)
    private BigDecimal makeE;        // MakeE 生产利润
    @JsonProperty("cTotal")
    @DecimalMin("0.0000") @DecimalMax("99999999999999.9999") @Digits(integer = 14, fraction = 4)
    private BigDecimal cTotal;       // CTotal 成本价（防 Jackson 连续大写 quirk）
    @JsonProperty("gTotal")
    @DecimalMin("0.0000") @DecimalMax("99999999999999.9999") @Digits(integer = 14, fraction = 4)
    private BigDecimal gTotal;       // GTotal 出厂价（防 Jackson 连续大写 quirk）

    private String sourceType;   // 来源（自制/采购/委外）

    /** 乐观锁版本（编辑时回传详情读到的 version；新建忽略。不符即 409）。 */
    private Long version;
}
