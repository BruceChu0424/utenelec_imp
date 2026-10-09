package com.uten.imp.features.notice;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.FinanceReviewerEligibilityPort;
import com.uten.imp.application.port.WarehouseTaskScopePort;
import com.uten.imp.features.admin.workflow.SalesOrderFinanceConfirmerEligibility;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.rd_task.RdTaskService;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import java.util.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class ProductionMaterialDiscoveryNoticeTest {
    final NoticeService notices=mock(NoticeService.class);
    final JdbcTemplate jdbc=mock(JdbcTemplate.class);
    final UserAccountRepository accounts=mock(UserAccountRepository.class);
    final PermissionResolver permissions=mock(PermissionResolver.class);
    final WarehouseTaskScopePort keepers=mock(WarehouseTaskScopePort.class);
    final ChainNoticeService service=new ChainNoticeService(notices,accounts,permissions,jdbc,mock(BusinessEventPublisher.class),mock(RdTaskService.class),mock(FinanceReviewerEligibilityPort.class),mock(SalesOrderFinanceConfirmerEligibility.class));
    final UUID request=UUID.randomUUID(),warehouse=UUID.randomUUID(),keeper=UUID.randomUUID(),other=UUID.randomUUID();
    ProductionMaterialDiscoveryNoticeTest(){service.setWarehouseRouter(new WarehouseNoticeRouter(keepers));}

    @Test void pendingKnownWarehouseReachesOnlyThatWarehouseKeeper(){
        row("PENDING",true,warehouse);pool();when(keepers.noticeRecipients(List.of(keeper,other),List.of(warehouse))).thenReturn(List.of(keeper));
        deliver("PENDING");assertPublished(keeper);verify(notices,never()).publishForUser(eq(other),anyString(),anyString(),anyString(),anyString(),anyString(),anyString(),any(),any());
    }
    // ADR-149: 未定仓的任务同样经唯一分发规则(主管 ∩ 池, 没有主管才整个池); 这里规则返回整个池。
    @Test void notYetAssignedWarehouseGoesThroughTheSameRoutingRule(){
        row("PENDING",true,null);pool();when(keepers.noticeRecipients(List.of(keeper,other),List.of())).thenReturn(List.of(keeper,other));
        deliver("PENDING");assertPublished(keeper);assertPublished(other);verify(keepers).noticeRecipients(List.of(keeper,other),List.of());
    }
    @Test void stoppedSourceOrConfiguredRequestResolvesInsteadOfDeliveringStalePendingCard(){
        row("PENDING",false,warehouse);deliver("VISIBILITY");verify(notices).resolveReviewNotices("PRODUCTION_MATERIAL_DISCOVERY_REQUEST",request,"STATE_CHANGED");
        clearInvocations(notices);row("CONFIGURED",true,warehouse);deliver("PENDING");verify(notices).resolveReviewNotices("PRODUCTION_MATERIAL_DISCOVERY_REQUEST",request,"STATE_CHANGED");
        verify(notices,never()).publishForUser(any(),anyString(),anyString(),anyString(),anyString(),anyString(),anyString(),any(),any());
    }
    // 同一申请的投递按申请串行: 先拿锁再读现状, 待领料与可见性一样先撤后发(乱序或重复投递不留两张卡)。
    @Test void pendingDeliveryRebuildsTheCardUnderThePerRequestLock(){
        row("PENDING",true,warehouse);pool();when(keepers.noticeRecipients(List.of(keeper,other),List.of(warehouse))).thenReturn(List.of(keeper));
        deliver("PENDING");
        var order=inOrder(jdbc,notices);
        order.verify(jdbc).queryForObject(contains("pg_advisory_xact_lock"),eq(String.class),eq("material-discovery-notice:"+request));
        order.verify(jdbc).queryForList(contains("FROM production_material_discovery_requests"),eq(request));
        order.verify(notices).resolveReviewNotices("PRODUCTION_MATERIAL_DISCOVERY_REQUEST",request,"REFRESHED");
        order.verify(notices).publishForUser(eq(keeper),anyString(),anyString(),anyString(),anyString(),anyString(),anyString(),any(),eq(request));
    }
    private void deliver(String event){service.deliverOutboxEvent("PRODUCTION_MATERIAL_DISCOVERY_"+event,request,new ObjectMapper().createObjectNode());}
    private void assertPublished(UUID user){verify(notices).publishForUser(eq(user),contains("待登记实际领料"),contains("车间申请生产"),eq("task"),eq("系统"),eq("/warehouse/tasks/draw"),eq("PRODUCTION_MATERIAL_DISCOVERY_PENDING"),isNull(),eq(request));}
    private void row(String status,boolean active,UUID warehouse){
        Map<String,Object> row=new HashMap<>();row.put("status",status);row.put("active",active);row.put("warehouse_id",warehouse);row.put("segment_code","ZX-TEST");row.put("goods_name","外壳");
        when(jdbc.queryForList(contains("FROM production_material_discovery_requests"),eq(request))).thenReturn(List.of(row));
    }
    private void pool(){
        when(jdbc.queryForList(contains("FROM users user_account"),eq(UUID.class),eq("SUB_WH"))).thenReturn(List.of(keeper,other));
        for(UUID id:List.of(keeper,other)){UserAccount user=mock(UserAccount.class);when(user.getStatus()).thenReturn("active");when(accounts.findById(id)).thenReturn(Optional.of(user));when(permissions.grantedPermsOf(user)).thenReturn(Set.of("stock_doc:view","stock_doc:approve","stock_doc:issue","notice:read"));}
    }
}
