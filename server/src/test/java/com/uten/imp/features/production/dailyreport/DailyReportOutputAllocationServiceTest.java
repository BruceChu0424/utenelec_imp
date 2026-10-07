package com.uten.imp.features.production.dailyreport;

import com.uten.imp.common.validation.RequestLimits;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.dailyreport.dto.DailyReportItemLine;
import com.uten.imp.features.production.dailyreport.dto.DailyReportOutputAllocationLine;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentMatchers;
import org.mockito.Mockito;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.UUID;
import java.util.stream.IntStream;

import static org.junit.jupiter.api.Assertions.*;

class DailyReportOutputAllocationServiceTest {
    private static final UUID A = UUID.fromString("00000000-0000-0000-0000-00000000000a");
    private static final UUID B = UUID.fromString("00000000-0000-0000-0000-00000000000b");
    private static final UUID C = UUID.fromString("00000000-0000-0000-0000-00000000000c");

    @Test void nullAndInvalidQuantityFailBeforeAnyDatabaseAccess() {
        var em=Mockito.mock(EntityManager.class);
        var service=new DailyReportOutputAllocationService(em);
        assertThrows(ApiException.class,()->service.split(UUID.randomUUID(),java.util.Arrays.asList((DailyReportItemLine)null)));
        var invalid=new DailyReportItemLine();invalid.setQty(new BigDecimal("0.00001"));
        assertThrows(ApiException.class,()->service.split(UUID.randomUUID(),List.of(invalid)));
        Mockito.verifyNoInteractions(em);
    }

    @Test void destinationsMustAddUpToTheReportedQuantityBeforeAnyDatabaseAccess() {
        // V736/ADR-127：一行报工的去向由工人逐条分配，合计必须等于实际产量；错了不猜、不补送仓。
        var em=Mockito.mock(EntityManager.class);
        var service=new DailyReportOutputAllocationService(em);
        var mismatch=line("10",DailyReportOutputAllocationLine.direct(A,new BigDecimal("4")),
                DailyReportOutputAllocationLine.warehouse(new BigDecimal("5")));
        var error=assertThrows(ApiException.class,()->service.split(UUID.randomUUID(),List.of(mismatch)));
        assertEquals("产出去向合计 9 与本行实际产量 10 不一致，请重新分配",error.getMessage());
        var zero=line("10",DailyReportOutputAllocationLine.direct(A,BigDecimal.ZERO),
                DailyReportOutputAllocationLine.warehouse(BigDecimal.TEN));
        assertThrows(ApiException.class,()->service.split(UUID.randomUUID(),List.of(zero)));
        var many=new ArrayList<DailyReportOutputAllocationLine>();
        IntStream.rangeClosed(0,RequestLimits.DAILY_REPORT_DIRECT_RECEIVERS)
                .forEach(index->many.add(DailyReportOutputAllocationLine.direct(UUID.randomUUID(),BigDecimal.ONE)));
        var tooMany=line(String.valueOf(many.size()),many.toArray(DailyReportOutputAllocationLine[]::new));
        assertTrue(assertThrows(ApiException.class,()->service.split(UUID.randomUUID(),List.of(tooMany)))
                .getMessage().contains("最多同时转给 "+RequestLimits.DAILY_REPORT_DIRECT_RECEIVERS+" 个上层工单"),
                "超过上限明确报错，不悄悄改成送入仓库");
        Mockito.verifyNoInteractions(em);
    }

    @Test void oneLineIsSplitIntoOnePiecePerReceiverAndAWarehousePieceWithItsReason() {
        // 共享子件报 11000：三个上层工单各 1000(先急后缓由工人确认)，其余 8000 送入仓库。
        var em=database(List.<Object[]>of(eligible(A,"1000"),eligible(B,"1000"),eligible(C,"1000")),"11000","11000");
        var input=line("11000",DailyReportOutputAllocationLine.direct(A,new BigDecimal("1000")),
                DailyReportOutputAllocationLine.direct(B,new BigDecimal("1000")),
                DailyReportOutputAllocationLine.direct(C,new BigDecimal("1000")),
                DailyReportOutputAllocationLine.warehouse(new BigDecimal("8000")));
        input.setIsFinal(true);
        var pieces=new DailyReportOutputAllocationService(em).split(UUID.randomUUID(),List.of(input));
        assertEquals(4,pieces.size());
        assertEquals(List.of(A,B,C),pieces.stream().limit(3).map(DailyReportItemLine::getDirectTransferDemandId).toList());
        assertTrue(pieces.stream().limit(3).allMatch(piece->"WORKSHOP".equals(piece.getDestination())&&piece.getOutputRouteReason()==null));
        var warehouse=pieces.getLast();
        assertEquals("WAREHOUSE",warehouse.getDestination());
        assertNull(warehouse.getDirectTransferDemandId());
        assertEquals("RECEIVERS_FULL",warehouse.getOutputRouteReason(),"能直送的都已分满，其余送入仓库");
        // BOM 学习口径(V711)：各块合计等于本次实际产量，同一批次、同一换算率、同一完结标记。
        assertEquals(0,new BigDecimal("11000").compareTo(pieces.stream().map(DailyReportItemLine::getQty).reduce(BigDecimal.ZERO,BigDecimal::add)));
        assertEquals(1,pieces.stream().map(DailyReportItemLine::getOutputBatchId).distinct().count());
        assertTrue(pieces.stream().allMatch(piece->Boolean.TRUE.equals(piece.getIsFinal())&&piece.getAllocations()==null));
    }

