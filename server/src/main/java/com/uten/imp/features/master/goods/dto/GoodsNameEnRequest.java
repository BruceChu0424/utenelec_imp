package com.uten.imp.features.master.goods.dto;

import jakarta.validation.constraints.Size;

/**
 * 单独修改货品英文名称(ADR-134, {@code PUT /api/master/goods/{id}/name-en})。
 *
 * @param nameEn  新英文名称; null 或空白 = 清空
 * @param version 详情读到的乐观锁版本; 不符 409
 */
public record GoodsNameEnRequest(@Size(max = 255) String nameEn, Long version) {
}
