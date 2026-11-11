package com.uten.imp.businesschain;
import java.math.BigDecimal;import java.util.*;
import org.junit.jupiter.api.Test;import org.springframework.beans.factory.annotation.Autowired;import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.security.core.context.SecurityContextHolder;
import com.uten.imp.features.production.execution.ProductionExecutionWorkbenchService;
import static org.junit.jupiter.api.Assertions.*;
class FeedbackWorkbenchProjectionFixture extends FeedbackLegacyMaterialUpgradeFixture {
 @Autowired ProductionExecutionWorkbenchService workbench;
 @Autowired org.springframework.transaction.PlatformTransactionManager transactions;
 @Autowired com.uten.imp.security.TxSessionVars tx;
    @Test void realWorkbenchSqlKeepsPartialMaterialAndWorkshopAuthorityIndependent() {
        var fixture=new WorkshopPublicSurplusEndToEndTest();beans.autowireBean(fixture);fixture.prepare();
        ((java.util.concurrent.atomic.AtomicInteger)ReflectionTestUtils.getField(FullChainEndToEndTest.class,"LEGACY_SEQ")).set(db.queryForObject("SELECT COALESCE(MAX(legacy_id),10000)+100 FROM units",Integer.class));
        Object partial=ReflectionTestUtils.invokeMethod(fixture,"createStartedTask","projection-partial"+UUID.randomUUID(),false,"1000",false,new BigDecimal("0.5"));
        Object full=ReflectionTestUtils.invokeMethod(fixture,"createStartedTask","projection-full"+UUID.randomUUID(),false,"1000",false,BigDecimal.ONE);
        var world=(FullChainEndToEndTest.World)ReflectionTestUtils.invokeMethod(full,"world");
        UUID reader=new org.springframework.transaction.support.TransactionTemplate(transactions).execute(status->{
                tx.bind();return fixture.fixture.createUserWithPerms(world,"projection-reader"+UUID.randomUUID(),
                "production_execution:view","production_workshop_task:view:all","production_execution:start",
                "production_daily_report:view","production_daily_report:create","workshop_material:choose");});
        db.update("UPDATE employees SET department_id=? WHERE id=(SELECT employee_id FROM users WHERE id=?)",id(full,"workshop"),reader);
        fixture.fixture.loginAs(reader);
        assertFalse(((com.uten.imp.security.AuthUser)SecurityContextHolder.getContext().getAuthentication().getPrincipal()).isSuperAdmin());
        for(Object task:List.of(partial,full)) {
            String code=db.queryForObject("SELECT segment_code FROM production_execution_segments WHERE id=?",String.class,id(task,"segment"));
            var page=workbench.workshopTasks(1,50,null,"IN_PROGRESS",null,null,null,null,null,null,code,null,null);
            assertEquals(1,page.getTotal());assertEquals(1,page.getItems().size());
            var row=page.getItems().getFirst();assertEquals(id(task,"segment"),row.segmentId());
            boolean assigned=task==full;
            assertEquals(!assigned,row.partialMaterialReportLimited());
            assertEquals(assigned,row.canReport());assertFalse(row.canStart(),"an already running task does not offer START");
            assertEquals(assigned,row.canBatchReport());
            if(!assigned) {
                assertTrue(row.blockedReason().contains("仅可查看其它车间"),row.blockedReason());
                assertTrue(row.allowedActions().isEmpty());assertFalse(row.canUrgePlanning());
            }
        }
    }

 private UUID id(Object task,String name){return ReflectionTestUtils.invokeMethod(task,name);}
}
