package com.uten.imp.features.master.paymentstyle.dto;

import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

/** 收付款类别树节点（递归 children）。 */
@Getter
@Setter
@NoArgsConstructor
public class PaymentStyleNode {
    private UUID id;
    private String code;
    private String name;
    private String category;
    private Integer level;
    private UUID parentId;
    private Integer sortOrder;
    private String path;
    private boolean departmental;
    private boolean receipt;
    private boolean payment;
    private Integer linkedAccountLegacyId;
    private UUID linkedAccountId;
    private BigDecimal initBalance;
    private String status;
    private Integer legacyId;
    private List<PaymentStyleNode> children = new ArrayList<>();
}
