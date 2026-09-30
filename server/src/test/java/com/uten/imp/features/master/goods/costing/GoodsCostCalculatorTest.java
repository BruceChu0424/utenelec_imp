package com.uten.imp.features.master.goods.costing;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.MasterReferenceValidationPort;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;
import static com.uten.imp.features.master.goods.costing.GoodsCostContracts.*;
import static com.uten.imp.features.master.goods.costing.GoodsCostSourceReader.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class GoodsCostCalculatorTest {
    final GoodsCostSourceReader sources=mock(GoodsCostSourceReader.class);
    final MasterReferenceValidationPort references=mock(MasterReferenceValidationPort.class);
    final GoodsCostJson json=new GoodsCostJson(new ObjectMapper().findAndRegisterModules());
    final GoodsCostCalculator calculator=new GoodsCostCalculator(sources,references,json);
    final UUID rootId=UUID.randomUUID(),materialId=UUID.randomUUID(),edgeId=UUID.randomUUID(),unitId=UUID.randomUUID();
    final GoodsInfo root=new GoodsInfo(rootId,"P1","成品",unitId,"个",null,null,"自制","1");
    final GoodsInfo material=new GoodsInfo(materialId,"M1","材料",unitId,"kg",null,null,"采购","1");
    @BeforeEach void defaults() {
        when(sources.goods(rootId)).thenReturn(root);when(sources.currency(null)).thenReturn("本币");
        when(sources.edges(materialId)).thenReturn(List.of());
        when(sources.approved(eq(material),eq(false),any(),isNull())).thenReturn(price("400","25","1"));
    }
    @Test void tinyMaterialDoesNotUseFourDecimalExecutionCeilingAndBagPriceKeepsItsRate() {
        when(sources.edges(rootId)).thenReturn(List.of(edge("0.00007",null,"PER_UNIT","1",true)));
        Calculation result=calculator.calculate(input("10000",List.of(),List.of()));
        assertThat(result.lines().getFirst().batchQty()).isEqualTo("0.7");
        assertThat(result.lines().getFirst().unitPrice()).isEqualTo("16");
        assertThat(result.totals().knownTotal()).isEqualTo("11.2");
        assertThat(result.totals().unitCost()).isEqualTo("0.00112");
    }
    @Test void learnedQuantityWinsAndNoSecondLossMultiplierIsInvented() {
        when(sources.edges(rootId)).thenReturn(List.of(edge("1","1.2","PER_UNIT","1",true)));
        Calculation result=calculator.calculate(input("3",List.of(),List.of()));
        assertThat(result.lines().getFirst().usageBasis()).isEqualTo("ACTUAL");
        assertThat(result.lines().getFirst().batchQty()).isEqualTo("3.6");
        assertThat(result.totals().knownTotal()).isEqualTo("57.6");
        assertThat(result.totals().actualUsageCount()).isEqualTo(1);
    }
    @Test void wholePackageIsPricedAtTheBatchBoundaryNotOneItemTimesBatch() {
        when(sources.edges(rootId)).thenReturn(List.of(edge("1",null,"PER_PACKAGE","100",false)));
        Calculation result=calculator.calculate(input("101",List.of(),List.of()));
        assertThat(result.lines().getFirst().batchQty()).isEqualTo("2");
        assertThat(result.totals().knownTotal()).isEqualTo("32");
    }
    @Test void missingPriceDoesNotBecomeZeroOrAllowCompleteTotal() {
        when(sources.edges(rootId)).thenReturn(List.of(edge("1",null,"PER_UNIT","1",true)));
        when(sources.approved(eq(material),eq(false),any(),isNull())).thenReturn(null);
        Calculation result=calculator.calculate(input("1",List.of(),List.of(fee("manage","PERCENT","12",List.of("MATERIAL")))));
        assertThat(result.lines().getFirst().amount()).isNull();
        assertThat(result.totals().unitCost()).isNull();
        assertThat(result.fees().getFirst().amount()).isNull();
        assertThat(result.fees().getFirst().valueState()).isEqualTo("INCOMPLETE");
        assertThat(result.fees().getFirst().reason()).contains("基数尚未完整");
        assertThat(result.totals().valueState()).isEqualTo("INCOMPLETE");
    }
    @Test void feeGraphSupportsChainedBasesAndDetectsCycles() {
        when(sources.edges(rootId)).thenReturn(List.of(edge("1",null,"PER_UNIT","1",true)));
        Calculation result=calculator.calculate(input("10",List.of(),List.of(
                fee("setup","FIXED_BATCH","20",List.of()),fee("manage","PERCENT","12",List.of("MATERIAL","setup")))));
        assertThat(result.totals().knownTotal()).isEqualTo("201.6");
        assertThat(result.fees().getLast().amount()).isEqualTo("21.6");
        assertThatThrownBy(()->calculator.calculate(input("1",List.of(),List.of(
                fee("a","PERCENT","1",List.of("b")),fee("b","PERCENT","1",List.of("a")))))).hasMessageContaining("循环");
    }
    @Test void manualOverrideRequiresReasonAndPreservesFullPricePrecision() {
        when(sources.edges(rootId)).thenReturn(List.of(edge("1",null,"PER_UNIT","1",true)));
        LineOverride override=new LineOverride(edgeId.toString(),null,null,"0.1234567891","1","1",null,"AS_RECORDED",null,"MANUAL","已核对采购协议");
        Calculation result=calculator.calculate(input("3",List.of(override),List.of()));
        assertThat(result.totals().knownTotal()).isEqualTo("0.3703703673");
        assertThat(result.lines().getFirst().priceEvidence().sourceType()).isEqualTo("MANUAL");
    }
    @Test void makeParentRollsChildrenForDisplayWithoutDoubleCounting() {
        UUID assembly=UUID.randomUUID(),childEdge=UUID.randomUUID();
        GoodsInfo sub=new GoodsInfo(assembly,"S1","半成品",unitId,"个",null,null,"自制","1");
        Edge first=new Edge(edgeId,rootId,sub,new BigDecimal("2"),null,new BigDecimal("2"),"NO_DATA",0,null,null,"PER_UNIT",BigDecimal.ONE,true,false,"1");
        Edge leaf=new Edge(childEdge,assembly,material,new BigDecimal("3"),null,new BigDecimal("3"),"NO_DATA",0,null,null,"PER_UNIT",BigDecimal.ONE,true,false,"1");
        when(sources.edges(rootId)).thenReturn(List.of(first));when(sources.edges(assembly)).thenReturn(List.of(leaf));
        Calculation result=calculator.calculate(input("10",List.of(),List.of()));
        assertThat(result.lines()).hasSize(2);
        assertThat(result.lines().getFirst().included()).isFalse();
        assertThat(result.lines().getFirst().amount()).isEqualTo("960");
        assertThat(result.totals().knownTotal()).isEqualTo("960");
    }
    @Test void priceColumnProducesTypedFeeAndExposesItsAmountOnThatPath() {
        when(sources.edges(rootId)).thenReturn(List.of(edge("2",null,"PER_UNIT","1",true)));
        DraftInput in=input("3",List.of(),List.of());
        in=new DraftInput(in.goodsId(),null,in.name(),in.batchQty(),null,"1",in.effectiveDate(),in.usageStrategy(),in.priceStrategy(),null,List.of(),List.of(),
                List.of(new PriceColumn("spray","喷油","PER_QUANTITY","PROCESS",List.of())),
                List.of(new PriceCell(edgeId.toString(),"spray","0.25",null,"工序协议")),Map.of(),null);
        Calculation result=calculator.calculate(in);
        assertThat(result.totals().process()).isEqualTo("1.5");
        assertThat(result.lines().getFirst().extraCosts()).containsEntry("spray","1.5");
        assertThat(result.lines().getFirst().materialAmount()).isEqualTo("96");
        assertThat(result.lines().getFirst().feeAmount()).isEqualTo("1.5");
        assertThat(result.lines().getFirst().amount()).isEqualTo("97.5");
        assertThat(result.totals().knownTotal()).isEqualTo("97.5");
    }
    @Test void changingApprovalEvidenceChangesDigestButClockDoesNot() {
        when(sources.edges(rootId)).thenReturn(List.of(edge("1",null,"PER_UNIT","1",true)));
        DraftInput in=input("1",List.of(),List.of());
        String first=calculator.calculate(in).contentDigest();
        assertThat(calculator.calculate(in).contentDigest()).isEqualTo(first);
        when(sources.approved(eq(material),eq(false),any(),isNull())).thenReturn(price("500","25","1"));
        assertThat(calculator.calculate(in).contentDigest()).isNotEqualTo(first);
    }
    @Test void repeatingQuantityAndDecimalPriceCancelBeforeAnyDecimalProjection() {
        when(sources.edges(rootId)).thenReturn(List.of(edge("1",null,"PER_PACKAGE","3",true)));
        when(sources.approved(eq(material),eq(false),any(),isNull())).thenReturn(price("3.123456789","1","1"));
        Calculation result=calculator.calculate(input("1",List.of(),List.of()));
        assertThat(result.totals().knownTotal()).isEqualTo("1.041152263");
    }
    @Test void nestedFractionalBomPathCancelsExactlyRatherThanAccumulatingRoundedUsage() {
        UUID assembly=UUID.randomUUID(),childEdge=UUID.randomUUID();
        GoodsInfo sub=new GoodsInfo(assembly,"S1","半成品",unitId,"个",null,null,"自制","1");
        Edge first=new Edge(edgeId,rootId,sub,BigDecimal.ONE,null,BigDecimal.ONE,"NO_DATA",0,null,null,"PER_PACKAGE",new BigDecimal("3"),true,false,"1");
        Edge leaf=new Edge(childEdge,assembly,material,new BigDecimal("3"),null,new BigDecimal("3"),"NO_DATA",0,null,null,"PER_UNIT",BigDecimal.ONE,true,false,"1");
        when(sources.edges(rootId)).thenReturn(List.of(first));when(sources.edges(assembly)).thenReturn(List.of(leaf));
        Calculation result=calculator.calculate(input("1",List.of(),List.of()));
        assertThat(result.lines().getLast().batchQty()).isEqualTo("1");
        assertThat(result.totals().knownTotal()).isEqualTo("16");
    }
    @Test void approvedRecordedPriceNeedsNoTaxAcknowledgementAndExplicitExclusionIsBoundToSourceRevision() {
        when(sources.edges(rootId)).thenReturn(List.of(edge("1",null,"PER_UNIT","1",true)));
        PriceEvidence first=recorded("1");
        when(sources.approved(eq(material),eq(false),any(),isNull())).thenReturn(first);
        Calculation automatic=calculator.calculate(input("1",List.of(),List.of()));
        assertThat(automatic.issues()).noneMatch(issue->issue.code().equals("TAX_BASIS_UNCONFIRMED"));
        assertThat(automatic.totals().valueState()).isEqualTo("COMPLETE");assertThat(automatic.totals().knownTotal()).isEqualTo("16");
        LineOverride ack=new LineOverride(edgeId.toString(),null,null,null,null,null,null,"EXCLUDE_TAX",edgeId,"APPROVED_PURCHASE","已核实原价含税，按原税率扣税","1");
        Calculation excluded=calculator.calculate(input("1",List.of(ack),List.of()));
        assertThat(excluded.totals().valueState()).isEqualTo("COMPLETE");assertThat(excluded.totals().knownTotal()).isNotEqualTo("16");
        when(sources.approved(eq(material),eq(false),any(),isNull())).thenReturn(recorded("2"));
        Calculation stale=calculator.calculate(input("1",List.of(ack),List.of()));
        assertThat(stale.totals().valueState()).isEqualTo("INCOMPLETE");assertThat(stale.totals().knownTotal()).isEqualTo("16");
        assertThat(stale.issues()).anyMatch(issue->issue.code().equals("TAX_BASIS_UNCONFIRMED"));
    }
    @Test void managementBaseIncludesDynamicProcessColumnsExactlyOnce() {
        when(sources.edges(rootId)).thenReturn(List.of(edge("1",null,"PER_UNIT","1",true)));
        DraftInput in=input("1",List.of(),List.of(fee("manage","PERCENT","12",List.of("DIRECT_COST"))));
        in=new DraftInput(in.goodsId(),null,in.name(),in.batchQty(),null,"1",in.effectiveDate(),in.usageStrategy(),in.priceStrategy(),null,List.of(),in.fees(),
                List.of(new PriceColumn("spray","喷油","PER_QUANTITY","PROCESS",List.of())),
                List.of(new PriceCell(edgeId.toString(),"spray","4",null,"工序价")),Map.of(),null);
        Calculation result=calculator.calculate(in);
        assertThat(result.totals().material()).isEqualTo("16");assertThat(result.totals().process()).isEqualTo("4");
        assertThat(result.totals().management()).isEqualTo("2.4");assertThat(result.totals().knownTotal()).isEqualTo("22.4");
    }
    @Test void templatesCannotCarryForeignOrExpiredBomPathsAcrossProducts() {
        when(sources.edges(rootId)).thenReturn(List.of(edge("1",null,"PER_UNIT","1",true)));
        FeeInput bound=new FeeInput("spray","喷油","PER_QUANTITY","PROCESS",edgeId.toString(),"1",null,List.of(),null,null);
        assertThatThrownBy(()->calculator.validateTemplatePaths(null,List.of(bound))).hasMessageContaining("限定具体产品");
        assertThatCode(()->calculator.validateTemplatePaths(rootId,List.of(bound))).doesNotThrowAnyException();
        when(sources.edges(rootId)).thenReturn(List.of());
        assertThatThrownBy(()->calculator.validateTemplatePaths(rootId,List.of(bound))).hasMessageContaining("已失效");
    }
    @Test void fixedCommercialAdjustmentCannotBeWashedIntoACompletePriceByTaxAcknowledgement() {
        when(sources.edges(rootId)).thenReturn(List.of(edge("1",null,"PER_UNIT","1",true)));
        PriceEvidence p=recorded("1");
        PriceEvidence components=new PriceEvidence(p.sourceType(),p.sourceId(),p.sourceItemId(),p.sourceNumber(),p.sourceVersion(),"APPROVED_WITH_COMPONENTS",
                p.supplierId(),p.currencyId(),p.currencyName(),p.unitId(),p.unitName(),p.unitRate(),p.originalUnitPrice(),p.exchangeRateToLocal(),p.taxRate(),p.taxMode(),p.sourceDate(),"原单另有每批固定费用10元，需拆分核对");
        when(sources.approved(eq(material),eq(false),any(),isNull())).thenReturn(components);
        LineOverride ack=new LineOverride(edgeId.toString(),null,null,null,null,null,null,"AS_RECORDED",edgeId,"APPROVED_PURCHASE","按原记录价","1");
        Calculation result=calculator.calculate(input("2",List.of(ack),List.of(fee("manage","PERCENT","12",List.of("MATERIAL")))));
        assertThat(result.totals().knownTotal()).isEqualTo("32");
        assertThat(result.totals().valueState()).isEqualTo("INCOMPLETE");
        assertThat(result.fees().getFirst().amount()).isNull();
        assertThat(result.issues()).anyMatch(issue->issue.code().equals("PRICE_COMPONENTS_UNCONFIRMED")&&issue.message().contains("固定费用"));
    }
    @Test void currencyRateDefaultsOnlyForVerifiedBaseCurrency() {
        UUID foreign=UUID.randomUUID(),base=UUID.randomUUID();when(sources.baseCurrency(base)).thenReturn(true);
        assertThatThrownBy(()->calculator.normalizeExchangeRate(foreign,null)).hasMessageContaining("缺少汇率");
        assertThatThrownBy(()->calculator.normalizeExchangeRate(foreign," ")).hasMessageContaining("缺少汇率");
        assertThatThrownBy(()->calculator.normalizeExchangeRate(base,"2")).hasMessageContaining("必须为1");
        assertThat(calculator.normalizeExchangeRate(base,null)).isEqualTo("1");
        assertThat(calculator.normalizeExchangeRate(null,null)).isEqualTo("1");
        assertThat(calculator.normalizeExchangeRate(foreign,"7.123456789123456789")).isEqualTo("7.123456789123456789");
    }
    @Test void manualPackagePriceNamesItsPricingBasisInsteadOfMislabelingItAsBasicUnitPrice() {
        when(sources.edges(rootId)).thenReturn(List.of(edge("1",null,"PER_UNIT","1",true)));
        LineOverride override=new LineOverride(edgeId.toString(),null,null,"400","25","1",null,"AS_RECORDED",null,"MANUAL","25kg一袋价400");
        CostLine line=calculator.calculate(input("1",List.of(override),List.of())).lines().getFirst();
        assertThat(line.unitPrice()).isEqualTo("16");assertThat(line.unitName()).isEqualTo("kg");
        assertThat(line.priceEvidence().originalUnitPrice()).isEqualTo("400");
        assertThat(line.priceEvidence().unitName()).isEqualTo("25 kg (计价基数)");
        assertThat(line.priceEvidence().unitId()).isNull();
    }
    @Test void missingCycleOutputIsNotInventedFromBatchQuantityAndBlankRemainsDraftable() {
        when(sources.edges(rootId)).thenReturn(List.of(edge("1",null,"PER_UNIT","1",true)));
        for(String quantity:Arrays.asList(null,""," ")) {
            FeeInput cycle=new FeeInput("cycle","注塑","PER_CYCLE","PROCESS",edgeId.toString(),"10",quantity,List.of(),"MANUAL",null);
            Calculation result=calculator.calculate(input("26",List.of(),List.of(cycle)));
            assertThat(result.fees().getFirst().amount()).isNull();assertThat(result.fees().getFirst().valueState()).isEqualTo("MISSING");
            assertThat(result.fees().getFirst().reason()).contains("每周期产出");
            assertThat(result.totals().valueState()).isEqualTo("INCOMPLETE");assertThat(result.totals().unitCost()).isNull();
        }
    }
    @Test void cycleOutputRoundsUpActualQuantityAndRejectsZeroOrNegativeOutput() {
        when(sources.edges(rootId)).thenReturn(List.of(edge("1",null,"PER_UNIT","1",true)));
        FeeInput cycle=new FeeInput("cycle","注塑","PER_CYCLE","PROCESS",edgeId.toString(),"10","25",List.of(),"MANUAL",null);
        Calculation result=calculator.calculate(input("26",List.of(),List.of(cycle)));
        assertThat(result.fees().getFirst().amount()).isEqualTo("20");assertThat(result.fees().getFirst().valueState()).isEqualTo("KNOWN");
        for(String invalid:List.of("0","-1"))assertThatThrownBy(()->calculator.calculate(input("26",List.of(),List.of(
                new FeeInput("cycle","注塑","PER_CYCLE","PROCESS",null,"10",invalid,List.of(),"MANUAL",null)))))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class).hasMessageContaining("费用");
    }
    @Test void dynamicCycleColumnAlsoRequiresExplicitCycleOutput() {
        when(sources.edges(rootId)).thenReturn(List.of(edge("1",null,"PER_UNIT","1",true)));
        DraftInput basic=input("26",List.of(),List.of());
        DraftInput input=new DraftInput(basic.goodsId(),null,basic.name(),basic.batchQty(),null,"1",basic.effectiveDate(),basic.usageStrategy(),basic.priceStrategy(),null,
                List.of(),List.of(),List.of(new PriceColumn("cycle","注塑","PER_CYCLE","PROCESS",List.of())),
                List.of(new PriceCell(edgeId.toString(),"cycle","10",null,"待填出模量")),Map.of(),null);
        Calculation result=calculator.calculate(input);
        assertThat(result.fees().getFirst().amount()).isNull();assertThat(result.totals().valueState()).isEqualTo("INCOMPLETE");
    }
    @Test void automaticBuyPrefersApprovedPriceAndOnlyThenUsesReliableInventoryReference() {
        when(sources.edges(rootId)).thenReturn(List.of(edge("1",null,"PER_UNIT","1",true)));
        DraftInput auto=withStrategy(input("1",List.of(),List.of()),"AUTO");
        assertThat(calculator.calculate(auto).lines().getFirst().priceEvidence().sourceType()).isEqualTo("APPROVED_PURCHASE");
        verify(sources,never()).inventory(any(),any());
        when(sources.approved(eq(material),eq(false),any(),isNull())).thenReturn(null);
        PriceEvidence pool=new PriceEvidence("INVENTORY_REFERENCE",materialId,null,null,"head:1","FINAL_REFERENCE",null,null,"本币",unitId,"kg","1","3","1",null,"AS_RECORDED",auto.effectiveDate(),"已核定库存参考");
        when(sources.inventory(eq(material),any())).thenReturn(pool);
        assertThat(calculator.calculate(auto).totals().knownTotal()).isEqualTo("3");
        clearInvocations(sources);
        assertThat(calculator.calculate(input("1",List.of(),List.of())).lines().getFirst().unitPrice()).isNull();
        verify(sources,never()).inventory(any(),any());
    }
    @Test void automaticSubcontractNeverAddsAWholeItemInventoryValueToSuppliedMaterials() {
        GoodsInfo subcontract=new GoodsInfo(materialId,"S1","委外件",unitId,"个",null,null,"委外","1");
        Edge top=new Edge(edgeId,rootId,subcontract,BigDecimal.ONE,null,BigDecimal.ONE,"NO_DATA",0,null,null,"PER_UNIT",BigDecimal.ONE,true,false,"1");
        when(sources.edges(rootId)).thenReturn(List.of(top));
        Calculation result=calculator.calculate(withStrategy(input("1",List.of(),List.of()),"AUTO"));
        assertThat(result.lines().getFirst().route()).isEqualTo("SUBCONTRACT");
        assertThat(result.lines().getFirst().unitPrice()).isNull();
        verify(sources,never()).inventory(any(),any());
    }
    @Test void makeWithoutBomRemainsVisibleAsMissingBasisAndNeverUsesAPurchasePrice() {
        when(sources.edges(rootId)).thenReturn(List.of());
        Calculation result=calculator.calculate(withStrategy(input("1",List.of(),List.of()),"AUTO"));
        assertThat(result.lines()).hasSize(1);assertThat(result.lines().getFirst().route()).isEqualTo("MAKE");
        assertThat(result.totals().valueState()).isEqualTo("INCOMPLETE");
        assertThat(result.issues()).anyMatch(issue->issue.code().equals("MISSING_MAKE_BASIS"));
        verify(sources,never()).approved(any(),anyBoolean(),any(),any());verify(sources,never()).inventory(any(),any());
    }
    @Test void boundedPriceSearchLeavesTheMaterialTableVisibleWithoutClaimingNoPriceExists() {
        when(sources.edges(rootId)).thenReturn(List.of(edge("1",null,"PER_UNIT","1",true)));
        when(sources.approved(eq(material),eq(false),any(),isNull())).thenThrow(new GoodsCostSourceReader.PriceSearchIncomplete("尚未查完"));
        Calculation result=calculator.calculate(withStrategy(input("1",List.of(),List.of()),"AUTO"));
        assertThat(result.lines()).hasSize(1);assertThat(result.lines().getFirst().amount()).isNull();
        assertThat(result.totals().valueState()).isEqualTo("INCOMPLETE");
        assertThat(result.issues()).anyMatch(issue->issue.code().equals("PRICE_SEARCH_INCOMPLETE"));
        assertThat(result.issues()).noneMatch(issue->issue.code().equals("MISSING_PRICE"));
        verify(sources,never()).inventory(any(),any());
    }
    private DraftInput withStrategy(DraftInput in,String strategy){return new DraftInput(in.goodsId(),in.clientId(),in.name(),in.batchQty(),in.currencyId(),in.exchangeRateToLocal(),in.effectiveDate(),
            in.usageStrategy(),strategy,in.templateId(),in.lineOverrides(),in.fees(),in.priceColumns(),in.priceCells(),in.extraFields(),in.notes());}
    private PriceEvidence recorded(String version) {
        PriceEvidence p=price("400","25","1");
        return new PriceEvidence(p.sourceType(),p.sourceId(),p.sourceItemId(),p.sourceNumber(),version,p.approvalState(),p.supplierId(),p.currencyId(),p.currencyName(),
                p.unitId(),p.unitName(),p.unitRate(),p.originalUnitPrice(),p.exchangeRateToLocal(),p.taxRate(),"AS_RECORDED",p.sourceDate(),null);
    }
    private DraftInput input(String batch,List<LineOverride> overrides,List<FeeInput> fees) {
        return new DraftInput(rootId,null,"成本",batch,null,"1",LocalDate.of(2026,9,29),"ACTUAL_FIRST","APPROVED_PURCHASE",null,
                overrides,fees,List.of(),List.of(),Map.of(),null);
    }
    private Edge edge(String design,String actual,String basis,String base,boolean partial) {
        return new Edge(edgeId,rootId,material,new BigDecimal(design),actual==null?null:new BigDecimal(actual),
                new BigDecimal(actual==null?design:actual),actual==null?"NO_DATA":"ACTUAL",actual==null?0:3,
                null,null,basis,new BigDecimal(base),partial,false,"1");
    }
    private PriceEvidence price(String amount,String rate,String fx) {
        return new PriceEvidence("APPROVED_PURCHASE",materialId,edgeId,"PO-1","1","APPROVED",null,null,"本币",unitId,"袋",rate,amount,fx,"13","AS_RECORDED",LocalDate.of(2026,9,28),null);
    }
    private FeeInput fee(String key,String type,String value,List<String> bases) {
        return new FeeInput(key,key,type,"MANAGEMENT",null,value,null,bases,"MANUAL","内部成本分摊");
    }
}
