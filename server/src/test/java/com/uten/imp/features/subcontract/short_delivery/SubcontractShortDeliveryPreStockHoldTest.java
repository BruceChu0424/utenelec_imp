package com.uten.imp.features.subcontract.short_delivery;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.concurrency.FulfillmentMutationLocks;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.SubcontractPreStockReleasePort;
import com.uten.imp.common.concurrency.ProcurementMutationLocks;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.subcontract.SubcontractDocumentAccessPolicy;
import com.uten.imp.features.subcontract.order.SubcontractOrderService;
import com.uten.imp.features.subcontract.plan.SubcontractMaterialPlanService;
import com.uten.imp.features.subcontract.short_delivery.SubcontractShortDeliveryContracts.CaseDetail;
import com.uten.imp.features.subcontract.short_delivery.SubcontractShortDeliveryContracts.DecisionRequest;
import com.uten.imp.features.subcontract.waste.SubcontractWasteService;
import com.uten.imp.security.DocumentAccessPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.ResultSetExtractor;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.argThat;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.CALLS_REAL_METHODS;
import static org.mockito.Mockito.RETURNS_SELF;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.doReturn;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.mockito.Mockito.withSettings;

/**
 * ADR-098 × ADR-090(2026-10-05)：委外回厂走「先入库后质检」时短交待判定期间——
 * <ul>
 *   <li>入库闸按路线给两种说法: 先质检后入库仍是「货先留在待入库不要上架」; 先入库后质检说
 *       「货已上架, 等委外判定短交后才能转为可用库存」, 判定完成系统自动转入;</li>
 *   <li>判定(分批到货 / 接受损耗)先取「订货单 + 被扣住的先入库合格品」首次预锁, 再锁案件行;
 *       判定写完后同一事务经端口补做自动转正。</li>
 * </ul>
 * 真库全链见 businesschain/SubcontractPreStockShortDeliveryEndToEndTest。
 */
class SubcontractShortDeliveryPreStockHoldTest {

    private static final UUID RECEIPT_ID = UUID.randomUUID();
    private static final UUID ORDER_ID = UUID.randomUUID();
    private static final UUID ITEM_ID = UUID.randomUUID();
    private static final UUID CASE_ID = UUID.randomUUID();
    private static final UUID OWNER_EMPLOYEE = UUID.randomUUID();
    private static final UUID ACTOR_USER = UUID.randomUUID();
    private static final UUID ACTOR_EMPLOYEE = UUID.randomUUID();
    private static final UUID WASTE_ID = UUID.randomUUID();

    private final List<String> trace = new ArrayList<>();
    private FakeJdbc jdbc;
    private SubcontractWasteService waste;
    private ProcurementMutationLocks mutationLocks;
    private SubcontractPreStockReleasePort release;
    private SubcontractShortDeliveryService service;

