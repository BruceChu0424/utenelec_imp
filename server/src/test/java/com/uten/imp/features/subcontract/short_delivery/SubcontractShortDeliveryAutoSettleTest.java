package com.uten.imp.features.subcontract.short_delivery;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.OrderQtyChangeRequest;
import com.uten.imp.features.subcontract.SubcontractDocumentAccessPolicy;
import com.uten.imp.features.subcontract.order.SubcontractOrderService;
import com.uten.imp.features.subcontract.plan.SubcontractMaterialPlanService;
import com.uten.imp.features.subcontract.waste.SubcontractWasteService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
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
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * ADR-103 §2.5 容差内自动结案的状态覆盖(1000 / 10% / 料已全发)：
 * <ul>
 *   <li>「分批到货」判定后的 WAITING_MORE 案件, 最后一批把累计送进允许损耗范围 → 与 PENDING_OWNER
 *       一样当场按允许损耗结案, 结案备注区分两种来路, decision/decided_* 与人工「接受损耗」同款;</li>
 *   <li>累计仍低于下限的 WAITING_MORE 案件不动;</li>
 *   <li>仓库「不再出仓」关计划(没有本次到货)：一件都没回厂的行不开案件, 已回厂进容差的行
 *       补开案件(receipt_id 记空)并结案;</li>
 *   <li>自动结案走 changeQtyForShortDeliveryBySystem(不过属主守卫、不开财务复核)。</li>
 * </ul>
 * 真库全链见 SubcontractToleranceAutoSettleEndToEndTest / SubcontractSoleComponentUnlockEndToEndTest。
 */
class SubcontractShortDeliveryAutoSettleTest {