    @Test void warehouseWhileAReceiverStillHasRoomIsTheWorkersOwnChoice() {
        var em=database(List.<Object[]>of(eligible(A,"1000"),eligible(B,"1000")),"3000","3000");
        var input=line("3000",DailyReportOutputAllocationLine.direct(A,new BigDecimal("1000")),
                DailyReportOutputAllocationLine.warehouse(new BigDecimal("2000")));
        var pieces=new DailyReportOutputAllocationService(em).split(UUID.randomUUID(),List.of(input));
        assertEquals("USER_CHOSEN",pieces.getLast().getOutputRouteReason());
        assertEquals(0,new BigDecimal("2000").compareTo(pieces.getLast().getQty()));
    }

    @Test void withoutAnyReceiverTheWarehouseReasonIsTheClosestBlockedReason() {
        var em=database(List.<Object[]>of(blocked(A,"DIFFERENT_WORKSHOP",40),blocked(B,"SUBCONTRACT_ROUTE",50)),"10","10");
        var pieces=new DailyReportOutputAllocationService(em).split(UUID.randomUUID(),List.of(line("10")));
        assertEquals(1,pieces.size());
        assertEquals("WAREHOUSE",pieces.getFirst().getDestination());
        assertEquals("DIFFERENT_WORKSHOP",pieces.getFirst().getOutputRouteReason());
    }

    @Test void aReceiverThatCannotTakeItIsRejectedWithTheSingleDatabaseReason() {
        // 与候选、审核、数据库守卫同一份判定：不能收就当场说原因，不拖到审核、不悄悄送仓。
        var em=database(List.<Object[]>of(blocked(A,"PLAN_NOT_ACTIVE",31)),"10","10");
        var error=assertThrows(ApiException.class,()->new DailyReportOutputAllocationService(em)
                .split(UUID.randomUUID(),List.of(line("10",DailyReportOutputAllocationLine.direct(A,BigDecimal.TEN)))));
        assertEquals("无法转到下一道工序：上层工单 ZX-A 不能收(PLAN_NOT_ACTIVE)",error.getMessage());
    }

    @Test void moreThanTheReceiverStillNeedsIsRejectedNotSilentlyWarehoused() {
        var em=database(List.<Object[]>of(eligible(A,"5")),"10","10");
        var error=assertThrows(ApiException.class,()->new DailyReportOutputAllocationService(em)
                .split(UUID.randomUUID(),List.of(line("10",DailyReportOutputAllocationLine.direct(A,new BigDecimal("6")),
                        DailyReportOutputAllocationLine.warehouse(new BigDecimal("4"))))));
        assertEquals("无法转到下一道工序：转给上层工单 ZX-A 的本次基本数量 6 超过最多可送 5",error.getMessage());
    }

    @Test void twoLinesShareOneReceiversRemainingNeed() {
        var em=database(List.<Object[]>of(eligible(A,"5")),"10","10");
        var first=line("3",DailyReportOutputAllocationLine.direct(A,new BigDecimal("3")));
        var second=line("3",DailyReportOutputAllocationLine.direct(A,new BigDecimal("3")));
        second.setExecutionSegmentId(first.getExecutionSegmentId());second.setPlanItemId(first.getPlanItemId());
        var error=assertThrows(ApiException.class,()->new DailyReportOutputAllocationService(em).split(UUID.randomUUID(),List.of(first,second)));
        assertTrue(error.getMessage().contains("最多可送 2"),error.getMessage());
    }

