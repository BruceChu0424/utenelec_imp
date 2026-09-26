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
import java.util.Arrays;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * ADR-115 仓库类通知按仓分发: 单据所在仓(含上级仓)登记了有效负责人时只发给通知池里的负责人;
 * 没登记、没定仓、或负责人都不在池里时照旧发给整个池(宁可多发, 不让任务掉进无人区)。
 */
class ChainNoticeWarehouseKeeperRoutingTest {

    private final UUID finishedGoodsKeeper = UUID.randomUUID();
    private final UUID hardwareKeeper = UUID.randomUUID();
    private final UUID supervisor = UUID.randomUUID();
    private final List<UUID> pool = List.of(finishedGoodsKeeper, hardwareKeeper, supervisor);
    private final UUID finishedGoodsWarehouse = UUID.randomUUID();

    @Test
    void keepersOfTheDocumentWarehouseReceiveTheNoticeInPoolOrder() {
        WarehouseTaskScopePort keepers = mock(WarehouseTaskScopePort.class);
        when(keepers.keeperUserIds(List.of(finishedGoodsWarehouse)))
                .thenReturn(List.of(supervisor, finishedGoodsKeeper));
        ChainNoticeService service = service(keepers);

        assertThat(service.warehouseRecipients(pool, List.of(finishedGoodsWarehouse)))
                .containsExactly(finishedGoodsKeeper, supervisor);
    }

    @Test
    void warehouseWithoutKeepersStillNotifiesTheWholePool() {
        WarehouseTaskScopePort keepers = mock(WarehouseTaskScopePort.class);
        when(keepers.keeperUserIds(any())).thenReturn(List.of());

        assertThat(service(keepers).warehouseRecipients(pool, List.of(finishedGoodsWarehouse)))
                .isEqualTo(pool);
    }

    @Test
    void keepersOutsideThePoolFallBackToTheWholePool() {
        WarehouseTaskScopePort keepers = mock(WarehouseTaskScopePort.class);
        // 负责人不在仓库部门或缺这项通知要求的权限: 不能让这张单据没人收到。
        when(keepers.keeperUserIds(any())).thenReturn(List.of(UUID.randomUUID()));

        assertThat(service(keepers).warehouseRecipients(pool, List.of(finishedGoodsWarehouse)))
                .isEqualTo(pool);
    }

    @Test
    void documentsWithoutAWarehouseDoNotQueryKeepers() {
        WarehouseTaskScopePort keepers = mock(WarehouseTaskScopePort.class);
        ChainNoticeService service = service(keepers);

        assertThat(service.warehouseRecipients(pool, List.of())).isEqualTo(pool);
        assertThat(service.warehouseRecipients(pool, Arrays.asList((UUID) null))).isEqualTo(pool);
        assertThat(service.warehouseRecipients(List.of(), List.of(finishedGoodsWarehouse))).isEmpty();
        verify(keepers, never()).keeperUserIds(any());
    }

    @Test
    void withoutTheKeeperPortRoutingIsUnchanged() {
        assertThat(service(null).warehouseRecipients(pool, List.of(finishedGoodsWarehouse)))
                .isEqualTo(pool);
    }

    /** 每一处仓库类通知都经过按仓分发; 新增仓库通知时漏接会在这里暴露。 */
    @Test
    void everyWarehouseDepartmentNoticeIsRoutedByWarehouse() throws Exception {
        String source = Files.readString(
                Path.of("src/main/java/com/uten/imp/features/notice/ChainNoticeService.java"),
                StandardCharsets.UTF_8);
        int routed = source.split("warehouseRecipients\\(departmentUserIdsWithAuthorit", -1).length - 1;
        int warehousePools = source.split("\"SUB_WH\"", -1).length - 1;
        // 13 处仓库通知池全部按仓分发(新增最底层自制件实际物料待登记；成品入库待审、成品待登记、领料待出库、IQC 待入库、IQC 结案、
        // 销售待拣货与撤回放行、委外出仓、委外预计回厂与撤回、采购预计到货、到货异常定案)。
        assertThat(routed).isEqualTo(13);
        assertThat(warehousePools).isEqualTo(routed);
    }

    private static ChainNoticeService service(WarehouseTaskScopePort keepers) {
        ChainNoticeService service = new ChainNoticeService(
                mock(NoticeService.class),
                mock(UserAccountRepository.class),
                mock(PermissionResolver.class),
                mock(JdbcTemplate.class),
                mock(BusinessEventPublisher.class),
                mock(RdTaskService.class),
                mock(FinanceReviewerEligibilityPort.class),
                mock(SalesOrderFinanceConfirmerEligibility.class));
        service.setWarehouseKeepers(keepers);
        return service;
    }
}