    private static final UUID RECEIPT_ID = UUID.randomUUID();
    private static final UUID ORDER_ID = UUID.randomUUID();
    private static final UUID ITEM_ID = UUID.randomUUID();
    private static final UUID CASE_ID = UUID.randomUUID();
    private static final UUID OWNER_EMPLOYEE = UUID.randomUUID();
    private static final UUID ACTOR_USER = UUID.randomUUID();
    private static final UUID ACTOR_EMPLOYEE = UUID.randomUUID();
    private static final UUID WASTE_ID = UUID.randomUUID();
    private static final UUID CHANGE_LOG_ID = UUID.randomUUID();
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
        when(waste.recordShortDeliveryLoss(any(), any(), any(), any(), any(), any(), any())).thenReturn(WASTE_ID);
        service = new SubcontractShortDeliveryService(jdbc, mock(EntityManager.class), mock(TxSessionVars.class),
                currentUser, events, mock(SubcontractDocumentAccessPolicy.class), waste, orders, plans,
                mock(EmployeeNameResolver.class), new ObjectMapper());
    }

    @Test
    void waitingMoreCaseEnteringToleranceSettlesLikePendingOwner() {
        jdbc.openStatus = "WAITING_MORE";
        jdbc.delivered = new BigDecimal("950");

        service.settleAfterStockIn(RECEIPT_ID);

        Object[] accepted = jdbc.acceptedLossArgs();
        assertEquals(WAITING_NOTE, accepted[0], "结案备注要说明这是分批到货之后累计进容差");
        assertEquals(ACTOR_USER, accepted[1]);
        assertEquals(ACTOR_EMPLOYEE, accepted[2], "decided_by 与人工接受损耗同款, 三列同非空过 V636 CHECK");
        assertEquals(0, new BigDecimal("50").compareTo((BigDecimal) accepted[3]), "loss_qty = 1000 - 950");
        assertEquals(CASE_ID, accepted[accepted.length - 1]);
        String sql = jdbc.acceptedLossSql();
        assertTrue(sql.contains("decision = 'ACCEPT_LOSS'"), sql);
        assertTrue(sql.contains("expected_complete_by = NULL"), "分批等待的预计到齐日随结案清空");
        assertTrue(sql.contains("status IN ('PENDING_OWNER', 'WAITING_MORE')"), "WAITING_MORE 案件必须能被这条 UPDATE 命中");
        verify(waste).recordShortDeliveryLoss(eq(ITEM_ID), eq(BigDecimal.ONE), argThat(q -> q.compareTo(new BigDecimal("50")) == 0),
                argThat(q -> q.compareTo(new BigDecimal("50")) == 0), eq(new BigDecimal("10")), anyString(), any());
        verify(orders).changeQtyForShortDeliveryBySystem(eq(ORDER_ID), argThat(request -> qtyOf(request).compareTo(new BigDecimal("950")) == 0));
        verify(orders, never()).changeQtyForShortDelivery(any(), any());
        verify(events).publishOnce(eq(SubcontractShortDeliveryService.EVENT_RESOLVED),
                eq(SubcontractShortDeliveryService.AGGREGATE_KIND), eq(CASE_ID), any(), anyString());
    }

    @Test
    void pendingOwnerCaseKeepsThePlainToleranceNote() {
        jdbc.openStatus = "PENDING_OWNER";
        jdbc.delivered = new BigDecimal("900");

        service.settleAfterStockIn(RECEIPT_ID);

        assertEquals(PENDING_NOTE, jdbc.acceptedLossArgs()[0]);
        verify(orders).changeQtyForShortDeliveryBySystem(eq(ORDER_ID), any());
    }

    @Test
    void waitingMoreCaseStillBelowFloorStaysOpen() {
        jdbc.openStatus = "WAITING_MORE";
        jdbc.delivered = new BigDecimal("890");

        service.settleAfterStockIn(RECEIPT_ID);

        assertNull(jdbc.find("SET status = 'ACCEPTED_LOSS'"), "累计 890 < 下限 900, 继续分批等待");
        verify(orders, never()).changeQtyForShortDeliveryBySystem(any(), any());
        verify(waste, never()).recordShortDeliveryLoss(any(), any(), any(), any(), any(), any(), any());
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
    void closedPlanWithArrivalInsideToleranceOpensCaseWithoutReceiptAndSettles() {
        jdbc.openStatus = null;
        jdbc.delivered = new BigDecimal("950");

        service.settleAfterMaterialIssueClosed(List.of(ITEM_ID));

        int opened = jdbc.indexOf("INSERT INTO subcontract_short_delivery_cases");
        assertTrue(opened >= 0, "关计划即算料发完, 已回厂 950 的行要补开案件");
        Object[] insertArgs = jdbc.updateArgs.get(opened);
        assertNull(insertArgs[10], "关计划那条路没有收货单, receipt_id 记空");
        assertNull(insertArgs[11]);
        assertEquals(PENDING_NOTE, jdbc.acceptedLossArgs()[0], "补开的是 PENDING_OWNER 案件, 随即按允许损耗结案");
        verify(orders).changeQtyForShortDeliveryBySystem(eq(ORDER_ID), any());
    }

    @Test
    void closedPlanWithEmptyIdsIsANoOp() {
        service.settleAfterMaterialIssueClosed(List.of());
        assertTrue(jdbc.updates.isEmpty());
        assertFalse(jdbc.factsLoaded);
    }

    private static BigDecimal qtyOf(OrderQtyChangeRequest request) {
        return request.items().getFirst().newQty();
    }

    /** 只桩短交服务在自动结案路径上真正会碰的五个 JdbcTemplate 入口, SQL 原样记下来供断言。 */
    private static final class FakeJdbc extends JdbcTemplate {
        String openStatus;
        BigDecimal delivered = BigDecimal.ZERO;
        boolean factsLoaded;
        final List<String> updates = new ArrayList<>();
        final List<Object[]> updateArgs = new ArrayList<>();

        @Override
        @SuppressWarnings("unchecked")
        public <T> List<T> queryForList(String sql, Class<T> elementType, Object... args) {
            return (List<T>) List.of(ITEM_ID);
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
                if (sql.contains("procurement_order_qty_change_logs")) {
                    when(rs.next()).thenReturn(true);
                    when(rs.getObject("id", UUID.class)).thenReturn(CHANGE_LOG_ID);
                } else {
                    when(rs.next()).thenReturn(false);
                }
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
