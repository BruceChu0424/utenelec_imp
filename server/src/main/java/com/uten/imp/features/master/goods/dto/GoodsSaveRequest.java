package com.uten.imp.features.master.goods.dto;

import com.fasterxml.jackson.annotation.JsonProperty;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 货品主档新建/编辑请求（goods:edit）。
 *
 * <p>只开放「标识 + 物理 + 价格」核心字段；老库 78 字段里的成本项/图片/关联 legacy_id
 * 暂不在表单维护（含义不明或结构留位）。legacy_id/审计/软删不可改。
 * 新建与编辑共用本 DTO（主档无「创建后不可改」字段、无父子约束）。
 *
 * <p>{@code mWeight} 加 {@link JsonProperty}：Jackson 对连续大写 getter（getMWeight）
 * 默认推导成 {@code MWeight}，与字段名不符，显式锁定为 {@code mWeight} 保证前后端一致。
 */
@Getter
@Setter
public class GoodsSaveRequest {

    @NotNull
    private UUID categoryId;     // 所属分类（必填）

    @NotBlank
    private String name;         // Goods_Name 名称
    private String code;         // ANumber 编号
    private String shortName;    // Short_Name 简称
    private String model;        // Number 型号
    private String spec;         // Standard 规格
    private BigDecimal price;    // Price（entity 存 Double，service 转）
    private String material;     // Material 材质
    private BigDecimal thickness;
    @JsonProperty("mWeight")
    private BigDecimal mWeight;  // MWeight 单重（防 Jackson 连续大写 quirk）
    private String pack;         // Pack 包装
    private Integer pieces;      // Pieces 件数
    private String status;       // Status（使用/禁用）
}
