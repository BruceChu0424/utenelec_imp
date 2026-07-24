package com.uten.imp.features.master.client.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.util.UUID;

/**
 * 客户列表项（轻量摘要，列表核心字段）。与 MouldListItem 同构，字段换成客户相关。
 */
@Getter
@AllArgsConstructor
public class ClientListItem {
    private UUID id;
    private String code;        // 客户编号（Number）
    private String name;        // 客户名称（Client_Name）
    private String status;      // 生命周期（使用/禁用）
    private String region;      // 区域（QYName，如 外贸/内销南区）
    private String linkman;     // 联系人（Link_Man）
    private Integer legacyId;
}
