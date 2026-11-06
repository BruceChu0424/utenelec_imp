package com.uten.imp.features.subcontract.short_delivery;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.features.subcontract.SubcontractDocumentAccessPolicy;
import com.uten.imp.features.subcontract.order.SubcontractOrderService;
import com.uten.imp.features.subcontract.plan.SubcontractMaterialPlanService;
import com.uten.imp.features.subcontract.waste.SubcontractWasteService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.ResultSetExtractor;
import org.springframework.jdbc.core.RowCallbackHandler;
import org.springframework.jdbc.core.RowMapper;

import java.math.BigDecimal;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.argThat;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.RETURNS_SELF;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/** Maximum material allowance never automatically settles a finished-product shortfall. */
class SubcontractShortDeliveryAutoSettleTest {

    private static final UUID RECEIPT_ID = UUID.randomUUID();
    private static final UUID ORDER_ID = UUID.randomUUID();
    private static final UUID ITEM_ID = UUID.randomUUID();
    private static final UUID CASE_ID = UUID.randomUUID();
    private static final UUID OWNER_EMPLOYEE = UUID.randomUUID();
    private static final UUID ACTOR_USER = UUID.randomUUID();
    private static final UUID ACTOR_EMPLOYEE = UUID.randomUUID();
    private static final UUID WASTE_ID = UUID.randomUUID();
    private static final String WAITING_NOTE = "分批到货后累计回厂已进入允许损耗范围, 系统按约定的允许损耗自动结案";
    private static final String PENDING_NOTE = "累计回厂已在本单允许损耗范围内, 系统按约定的允许损耗自动结案";

    private FakeJdbc jdbc;
    private SubcontractWasteService waste;
    private SubcontractOrderService orders;
    private BusinessEventPublisher events;
    private SubcontractShortDeliveryService service;

    @BeforeEach
    void setUp() {
        jdbc = new FakeJdbc();
        waste = mock(SubcontractWasteService.class);
        orders = mock(SubcontractOrderService.class);
        events = mock(BusinessEventPublisher.class);
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        when(currentUser.requireId()).thenReturn(ACTOR_USER);
        when(currentUser.requireEmployeeId()).thenReturn(ACTOR_EMPLOYEE);
        SubcontractMaterialPlanService plans = mock(SubcontractMaterialPlanService.class);
        when(plans.minimumOrderQtyFromIssued(eq(ITEM_ID), any())).thenReturn(new BigDecimal("1000"));
        when(waste.recordShortDeliveryLoss(any(), any(), any(), any())).thenReturn(WASTE_ID);
        EntityManager em = mock(EntityManager.class);
        Query closure = mock(Query.class, RETURNS_SELF);
        when(em.createNativeQuery(anyString())).thenReturn(closure);
        service = new SubcontractShortDeliveryService(jdbc, em, mock(TxSessionVars.class),
                currentUser, events, mock(SubcontractDocumentAccessPolicy.class), waste, orders, plans,
                mock(EmployeeNameResolver.class), new ObjectMapper());
    }

    @Test
    void waitingMoreAtTheHistoricalToleranceStillNeedsTheFinishedTarget() {
        jdbc.openStatus = "WAITING_MORE";
        jdbc.delivered = new BigDecimal("950");
        service.settleAfterStockIn(RECEIPT_ID);
        assertNull(jdbc.find("SET status = 'ACCEPTED_LOSS'"));
        verify(waste, never()).recordShortDeliveryLoss(any(), any(), any(), any());
        verify(orders, never()).changeQtyForShortDeliveryBySystem(any(), any());
        verify(events, never()).publishOnce(eq(SubcontractShortDeliveryService.EVENT_RESOLVED),any(),any(),any(),any());
    }

    @Test
    void pendingOwnerAt900Of1000CannotBeAutomaticallyClosedByTheMaterialBudget() {
        jdbc.openStatus = "PENDING_OWNER";
        jdbc.delivered = new BigDecimal("900");
        service.settleAfterStockIn(RECEIPT_ID);
        assertNull(jdbc.find("SET status = 'ACCEPTED_LOSS'"));
        verify(waste, never()).recordShortDeliveryLoss(any(), any(), any(), any());
        verify(orders, never()).changeQtyForShortDelivery(any(), any());
    }

