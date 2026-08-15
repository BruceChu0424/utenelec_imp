package com.uten.imp.features.master.paymentstyle.dto;

import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 收付款类别编辑请求（payment_style:edit）。
 *
 * <p>部分更新：缺失字段表示不修改。code/category 不可改（影响 path 与报表归类）；
 * 显式改 parent 会触发整棵子树层级和路径重建。
 */
@Getter
@Setter
public class PaymentStyleUpdateRequest {

    /** 部分更新：null 表示不修改名称。 */
    private String name;

    private UUID parentId;

    /**
     * 显式移动到根节点。仅 {@code true} 有含义，并且不能与 {@link #parentId} 同时提交。
     * {@code parentId == null} 默认仍表示“不修改上级”，避免普通编辑意外移根。
     */
    private Boolean moveToRoot;

    private Integer sortOrder;

    private Boolean departmental;
    private Boolean receipt;
    private Boolean payment;

    /** 迁移兼容影子；普通 API 不按该字段反查账户。 */
    private Integer linkedAccountLegacyId;
    /** 关联账户 UUID 真源；与 legacy 影子同时提交时必须一致。 */
    private UUID linkedAccountId;
    private BigDecimal initBalance;
    private String status;
}
