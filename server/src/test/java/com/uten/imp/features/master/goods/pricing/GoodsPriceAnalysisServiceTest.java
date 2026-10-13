package com.uten.imp.features.master.goods.pricing;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.master.goods.costing.GoodsCostCalculator;
import com.uten.imp.features.master.goods.costing.GoodsCostContracts;
import com.uten.imp.features.master.goods.costing.GoodsCostSheetService;
import com.uten.imp.security.OwnerVisibility;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import java.util.*;
import static com.uten.imp.features.master.goods.pricing.GoodsPriceContracts.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class GoodsPriceAnalysisServiceTest {
    private final UUID goods=UUID.randomUUID(),unit=UUID.randomUUID(),currency=UUID.randomUUID(),supplier=UUID.randomUUID(),snapshotId=UUID.randomUUID();
    private GoodsPriceAccess access;private GoodsPriceSourceReader sources;private GoodsCostSheetService costs;private GoodsPriceAnalysisService service;
    private MasterReferenceValidationPort references;
    private GoodsCostContracts.Calculation calculation;
    private Context context;
    @BeforeEach void setup(){
        access=mock(GoodsPriceAccess.class);sources=mock(GoodsPriceSourceReader.class);costs=mock(GoodsCostSheetService.class);
        references=mock(MasterReferenceValidationPort.class);
        service=new GoodsPriceAnalysisService(access,references,sources,costs,mock(NamedParameterJdbcTemplate.class));
        when(access.sourceScope(any())).thenReturn(new OwnerVisibility.OwnerScope(true,Set.of()));when(access.has("goods:cost:view")).thenReturn(true);
        when(sources.goods(goods)).thenReturn(new GoodsPriceSourceReader.Goods(goods,"P","Product",unit,null));
        context=new Context(null,null,null,unit,"件",currency,"CNY","0",null,180,"AS_RECORDED","APPROVED_ORDER_TERMS","CHARGED_LINE_QUANTITY","1",null);
        when(sources.read(any(),any(),anyInt(),any())).thenReturn(new GoodsPriceSourceReader.Data(context,List.of(),true));
        var snapshot=mock(GoodsCostContracts.Snapshot.class);var input=mock(GoodsCostContracts.DraftInput.class);calculation=mock(GoodsCostContracts.Calculation.class);var totals=mock(GoodsCostContracts.Totals.class);
        when(costs.readSnapshot(snapshotId)).thenReturn(snapshot);when(snapshot.kind()).thenReturn("CONFIRMED");when(snapshot.input()).thenReturn(input);when(input.goodsId()).thenReturn(goods);when(input.batchQty()).thenReturn("100");
        when(snapshot.contentDigest()).thenReturn("immutable-cost");when(snapshot.calculation()).thenReturn(calculation);when(calculation.totals()).thenReturn(totals);
        when(calculation.algorithmVersion()).thenReturn(GoodsCostCalculator.ALGORITHM);when(calculation.currencyId()).thenReturn(currency);when(calculation.currencyName()).thenReturn("CNY");when(calculation.unitId()).thenReturn(unit);when(calculation.unitName()).thenReturn("件");
        when(totals.valueState()).thenReturn("COMPLETE");when(totals.unitCost()).thenReturn("70");when(totals.byCategory()).thenReturn(Map.of("MATERIAL","50","PROCESS","20"));
    }
    @Test void oldConfirmedCostAlgorithmCannotReintroduceWrongFxIntoNewQuote(){
        when(calculation.algorithmVersion()).thenReturn("GOODS_COST_V2");
        CostSummary cost=service.analysis(sales("100")).costSummary();
        assertThat(cost.suggestedPrice()).isNull();assertThat(cost.missingCostComponents()).contains("COST_VERSION_REVIEW_REQUIRED");assertThat(cost.unitCost()).isEqualTo("70");
    }
    @Test void currentConfirmedEstimateQuotesByMarginAndRetainsItsOwnCurrencyAndVersion(){
        CostSummary cost=service.analysis(sales("100")).costSummary();
        assertThat(cost.suggestedPrice()).isEqualTo("87.5");assertThat(cost.basis()).isEqualTo("CONFIRMED_ESTIMATE");assertThat(cost.actualFullCostComplete()).isFalse();
        assertThat(cost.snapshotId()).isEqualTo(snapshotId);assertThat(cost.currencyName()).isEqualTo("CNY");
    }
    @Test void differentBatchDoesNotLinearlyConvertFixedFees(){
        CostSummary cost=service.analysis(sales("200")).costSummary();assertThat(cost.suggestedPrice()).isNull();assertThat(cost.missingCostComponents()).contains("COST_BATCH_MISMATCH");
    }
    @Test void omittedRequestCurrencyStillUsesResolvedComparisonContext(){
        var usd=new Context(null,null,null,unit,"件",UUID.randomUUID(),"USD","0",null,180,"AS_RECORDED","APPROVED_ORDER_TERMS","CHARGED_LINE_QUANTITY","1",null);
        when(sources.read(any(),any(),anyInt(),any())).thenReturn(new GoodsPriceSourceReader.Data(usd,List.of(),true));
        CostSummary cost=service.analysis(sales("100")).costSummary();assertThat(cost.suggestedPrice()).isNull();assertThat(cost.missingCostComponents()).contains("COST_CURRENCY_MISMATCH");assertThat(cost.currencyName()).isEqualTo("CNY");
    }
    @Test void zeroChargeGiftRowDoesNotDisableOtherRowsAndCurrentOrderIsExcluded(){
        ready();UUID currentOrder=UUID.randomUUID();
        var result=service.check(new CheckRequest(Kind.PURCHASE,180,currentOrder,List.of(item("gift","0","0"),item("charged","100","50"))));
        assertThat(result.rows().getFirst().reasonCodes()).contains("NO_CHARGED_QUANTITY");assertThat(result.rows().get(1).severity()).isEqualTo("WARNING");
        assertThat(result.rows().get(1).currencyName()).isEqualTo("CNY");assertThat(result.rows().get(1).unitName()).isEqualTo("件");
        verify(sources,atLeastOnce()).read(argThat(q->currentOrder.equals(q.excludeOrderId())),any(),eq(180),any());
    }
    @Test void clientClaimOfNoOperationOnAnExtraColumnCannotSuppressFeeUncertainty(){
        var item=new CheckItem("x",goods,supplier,null,unit,currency,"0","1","10",null,List.of(Map.of("operation","NONE","value",999)),"1",null);
        assertThat(service.check(new CheckRequest(Kind.PURCHASE,180,null,List.of(item))).rows().getFirst().reasonCodes()).contains("UNDIVIDED_PRICE_COMPONENTS");
        verify(sources,never()).read(any(),any(),anyInt(),any());
    }
    @Test void quotePagePermissionAloneCannotReadFinanceQuoteHistory(){
        when(access.has("sales_quote:view")).thenReturn(true);var request=new HistoryQuery(sales("100"),null,null,null,50);
        service.history(request);verify(sources).history(eq(request),any(),eq(false),eq(false));
    }
    @Test void detailRequiresCurrentGoodsAccessBeforeReadingAnySource() {
        var query=new DetailQuery(Kind.PURCHASE,"PURCHASE_ORDER",UUID.randomUUID(),UUID.randomUUID(),null,"a".repeat(64));
        doThrow(new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.NOT_FOUND,"货品不可访问"))
                .when(references).requireVisibleGoods(goods);
        assertThatThrownBy(()->service.detail(goods,query)).hasMessageContaining("货品不可访问");
        verify(access).requireHistory(Kind.PURCHASE);verify(sources,never()).detail(any(),any(),any(),anyBoolean(),anyBoolean());
    }
    @Test void detailKeepsExactAmountsAndUnknownHistoricalLabelsInItsLimitedFieldProjection() {
        ObjectMapper mapper=new ObjectMapper().findAndRegisterModules();Map<String,Object> facts=new HashMap<>();
        facts.put("sourceType","PURCHASE_ORDER_APPROVAL");facts.put("sourceId",UUID.randomUUID());facts.put("sourceItemId",UUID.randomUUID());
        facts.put("sourceRevision","a".repeat(64));facts.put("historyVersionId",UUID.randomUUID());facts.put("lifecycle","SUPERSEDED_APPROVED_VERSION");
        facts.put("quantity","3");facts.put("unitPrice","0.6666666666666666666666666666666667");facts.put("amount","2");
        facts.put("reasonCodes",List.of("HISTORICAL_VERSION_ONLY","SOURCE_IDENTITY_INCOMPLETE"));
        Observation row=mapper.convertValue(facts,Observation.class);
        var query=new DetailQuery(Kind.PURCHASE,row.sourceType(),row.sourceId(),row.sourceItemId(),row.historyVersionId(),row.sourceRevision());
        when(sources.detail(eq(goods),eq(query),any(),eq(false),eq(false))).thenReturn(row);
        Detail detail=service.detail(goods,query);
        assertThat(detail.observation()).isEqualTo(row);assertThat(detail.reasonCodes()).contains("SOURCE_IDENTITY_INCOMPLETE");
        assertThat(detail.fields()).filteredOn(f->f.key().equals("unitPrice")).singleElement().extracting(DetailField::value).isEqualTo(row.unitPrice());
        assertThat(detail.fields()).filteredOn(f->f.key().equals("goodsNameSnapshot")).singleElement().extracting(DetailField::value).isNull();
        assertThat(mapper.valueToTree(detail).toString()).doesNotContain("approval_snapshot","submission_snapshot","finance_total_local");
    }
    @Test void detailCannotUseAnUnversionedHistoricalSourceOrMalformedRevision() {
        for(var query:List.of(
                new DetailQuery(Kind.PURCHASE,"PURCHASE_ORDER_APPROVAL",UUID.randomUUID(),UUID.randomUUID(),null,"a".repeat(64)),
                new DetailQuery(Kind.PURCHASE,"SALES_QUOTE_CONFIRMED",UUID.randomUUID(),UUID.randomUUID(),UUID.randomUUID(),"a".repeat(64)),
                new DetailQuery(Kind.PURCHASE,"PURCHASE_ORDER",UUID.randomUUID(),UUID.randomUUID(),null,"invalid")))
            assertThatThrownBy(()->service.detail(goods,query)).hasMessageContaining("重新加载");
        verifyNoInteractions(sources);
    }
    @Test void stableEvidenceIgnoresReadTimeButDetectsSourceVersionChanges(){
        ready();Query q=new Query(goods,Kind.PURCHASE,180,null,null,unit,currency,"0","100",null,null,null,null,"1");
        String token=service.analysis(q).evidenceToken();service.requireCurrentEvidence(q,token);
        when(sources.read(any(),any(),anyInt(),any())).thenReturn(new GoodsPriceSourceReader.Data(context,List.of(),true));
        assertThatThrownBy(()->service.requireCurrentEvidence(q,token)).hasMessageContaining("依据已变化");
    }
    private Query sales(String qty){return new Query(goods,Kind.SALES,180,null,null,null,null,null,qty,null,null,snapshotId,"0.20",null);}
    private CheckItem item(String row,String qty,String price){return new CheckItem(row,goods,supplier,null,unit,currency,"0",qty,price,null,List.of(),"1",null);}
    @Test void positiveGiftQuantityDoesNotBecomeANormalPaidPrice(){
        ready();var item=new CheckItem("paid-plus-gift",goods,supplier,null,unit,currency,"0","100","10",null,List.of(),"1","20");
        var row=service.check(new CheckRequest(Kind.PURCHASE,180,null,List.of(item))).rows().getFirst();
        assertThat(row.severity()).isEqualTo("INSUFFICIENT");assertThat(row.reasonCodes()).contains("GIFT_COMPONENT");verify(sources,never()).read(any(),any(),anyInt(),any());
    }
    @Test void differentQuantitiesReuseRawSourcesButKeepIndependentStatisticsAndEvidence(){
        ready();
        var result=service.check(new CheckRequest(Kind.PURCHASE,180,null,List.of(item("normal","100","10"),item("different-batch","100000","10"))));
        assertThat(result.rows().getFirst().status()).isEqualTo("READY");
        assertThat(result.rows().get(1).status()).isEqualTo("INSUFFICIENT");assertThat(result.rows().get(1).reasonCodes()).contains("QUANTITY_CONTEXT_WEAK");
        assertThat(result.rows().getFirst().evidenceToken()).isNotEqualTo(result.rows().get(1).evidenceToken());
        verify(sources).read(argThat(q->supplier.equals(q.supplierId())&&q.quantity()==null),any(),eq(180),any());
        verify(sources).read(argThat(q->q.supplierId()==null&&q.quantity()==null),any(),eq(180),any());
        verify(sources,times(2)).read(any(),any(),anyInt(),any());verify(sources).goods(goods);verify(references).requireVisibleGoods(goods);
    }
    @Test void responseQuantityAlwaysComesFromItsOwnRequestRatherThanCachedSourceContext(){
        var unrelated=new Context(null,null,null,unit,"件",currency,"CNY","0","777",180,"AS_RECORDED","APPROVED_ORDER_TERMS","CHARGED_LINE_QUANTITY","1",null);
        when(sources.read(any(),any(),anyInt(),any())).thenReturn(new GoodsPriceSourceReader.Data(unrelated,List.of(),true));
        Query first=new Query(goods,Kind.PURCHASE,180,null,null,unit,currency,"0","100",null,null,null,null,"1");
        Query second=new Query(goods,Kind.PURCHASE,180,null,null,unit,currency,"0","200",null,null,null,null,"1");
        assertThat(service.analysis(first).context().quantity()).isEqualTo("100");
        assertThat(service.analysis(second).context().quantity()).isEqualTo("200");
    }
    private void ready(){
        ObjectMapper json=new ObjectMapper().findAndRegisterModules();List<Observation> rows=new ArrayList<>();
        for(int i=0;i<3;i++)rows.add(json.convertValue(Map.of("sourceId",UUID.randomUUID(),"sourceItemId",UUID.randomUUID(),"sourceRevision","v1","businessDate",BusinessTime.today().minusDays(i),"quantity","100","unitPrice","10","amount","1000","comparable",true),Observation.class));
        when(sources.read(any(),any(),anyInt(),any())).thenReturn(new GoodsPriceSourceReader.Data(context,rows,true));
    }
}
