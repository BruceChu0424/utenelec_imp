package com.uten.imp.features.sales.quote.dto;

import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/** 销售报价列表项(statusBucket/allowedActions 口径同 {@link QuoteDetail})。 */
@Getter
@Setter
@NoArgsConstructor
public class QuoteListItem {
    private UUID id;
    private String billNo;
    private LocalDate billDate;
    private UUID clientId;
    private BigDecimal totalOriginal;
    private BigDecimal totalLocal;
    private Short status;
    private boolean closed;
    private Integer legacyId;
    /** Current caller may mutate this document (functional permission + owner scope + draft). */
    private boolean writable;
    private UUID sellerId;
    private String statusBucket;
    private String financeReturnReason;
    private OffsetDateTime submittedAt;
    private OffsetDateTime financeConfirmedAt;
    private int reviewRevision;
    private UUID convertedOrderId;
    private String convertedOrderNo;
    private String clientFileCurrency;
    private List<String> allowedActions;
    private boolean priceMasked;
}
