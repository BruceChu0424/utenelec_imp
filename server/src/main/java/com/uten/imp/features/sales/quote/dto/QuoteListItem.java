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
public class QuoteListItem extends com.uten.imp.common.history.DocumentHistoryMetadata {
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
    /** 报价币种(与订货单列表同名; 列表的币种列按它解析名称)。 */
    private UUID currencyId;
    /** 交货日期(与订货单列表同名)。 */
    private LocalDate deliverDate;
    private String statusBucket;
    private String financeReturnReason;
    private OffsetDateTime submittedAt;
    private OffsetDateTime financeConfirmedAt;
    private int reviewRevision;
    private OffsetDateTime customerAcceptedAt;
    private Integer customerAcceptedRevision;
    private String cancelReason;
    private OffsetDateTime cancelledAt;
    private UUID convertedOrderId;
    private String convertedOrderNo;
    private String clientFileCurrency;
    private List<String> allowedActions;
    private boolean priceMasked;

    @Override public void disableHistoryActions() {
        writable = false;
        allowedActions = java.util.List.of();
    }
}
