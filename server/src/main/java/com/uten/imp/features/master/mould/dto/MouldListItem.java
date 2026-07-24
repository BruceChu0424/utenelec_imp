package com.uten.imp.features.master.mould.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.util.UUID;

/**
 * 模具列表项（轻量摘要，列表核心字段）。与 GoodsListItem 同构，字段换成模具相关。
 */
@Getter
@AllArgsConstructor
public class MouldListItem {
    private UUID id;
    private String code;        // 模具编号（Number）
    private String name;        // 模具名称（MouldName）
    private String status;      // 生命周期（使用/报废）
    private String place;       // 车间/位置
    private String keeper;      // 保管人
    private Integer legacyId;
}