    @Test void theNeedShareIsTheMostThatCanGoToTheNextProcess() {
        // 计划 100 里只有 60 是需求份(40 是公共备货)：直送最多 60，公共部分一律送入仓库(ADR-118 §3)。
        var em=database(List.<Object[]>of(eligible(A,"100")),"100","60");
        var error=assertThrows(ApiException.class,()->new DailyReportOutputAllocationService(em)
                .split(UUID.randomUUID(),List.of(line("100",DailyReportOutputAllocationLine.direct(A,new BigDecimal("80")),
                        DailyReportOutputAllocationLine.warehouse(new BigDecimal("20"))))));
        assertTrue(error.getMessage().startsWith("本行最多 60 可以转下一道工序"),error.getMessage());
        var pieces=new DailyReportOutputAllocationService(database(List.<Object[]>of(eligible(A,"100")),"100","60"))
                .split(UUID.randomUUID(),List.of(line("100",DailyReportOutputAllocationLine.direct(A,new BigDecimal("60")),
                        DailyReportOutputAllocationLine.warehouse(new BigDecimal("40")))));
        assertEquals(2,pieces.size());
        assertTrue(pieces.getLast().isPublicOutput());
        assertEquals("PUBLIC_SHARE",pieces.getLast().getOutputRouteReason());
        assertFalse(Boolean.TRUE.equals(pieces.getLast().getIsFinal()),"公共备货块永远不是完结块");
    }

    @Test void supplementPreviewOnlyCountsQuantitiesAndNeverJudgesReceivers() {
        // 追加计划的预览/审核回放只算原计划承接多少、超出多少：上层工单在此期间停产或已备齐，
        // 不能让一个与追加无关的直送原因拦住批准(直送在保存报工时再按当时判定核对)。
        var em=database(List.<Object[]>of(blocked(A,"PLAN_NOT_ACTIVE",31)),"100","100");
        var input=line("120",DailyReportOutputAllocationLine.direct(A,new BigDecimal("100")),
                DailyReportOutputAllocationLine.warehouse(new BigDecimal("20")));
        var slices=new DailyReportOutputAllocationService(em).splitForPreview(UUID.randomUUID(),List.of(input),List.of());
        assertEquals(0,new BigDecimal("20").compareTo(slices.stream().filter(DailyReportItemLine::isActualSurplus)
                .map(DailyReportItemLine::getQty).reduce(BigDecimal.ZERO,BigDecimal::add)));
        assertTrue(slices.stream().noneMatch(slice->"WORKSHOP".equals(slice.getDestination())));
        Mockito.verify(em,Mockito.never()).createNativeQuery(ArgumentMatchers.contains("fn_workshop_direct_targets"));
        Mockito.verify(em,Mockito.never()).createNativeQuery(ArgumentMatchers.contains("FROM production_material_demands WHERE id IN"));
        // 保存时同一份分配照样当场说出不可转原因。
        assertThrows(ApiException.class,()->new DailyReportOutputAllocationService(em).split(UUID.randomUUID(),List.of(input)));
    }

    @Test void aLineWithoutAWorkOrderCannotGoToTheNextProcess() {
        var em=Mockito.mock(EntityManager.class);
        var unowned=new DailyReportItemLine();unowned.setQty(BigDecimal.ONE);
        unowned.setAllocations(List.of(DailyReportOutputAllocationLine.direct(A,BigDecimal.ONE)));
        assertThrows(ApiException.class,()->new DailyReportOutputAllocationService(em).split(UUID.randomUUID(),List.of(unowned)));
        var warehouse=new DailyReportItemLine();warehouse.setQty(BigDecimal.ONE);
        assertEquals("WAREHOUSE",new DailyReportOutputAllocationService(em).split(UUID.randomUUID(),List.of(warehouse)).getFirst().getDestination());
    }

