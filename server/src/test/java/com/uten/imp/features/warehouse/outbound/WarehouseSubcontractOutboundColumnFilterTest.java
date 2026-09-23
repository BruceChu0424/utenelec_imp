package com.uten.imp.features.warehouse.outbound;

import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.subcontract.plan.SubcontractMaterialPlanService;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.mockito.ArgumentMatchers;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;

import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 委外出仓工作台表头筛选（2026-09-16）：supplierId 按计划外键等值（? 绑定）；
 * status 是派生任务状态（有草稿=待拣货 / 无草稿=待出仓），非法值 fail-closed。
 */
class WarehouseSubcontractOutboundColumnFilterTest {

    @Test
    void supplierAndDerivedStatusFlowIntoCountAndListWithBoundParameters() {
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        when(jdbc.queryForObject(anyString(), eq(Long.class), any(Object[].class)))
                .thenReturn(0L);
        when(jdbc.query(anyString(), ArgumentMatchers.<RowMapper<Object>>any(), any(Object[].class)))
                .thenReturn(List.of());
        SubcontractMaterialPlanService service = service(jdbc);

        UUID supplierId = UUID.randomUUID();
        service.tasks(1, 20, "", supplierId, "DRAFT_PICKING");

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        ArgumentCaptor<Object[]> args = ArgumentCaptor.forClass(Object[].class);
        // 计数与列表共用 base：supplier 等值 + 派生状态子句都进 WHERE，列名硬编码。
        verify(jdbc, org.mockito.Mockito.atLeastOnce()).queryForObject(
                sql.capture(), eq(Long.class), args.capture());
        assertThat(sql.getAllValues()).anySatisfy(statement -> assertThat(statement)
                .contains("p.supplier_id = ?")
                .contains("draft.issue_id IS NOT NULL"));
        assertThat(args.getAllValues()).anySatisfy(argv -> assertThat(argv[0])
                .isEqualTo(supplierId));

        // READY_OUTBOUND 对称分支：无草稿（draft.issue_id IS NULL）且此刻有可发量。
        service.tasks(1, 20, "", null, "READY_OUTBOUND");
        verify(jdbc, org.mockito.Mockito.atLeastOnce()).queryForObject(
                sql.capture(), eq(Long.class), any(Object[].class));
        assertThat(sql.getAllValues()).anySatisfy(statement -> assertThat(statement)
                .contains("draft.issue_id IS NULL")
                .contains("agg.issuable_total > 0"));

        // ADR-103 第三档 WAITING_COMPONENT：无草稿、可发合计为 0、且有行在等子件到货；
        // 可发合计与等料行数都在 agg 里按作业叶仓合格可动用量算, 与锁判据同一份 SQL 片段。
        service.tasks(1, 20, "", null, "WAITING_COMPONENT");
        verify(jdbc, org.mockito.Mockito.atLeastOnce()).queryForObject(
                sql.capture(), eq(Long.class), any(Object[].class));
        assertThat(sql.getAllValues()).anySatisfy(statement -> assertThat(statement)
                .contains("draft.issue_id IS NULL")
                .contains("agg.issuable_total <= 0")
                .contains("agg.waiting_component_line_count > 0")
                .contains("AS issuable_total")
                .contains("AS waiting_component_line_count")
                .contains(SubcontractMaterialPlanService.QUALIFIED_AVAILABLE_STOCK_SOURCE));

        // 非法派生状态 fail-closed。
        assertThatThrownBy(() -> service.tasks(1, 20, "", null, "SHIPPED"))
                .isInstanceOf(ApiException.class);
    }

    private static SubcontractMaterialPlanService service(JdbcTemplate jdbc) {
        return new SubcontractMaterialPlanService(
                mock(EntityManager.class),
                jdbc,
                mock(DocNumberService.class),
                mock(com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueRepository.class),
                mock(com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueItemRepository.class),
                mock(SecurityContextCurrentUser.class),
                mock(com.uten.imp.application.port.SubcontractChainNoticePort.class),
                mock(com.uten.imp.features.stock.InventoryMutationLock.class),
                mock(com.uten.imp.application.port.SubcontractOrderPreparationPort.class),
                mock(org.springframework.beans.factory.ObjectProvider.class));
    }
}
