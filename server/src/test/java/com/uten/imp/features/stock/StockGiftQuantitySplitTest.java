package com.uten.imp.features.stock;
import java.math.BigDecimal;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.springframework.test.util.ReflectionTestUtils;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

/** Real production partial-acceptance helpers must conserve the original gift fact. */
class StockGiftQuantitySplitTest {
    private final StockDocService service=mock(StockDocService.class,CALLS_REAL_METHODS);
    record Split(StockDocumentItem accepted,StockDocumentItem residual){}
    private StockDocumentItem item(String qty,String gift){
        var item=new StockDocumentItem();item.setGoodsId(UUID.randomUUID());item.setUnitRate(BigDecimal.ONE);
        item.setQty(new BigDecimal(qty));item.setBaseQty(item.getQty());item.setGiftQty(gift==null?null:new BigDecimal(gift));return item;
    }
    private Split split(StockDocumentItem source,String accepted){
        BigDecimal proposed=source.getQty(),acceptedQty=new BigDecimal(accepted),remaining=proposed.subtract(acceptedQty);
        var document=new StockDocument();document.setBillNo("GIFT-SPLIT");
        StockDocumentItem residual=ReflectionTestUtils.invokeMethod(service,"copyFinishedInboundResidualItem",source,document,remaining);
        ReflectionTestUtils.invokeMethod(service,"applyAcceptedFinishedInboundQuantity",source,acceptedQty,proposed);
        return new Split(source,residual);
    }
    @Test void smallestGiftSplitDoesNotDoubleItsRecordedQuantity(){
        var result=split(item("2","0.0001"),"1");
        assertThat(result.accepted().getGiftQty()).isZero();
        assertThat(result.residual().getGiftQty()).isEqualByComparingTo("0.0001");
        assertThat(result.accepted().getGiftQty().add(result.residual().getGiftQty())).isEqualByComparingTo("0.0001");
    }
    @Test void oddGiftQuantumStaysInTheLastResidual(){
        var result=split(item("2","0.0003"),"1");
        assertThat(result.accepted().getGiftQty()).isEqualByComparingTo("0.0001");
        assertThat(result.residual().getGiftQty()).isEqualByComparingTo("0.0002");
        assertThat(result.accepted().getGiftQty().add(result.residual().getGiftQty())).isEqualByComparingTo("0.0003");
    }
    @Test void repeatedPartialAcceptancePreservesOriginalGiftAcrossEveryGeneration(){
        var first=split(item("3","1.25"),"1");var second=split(first.residual(),"1");
        assertThat(first.accepted().getGiftQty().add(second.accepted().getGiftQty()).add(second.residual().getGiftQty())).isEqualByComparingTo("1.25");
        assertThat(second.residual().getGiftQty()).isEqualByComparingTo("0.4167");
    }
    @Test void unknownZeroAndMaximumStoredFactsKeepTheirExactMeaning(){
        var unknown=split(item("2",null),"1");assertThat(unknown.accepted().getGiftQty()).isNull();assertThat(unknown.residual().getGiftQty()).isNull();
        var zero=split(item("2","0"),"1");assertThat(zero.accepted().getGiftQty()).isZero();assertThat(zero.residual().getGiftQty()).isZero();
        var max=split(item("2","99999999999999.9999"),"1");
        assertThat(max.accepted().getGiftQty().add(max.residual().getGiftQty())).isEqualByComparingTo("99999999999999.9999");
    }
}
