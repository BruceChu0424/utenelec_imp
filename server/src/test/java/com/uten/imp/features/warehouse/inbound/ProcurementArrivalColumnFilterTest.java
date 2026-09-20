package com.uten.imp.features.warehouse.inbound;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.FinanceReviewerEligibilityPort;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.common.concurrency.ProcurementMutationLocks;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.purchase.receipt.ReceiptPriceMasker;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
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
 * 入库工作台表头筛选（2026-09-16）：
 * ①到货异常 supplier/warehouse/status —— 三列全部参数绑定（?），status 白名单 fail-closed；
 * ②预计到货 supplier —— 计数与列表同口径（countExpectations 同样带 supplier 过滤）。
 */
class ProcurementArrivalColumnFilterTest {

    private final JdbcTemplate jdbc = mock(JdbcTemplate.class);
    private final ProcurementArrivalControlService service = service(jdbc);

    @Test
    void arrivalExceptionColumnsBindParametersAndStatusWhitelist() {
        when(jdbc.queryForObject(anyString(), eq(Long.class), any(Object[].class)))
                .thenReturn(0L);
        when(jdbc.query(anyString(), ArgumentMatchers.<RowMapper<Object>>any(), any(Object[].class)))
                .thenReturn(List.of());

        UUID supplierId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        service.warehouseExceptions(1, 20, "", false,
                supplierId, warehouseId, "pending_finance ");

        // ①计数查询：供应商/仓库/状态三个等值子句全部进 WHERE（列名硬编码，值走 ?）。
        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        ArgumentCaptor<Object[]> args = ArgumentCaptor.forClass(Object[].class);
        verify(jdbc, org.mockito.Mockito.atLeastOnce()).queryForObject(
                sql.capture(), eq(Long.class), args.capture());
        assertThat(sql.getAllValues()).anySatisfy(statement -> assertThat(statement)
                .contains("exception.supplier_id = ?")
                .contains("exception.warehouse_id = ?")
                .contains("exception.status = ?"));
        assertThat(args.getAllValues()).anySatisfy(argv -> assertThat(argv)
                .containsExactlyInAnyOrder(supplierId, warehouseId, "PENDING_FINANCE"));

        // ②非法状态 fail-closed。
        assertThatThrownBy(() -> service.warehouseExceptions(
                1, 20, "", false, null, null, "NOT_A_STATUS"))
                .isInstanceOf(ApiException.class);
    }

    @Test
    void expectationSupplierFilterHitsBothListAndCountWithBoundParameter() {
        when(jdbc.queryForObject(anyString(), eq(Long.class), any(Object[].class)))
                .thenReturn(0L);
        when(jdbc.query(anyString(), ArgumentMatchers.<RowMapper<Object>>any(), any(Object[].class)))
                .thenReturn(List.of());

        UUID supplierId = UUID.randomUUID();
        service.expectations(1, 20, "", "", supplierId);

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        // 计数（queryForObject）与列表（query）两条 SQL 同口径叠加 supplier 过滤，
        // 翻页总数不漂移。
        verify(jdbc).queryForObject(
                sql.capture(), eq(Long.class), any(Object[].class));
        assertThat(sql.getValue()).contains("expectation.supplier_id = ?");
        verify(jdbc, org.mockito.Mockito.atLeastOnce()).query(
                sql.capture(), ArgumentMatchers.<RowMapper<Object>>any(), any(Object[].class));
        assertThat(sql.getAllValues()).anySatisfy(statement -> assertThat(statement)
                .contains("expectation.supplier_id = ?"));
    }

    private static ProcurementArrivalControlService service(JdbcTemplate jdbc) {
        return new ProcurementArrivalControlService(
                jdbc,
                mock(ObjectMapper.class),
                mock(BusinessEventPublisher.class),
                mock(SecurityContextCurrentUser.class),
                mock(TxSessionVars.class),
                mock(FinanceReviewerEligibilityPort.class),
                mock(ReceiptPriceMasker.class),
                mock(ProcurementMutationLocks.class));
    }
}