    @Test void draftReservationCannotBeReclassifiedAsActualSurplus() {
        var capacity=new DailyReportOutputAllocationService.Capacity(new BigDecimal("100"),new BigDecimal("40"));
        assertThrows(ApiException.class,()->capacity.take(new BigDecimal("120")));
        assertEquals(new BigDecimal("40"),capacity.take(new BigDecimal("40")));
    }
    @Test void approvedUnclaimedSupplementRejectsProoflessSurplusAndPointsToTheSupplementEntry() {
        // 2026-10-06：已批准未续报的固定追加量占住公共超产额度——无 proof 的超额行 409，
        // 文案指路「固定追加量·续报」，不让工人在原工单反复试错或再造一张追加计划。
        var line=new DailyReportItemLine();
        line.setExecutionSegmentId(UUID.fromString("00000000-0000-0000-0000-0000000000f1"));
        line.setQty(new BigDecimal("25"));line.setActualSurplus(true);
        var error=assertThrows(ApiException.class,()->new DailyReportOutputAllocationService(allowance("0","25"))
                .requireAllowance(UUID.randomUUID(),List.of(line)));
        assertEquals(ErrorCode.CONFLICT,error.getCode());
        assertTrue(error.getMessage().contains("已批准剩余超产额度 0"),error.getMessage());
        assertTrue(error.getMessage().contains("已批准的固定追加量还有 25 未续报"),error.getMessage());
        assertTrue(error.getMessage().contains("「我的车间任务 → 固定追加量·续报」"),error.getMessage());
        assertNotNull(error.getFieldErrors());
        assertEquals("overproductionSupplement",error.getFieldErrors().getFirst().field());
    }
    @Test void claimedSupplementRestoresThePublicSurplusAllowance() {
        // 续报写入活跃 CLAIM 后待续报量归零、额度恢复：同一批超额此时按公共超产口径放行。
        var line=new DailyReportItemLine();
        line.setExecutionSegmentId(UUID.fromString("00000000-0000-0000-0000-0000000000f1"));
        line.setQty(new BigDecimal("20"));line.setActualSurplus(true);
        assertDoesNotThrow(()->new DailyReportOutputAllocationService(allowance("20","0"))
                .requireAllowance(UUID.randomUUID(),List.of(line)));
        // 额度真耗尽时仍按原口径拦下并引导提交追加计划，不提续报。
        var rejected=assertThrows(ApiException.class,()->new DailyReportOutputAllocationService(allowance("0","0"))
                .requireAllowance(UUID.randomUUID(),List.of(line)));
        assertTrue(rejected.getMessage().contains("超出部分须如实登记超限原因并交计划处置"),rejected.getMessage());
        assertFalse(rejected.getMessage().contains("固定追加量·续报"),rejected.getMessage());
    }
    @Test void approvedRemainingIsConsumedBeforeNewPhysicalSurplus() {
        var capacity=new DailyReportOutputAllocationService.Capacity(new BigDecimal("100"),new BigDecimal("100"));
        assertEquals(new BigDecimal("60"),capacity.take(new BigDecimal("60")));
        assertEquals(new BigDecimal("40"),capacity.take(new BigDecimal("80")));
        assertEquals(BigDecimal.ZERO,capacity.take(new BigDecimal("20")));
    }
    @Test void completedTwelveHundredKeepsOneBatchAndSplitsOnlyTheLastHundredForDisposition() {
        var em=database(List.of(),"1000","1000","100");
        var input=line("1200");input.setOverLimitReason("设备停机惯性产出");input.setWeight(new BigDecimal("12"));
        var pieces=new DailyReportOutputAllocationService(em).split(UUID.randomUUID(),List.of(input));
        assertEquals(List.of(new BigDecimal("1000"),new BigDecimal("100"),new BigDecimal("100")),
                pieces.stream().map(DailyReportItemLine::getQty).toList());
        assertEquals(1,pieces.stream().map(DailyReportItemLine::getOutputBatchId).distinct().count());
        assertFalse(pieces.get(1).isOverLimit());assertTrue(pieces.get(2).isOverLimit());
        assertEquals("设备停机惯性产出",pieces.get(2).getOverLimitReason());
        assertNull(pieces.get(0).getOverLimitReason());assertNull(pieces.get(1).getOverLimitReason());
        assertEquals(new BigDecimal("12.0000"),pieces.stream().map(DailyReportItemLine::getWeight).reduce(BigDecimal.ZERO,BigDecimal::add));
        assertTrue(pieces.get(2).isActualSurplus());assertTrue(pieces.get(2).isPublicOutput());
        assertFalse(Boolean.TRUE.equals(pieces.get(2).getIsFinal()));
    }
    @Test void twoActualInputLinesCannotEachReuseTheSameTolerance() {
        var first=line("1050");var second=line("150");second.setOverLimitReason("本批实物清点超过原限额");
        var pieces=new DailyReportOutputAllocationService(database(List.of(),"1000","1000","100"))
                .split(UUID.randomUUID(),List.of(first,second));
        assertEquals(0,new BigDecimal("1200").compareTo(pieces.stream().map(DailyReportItemLine::getQty).reduce(BigDecimal.ZERO,BigDecimal::add)));
        assertEquals(0,new BigDecimal("100").compareTo(pieces.stream().filter(DailyReportItemLine::isOverLimit).map(DailyReportItemLine::getQty).reduce(BigDecimal.ZERO,BigDecimal::add)));
        assertEquals(0,new BigDecimal("100").compareTo(pieces.stream().filter(p->p.isActualSurplus()&&!p.isOverLimit()).map(DailyReportItemLine::getQty).reduce(BigDecimal.ZERO,BigDecimal::add)));
    }
    @Test void overLimitWithoutReasonFailsWithoutTruncatingItsActualInput() {
        var input=line("1200");
        var error=assertThrows(ApiException.class,()->new DailyReportOutputAllocationService(database(List.of(),"1000","1000","100"))
                .split(UUID.randomUUID(),List.of(input)));
        assertEquals("overLimitReason",error.getFieldErrors().getFirst().field());
        assertEquals(new BigDecimal("1200"),input.getQty());
    }
    @Test void splitWeightPreservesOriginalTotalIncludingRoundingResidual() {
        var original=new DailyReportItemLine();original.setQty(new BigDecimal("3"));original.setWeight(BigDecimal.ONE);
        var first=new DailyReportItemLine();first.setQty(BigDecimal.ONE);
        var second=new DailyReportItemLine();second.setQty(BigDecimal.ONE);
        var last=new DailyReportItemLine();last.setQty(BigDecimal.ONE);
        DailyReportOutputAllocationService.distributeWeight(original,List.of(first,second,last));
        assertEquals(new BigDecimal("0.3333"),first.getWeight());
        assertEquals(new BigDecimal("0.3333"),last.getWeight());
        assertEquals(0,BigDecimal.ONE.compareTo(first.getWeight().add(second.getWeight()).add(last.getWeight())));
    }
    @Test void tinyWeightSplitNeverProducesANegativeLastSlice() {
        var original=new DailyReportItemLine();original.setQty(new BigDecimal("4"));original.setWeight(new BigDecimal("0.0002"));
        var pieces=new ArrayList<DailyReportItemLine>();
        for(int index=0;index<4;index++){var item=new DailyReportItemLine();item.setQty(BigDecimal.ONE);pieces.add(item);}
        DailyReportOutputAllocationService.distributeWeight(original,pieces);
        assertTrue(pieces.stream().allMatch(piece->piece.getWeight().signum()>=0));
        assertEquals(0,original.getWeight().compareTo(pieces.stream().map(DailyReportItemLine::getWeight).reduce(BigDecimal.ZERO,BigDecimal::add)));
    }
    @Test void theWholeDefectOfOneEntryStaysOnItsFirstSliceOnly() {
        var input=new DailyReportItemLine();input.setQty(new BigDecimal("10"));input.setDefectQty(new BigDecimal("3"));
        var pieces=new java.util.ArrayList<DailyReportItemLine>();
        for(String qty:List.of("5","4","1")){
            var piece=new DailyReportItemLine();org.springframework.beans.BeanUtils.copyProperties(input,piece);
            piece.setQty(new BigDecimal(qty));pieces.add(piece);
        }
        DailyReportOutputAllocationService.keepDefectOnFirstSlice(input,pieces);
        assertEquals(new BigDecimal("3"),pieces.get(0).getDefectQty());
        assertEquals(BigDecimal.ZERO,pieces.get(1).getDefectQty());
        assertEquals(BigDecimal.ZERO,pieces.get(2).getDefectQty());
        assertEquals(List.of(new BigDecimal("5"),new BigDecimal("4"),BigDecimal.ONE),
                pieces.stream().map(DailyReportItemLine::getQty).toList(),"slicing only ever moves the good quantity");
    }
    @Test void nonBasicUnitMultiLineTransferDebitsEachActualRoundedLedgerQuantity() {
        BigDecimal remaining=new BigDecimal("0.0006");
        for(int index=0;index<3;index++) {
            BigDecimal actualBase=DailyReportOutputAllocationService.transferBaseQuantity(new BigDecimal("0.0001"),new BigDecimal("1.5"));
            assertEquals(new BigDecimal("0.0002"),actualBase);
            remaining=remaining.subtract(actualBase);
        }
        assertEquals(0,remaining.signum(),"three separately posted lines must exhaust the same base-quantity budget");
        assertEquals(new BigDecimal("1.0000"),DailyReportOutputAllocationService.transferBaseQuantity(new BigDecimal("3"),new BigDecimal("0.333333")));
    }

