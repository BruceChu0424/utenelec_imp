package com.uten.imp.features.master.goods.costing;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.MasterReferenceValidationPort;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static com.uten.imp.features.master.goods.costing.GoodsCostContracts.*;
import static com.uten.imp.features.master.goods.costing.GoodsCostSourceReader.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Repeated BOM paths retain their own business facts while sharing one read snapshot. */
class GoodsCostSourceDeduplicationTest {
    private final GoodsCostSourceReader sources=mock(GoodsCostSourceReader.class);
    private final MasterReferenceValidationPort references=mock(MasterReferenceValidationPort.class);
    private final GoodsCostCalculator calculator=new GoodsCostCalculator(sources,references,
            new GoodsCostJson(new ObjectMapper().findAndRegisterModules()));
    private final UUID rootId=UUID.randomUUID(),materialId=UUID.randomUUID(),unitId=UUID.randomUUID();
    private final UUID sourceItem=UUID.randomUUID();
    private final LocalDate date=LocalDate.of(2026,10,26);
    private final GoodsInfo root=new GoodsInfo(rootId,"P","产品",unitId,"个",null,null,"自制","1");
    private final GoodsInfo material=new GoodsInfo(materialId,"M","材料",unitId,"个",null,null,"采购","1");

    @BeforeEach void defaults() {
        when(sources.goods(rootId)).thenReturn(root);
        when(sources.currency(null)).thenReturn("本币");
        when(sources.edges(materialId)).thenReturn(List.of());
        when(sources.approved(any(),anyBoolean(),any(),nullable(UUID.class)))
                .thenAnswer(call->price(call.getArgument(0),"10","APPROVED_PURCHASE"));
    }

    @Test void sharedMaterialReadsOnceWhileEachPathKeepsItsOwnQuantityAndAmount() {
        Paths paths=shared(material,material);
        LineOverride quantity=new LineOverride(paths.second(),"3",null,null,null,null,null,null,null,null,"经确认的用量");
        Calculation result=calculator.calculate(input("APPROVED_PURCHASE",date,List.of(quantity)));
        assertThat(line(result,paths.first()).amount()).isEqualTo("10");
        assertThat(line(result,paths.second()).batchQty()).isEqualTo("6");
        assertThat(line(result,paths.second()).amount()).isEqualTo("60");
        assertThat(result.totals().knownTotal()).isEqualTo("70");
        verify(references,times(1)).requireVisibleGoods(materialId);
        verify(sources,times(1)).edges(materialId);
        verify(sources,times(1)).approved(material,false,date,null);
    }

    @Test void sharedMissingApprovedAndInventoryPricesAreReadOnceAndRemainMissingPerPath() {
        Paths paths=shared(material,material);
        when(sources.approved(material,false,date,null)).thenReturn(null);
        when(sources.inventory(material,date)).thenReturn(null);
        Calculation result=calculator.calculate(input("AUTO",date,List.of()));
        assertThat(line(result,paths.first()).amount()).isNull();
        assertThat(line(result,paths.second()).amount()).isNull();
        assertThat(result.totals().missingPriceCount()).isEqualTo(2);
        assertThat(result.issues()).filteredOn(issue->issue.code().equals("MISSING_PRICE")).hasSize(2);
        verify(sources,times(1)).approved(material,false,date,null);
        verify(sources,times(1)).inventory(material,date);
    }

    @Test void inventoryReferenceIsSharedWithoutRepeatingAuthorityReadsForEachPath() {
        Paths paths=shared(material,material);
        when(sources.inventory(material,date)).thenReturn(price(material,"4","INVENTORY_REFERENCE"));
        Calculation result=calculator.calculate(input("INVENTORY",date,List.of()));
        assertThat(line(result,paths.first()).amount()).isEqualTo("4");
        assertThat(line(result,paths.second()).amount()).isEqualTo("8");
        verify(sources,times(1)).inventory(material,date);
        verify(sources,never()).approved(any(),anyBoolean(),any(),nullable(UUID.class));
    }

    @ParameterizedTest
    @ValueSource(strings={"COLOR","UNIT","REVISION"})
    void distinctGoodsEvidenceParametersCannotShareApprovedPrice(String dimension) {
        GoodsInfo other=variation(dimension);
        Paths paths=shared(material,other);
        when(sources.approved(other,false,date,null)).thenReturn(price(other,"7","APPROVED_PURCHASE"));
        Calculation result=calculator.calculate(input("APPROVED_PURCHASE",date,List.of()));
        assertThat(line(result,paths.first()).amount()).isEqualTo("10");
        assertThat(line(result,paths.second()).amount()).isEqualTo("14");
        verify(sources,times(1)).approved(material,false,date,null);
        verify(sources,times(1)).approved(other,false,date,null);
        verify(references,times(1)).requireVisibleGoods(materialId);
    }

