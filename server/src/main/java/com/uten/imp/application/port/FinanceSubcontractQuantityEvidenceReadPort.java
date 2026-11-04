package com.uten.imp.application.port;

import com.fasterxml.jackson.annotation.JsonFormat;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;

/** Single quantity-evidence contract for the original nineteen-column subcontract statement and immutable exports.
 * These reviewed financial statement sources never change stock, costs or original processing consideration. */
public interface FinanceSubcontractQuantityEvidenceReadPort {
    public enum Purpose { ROW_CORRESPONDENCE, PERIOD_OPENING, PERIOD_ENDING }
    public enum EvidenceType { BILATERAL_SETTLEMENT_EQUIVALENCE, RECEIPT_USAGE_DOCUMENT, PHYSICAL_COUNT }
    public enum SourceKind { MATERIAL_ISSUE, MATERIAL_RETURN, RECEIPT, PRODUCT_RETURN }
    public record Scope(UUID supplierId,LocalDate dateFrom,LocalDate dateTo) { }
    public record StockGroup(UUID goodsId,UUID colorId,UUID pcsUnitId) { }
    public record SourceRef(SourceKind kind,UUID itemId) { }
    /** Source unit and original quantity stay in the independently frozen source snapshot.
     * quantityPcs is explicitly supplied evidence in the selected real PCS unit, never a BOM-derived default.
     * No amount allocation field exists: processing money remains on its unique original source row. */
    public record Input(Scope scope,Purpose purpose,EvidenceType evidenceType,
                       SourceRef source,UUID materialIssueItemId,StockGroup stockGroup,
                       @JsonFormat(shape=JsonFormat.Shape.STRING) BigDecimal quantityPcs,
                       LocalDate evidenceDate,Boolean enabled,Boolean applyToStatement,String sourceReference) { }
    public record Attachment(String filename,String contentType,long size,String sha256) { }
    public record SourceSnapshot(SourceRef source,UUID documentId,UUID orderItemId,String billNo,LocalDate businessDate,
                                 UUID supplierId,UUID goodsId,UUID colorId,UUID unitId,String goodsCode,String goodsName,
                                 String unitCode,String unitName,
                                 @JsonFormat(shape=JsonFormat.Shape.STRING) BigDecimal quantityOriginal,
                                 UUID currencyId,
                                 @JsonFormat(shape=JsonFormat.Shape.STRING) BigDecimal priceOriginal,
                                 @JsonFormat(shape=JsonFormat.Shape.STRING) BigDecimal amountOriginal,
                                 String sourceBasis,List<String> issues,String identityFingerprint) { }
    /** A book estimate is separately labelled; null is never replaced by confirmed PCS or zero. */
    public record Approved(UUID id,String scopeKey,long revision,Input input,SourceSnapshot source,SourceSnapshot materialSource,
                           @JsonFormat(shape=JsonFormat.Shape.STRING) BigDecimal appliedQuantityPcs,
                           @JsonFormat(shape=JsonFormat.Shape.STRING) BigDecimal bookEstimatedPcs,
                           @JsonFormat(shape=JsonFormat.Shape.STRING) BigDecimal differencePcs,
                           String bookEstimateBasis,Attachment attachment,UUID submittedBy,UUID reviewedBy) { }
    public record Snapshot(Scope scope,List<Approved> evidence,String fingerprint) { }
    /** Latest independently approved enabled evidence for this exact supplier/period; missing remains unknown. */
    Snapshot approved(Scope scope);
}
