package com.uten.imp.features.master.goods.dto;

import lombok.Getter;
import com.fasterxml.jackson.annotation.JsonIgnore;
import com.fasterxml.jackson.annotation.JsonSetter;
import lombok.Setter;

import jakarta.validation.constraints.NotNull;
import java.math.BigDecimal;
import java.util.UUID;

/**
 * 组装信息行 新建/编辑请求（goods:edit）。
 *
 * <p>componentGoodsId 必填且必须是存在、可见货品的 UUID；UI 可按编号/名称搜索，但最终只提交 UUID，
 * 展示编号改变不会改变 BOM 关系。total 不传时后端按 qty*price 兜底重算。
 */
@Getter
@Setter
public class BomItemSaveRequest {

    @NotNull
    private UUID componentGoodsId;   // 组件货品 UUID（唯一实时关联键，必填）

    private BigDecimal qty;          // 用量（默认 1）
    private String controlStage;     // START/ASSEMBLY/FINISH/SHIP/REFERENCE
    private String consumptionBasis; // PER_UNIT/PER_PACKAGE/FIXED_BATCH
    private BigDecimal basisOutputQty;
    private Boolean allowPartialPackage;
    // 仅 START/ASSEMBLY/FINISH 可为 true；SHIP/REFERENCE 只能作参考。
    private Boolean hardGate;
    private BigDecimal price;        // 单价
    private BigDecimal total;        // 金额（可空，后端兜底 qty*price）
    private UUID colorId;
    private Integer colorLegacyId;   // 旧库颜色主键快照；不能单独用于建立新关系
    private UUID defaultSupplierId;
    private Integer vendLegacyId;    // 旧库供应商主键快照；不能单独用于建立新关系
    private String summary;          // 备注（外购/外加工...）

    @JsonIgnore
    private boolean colorReferencePresent;
    @JsonIgnore
    private boolean defaultSupplierReferencePresent;

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

    public boolean hasColorReference() {
        return colorReferencePresent;
    }

    public boolean hasDefaultSupplierReference() {
        return defaultSupplierReferencePresent;
    }
}
