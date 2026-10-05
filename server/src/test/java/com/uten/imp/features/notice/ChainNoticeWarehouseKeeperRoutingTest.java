package com.uten.imp.features.notice;

import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.FinanceReviewerEligibilityPort;
import com.uten.imp.application.port.WarehouseTaskScopePort;
import com.uten.imp.features.admin.workflow.SalesOrderFinanceConfirmerEligibility;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.rd_task.RdTaskService;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * ADR-149 仓库类通知唯一分发规则(取代 ADR-115 的「负责人 ∩ 池, 为空发整个池」): ChainNoticeService 的每一处
 * 仓库通知都经 {@link WarehouseNoticeRouter}; 规则本身(子仓负责人 ∩ 池 → 主管 ∩ 池 → 池)在数据库函数
 * fn_warehouse_notice_recipients, 由 WarehouseDataScopePostgresTest 钉住。
 */
class ChainNoticeWarehouseKeeperRoutingTest {

    private final UUID finishedGoodsKeeper = UUID.randomUUID();
    private final UUID hardwareKeeper = UUID.randomUUID();
    private final UUID supervisor = UUID.randomUUID();
    private final List<UUID> pool = List.of(finishedGoodsKeeper, hardwareKeeper, supervisor);
    private final UUID finishedGoodsWarehouse = UUID.randomUUID();

    @Test
    void recipientsComeFromTheSingleRoutingRule() {
        WarehouseTaskScopePort scopes = mock(WarehouseTaskScopePort.class);
        when(scopes.noticeRecipients(pool, List.of(finishedGoodsWarehouse))).thenReturn(List.of(finishedGoodsKeeper));

        assertThat(service(scopes).warehouseRecipients(pool, List.of(finishedGoodsWarehouse)))
                .containsExactly(finishedGoodsKeeper);
    }

    @Test
    void unassignedDocumentsStillGoThroughTheRule() {
        WarehouseTaskScopePort scopes = mock(WarehouseTaskScopePort.class);
        // 未定仓的任务交主管那一级, 不再直接发整个池。
        when(scopes.noticeRecipients(pool, List.of())).thenReturn(List.of(supervisor));

        assertThat(service(scopes).warehouseRecipients(pool, List.of())).containsExactly(supervisor);
    }

    @Test
    void emptyPoolNeverQueriesTheRule() {
        WarehouseTaskScopePort scopes = mock(WarehouseTaskScopePort.class);

        assertThat(service(scopes).warehouseRecipients(List.of(), List.of(finishedGoodsWarehouse))).isEmpty();
        verify(scopes, never()).noticeRecipients(any(), any());
    }

    @Test
    void routerPoolAddsOnlyTheInvolvedWarehousesKeepersOutsideTheDepartmentWhoQualify() {
        WarehouseTaskScopePort scopes = mock(WarehouseTaskScopePort.class);
        UUID financeKeeper = UUID.randomUUID();
        UUID unqualified = UUID.randomUUID();
        // 候选只来自这张单涉及的仓(子仓负责人 + 指定的主管), 别的仓的负责人不进池。
        when(scopes.noticeCandidateUserIds(List.of(finishedGoodsWarehouse)))
                .thenReturn(List.of(supervisor, financeKeeper, unqualified));

        assertThat(new WarehouseNoticeRouter(scopes).pool(pool, id -> !id.equals(unqualified),
                List.of(finishedGoodsWarehouse)))
                .containsExactly(finishedGoodsKeeper, hardwareKeeper, supervisor, financeKeeper);
        verify(scopes, never()).responsibleUserIds();
    }

    @Test
    void withoutTheRouterRoutingIsUnchanged() {
        assertThat(service(null).warehouseRecipients(pool, List.of(finishedGoodsWarehouse))).isEqualTo(pool);
    }

    /** 每一处仓库类通知都用仓库通知池并经唯一规则分发; 新增仓库通知时漏接会在这里暴露。 */
    @Test
    void everyWarehouseDepartmentNoticeIsRoutedByWarehouse() throws Exception {
        String source = Files.readString(
                Path.of("src/main/java/com/uten/imp/features/notice/ChainNoticeService.java"),
                StandardCharsets.UTF_8);
        int routed = source.split("warehouseRecipients\\(warehousePool\\(", -1).length - 1;
        int legacy = source.split("warehouseRecipients\\(departmentUserIdsWithAuthorit", -1).length - 1;
        int warehousePools = source.split("\"SUB_WH\"", -1).length - 1;
        // 14 处仓库通知全部用仓库通知池按仓分发(最底层自制件实际物料待登记、成品入库待审、成品待登记、领料待出库、
        // IQC 待入库、IQC 结案、销售待拣货与撤回放行、委外领料待发料(ADR-143 每张草稿一条)、委外领料已撤回、
        // 委外预计回厂与撤回、采购预计到货、到货异常定案)。
        assertThat(routed).isEqualTo(14);
        assertThat(legacy).isZero();
        // 「SUB_WH」部门池只在 warehousePool 里出现一次(仓库类通知不再各自拼部门池)。
        assertThat(warehousePools).isEqualTo(1);
        // 另两处仓库通知(车间内料仓、盘点审核)也只经同一个 router。
        for (String file : List.of("WorkshopMaterialNoticeService.java", "StockCountNoticeHandler.java")) {
            String other = Files.readString(Path.of("src/main/java/com/uten/imp/features/notice/" + file),
                    StandardCharsets.UTF_8);
            assertThat(other).contains("warehouseRouter.recipients(").doesNotContain("keeperUserIds(");
        }
    }

    private static ChainNoticeService service(WarehouseTaskScopePort scopes) {
        ChainNoticeService service = new ChainNoticeService(
                mock(NoticeService.class),
                mock(UserAccountRepository.class),
                mock(PermissionResolver.class),
                mock(JdbcTemplate.class),
                mock(BusinessEventPublisher.class),
                mock(RdTaskService.class),
                mock(FinanceReviewerEligibilityPort.class),
                mock(SalesOrderFinanceConfirmerEligibility.class));
        service.setWarehouseRouter(scopes == null ? null : new WarehouseNoticeRouter(scopes));
        return service;
    }
}
