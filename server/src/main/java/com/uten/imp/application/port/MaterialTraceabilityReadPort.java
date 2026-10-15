package com.uten.imp.application.port;

import com.fasterxml.jackson.databind.annotation.JsonSerialize;
import com.uten.imp.common.finance.ExactDecimalText;
import com.uten.imp.common.web.PageResponse;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** Read boundary for the where-used centre; implementations retain document and physical-source authority. */
public interface MaterialTraceabilityReadPort {
    enum SubjectType { GOODS, PURCHASE_ORDER, SUBCONTRACT_ORDER, PRODUCTION_PLAN, PRODUCTION_REPORT, STOCK_DOC, PRODUCTION_OUTPUT_LOT }

    record Subject(String type, UUID id, String code, String label, LocalDate documentDate, String status,
                   UUID goodsId, String goodsCode, String goodsName, String basis, boolean traceable, String reason) {}

    record Goods(UUID goodsId, String goodsCode, String goodsName, UUID colorId, String colorName, UUID unitId, String unitName) {}

    record Source(String type, UUID id, String code, LocalDate date, Goods goods,
                  @JsonSerialize(using=ExactDecimalText.class) BigDecimal qty, String unitName, String status,
                  String basis, String note, String warehouseName, String supplierName,UUID itemId,
                  Goods relatedProduct,UUID relatedOrderId,String relatedOrderCode,String docType) {}

    /** Existing canonical trace rows implement this boundary without copying their JSON projection. */
    interface TraceItem { String id(); String kind(); String quantityBasis(); }

    record Result(List<? extends TraceItem> items, int page, int size, long total, int totalPages,
                  Subject subject, List<Source> sources, boolean sourcesTruncated, List<String> coverageNotes) {}

    PageResponse<Subject> subjects(String kind, String keyword, boolean exact, int page, int size);
    Result trace(String subjectType, UUID subjectId, String direction, LocalDate dateFrom, LocalDate dateTo, int page, int size);
}