    @ParameterizedTest
    @ValueSource(strings={"COLOR","UNIT"})
    void distinctInventoryEvidenceParametersCannotShareAuthority(String dimension) {
        GoodsInfo other=variation(dimension);
        Paths paths=shared(material,other);
        when(sources.inventory(material,date)).thenReturn(price(material,"4","INVENTORY_REFERENCE"));
        when(sources.inventory(other,date)).thenReturn(price(other,"7","INVENTORY_REFERENCE"));
        Calculation result=calculator.calculate(input("INVENTORY",date,List.of()));
        assertThat(line(result,paths.first()).amount()).isEqualTo("4");
        assertThat(line(result,paths.second()).amount()).isEqualTo("14");
        verify(sources,times(1)).inventory(material,date);
        verify(sources,times(1)).inventory(other,date);
    }

    @Test void purchaseAndSubcontractQueriesRemainIndependentForTheSameMaterial() {
        Paths paths=shared(material,material);
        when(sources.approved(material,true,date,null)).thenReturn(price(material,"7","APPROVED_SUBCONTRACT"));
        Calculation result=calculator.calculate(input("APPROVED_PURCHASE",date,
                List.of(override(paths.second(),"SUBCONTRACT",null))));
        assertThat(line(result,paths.first()).route()).isEqualTo("BUY");
        assertThat(line(result,paths.second()).route()).isEqualTo("SUBCONTRACT");
        assertThat(line(result,paths.second()).amount()).isEqualTo("14");
        verify(sources,times(1)).approved(material,false,date,null);
        verify(sources,times(1)).approved(material,true,date,null);
    }

    @Test void explicitSourceItemsRemainIndependentForTheSameMaterial() {
        Paths paths=shared(material,material);
        UUID otherItem=UUID.randomUUID();
        when(sources.approved(material,false,date,sourceItem)).thenReturn(price(material,"3","APPROVED_PURCHASE"));
        when(sources.approved(material,false,date,otherItem)).thenReturn(price(material,"7","APPROVED_PURCHASE"));
        Calculation result=calculator.calculate(input("APPROVED_PURCHASE",date,List.of(
                override(paths.first(),null,sourceItem),override(paths.second(),null,otherItem))));
        assertThat(line(result,paths.first()).amount()).isEqualTo("3");
        assertThat(line(result,paths.second()).amount()).isEqualTo("14");
        verify(sources,times(1)).approved(material,false,date,sourceItem);
        verify(sources,times(1)).approved(material,false,date,otherItem);
    }

    @Test void sharedRawApprovedEvidenceStillAppliesTaxAcknowledgementPerPath() {
        Paths paths=shared(material,material);
        LineOverride tax=new LineOverride(paths.second(),null,null,null,null,null,null,
                "EXCLUDE_TAX",sourceItem,"APPROVED_PURCHASE","此路径确认原价含税","1");
        Calculation result=calculator.calculate(input("APPROVED_PURCHASE",date,List.of(tax)));
        assertThat(line(result,paths.first()).priceEvidence().taxMode()).isEqualTo("AS_RECORDED");
        assertThat(line(result,paths.second()).priceEvidence().taxMode()).isEqualTo("EXCLUDE_TAX");
        assertThat(new BigDecimal(line(result,paths.second()).unitPrice())).isLessThan(new BigDecimal("10"));
        verify(sources,times(1)).approved(material,false,date,null);
    }

    @Test void incompleteApprovedSearchIsNotCachedAsAMissingPriceOrSuccessfulEvidence() {
        Paths paths=shared(material,material);
        when(sources.approved(material,false,date,null))
                .thenThrow(new PriceSearchIncomplete("本次未查完"))
                .thenReturn(price(material,"7","APPROVED_PURCHASE"));
        Calculation result=calculator.calculate(input("AUTO",date,List.of()));
        assertThat(line(result,paths.first()).amount()).isNull();
        assertThat(line(result,paths.second()).amount()).isEqualTo("14");
        assertThat(result.issues()).filteredOn(issue->issue.code().equals("PRICE_SEARCH_INCOMPLETE")).hasSize(1);
        verify(sources,times(2)).approved(material,false,date,null);
        verify(sources,never()).inventory(any(),any());
    }

    @Test void incompleteInventoryAuthorityIsNotCachedAndApprovedMissIsStillShared() {
        Paths paths=shared(material,material);
        when(sources.approved(material,false,date,null)).thenReturn(null);
        when(sources.inventory(material,date))
                .thenThrow(new PriceSearchIncomplete("本次库存依据未查完"))
                .thenReturn(price(material,"7","INVENTORY_REFERENCE"));
        Calculation result=calculator.calculate(input("AUTO",date,List.of()));
        assertThat(line(result,paths.first()).amount()).isNull();
        assertThat(line(result,paths.second()).amount()).isEqualTo("14");
        verify(sources,times(1)).approved(material,false,date,null);
        verify(sources,times(2)).inventory(material,date);
    }

