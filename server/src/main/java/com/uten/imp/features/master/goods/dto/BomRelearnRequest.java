package com.uten.imp.features.master.goods.dto;

import jakarta.validation.constraints.NotNull;

import java.util.UUID;

/** 「从现在起重新学习」某个组件的真实使用数量(ADR-129 §2.9)。 */
public record BomRelearnRequest(@NotNull UUID componentGoodsId) {
}
