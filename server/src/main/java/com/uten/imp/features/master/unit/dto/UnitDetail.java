package com.uten.imp.features.master.unit.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.util.UUID;

/**
 * 基本单位详情（扁平主档，与列表项同字段，保留独立 DTO 与货品范式对齐）。
 */
@Getter
@AllArgsConstructor
public class UnitDetail {
    private UUID id;
    private String code;
    private String name;
    private String status;
    /** 仅旧库迁移溯源；在线新建为 null，关系身份始终使用 {@link #id}。 */
    private Integer legacyId;
    /**
     * 计量维度(落 unit_measurement_profiles)：
     * COUNT 数量 / MASS 重量 / LENGTH 长度 / AREA 面积 / VOLUME 体积 / OTHER 其他。
     * null = 未设置。
     */
    private String measurementDimension;
    /**
     * 等于哪种重量单位(V743/ADR-135，仅重量维度)：G 克 / KG 千克 / T 吨 / JIN 斤 / LB 磅 / OZ 盎司。
     * 设了代码的单位做基本单位时，货品重量按数量精确折算，仓库不再另录实称重量；
     * null = 未指定(重量维度也允许不指定, 不做折算)。
     */
    private String massUnitCode;
}