    @BeforeEach
    void setUp() {
        jdbc = new FakeJdbc(trace);
        waste = mock(SubcontractWasteService.class);
        when(waste.recordShortDeliveryLoss(any(), any(), any(), any(), any(), any())).thenReturn(WASTE_ID);
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        when(currentUser.requireId()).thenReturn(ACTOR_USER);
        when(currentUser.requireEmployeeId()).thenReturn(ACTOR_EMPLOYEE);
        SubcontractDocumentAccessPolicy access = mock(SubcontractDocumentAccessPolicy.class);
        when(access.nativeReadScope(anyString(), anyString(), anyString()))
                .thenReturn(new DocumentAccessPolicy.NativeReadScope("TRUE", null, Set.of()));
        EntityManager em = mock(EntityManager.class);
        Query anyQuery = mock(Query.class, RETURNS_SELF);
        when(em.createNativeQuery(anyString())).thenReturn(anyQuery);
        Query detailQuery = mock(Query.class, RETURNS_SELF);
        when(detailQuery.getResultList()).thenAnswer(call -> {
            Object[] row = new Object[39];
            row[0] = CASE_ID;
            row[1] = ORDER_ID;
            row[3] = ITEM_ID;
            row[21] = jdbc.decidedStatus;
            row[38] = 4L;
            List<Object[]> rows = new ArrayList<>();
            rows.add(row);
            return rows;
        });
        when(em.createNativeQuery(argThat((String sql) -> sql != null && sql.contains("effective_status"))))
                .thenReturn(detailQuery);
        service = new SubcontractShortDeliveryService(jdbc, em, mock(TxSessionVars.class), currentUser,
                mock(BusinessEventPublisher.class), access, waste, mock(SubcontractOrderService.class),
                mock(SubcontractMaterialPlanService.class), mock(EmployeeNameResolver.class), new ObjectMapper());

        mutationLocks = mock(ProcurementMutationLocks.class);
        FulfillmentMutationLocks.Guard guard = mock(FulfillmentMutationLocks.Guard.class);
        doAnswer(call -> {
            trace.add("verify-prefix");
            return null;
        }).when(guard).verifyUnchanged();
        when(mutationLocks.subcontractShortDeliveryDecision(any(), any())).thenAnswer(call -> {
            trace.add("prefix:" + call.getArgument(0) + ":" + call.getArgument(1));
            return guard;
        });
        release = mock(SubcontractPreStockReleasePort.class);
        when(release.releaseHeldPreStock(any())).thenAnswer(call -> {
            trace.add("release:" + call.getArgument(0));
            return 1;
        });
        @SuppressWarnings("unchecked")
        ObjectProvider<SubcontractPreStockReleasePort> provider =
                mock(ObjectProvider.class, withSettings().defaultAnswer(CALLS_REAL_METHODS));
        doReturn(release).when(provider).getIfAvailable();
        ReflectionTestUtils.setField(service, "mutationLocks", mutationLocks);
        ReflectionTestUtils.setField(service, "preStockRelease", provider);
    }

    // ===================== 入库闸的两种说法 =====================

    @Test
    void preStockedHoldSaysTheGoodsAreShelvedAndConvertAfterTheDecision() {
        jdbc.holdRow = holdRow(false);

        String normal = service.stockInHoldReason(RECEIPT_ID);
        String preStocked = service.preStockedHoldReason(RECEIPT_ID);

        String fact = "委外订货单 EO202610050001 的「V5一开铁架 V51032」回厂比订货少 50 个(订 100 个, 累计到 50 个), "
                + "已通知委外判定是分批到货还是接受损耗; ";
        assertEquals(fact + "判定完成前这批先不入库, 货先留在待入库不要上架。", normal,
                "先质检后入库的说法保持原样(货还在待入库区)");
        assertEquals(fact + "货已上架, 等委外判定短交后才能转为可用库存; 判定完成系统自动转入, 仓库不用再点确认入库。",
                preStocked);
        assertFalse(preStocked.contains("不要上架"), "先入库后质检的货登记时已上架, 不能再叫仓库别上架");
        assertFalse(preStocked.contains("（") || preStocked.contains("）"), "新增文案括号一律半角");
    }

    @Test
    void overdueWaitIsNamedOnBothRoutes() {
        jdbc.holdRow = holdRow(true);

        assertTrue(service.stockInHoldReason(RECEIPT_ID).contains("此前判定的分批到货已过预计到齐日"));
        String preStocked = service.preStockedHoldReason(RECEIPT_ID);
        assertTrue(preStocked.contains("此前判定的分批到货已过预计到齐日"), preStocked);
        assertTrue(preStocked.contains("货已上架"), preStocked);
    }

    @Test
    void noPendingCaseMeansNoHoldOnEitherRoute() {
        jdbc.holdRow = null;

        assertNull(service.stockInHoldReason(RECEIPT_ID));
        assertNull(service.preStockedHoldReason(RECEIPT_ID));
        assertNull(service.preStockedHoldReason(null));
    }

    // ===================== 判定: 先预锁, 判定后补做转正 =====================