    @Test void independentCalculationsReadCurrentVisibilityPriceAndDateAgain() {
        shared(material,material);
        DraftInput initial=input("AUTO",date,List.of());
        when(sources.approved(material,false,date,null)).thenReturn(null);
        assertThat(calculator.calculate(initial).totals().unitCost()).isNull();
        when(sources.approved(material,false,date,null)).thenReturn(price(material,"7","APPROVED_PURCHASE"));
        assertThat(calculator.calculate(initial).totals().knownTotal()).isEqualTo("21");
        LocalDate next=date.plusDays(1);
        when(sources.approved(material,false,next,null)).thenReturn(price(material,"9","APPROVED_PURCHASE"));
        assertThat(calculator.calculate(input("AUTO",next,List.of())).totals().knownTotal()).isEqualTo("27");
        verify(references,times(3)).requireVisibleGoods(materialId);
        verify(sources,times(2)).approved(material,false,date,null);
        verify(sources,times(1)).approved(material,false,next,null);
        verify(sources,times(1)).inventory(material,date);
    }

    @Test void aFailedVisibilityCheckDoesNotPoisonTheNextCalculation() {
        shared(material,material);
        doThrow(new IllegalStateException("拒绝访问")).doNothing().when(references).requireVisibleGoods(materialId);
        assertThatThrownBy(()->calculator.calculate(input("AUTO",date,List.of())))
                .hasMessage("拒绝访问");
        assertThat(calculator.calculate(input("AUTO",date,List.of())).totals().knownTotal()).isEqualTo("30");
        verify(references,times(2)).requireVisibleGoods(materialId);
        verify(sources,times(1)).approved(material,false,date,null);
    }

    private GoodsInfo variation(String dimension) {
        return new GoodsInfo(materialId,material.code(),material.name(),
                "UNIT".equals(dimension)?UUID.randomUUID():unitId,material.unitName(),
                "COLOR".equals(dimension)?UUID.randomUUID():null,
                "COLOR".equals(dimension)?"蓝色":null,material.sourceType(),"REVISION".equals(dimension)?"2":"1");
    }
    private record Paths(String first,String second) {}
    private Paths shared(GoodsInfo first,GoodsInfo second) {
        UUID assemblyA=UUID.randomUUID(),assemblyB=UUID.randomUUID(),topA=UUID.randomUUID(),topB=UUID.randomUUID();
        UUID leafA=UUID.randomUUID(),leafB=UUID.randomUUID();
        GoodsInfo a=new GoodsInfo(assemblyA,"A","组件甲",unitId,"个",null,null,"自制","1");
        GoodsInfo b=new GoodsInfo(assemblyB,"B","组件乙",unitId,"个",null,null,"自制","1");
        when(sources.edges(rootId)).thenReturn(List.of(edge(topA,rootId,a,"1"),edge(topB,rootId,b,"2")));
        when(sources.edges(assemblyA)).thenReturn(List.of(edge(leafA,assemblyA,first,"1")));
        when(sources.edges(assemblyB)).thenReturn(List.of(edge(leafB,assemblyB,second,"1")));
        return new Paths(topA+"/"+leafA,topB+"/"+leafB);
    }
    private Edge edge(UUID id,UUID parent,GoodsInfo goods,String qty) {
        return new Edge(id,parent,goods,new BigDecimal(qty),null,new BigDecimal(qty),"NO_DATA",0,
                null,null,"PER_UNIT",BigDecimal.ONE,true,false,"1");
    }
    private DraftInput input(String strategy,LocalDate effectiveDate,List<LineOverride> overrides) {
        return new DraftInput(rootId,null,"成本","1",null,"1",effectiveDate,"DESIGN",strategy,null,
                overrides,List.of(),List.of(),List.of(),Map.of(),null);
    }
    private LineOverride override(String path,String route,UUID item) {
        return new LineOverride(path,null,route,null,null,null,null,null,item,
                item==null?null:"APPROVED_PURCHASE_PINNED","经确认的路径依据");
    }
    private CostLine line(Calculation calculation,String path) {
        return calculation.lines().stream().filter(line->line.path().equals(path)).findFirst().orElseThrow();
    }
    private PriceEvidence price(GoodsInfo goods,String value,String type) {
        return new PriceEvidence(type,materialId,sourceItem,"PO-1","1","APPROVED",null,null,"本币",
                goods.unitId(),goods.unitName(),"1",value,"1","10","AS_RECORDED",date,"原始依据");
    }
}