    @Test
    void supplyLossAllowanceDoesNotAutomaticallyAcceptASecondFinishedGoodsShortfall() {
        jdbc.openStatus = "PENDING_OWNER";
        jdbc.delivered = new BigDecimal("900");
        jdbc.normalLossSupplied = true;

        service.settleAfterStockIn(RECEIPT_ID);

        assertNull(jdbc.find("SET status = 'ACCEPTED_LOSS'"), "已为损耗加料的1000目标不能到900自动结案");
        verify(waste, never()).recordShortDeliveryLoss(any(), any(), any(), any());
    }

    @Test
    void waitingMoreCaseStillBelowFloorStaysOpen() {
        jdbc.openStatus = "WAITING_MORE";
        jdbc.delivered = new BigDecimal("890");

        service.settleAfterStockIn(RECEIPT_ID);

        assertNull(jdbc.find("SET status = 'ACCEPTED_LOSS'"), "累计 890 < 成品目标1000, 继续分批等待");
        verify(orders, never()).changeQtyForShortDeliveryBySystem(any(), any());
        verify(waste, never()).recordShortDeliveryLoss(any(), any(), any(), any());
    }

    @Test
    void closedPlanWithoutAnyArrivalOpensNothing() {
        jdbc.openStatus = null;
        jdbc.delivered = BigDecimal.ZERO;

        service.settleAfterMaterialIssueClosed(List.of(ITEM_ID));

        assertTrue(jdbc.updates.isEmpty(), "没有回厂就没有可判的短交, 不开案件也不发通知: " + jdbc.updates);
        verify(events, never()).publishOnce(any(), any(), any(), any(), any());
    }

    @Test
    void closedPlanBelowTheFinishedTargetOpensAnOwnerCaseWithoutInventingDeliveredProducts() {
        jdbc.openStatus = null;
        jdbc.delivered = new BigDecimal("950");

        service.settleAfterMaterialIssueClosed(List.of(ITEM_ID));

        int opened = jdbc.indexOf("INSERT INTO subcontract_short_delivery_cases");
        assertTrue(opened >= 0, "关计划即算料发完, 已回厂 950 的行要补开案件");
        Object[] insertArgs = jdbc.updateArgs.get(opened);
        assertNull(insertArgs[10], "关计划那条路没有收货单, receipt_id 记空");
        assertNull(insertArgs[11]);
        assertNull(jdbc.find("SET status = 'ACCEPTED_LOSS'"));
        assertEquals("BELOW_FLOOR",insertArgs[16]);
        verify(waste, never()).recordShortDeliveryLoss(any(),any(),any(),any());
        verify(orders, never()).changeQtyForShortDeliveryBySystem(any(), any());
        verify(orders, never()).changeQtyForShortDelivery(any(), any());
    }

    @Test
    void closedPlanWithEmptyIdsIsANoOp() {
        service.settleAfterMaterialIssueClosed(List.of());
        assertTrue(jdbc.updates.isEmpty());
        assertFalse(jdbc.factsLoaded);
    }

    /** 只桩自动结案需要的事实读取与案件写入；本夹具的全部回厂量均已合格入库。 */
    private static final class FakeJdbc extends JdbcTemplate {
        String openStatus;
        BigDecimal delivered = BigDecimal.ZERO;
        boolean factsLoaded;
        boolean normalLossSupplied;
        final List<String> updates = new ArrayList<>();
        final List<Object[]> updateArgs = new ArrayList<>();

        @Override
        @SuppressWarnings("unchecked")
        public <T> List<T> queryForList(String sql, Class<T> elementType, Object... args) {
            return (List<T>) List.of(ITEM_ID);
        }

        @Override
        public <T> T queryForObject(String sql, Class<T> requiredType, Object... args) {
            if (requiredType == BigDecimal.class && sql.contains("inspection.warehouse_stocked_base_qty")) {
                return requiredType.cast(delivered);
            }
            throw new AssertionError("Unsupported fixture query: " + sql);
        }

        @Override
        public <T> List<T> query(String sql, RowMapper<T> rowMapper, Object... args) {
            factsLoaded = true;
            try {
                return List.of(rowMapper.mapRow(factRow(), 0));
            } catch (SQLException e) {
                throw new IllegalStateException(e);
            }
        }