    @Test
    void waitMoreTakesTheDecisionPrefixBeforeTheCaseLockAndReleasesHeldPreStockAfterDeciding() {
        CaseDetail detail = service.decide(CASE_ID, new DecisionRequest(
                "WAIT_MORE", BusinessTime.today().plusDays(7), "委外商下周补齐", 3L));

        assertEquals("WAITING_MORE", detail.row().status());
        assertEquals(List.of(
                "head", "prefix:" + ORDER_ID + ":[" + ITEM_ID + "]", "verify-prefix", "lock-case",
                "facts", "update:WAITING_MORE", "release:[" + ITEM_ID + "]"), withoutEvents(),
                "订货单 + 被扣住的先入库合格品先预锁, 再锁案件; 判定写完才补做转正");
    }

    @Test
    void acceptLossSettlesFirstAndThenReleasesHeldPreStockInTheSameTransaction() {
        CaseDetail detail = service.decide(CASE_ID, new DecisionRequest(
                "ACCEPT_LOSS", null, "委外商确认只能交 50 个", 3L));

        assertEquals("ACCEPTED_LOSS", detail.row().status());
        List<String> steps = withoutEvents();
        assertEquals("prefix:" + ORDER_ID + ":[" + ITEM_ID + "]", steps.get(1));
        assertTrue(steps.indexOf("lock-case") > steps.indexOf("verify-prefix"), steps.toString());
        assertTrue(steps.indexOf("update:ACCEPTED_LOSS") < steps.indexOf("release:[" + ITEM_ID + "]"),
                "接受损耗写完才补做转正: " + steps);
        verify(waste).recordShortDeliveryLoss(eq(ITEM_ID), argThat(q -> q.compareTo(new BigDecimal("50")) == 0),
                argThat(q -> q.compareTo(new BigDecimal("5")) == 0), eq(new BigDecimal("5")), anyString(), any());
    }

    @Test
    void closedCaseIsRejectedWithoutReleasingAnything() {
        jdbc.caseStatus = "ACCEPTED_LOSS";

        ApiException closed = assertThrows(ApiException.class, () -> service.decide(CASE_ID,
                new DecisionRequest("WAIT_MORE", BusinessTime.today().plusDays(7), null, 3L)));

        assertEquals(ErrorCode.CONFLICT, closed.getCode());
        verify(release, never()).releaseHeldPreStock(any());
    }

    @Test
    void unknownCaseTakesNoPrefixAndReportsNotFound() {
        jdbc.caseExists = false;

        ApiException missing = assertThrows(ApiException.class, () -> service.decide(CASE_ID,
                new DecisionRequest("WAIT_MORE", BusinessTime.today().plusDays(7), null, 3L)));

        assertEquals(ErrorCode.NOT_FOUND, missing.getCode());
        verify(mutationLocks, never()).subcontractShortDeliveryDecision(any(), any());
        verify(release, never()).releaseHeldPreStock(any());
    }

    private List<String> withoutEvents() {
        return trace.stream().filter(step -> !step.startsWith("event")).toList();
    }

    private static Map<String, Object> holdRow(boolean overdue) {
        Map<String, Object> row = new LinkedHashMap<>();
        row.put("order_bill_no", "EO202610050001");
        row.put("goods_name", "V5一开铁架");
        row.put("goods_code", "V51032");
        row.put("unit_name", "个");
        row.put("ordered_qty", new BigDecimal("100.0000"));
        row.put("delivered_qty", new BigDecimal("50.0000"));
        row.put("shortfall_qty", new BigDecimal("50.0000"));
        row.put("overdue_wait", overdue);
        return row;
    }

    /** 只桩判定与入库闸需要的读写; 订货 100、允许损耗 5%、料已全发、累计回厂 50(严重短交)。 */
    private static final class FakeJdbc extends JdbcTemplate {
        private final List<String> trace;
        Map<String, Object> holdRow;
        boolean caseExists = true;
        String caseStatus = "PENDING_OWNER";
        String decidedStatus = "PENDING_OWNER";

        FakeJdbc(List<String> trace) {
            this.trace = trace;
        }

        @Override
        public List<Map<String, Object>> queryForList(String sql, Object... args) {
            return holdRow == null ? List.of() : List.of(holdRow);
        }

