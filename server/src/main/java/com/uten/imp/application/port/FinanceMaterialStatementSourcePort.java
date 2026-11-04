package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;

/** Minimal physical-source evidence for the original other-receivable statement; never stock or GL writes. */
public interface FinanceMaterialStatementSourcePort {
    enum Kind { PURCHASE_RECEIPT_LINE,STOCK_OTHER_OUT_LINE,SALES_OTHER_SHIPMENT_LINE,SUBCONTRACT_MATERIAL_ISSUE_LINE,SUBCONTRACT_MATERIAL_RETURN_LINE }
    enum ColorMode { NO_COLOR, EXACT, ANY }
    record Key(Kind kind,UUID lineId) { }
    /** eventSign signs the original statement column: normal receipt/outgoing +1, material return -1; actual reversal is the opposite sign.
     * baseQuantity is the stock base unit; quantity is the exact source-unit quotient, or null when not finite. */
    record Effect(UUID movementId,UUID stockInItemId,LocalDate businessDate,LocalDate sourceBusinessDate,LocalDate confirmationDate,int eventSign,boolean reversal,
                  UUID warehouseId,UUID unitId,
                  @com.fasterxml.jackson.annotation.JsonFormat(shape=com.fasterxml.jackson.annotation.JsonFormat.Shape.STRING)BigDecimal baseQuantity,
                  @com.fasterxml.jackson.annotation.JsonFormat(shape=com.fasterxml.jackson.annotation.JsonFormat.Shape.STRING)BigDecimal unitRate,
                  @com.fasterxml.jackson.annotation.JsonFormat(shape=com.fasterxml.jackson.annotation.JsonFormat.Shape.STRING)BigDecimal quantity,
                  @com.fasterxml.jackson.annotation.JsonFormat(shape=com.fasterxml.jackson.annotation.JsonFormat.Shape.STRING)BigDecimal weightKg,
                  @com.fasterxml.jackson.annotation.JsonFormat(shape=com.fasterxml.jackson.annotation.JsonFormat.Shape.STRING)BigDecimal estimatedWeightKg,
                  String weightSource,String identityFingerprint,Map<String,Object> sourceSnapshot) { }
    /**
     * quantity is in the immutable source unit; unitRate is a source base-unit fact, never a KG/PCS guess.
     * weightKg is only an actual, exact or explicit measured slice. An average/estimate remains in estimatedWeightKg.
     * Reversal is another dated effect of the same source, not deletion of its earlier physical event.
     */
    record Fact(Key key,UUID documentId,String billNo,LocalDate businessDate,LocalDate reversedDate,
                UUID supplierId,UUID customerId,UUID warehouseId,UUID goodsId,UUID colorId,
                String goodsCode,String goodsName,String specification,UUID unitId,String unitName,
                @com.fasterxml.jackson.annotation.JsonFormat(shape=com.fasterxml.jackson.annotation.JsonFormat.Shape.STRING)BigDecimal quantity,@com.fasterxml.jackson.annotation.JsonFormat(shape=com.fasterxml.jackson.annotation.JsonFormat.Shape.STRING)BigDecimal unitRate,@com.fasterxml.jackson.annotation.JsonFormat(shape=com.fasterxml.jackson.annotation.JsonFormat.Shape.STRING)BigDecimal weightKg,@com.fasterxml.jackson.annotation.JsonFormat(shape=com.fasterxml.jackson.annotation.JsonFormat.Shape.STRING)BigDecimal estimatedWeightKg,
                String weightBasis,boolean approved,boolean identityComplete,String identityFingerprint,
                Map<String,Object> sourceSnapshot,List<Effect> effects,List<String> issues) { }
    record Query(Kind kind,UUID supplierId,UUID customerId,UUID goodsId,UUID colorId,
                 LocalDate dateFrom,LocalDate dateTo,String keyword,int page,int size,ColorMode colorMode,boolean includeDerivedQuantity) {
        public Query(Kind kind,UUID supplierId,UUID customerId,UUID goodsId,UUID colorId,LocalDate from,LocalDate to,String keyword,int page,int size){
            this(kind,supplierId,customerId,goodsId,colorId,from,to,keyword,page,size,colorId==null?ColorMode.NO_COLOR:ColorMode.EXACT,true);
        }
        public Query(Kind kind,UUID supplierId,UUID customerId,UUID goodsId,UUID colorId,LocalDate from,LocalDate to,String keyword,int page,int size,ColorMode mode){this(kind,supplierId,customerId,goodsId,colorId,from,to,keyword,page,size,mode,true);}
    }
    record Page(List<Fact> items,int page,int size,long total,int totalPages) { }
    /** Caller is already company-wide finance; the implementation authorizes this minimal cross-module purpose. */
    Page candidates(Query query);
    /** Exact bounded IDs retain their original order; missing/unapproved sources return explicit validation errors. */
    List<Fact> read(List<Key> keys);
    /** Same immutable facts without deriving an unrelated display quotient during evidence verification. */
    List<Fact> readForIdentity(List<Key> keys);
}