    private static DailyReportItemLine line(String qty,DailyReportOutputAllocationLine... allocations) {
        var line=new DailyReportItemLine();line.setQty(new BigDecimal(qty));
        line.setExecutionSegmentId(UUID.fromString("00000000-0000-0000-0000-0000000000f1"));
        line.setPlanItemId(UUID.fromString("00000000-0000-0000-0000-0000000000f2"));
        line.setUnitRate(BigDecimal.ONE);
        line.setAllocations(allocations.length==0?null:List.of(allocations));
        return line;
    }

    /** One row of fn_workshop_direct_targets(:source) as the service reads it. */
    private static Object[] eligible(UUID demand,String remaining) {
        return new Object[]{demand,true,null,null,null,new BigDecimal(remaining),new BigDecimal(remaining),"上层工单 ZX-"+label(demand)};
    }
    private static Object[] blocked(UUID demand,String code,int rank) {
        return new Object[]{demand,false,code,"上层工单 ZX-"+label(demand)+" 不能收("+code+")",rank,BigDecimal.ZERO,BigDecimal.ZERO,
                "上层工单 ZX-"+label(demand)};
    }
    private static String label(UUID demand){return demand.equals(A)?"A":demand.equals(B)?"B":"C";}

    /**
     * The native queries the router issues: locks, the source work order's planned/need share,
     * capacity reads, the single list of receivers and the plain quantity text.
     */
    private static EntityManager database(List<Object[]> targets,String planned,String needShare) {
        return database(targets,planned,needShare,"0");
    }
    private static EntityManager database(List<Object[]> targets,String planned,String needShare,String allowance) {
        var em=Mockito.mock(EntityManager.class);
        Mockito.when(em.createNativeQuery(ArgumentMatchers.anyString())).thenAnswer(invocation->{
            String sql=invocation.getArgument(0);
            var query=Mockito.mock(Query.class);
            List<Object[]> bound=new ArrayList<>();
            Mockito.when(query.setParameter(ArgumentMatchers.anyString(),ArgumentMatchers.any())).thenAnswer(set->{
                bound.add(new Object[]{set.getArgument(0),set.getArgument(1)});return query;});
            Mockito.when(query.getSingleResult()).thenAnswer(ignored->{
                if(sql.contains("fn_execution_actual_surplus_available"))return new BigDecimal(allowance);
                if(sql.contains("QTY_EXCEEDS_REMAINING"))return "转给"+value(bound,"receiver")+" 的本次基本数量 "
                        +((BigDecimal)value(bound,"qty")).stripTrailingZeros().toPlainString()+" 超过最多可送 "
                        +((BigDecimal)value(bound,"room")).stripTrailingZeros().toPlainString();
                return BigDecimal.ZERO;
            });
            Mockito.when(query.getResultList()).thenAnswer(ignored->{
                if(sql.contains("fn_workshop_direct_targets(:source) target"))return new ArrayList<>(targets);
                if(sql.contains("fn_workshop_direct_targets(:source,:target)"))return List.of();
                if(sql.contains("SELECT segment.planned_qty"))return Collections.singletonList(
                        new Object[]{new BigDecimal(planned),BigDecimal.ZERO,new BigDecimal(needShare),false});
                if(sql.contains("fn_actual_supplement_reserved_original_qty"))return Collections.singletonList(
                        new Object[]{BigDecimal.ZERO,BigDecimal.ZERO,BigDecimal.ZERO});
                return List.of();
            });
            return query;
        });
        return em;
    }
    /**
     * requireAllowance 读的两个额度函数：公共超产可用额度与已批准未续报的固定追加量
     * (均为数据库函数，这里按服务读法各自给值，验证拦截与文案分流)。
     */
    private static EntityManager allowance(String available,String pending) {
        var em=Mockito.mock(EntityManager.class);
        Mockito.when(em.createNativeQuery(ArgumentMatchers.anyString())).thenAnswer(invocation->{
            String sql=invocation.getArgument(0);
            var query=Mockito.mock(Query.class);
            Mockito.when(query.setParameter(ArgumentMatchers.anyString(),ArgumentMatchers.any())).thenReturn(query);
            Mockito.when(query.getSingleResult()).thenAnswer(ignored->
                    sql.contains("fn_execution_actual_surplus_available")?new BigDecimal(available):new BigDecimal(pending));
            return query;
        });
        return em;
    }

    private static Object value(List<Object[]> bound,String name) {
        for(Object[] entry:bound)if(name.equals(entry[0]))return entry[1];
        return null;
    }
}