        @Override
        public <T> T query(String sql, ResultSetExtractor<T> rse, Object... args) {
            try {
                ResultSet rs = mock(ResultSet.class);
                if (sql.contains("SELECT order_id, order_item_id FROM subcontract_short_delivery_cases")) {
                    trace.add("head");
                    when(rs.next()).thenReturn(caseExists, false);
                    when(rs.getObject(1, UUID.class)).thenReturn(ORDER_ID);
                    when(rs.getObject(2, UUID.class)).thenReturn(ITEM_ID);
                } else if (sql.contains("FROM subcontract_short_delivery_cases WHERE id = ? FOR UPDATE")) {
                    trace.add("lock-case");
                    when(rs.next()).thenReturn(caseExists, false);
                    when(rs.getObject(1, UUID.class)).thenReturn(CASE_ID);
                    when(rs.getString(2)).thenReturn(caseStatus);
                    when(rs.getObject(3, UUID.class)).thenReturn(ITEM_ID);
                    when(rs.getObject(4, UUID.class)).thenReturn(ORDER_ID);
                    when(rs.getLong(5)).thenReturn(3L);
                    when(rs.getObject(6, UUID.class)).thenReturn(OWNER_EMPLOYEE);
                    when(rs.getString(7)).thenReturn("SEVERE");
                } else {
                    when(rs.next()).thenReturn(false);
                }
                return rse.extractData(rs);
            } catch (SQLException e) {
                throw new IllegalStateException(e);
            }
        }

        @Override
        public <T> List<T> query(String sql, RowMapper<T> rowMapper, Object... args) {
            if (!sql.contains("material_fully_issued")) return List.of();
            trace.add("facts");
            try {
                return List.of(rowMapper.mapRow(factRow(), 0));
            } catch (SQLException e) {
                throw new IllegalStateException(e);
            }
        }

        @Override
        public int update(String sql, Object... args) {
            if (sql.contains("SET status = 'WAITING_MORE'")) {
                trace.add("update:WAITING_MORE");
                decidedStatus = "WAITING_MORE";
            } else if (sql.contains("SET status = 'ACCEPTED_LOSS'")) {
                trace.add("update:ACCEPTED_LOSS");
                decidedStatus = "ACCEPTED_LOSS";
            } else {
                trace.add("event");
            }
            return 1;
        }

        private ResultSet factRow() throws SQLException {
            ResultSet rs = mock(ResultSet.class);
            when(rs.getObject(1, UUID.class)).thenReturn(ITEM_ID);
            when(rs.getObject(2, UUID.class)).thenReturn(ORDER_ID);
            when(rs.getString(3)).thenReturn("EO202610050001");
            when(rs.getObject(4, UUID.class)).thenReturn(UUID.randomUUID());
            when(rs.getObject(5, UUID.class)).thenReturn(OWNER_EMPLOYEE);
            when(rs.getObject(6, UUID.class)).thenReturn(OWNER_EMPLOYEE);
            when(rs.getObject(7, UUID.class)).thenReturn(UUID.randomUUID());
            when(rs.getObject(8, UUID.class)).thenReturn(null);
            when(rs.getObject(9, UUID.class)).thenReturn(UUID.randomUUID());
            when(rs.getString(10)).thenReturn("V51032");
            when(rs.getString(11)).thenReturn("V5一开铁架");
            when(rs.getString(12)).thenReturn(null);
            when(rs.getString(13)).thenReturn("个");
            when(rs.getObject(14)).thenReturn(1);
            when(rs.getInt(14)).thenReturn(1);
            when(rs.getBigDecimal(15)).thenReturn(new BigDecimal("100"));
            when(rs.getBigDecimal(16)).thenReturn(new BigDecimal("5"));
            when(rs.getBigDecimal(17)).thenReturn(BigDecimal.ONE);
            when(rs.getBigDecimal(18)).thenReturn(new BigDecimal("50"));
            when(rs.getBoolean(19)).thenReturn(true);
            when(rs.getBigDecimal(20)).thenReturn(BigDecimal.ZERO);
            return rs;
        }
    }
}
