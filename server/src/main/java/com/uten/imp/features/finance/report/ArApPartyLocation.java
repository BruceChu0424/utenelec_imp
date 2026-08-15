package com.uten.imp.features.finance.report;

import java.util.UUID;

/**
 * 应收应付统一搜索的轻量分类定位结果。
 *
 * <p>一行代表一种往来单位类型下的一个命中分类；同一分类中的多个往来单位已在 SQL
 * 层去重。{@code categoryId == null} 表示至少命中一个未分类往来单位。
 */
public record ArApPartyLocation(String partyType, UUID categoryId) {
}
