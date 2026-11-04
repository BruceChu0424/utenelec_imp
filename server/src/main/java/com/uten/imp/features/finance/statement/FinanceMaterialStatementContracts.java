package com.uten.imp.features.finance.statement;

import com.uten.imp.application.port.FinanceMaterialStatementSourcePort;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;

/** Explicit future-maintainable relations; none of these inputs changes warehouse quantities or posts another fee. */
public final class FinanceMaterialStatementContracts {
    private FinanceMaterialStatementContracts() { }
    public enum AmountBasis { LOCAL,ORIGINAL }
    public enum EvidenceKind { CONTEXT,GOODS,NATIVE_PARTY,UNIT,OPENING,WEIGHT,SOURCE_RELATION,COVERAGE,FEE,ZERO,SIDEBAR,CLOSE }
    public enum FlowRole { INBOUND,MATERIAL_OUT,FINISHED_OUT,MATERIAL_RETURN }
    public record SourceGoods(UUID contextId,FinanceMaterialStatementSourcePort.Kind sourceKind,UUID goodsId,UUID colorId,FlowRole flowRole,String sourceReference,Boolean enabled,String productNameCaption,String specificationCaption) {
        public SourceGoods(UUID contextId,FinanceMaterialStatementSourcePort.Kind sourceKind,UUID goodsId,UUID colorId,FlowRole flowRole,String sourceReference){this(contextId,sourceKind,goodsId,colorId,flowRole,sourceReference,true,null,null);}public boolean active(){return !Boolean.FALSE.equals(enabled);}
    }
    public record SidebarLine(UUID contextId,int slot,LocalDate dateFrom,LocalDate dateTo,UUID materialContextId,String productNameCaption,String unitCaption,BigDecimal referencePrice,UUID referenceCurrencyId,String sourceReference,Boolean enabled){public boolean active(){return !Boolean.FALSE.equals(enabled);}}
    public record Close(UUID contextId,String sourceReference) { }
    public record Draft(UUID requestId,UUID id,long expectedVersion,UUID contextId,long expectedContextVersion,
                        UUID expectedApprovedId,EvidenceKind kind,com.fasterxml.jackson.databind.JsonNode input) { }
    public record VerifyOperation(String path,com.fasterxml.jackson.databind.JsonNode body) { }
    public record Action(UUID requestId,long expectedVersion,long expectedContextVersion,String reason) { }
    public record ContextInput(UUID requestId,UUID id,Long expectedVersion,UUID auxiliaryId,UUID accountingCurrencyId,
                               AmountBasis amountBasis,UUID originalCurrencyId,
                               UUID goodsId,UUID colorId,LocalDate effectiveFrom,String sourceReference,String accountCode,
                               Integer sortOrder,Set<FinanceMaterialStatementSourcePort.Kind> requiredSourceKinds,
                               String productNameCaption,String specificationCaption,UUID sideQuantityUnitId,String quantityUnitCaption,
                               UUID draftId,Long expectedDraftVersion,Integer sideSlot) {
        public ContextInput(UUID requestId,UUID id,Long expectedVersion,UUID auxiliaryId,UUID accountingCurrencyId,AmountBasis amountBasis,UUID originalCurrencyId,UUID goodsId,UUID colorId,LocalDate effectiveFrom,String sourceReference,String accountCode,Integer sortOrder,Set<FinanceMaterialStatementSourcePort.Kind> requiredSourceKinds,String productNameCaption,String specificationCaption,UUID sideQuantityUnitId,String quantityUnitCaption){this(requestId,id,expectedVersion,auxiliaryId,accountingCurrencyId,amountBasis,originalCurrencyId,goodsId,colorId,effectiveFrom,sourceReference,accountCode,sortOrder,requiredSourceKinds,productNameCaption,specificationCaption,sideQuantityUnitId,quantityUnitCaption,null,null,null);}
    }
    public record CompareRow(int sourceRow,String reportRowKey) { }
    public record Compare(UUID sourceImportId,UUID auxiliaryId,UUID accountingCurrencyId,UUID contextId,
                          LocalDate dateFrom,LocalDate dateTo,List<CompareRow> rows,boolean allMaterialContexts) {
        public Compare(UUID sourceImportId,UUID auxiliaryId,UUID accountingCurrencyId,UUID contextId,LocalDate dateFrom,LocalDate dateTo,List<CompareRow> rows){this(sourceImportId,auxiliaryId,accountingCurrencyId,contextId,dateFrom,dateTo,rows,false);}
    }
    /** Native supplier/customer UUID relation is reviewed; OTHER financial parties are never matched by name. */
    public record NativePartyLink(UUID requestId,UUID contextId,long expectedVersion,String nativeRole,UUID nativePartyId,
                                  FinanceMaterialStatementSourcePort.Kind sourceKind,String sourceReference,boolean enabled) { }
    public record UnitEvidence(UUID requestId,UUID contextId,long expectedVersion,UUID sourceUnitId,
                               BigDecimal kgPerSourceUnit,BigDecimal pcsPerSourceUnit,String sourceReference,
                               UUID sourceGoodsId,UUID sourceColorId,String quantityBasis,BigDecimal sourceUnitRate,String kgBasis,Boolean enabled) {
        public UnitEvidence(UUID requestId,UUID contextId,long expectedVersion,UUID sourceUnitId,BigDecimal kgPerSourceUnit,BigDecimal pcsPerSourceUnit,String sourceReference,UUID sourceGoodsId,UUID sourceColorId,String quantityBasis,BigDecimal sourceUnitRate,String kgBasis){this(requestId,contextId,expectedVersion,sourceUnitId,kgPerSourceUnit,pcsPerSourceUnit,sourceReference,sourceGoodsId,sourceColorId,quantityBasis,sourceUnitRate,kgBasis,true);}public boolean active(){return !Boolean.FALSE.equals(enabled);}
    }
    public record OpeningEvidence(UUID requestId,UUID contextId,long expectedVersion,LocalDate effectiveFrom,
                                  BigDecimal balanceWeightKg,String sourceReference) { }
    public record WeightEvidence(UUID requestId,UUID contextId,long expectedVersion,FinanceMaterialStatementSourcePort.Key source,
                                 String expectedIdentityFingerprint,BigDecimal actualWeightKg,BigDecimal actualQuantityPcs,String sourceReference,
                                 UUID movementId,String expectedEffectFingerprint,Boolean enabled) {
        public WeightEvidence(UUID requestId,UUID contextId,long expectedVersion,FinanceMaterialStatementSourcePort.Key source,String expectedIdentityFingerprint,BigDecimal actualWeightKg,BigDecimal actualQuantityPcs,String sourceReference,UUID movementId,String expectedEffectFingerprint){this(requestId,contextId,expectedVersion,source,expectedIdentityFingerprint,actualWeightKg,actualQuantityPcs,sourceReference,movementId,expectedEffectFingerprint,true);}public boolean active(){return !Boolean.FALSE.equals(enabled);}
    }
    public record ZeroProcessing(UUID contextId,FinanceMaterialStatementSourcePort.Key source,String expectedIdentityFingerprint,UUID movementId,String expectedEffectFingerprint,boolean zeroProcessing,String sourceReference) { }
    public record SourceRelation(UUID contextId,FinanceMaterialStatementSourcePort.Key source,String expectedIdentityFingerprint,String sourceReference,Boolean enabled){public SourceRelation(UUID contextId,FinanceMaterialStatementSourcePort.Key source,String expectedIdentityFingerprint,String sourceReference){this(contextId,source,expectedIdentityFingerprint,sourceReference,true);}public boolean active(){return !Boolean.FALSE.equals(enabled);}}
    public record SourceCoverage(UUID contextId,FinanceMaterialStatementSourcePort.Kind sourceKind,LocalDate dateFrom,LocalDate dateTo,
                                 List<FinanceMaterialStatementSourcePort.Key> completeSources,boolean completeReviewed,String sourceReference,Boolean enabled){public SourceCoverage(UUID contextId,FinanceMaterialStatementSourcePort.Kind sourceKind,LocalDate dateFrom,LocalDate dateTo,List<FinanceMaterialStatementSourcePort.Key> completeSources,boolean completeReviewed,String sourceReference){this(contextId,sourceKind,dateFrom,dateTo,completeSources,completeReviewed,sourceReference,true);}public boolean active(){return !Boolean.FALSE.equals(enabled);}}
    public record GlAllocationKey(UUID entryId,int allocationNo) { }
    /** Split one real receivable allocation completely, retaining an explicit nonprocessing remainder if applicable. */
    /** Original amounts may stay null together when the real GL source has no original-currency evidence. */
    public enum AdjustmentPurpose { VAT,CUSTOMER_TAXPOINT }
    public record AdjustmentSource(GlAllocationKey source,String expectedSourceFingerprint,AdjustmentPurpose purpose,BigDecimal unrelatedLocal,BigDecimal unrelatedOriginal,String sourceReference) { }
    public record AdjustmentPart(GlAllocationKey source,BigDecimal amountLocal,BigDecimal amountOriginal,boolean includedInProcessing) { }
    public record FeePart(UUID contextId,FinanceMaterialStatementSourcePort.Key outboundSource,BigDecimal amountOriginal,
                          BigDecimal amountLocal,BigDecimal quotedProcessingPrice,UUID quotationCurrencyId,String quotationReference,UUID outboundMovementId,String quotationTaxBasis,
                          boolean adjustmentReviewed,List<AdjustmentPart> adjustments) {
        public FeePart(UUID contextId,FinanceMaterialStatementSourcePort.Key outboundSource,BigDecimal amountOriginal,BigDecimal amountLocal,BigDecimal quotedProcessingPrice,UUID quotationCurrencyId,String quotationReference,UUID outboundMovementId,String quotationTaxBasis){this(contextId,outboundSource,amountOriginal,amountLocal,quotedProcessingPrice,quotationCurrencyId,quotationReference,outboundMovementId,quotationTaxBasis,false,List.of());}
    }
    public record FeeAssignment(UUID requestId,GlAllocationKey source,long expectedVersion,List<FeePart> processingParts,
                                BigDecimal nonprocessingOriginal,BigDecimal nonprocessingLocal,String sourceReference,String expectedSourceFingerprint,List<AdjustmentSource> adjustmentSources) {
        public FeeAssignment(UUID requestId,GlAllocationKey source,long expectedVersion,List<FeePart> processingParts,BigDecimal nonprocessingOriginal,BigDecimal nonprocessingLocal,String sourceReference,String expectedSourceFingerprint){this(requestId,source,expectedVersion,processingParts,nonprocessingOriginal,nonprocessingLocal,sourceReference,expectedSourceFingerprint,List.of());}
    }
}
