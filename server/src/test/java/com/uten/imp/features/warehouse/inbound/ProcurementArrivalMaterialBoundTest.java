package com.uten.imp.features.warehouse.inbound;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.FinanceReviewerEligibilityPort;
import com.uten.imp.common.concurrency.ProcurementMutationLocks;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.purchase.receipt.ReceiptPriceMasker;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;

import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.math.BigDecimal;
import java.util.Arrays;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;

/**
 * ADR-143 §三.6：委外回厂上限被「委外商用我方已发直属物料能做成的套数」压住时(含与财务批准
 * 剩余量**相等**)按「委外商自带料」措辞。全发时两者恰好相等, 严格小于会让它永远落到
 * 「超过财务批准可收量」那句, 财务看不出多出来的是委外商自己的料。
 *
 * <p>ADR-144 §2.2：采购到货容量拆成 欠交 owed / 容差 tolerance(允许超收量剩余) / 质检补回
 * replacement 三份；来源歧义只看 owed 与 replacement 同时为正；按 补回、欠交、容差 的顺序消耗。
 */
class ProcurementArrivalMaterialBoundTest {

    @Test
    void suppliedEqualToFinanceRemainingIsMaterialBound() throws Exception {
        Capacity capacity = subcontract("1000", "0", "1000");
        assertTrue(capacity.materialBound(), "1:1 全发: 供料上限 = 财务批准剩余量, 仍按自带料措辞");
        assertEquals(0, new BigDecimal("1000").compareTo(capacity.owed()));
    }

    @Test
    void suppliedBelowFinanceRemainingIsMaterialBound() throws Exception {
        Capacity capacity = subcontract("1000", "0", "900");
        assertTrue(capacity.materialBound());
        assertEquals(0, new BigDecimal("900").compareTo(capacity.owed()), "上限压到实际供料量");
    }

    @Test
    void suppliedAboveFinanceRemainingKeepsFinanceWording() throws Exception {
        Capacity capacity = subcontract("1000", "0", "1100");
        assertFalse(capacity.materialBound(), "料发多了, 压住上限的是财务批准量, 不是供料");
        assertEquals(0, new BigDecimal("1000").compareTo(capacity.owed()));
    }

    @Test
    void partiallyReceivedLineComparesRemainingNotTotals() throws Exception {
        Capacity capacity = subcontract("1000", "800", "1000");
        assertTrue(capacity.materialBound(), "已收 800: 供料剩 200 = 财务剩 200, 同样相等同样自带料");
        assertEquals(0, new BigDecimal("200").compareTo(capacity.owed()));
    }

    /** ADR-143 §二.3：没有领料计划行的明细可回厂套数按 0 计(fail-closed)，没有「委外商自备料」豁免。 */
    @Test
    void itemWithoutPlanLinesFailsClosedAndSendsEverythingToFinance() throws Exception {
        Capacity capacity = subcontract("1000", "0", "0");
        assertTrue(capacity.materialBound(), "没有计划行 = 我方没发料, 交回的全部按委外商自带料转财务");
        assertEquals(0, capacity.owed().signum());
        assertEquals(0, capacity.available().signum());
        assertEquals(0, capacity.tolerance().signum(), "委外没有允许超收量");
    }

    @Test
    void purchaseOrderIsNeverMaterialBound() throws Exception {
        Capacity capacity = purchase("1000", "1000", "0", null);
        assertFalse(capacity.materialBound());
        assertEquals(0, new BigDecimal("1000").compareTo(capacity.available()));
        assertEquals(0, capacity.tolerance().signum(), "比例为空 = 0, 与原严格口径一致");
    }

    @Test
    void purchaseToleranceIsTheOnlyRoomOnceTheOrderQuantityIsReceived() throws Exception {
        // Q=100, p=5%: T = 5。收满 100 后还能收 5; 已收 103 后只剩 2。
        Capacity full = purchase("100", "100", "100", "5");
        assertEquals(0, full.owed().signum());
        assertEquals(0, new BigDecimal("5").compareTo(full.available()));
        Capacity over = purchase("100", "100", "103", "5");
        assertEquals(0, new BigDecimal("2").compareTo(over.available()));
        Capacity partial = purchase("100", "100", "60", "5");
        assertEquals(0, new BigDecimal("40").compareTo(partial.owed()));
        assertEquals(0, new BigDecimal("45").compareTo(partial.available()), "欠交 40 + 容差 5");
    }

    @Test
    void purchaseIqcReturnIsAReplacementAndIsConsumedBeforeTheTolerance() throws Exception {
        // 收满 100, 质检不合格 10 已实物退回: 欠交 0, 补回 10, 容差 5。自动来源不 409, 按补回。
        CapacityProbe probe = probe("PURCHASE", "100", "100", "100", "5", "0", "10");
        assertEquals(0, new BigDecimal("15").compareTo(probe.available(null)));
        probe.consume(null, new BigDecimal("10"));
        assertEquals(0, new BigDecimal("5").compareTo(probe.available(null)),
                "先吃补回 10, 容差 5 原样留着");
    }

