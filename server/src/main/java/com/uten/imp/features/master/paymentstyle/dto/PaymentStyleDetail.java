package com.uten.imp.features.master.paymentstyle.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.util.UUID;

@Getter
@AllArgsConstructor
public class PaymentStyleDetail {
    private UUID id;
    private String code;
    private String name;
    private String category;
    private Integer level;
    private Integer legacyId;
    private UUID parentId;
    private String parentName;
    private Integer sortOrder;
    private String path;
    private boolean departmental;
    private boolean receipt;
    private boolean payment;
    private Integer linkedAccountLegacyId;
    private UUID linkedAccountId;
    private BigDecimal initBalance;
    private String status;
    private long childCount;
}