        @Override
        public void query(String sql, RowCallbackHandler rch, Object... args) {
            if (openStatus == null) return;
            try {
                rch.processRow(caseRow());
            } catch (SQLException e) {
                throw new IllegalStateException(e);
            }
        }

        @Override
        public <T> T query(String sql, ResultSetExtractor<T> rse, Object... args) {
            try {
                ResultSet rs = mock(ResultSet.class);
                when(rs.next()).thenReturn(false);
                return rse.extractData(rs);
            } catch (SQLException e) {
                throw new IllegalStateException(e);
            }
        }

        @Override
        public int update(String sql, Object... args) {
            updates.add(sql);
            updateArgs.add(args);
            if (sql.contains("INSERT INTO subcontract_short_delivery_cases")) openStatus = "PENDING_OWNER";
            if (sql.contains("SET status = 'ACCEPTED_LOSS'")) openStatus = "ACCEPTED_LOSS";
            return 1;
        }

        int indexOf(String fragment) {
            for (int i = 0; i < updates.size(); i++) {
                if (updates.get(i).contains(fragment)) return i;
            }
            return -1;
        }

        String find(String fragment) {
            int index = indexOf(fragment);
            return index < 0 ? null : updates.get(index);
        }

        String acceptedLossSql() {
            String sql = find("SET status = 'ACCEPTED_LOSS'");
            if (sql == null) throw new AssertionError("expected ACCEPTED_LOSS update, got " + updates);
            return sql;
        }

        Object[] acceptedLossArgs() {
            acceptedLossSql();
            return updateArgs.get(indexOf("SET status = 'ACCEPTED_LOSS'"));
        }

        private ResultSet factRow() throws SQLException {
            ResultSet rs = mock(ResultSet.class);
            when(rs.getObject(1, UUID.class)).thenReturn(ITEM_ID);
            when(rs.getObject(2, UUID.class)).thenReturn(ORDER_ID);
            when(rs.getString(3)).thenReturn("EO202609220001");
            when(rs.getObject(4, UUID.class)).thenReturn(UUID.randomUUID());
            when(rs.getObject(5, UUID.class)).thenReturn(OWNER_EMPLOYEE);
            when(rs.getObject(6, UUID.class)).thenReturn(OWNER_EMPLOYEE);
            when(rs.getObject(7, UUID.class)).thenReturn(UUID.randomUUID());
            when(rs.getObject(8, UUID.class)).thenReturn(null);
            when(rs.getObject(9, UUID.class)).thenReturn(UUID.randomUUID());
            when(rs.getString(10)).thenReturn("V51043");
            when(rs.getString(11)).thenReturn("E极插套(酸洗)");
            when(rs.getString(12)).thenReturn(null);
            when(rs.getString(13)).thenReturn("件");
            when(rs.getObject(14)).thenReturn(1);
            when(rs.getInt(14)).thenReturn(1);
            when(rs.getBigDecimal(15)).thenReturn(new BigDecimal("1000"));
            when(rs.getBigDecimal(16)).thenReturn(new BigDecimal("10"));
            when(rs.getBigDecimal(17)).thenReturn(BigDecimal.ONE);
            when(rs.getBigDecimal(18)).thenReturn(delivered);
            when(rs.getBoolean(19)).thenReturn(true);
            when(rs.getBigDecimal(20)).thenReturn(BigDecimal.ZERO);
            when(rs.getBoolean(21)).thenReturn(normalLossSupplied);
            return rs;
        }

        private ResultSet caseRow() throws SQLException {
            ResultSet rs = mock(ResultSet.class);
            when(rs.getObject("order_item_id", UUID.class)).thenReturn(ITEM_ID);
            when(rs.getObject("id", UUID.class)).thenReturn(CASE_ID);
            when(rs.getString("status")).thenReturn(openStatus);
            when(rs.getObject("expected_complete_by", LocalDate.class))
                    .thenReturn("WAITING_MORE".equals(openStatus) ? LocalDate.now().plusDays(7) : null);
            when(rs.getLong("version")).thenReturn(3L);
            when(rs.getObject("owner_employee_id", UUID.class)).thenReturn(OWNER_EMPLOYEE);
            return rs;
        }
    }
}
