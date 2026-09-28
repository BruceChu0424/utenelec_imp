package com.uten.imp.features.master.learning;

import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 客户资料「货品对照」页签的一行(ADR-134, {@code GET /api/master/clients/{id}/goods-aliases})。
 *
 * @param scope               CLIENT(该客户专属); 列表只返回该客户的对照
 * @param aliasKind           PART_NO 客户型号 / DESCRIPTION 客户品名
 * @param aliasText           客户最近一次在文件里的写法
 * @param contextText         适用范围的可读写法(系列与主色, 例如「Z9 · 白」); 未知为空
 * @param confirmCount        被保存确认的次数
 * @param explicitCount       用户明确选择这个货品的次数
 * @param lastConfirmedByName 最近一次确认人「姓名(工号)」
 * @param canDelete           当前用户能否删除(client:edit 且对该客户有写范围)
 */
public record ClientGoodsAliasView(UUID id, String scope, String aliasKind, String aliasText, String contextText,
                                   GoodsRef goods, int confirmCount, int explicitCount,
                                   OffsetDateTime lastConfirmedAt, String lastConfirmedByName, boolean canDelete) {

    /** 对照指向的货品。 */
    public record GoodsRef(UUID id, String code, String name, String colorName) {
    }
}
