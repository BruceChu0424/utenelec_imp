package com.uten.imp.features.master.unit.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.util.UUID;

/**
 * 基本单位列表项（扁平主档，列表即全字段）。
 */
@Getter
@AllArgsConstructor
public class UnitListItem {
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
     * 等于哪种重量单位(V743/ADR-135，仅重量维度)：G/KG/T/JIN/LB/OZ；null = 未指定。
     * 字典接口也带上，货品编辑、仓库称重据此判断「按数量精确折算重量」。
     */
    private String massUnitCode;
}