    @Test
    void owedAndReplacementTogetherNeedAnExplicitSource() throws Exception {
        // 已收 90(欠交 10) 且质检退回 10 待补: 两份同时为正, 自动来源必须 409 让人选。
        CapacityProbe probe = probe("PURCHASE", "100", "100", "90", "5", "0", "10");
        InvocationTargetException ambiguous =
                assertThrows(InvocationTargetException.class, () -> probe.available(null));
        assertInstanceOf(ApiException.class, ambiguous.getCause());
        assertEquals(0, new BigDecimal("15").compareTo(probe.available("NORMAL")), "欠交 10 + 容差 5");
        assertEquals(0, new BigDecimal("25").compareTo(probe.available("RETURN_REPLACEMENT")));
    }

    private record Capacity(BigDecimal owed, BigDecimal tolerance, BigDecimal available, boolean materialBound) {}

    private static Capacity subcontract(String financeApproved, String received, String supplied)
            throws Exception {
        return probe("SUBCONTRACT", "1000", financeApproved, received, null, supplied, "0").snapshot();
    }

    private static Capacity purchase(String orderQty, String financeApproved, String received, String pct)
            throws Exception {
        return probe("PURCHASE", orderQty, financeApproved, received, pct, "0", "0").snapshot();
    }

    /** 反射调私有 arrivalCapacity(ArrivalRow, orderType), 再读写返回的私有 ArrivalCapacity。 */
    private static CapacityProbe probe(String orderType, String orderQty, String financeApproved,
                                       String received, String pct, String supplied,
                                       String returnedIqcFailure) throws Exception {
        CapacityJdbc jdbc = new CapacityJdbc(new BigDecimal(supplied), new BigDecimal(returnedIqcFailure));
        ProcurementArrivalControlService service = new ProcurementArrivalControlService(
                jdbc,
                new ObjectMapper(),
                mock(BusinessEventPublisher.class),
                mock(SecurityContextCurrentUser.class),
                mock(TxSessionVars.class),
                mock(FinanceReviewerEligibilityPort.class),
                mock(ReceiptPriceMasker.class),
                mock(ProcurementMutationLocks.class));
        Class<?> rowType = Arrays.stream(ProcurementArrivalControlService.class.getDeclaredClasses())
                .filter(candidate -> candidate.getSimpleName().equals("ArrivalRow"))
                .findFirst().orElseThrow();
        Constructor<?> rowConstructor = rowType.getDeclaredConstructors()[0];
        rowConstructor.setAccessible(true);
        Object row = rowConstructor.newInstance(
                UUID.randomUUID(), UUID.randomUUID(), "RC-1",
                UUID.randomUUID(), UUID.randomUUID(), "EO-1",
                null, null, null, null,
                UUID.randomUUID(), null, null,
                null, null, null,
                new BigDecimal("1050"), new BigDecimal(orderQty), new BigDecimal(received), BigDecimal.ZERO,
                new BigDecimal(financeApproved),
                null, null, null, null,
                pct == null ? null : new BigDecimal(pct));
        Method arrivalCapacity = ProcurementArrivalControlService.class
                .getDeclaredMethod("arrivalCapacity", rowType, String.class);
        arrivalCapacity.setAccessible(true);
        return new CapacityProbe(arrivalCapacity.invoke(service, row, orderType));
    }

    private record CapacityProbe(Object capacity) {
        BigDecimal available(String intent) throws Exception {
            Method available = capacity.getClass().getDeclaredMethod("available", String.class);
            available.setAccessible(true);
            return (BigDecimal) available.invoke(capacity, intent);
        }

        void consume(String intent, BigDecimal quantity) throws Exception {
            Method consume = capacity.getClass().getDeclaredMethod("consume", String.class, BigDecimal.class);
            consume.setAccessible(true);
            consume.invoke(capacity, intent, quantity);
        }

        Capacity snapshot() throws Exception {
            return new Capacity((BigDecimal) field("owed"), (BigDecimal) field("tolerance"),
                    available("NORMAL"), (Boolean) field("materialBound"));
        }

        private Object field(String name) throws Exception {
            Field field = capacity.getClass().getDeclaredField(name);
            field.setAccessible(true);
            return field.get(capacity);
        }
    }

    /**
     * arrivalCapacity 走 queryForObject 标量查询与一条供料上限列表查询, 按 SQL 片段分发。
     * 委外明细总能查到一行; 没有计划行时 fn_subcontract_returnable_qty 为 0。
     */
    private static final class CapacityJdbc extends JdbcTemplate {
        private final BigDecimal supplied;
        private final BigDecimal returnedIqcFailure;

        private CapacityJdbc(BigDecimal supplied, BigDecimal returnedIqcFailure) {
            this.supplied = supplied;
            this.returnedIqcFailure = returnedIqcFailure;
        }

        @Override
        public <T> T queryForObject(String sql, Class<T> requiredType, Object... args) {
            if (sql.contains("procurement_iqc_replacement_allocations")) return requiredType.cast(BigDecimal.ZERO);
            if (sql.contains("procurement_iqc_rejection_cases")) return requiredType.cast(returnedIqcFailure);
            // ADR-114(V688): 委外行已独立结清的损耗量从可到货上限里扣掉; 本用例无损耗。
            if (sql.contains("fn_subcontract_settled_loss_qty")) return requiredType.cast(BigDecimal.ZERO);
            throw new IllegalStateException("unexpected scalar query: " + sql);
        }

        @Override
        @SuppressWarnings("unchecked")
        public <T> List<T> query(String sql, RowMapper<T> rowMapper, Object... args) {
            if (sql.contains("fn_subcontract_returnable_qty")) {
                return List.of((T) supplied);
            }
            throw new IllegalStateException("unexpected list query: " + sql);
        }
    }
}
