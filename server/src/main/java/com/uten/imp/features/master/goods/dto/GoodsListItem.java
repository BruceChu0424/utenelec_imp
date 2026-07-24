package com.uten.imp.features.master.goods.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 货品列表项（轻量摘要，列表核心字段）。
 * price 统一用 BigDecimal 便于前端精度展示（实体 price 为 Double，service 端转换）。
 */
@Getter
@AllArgsConstructor
public class GoodsListItem {
    private UUID id;
    private String code;
    private String name;
    private String spec;
    private String model;
    private BigDecimal price;
    private String status;
    private Integer legacyId;
}
