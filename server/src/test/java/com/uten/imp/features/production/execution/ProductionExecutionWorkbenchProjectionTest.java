package com.uten.imp.features.production.execution;

import com.uten.imp.application.port.ProductionMaterialUsageReadPort;
import org.junit.jupiter.api.Test;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.List;
import java.util.UUID;
import static org.junit.jupiter.api.Assertions.*;

class ProductionExecutionWorkbenchProjectionTest {
    @Test void materialLimitScopeAndTotalAreIndependentTailColumns() {
        Object[] row=row(false,true);
        row[ProductionExecutionWorkbenchService.SEGMENT_CANDIDATE_TOTAL_COLUMN]=378L;
        assertTrue(ProductionExecutionWorkbenchService.segmentOriginalTaskScope(row));
        assertEquals(378L,ProductionExecutionWorkbenchService.segmentCandidateTotal(row));
        row[ProductionExecutionWorkbenchService.SEGMENT_PARTIAL_MATERIAL_LIMIT_COLUMN]=true;
        row[ProductionExecutionWorkbenchService.SEGMENT_ORIGINAL_TASK_SCOPE_COLUMN]=false;
        assertFalse(ProductionExecutionWorkbenchService.segmentOriginalTaskScope(row));
        assertEquals(378L,ProductionExecutionWorkbenchService.segmentCandidateTotal(row));
    }

    @Test void fullMaterialIssueDoesNotRetireAnAuthorizedTasksCommands() throws Exception {
        var task=map(row(false,true));
        assertTrue(task.canReport());assertTrue(task.canStart());assertTrue(task.canBatchReport());
        assertEquals(Boolean.FALSE,task.partialMaterialReportLimited());
    }

    @Test void partialMaterialIssueDoesNotAuthorizeAnotherWorkshopsTask() throws Exception {
        var task=map(row(true,false));
        assertFalse(task.canReport());assertFalse(task.canStart());assertFalse(task.canBatchReport());
        assertEquals(Boolean.TRUE,task.partialMaterialReportLimited());
        assertTrue(task.blockedReason().contains("仅可查看其它车间"));
    }

    @Test void projectionDriftFailsExplicitlyBeforePublishingAFalseCount() {
        assertThrows(IllegalStateException.class,()->ProductionExecutionWorkbenchService.segmentCandidateTotal(new Object[82]));
    }

    private static Object[] row(boolean limited,boolean scope) {
        Object[] row=new Object[ProductionExecutionWorkbenchService.SEGMENT_CANDIDATE_TOTAL_COLUMN+1];
        row[0]=UUID.randomUUID();row[1]=UUID.randomUUID();row[20]="IN_PROGRESS";
        row[27]=true;row[28]=true;row[29]=true;row[33]=0L;
        row[46]=true;row[47]=true;row[64]=0L;
        row[ProductionExecutionWorkbenchService.SEGMENT_PARTIAL_MATERIAL_LIMIT_COLUMN]=limited;
        row[ProductionExecutionWorkbenchService.SEGMENT_ORIGINAL_TASK_SCOPE_COLUMN]=scope;
        row[ProductionExecutionWorkbenchService.SEGMENT_CANDIDATE_TOTAL_COLUMN]=1L;
        return row;
    }

    private static ProductionExecutionWorkbenchSegment map(Object[] row) throws Exception {
        Class<?> planning=Class.forName(ProductionExecutionWorkbenchService.class.getName()+"$PlanningFacts");
        Field none=planning.getDeclaredField("NONE");none.setAccessible(true);
        Method mapper=ProductionExecutionWorkbenchService.class.getDeclaredMethod("segmentRow",Object[].class,
                ProductionMaterialUsageReadPort.UsageFlags.class,String.class,planning,boolean.class,List.class);
        mapper.setAccessible(true);
        return (ProductionExecutionWorkbenchSegment)mapper.invoke(null,row,ProductionMaterialUsageReadPort.UsageFlags.NONE,null,none.get(null),false,List.of());
    }
}
