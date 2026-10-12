package com.uten.imp.features.production;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.plan.*;
import com.uten.imp.features.production.plan.dto.*;
import com.uten.imp.features.production.dailyreport.*;
import com.uten.imp.features.production.dailyreport.dto.*;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

class ProductionReviewedInputGuardTest {
    @Test void planKeepsMaximumDecimalAndQuantityUnitAndSourceIdentity(){
        var header=plan();var before=planLine("10");var request=planRequest(header,before,"99999999999999.1234");
        assertThatCode(()->ProductionReviewedInputGuard.plan(header,List.of(before),request)).doesNotThrowAnyException();
        request.getItems().getFirst().setUnitRate(new BigDecimal("1.000001"));
        assertThatThrownBy(()->ProductionReviewedInputGuard.plan(header,List.of(before),request)).isInstanceOf(ApiException.class).hasMessageContaining("单位");
        assertThat(before.getQty()).isEqualByComparingTo("10");
    }
    @Test void analysisAndSupplementPlanQuantityCanOnlyChangeThroughTheirOriginalSource(){
        for(boolean analysis:List.of(true,false)){
            var header=plan();if(analysis)header.setMaterialAnalysisId(UUID.randomUUID());else header.setActualOutputSupplementRequestId(UUID.randomUUID());
            var before=planLine("10");var request=planRequest(header,before,"11");
            assertThatThrownBy(()->ProductionReviewedInputGuard.plan(header,List.of(before),request)).isInstanceOf(ApiException.class).hasMessageContaining("冻结计划量");
            request.getItems().getFirst().setQty(BigDecimal.TEN);
            assertThatCode(()->ProductionReviewedInputGuard.plan(header,List.of(before),request)).doesNotThrowAnyException();
        }
    }
    @Test void reviewedDailyInputGroupCanResizeItsOriginalWarehouseSlicesButCannotRetargetPlan(){
        var header=daily();var first=dailyLine("4");var second=dailyLine("2");second.setOutputBatchId(first.getOutputBatchId());
        second.setGoodsId(first.getGoodsId());second.setPlanItemId(first.getPlanItemId());
        var request=dailyRequest(header,first,"7");
        assertThatCode(()->ProductionReviewedInputGuard.daily(header,List.of(first,second),request)).doesNotThrowAnyException();
        request.getItems().getFirst().setPlanItemId(UUID.randomUUID());
        assertThatThrownBy(()->ProductionReviewedInputGuard.daily(header,List.of(first,second),request)).isInstanceOf(ApiException.class).hasMessageContaining("计划");
    }
    @Test void dailyCannotMoveOutputToANewReceivingDemandOrAlterFixedAuthorizedBatch(){
        var header=daily();var first=dailyLine("4");var request=dailyRequest(header,first,"4");
        request.getItems().getFirst().setAllocations(List.of(DailyReportOutputAllocationLine.direct(UUID.randomUUID(),new BigDecimal("4"))));
        assertThatThrownBy(()->ProductionReviewedInputGuard.daily(header,List.of(first),request)).isInstanceOf(ApiException.class).hasMessageContaining("接收工单");
        request.getItems().getFirst().setAllocations(null);
        UUID proof=UUID.randomUUID();first.setSupplementProofId(proof);request.getItems().getFirst().setSupplementProofId(proof);request.getItems().getFirst().setQty(new BigDecimal("5"));
        assertThatThrownBy(()->ProductionReviewedInputGuard.daily(header,List.of(first),request)).isInstanceOf(ApiException.class).hasMessageContaining("授权数量");
    }
    @Test void fiveDecimalAndOverflowQuantitiesAreRejectedBeforeMutatingEitherDocument(){
        for(String bad:List.of("0","-1","1.00005","100000000000000")){
            var header=plan();var before=planLine("10");var request=planRequest(header,before,bad);
            assertThatThrownBy(()->ProductionReviewedInputGuard.plan(header,List.of(before),request)).isInstanceOf(ApiException.class).hasMessageContaining("4 位小数");
            var report=daily();var item=dailyLine("4");var input=dailyRequest(report,item,bad);
            assertThatThrownBy(()->ProductionReviewedInputGuard.daily(report,List.of(item),input)).isInstanceOf(ApiException.class).hasMessageContaining("4 位小数");
        }
    }
    @Test void missingOutputRouteIsRejectedAsBusinessInputInsteadOfANullPointer(){
        var header=daily();var first=dailyLine("4");var request=dailyRequest(header,first,"4");
        request.getItems().getFirst().setAllocations(Arrays.asList((DailyReportOutputAllocationLine)null));
        assertThatThrownBy(()->ProductionReviewedInputGuard.daily(header,List.of(first),request)).isInstanceOf(ApiException.class).hasMessageContaining("去向不能为空");
    }
    @Test void extensionVersionCannotBeBorrowedFromAnotherSameDocumentLine(){
        var h=plan();var item=planLine("10");var request=planRequest(h,item,"11");
        request.getItems().getFirst().setPlatformFields(new com.uten.imp.common.platformcolumns.PlatformColumnLineInput.Fields(UUID.randomUUID(),1,List.of()));
        assertThatThrownBy(()->ProductionReviewedInputGuard.plan(h,List.of(item),request)).isInstanceOf(ApiException.class).hasMessageContaining("本条原计划行");
        var report=daily();var output=dailyLine("4");var daily=dailyRequest(report,output,"4");
        daily.getItems().getFirst().setPlatformFields(new com.uten.imp.common.platformcolumns.PlatformColumnLineInput.Fields(UUID.randomUUID(),1,List.of()));
        assertThatThrownBy(()->ProductionReviewedInputGuard.daily(report,List.of(output),daily)).isInstanceOf(ApiException.class).hasMessageContaining("原报工批次");
    }
    private ProductionPlan plan(){var h=new ProductionPlan();h.setBillDate(LocalDate.of(2026,10,11));return h;}
    private ProductionPlanItem planLine(String qty){var l=new ProductionPlanItem();l.setId(UUID.randomUUID());l.setGoodsId(UUID.randomUUID());l.setUnitRate(BigDecimal.ONE);l.setQty(new BigDecimal(qty));return l;}
    private PlanSaveRequest planRequest(ProductionPlan h,ProductionPlanItem before,String qty){var r=new PlanSaveRequest();r.setBillDate(h.getBillDate());var l=new PlanItemLine();l.setSourceItemId(before.getId());l.setGoodsId(before.getGoodsId());l.setUnitRate(before.getUnitRate());l.setQty(new BigDecimal(qty));r.setItems(List.of(l));return r;}
    private ProductionDailyReport daily(){var h=new ProductionDailyReport();h.setBillDate(LocalDate.of(2026,10,11));return h;}
    private ProductionDailyReportItem dailyLine(String qty){var l=new ProductionDailyReportItem();l.setId(UUID.randomUUID());l.setOutputBatchId(UUID.randomUUID());l.setGoodsId(UUID.randomUUID());l.setPlanItemId(UUID.randomUUID());l.setUnitRate(BigDecimal.ONE);l.setQty(new BigDecimal(qty));return l;}
    private DailyReportSaveRequest dailyRequest(ProductionDailyReport h,ProductionDailyReportItem before,String qty){var r=new DailyReportSaveRequest();r.setBillDate(h.getBillDate());var l=new DailyReportItemLine();l.setReviewSourceItemId(before.getId());l.setGoodsId(before.getGoodsId());l.setUnitRate(before.getUnitRate());l.setPlanItemId(before.getPlanItemId());l.setQty(new BigDecimal(qty));r.setItems(List.of(l));return r;}
}
