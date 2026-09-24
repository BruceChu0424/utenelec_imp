package com.uten.imp.features.warehouse.inbound;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.FinanceReviewerEligibilityPort;
import com.uten.imp.common.concurrency.ProcurementMutationLocks;
import com.uten.imp.features.purchase.receipt.ReceiptPriceMasker;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;

import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.math.BigDecimal;
import java.util.Arrays;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;

/**
 * ADR-103 §2.5：委外回厂上限被「我方发出去的料」压住时(含与财务批准剩余量**相等**)按
 * 「委外商自带料」措辞。路线 B 子件:委外件 1:1 全发时两者恰好相等, 此前严格小于让它永远
 * 落到「超过财务批准可收量」那句, 财务看不出多出来的是委外商自己的料。
 */
class ProcurementArrivalMaterialBoundTest {

    @Test
    void suppliedEqualToFinanceRemainingIsMaterialBound() throws Exception {
        Capacity capacity = capacity("SUBCONTRACT", "1000", "0", "1000");
        assertTrue(capacity.materialBound(), "1:1 全发: 供料上限 = 财务批准剩余量, 仍按自带料措辞");
        assertEquals(0, new BigDecimal("1000").compareTo(capacity.normal()));
    }

    @Test
    void suppliedBelowFinanceRemainingIsMaterialBound() throws Exception {
        Capacity capacity = capacity("SUBCONTRACT", "1000", "0", "900");
        assertTrue(capacity.materialBound());
        assertEquals(0, new BigDecimal("900").compareTo(capacity.normal()), "上限压到实际供料量");
    }

    @Test
    void suppliedAboveFinanceRemainingKeepsFinanceWording() throws Exception {
        Capacity capacity = capacity("SUBCONTRACT", "1000", "0", "1100");
        assertFalse(capacity.materialBound(), "料发多了, 压住上限的是财务批准量, 不是供料");
        assertEquals(0, new BigDecimal("1000").compareTo(capacity.normal()));
    }

    @Test
    void partiallyReceivedLineComparesRemainingNotTotals() throws Exception {
        Capacity capacity = capacity("SUBCONTRACT", "1000", "800", "1000");
        assertTrue(capacity.materialBound(), "已收 800: 供料剩 200 = 财务剩 200, 同样相等同样自带料");
        assertEquals(0, new BigDecimal("200").compareTo(capacity.normal()));
    }

    @Test
    void legacyOrderWithoutOutboundPlanIsNeverMaterialBound() throws Exception {
        Capacity capacity = capacity("SUBCONTRACT", "1000", "0", null);
        assertFalse(capacity.materialBound(), "V304 之前的手工发料不受供料上限约束");
        assertEquals(0, new BigDecimal("1000").compareTo(capacity.normal()));
    }

    @Test
    void purchaseOrderIsNeverMaterialBound() throws Exception {
        Capacity capacity = capacity("PURCHASE", "1000", "0", "1000");
        assertFalse(capacity.materialBound());
    }

    private record Capacity(BigDecimal normal, boolean materialBound) {}

    /** 反射调私有 arrivalCapacity(ArrivalRow, orderType), 读私有 ArrivalCapacity 的两个字段。 */
    private static Capacity capacity(String orderType, String financeApproved, String received,
                                     String supplied) throws Exception {
        CapacityJdbc jdbc = new CapacityJdbc(supplied == null ? null : new BigDecimal(supplied));
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
                new BigDecimal("1050"), new BigDecimal("1000"), new BigDecimal(received), BigDecimal.ZERO,
                new BigDecimal(financeApproved),
                null, null, null, null);
        Method arrivalCapacity = ProcurementArrivalControlService.class
                .getDeclaredMethod("arrivalCapacity", rowType, String.class);
        arrivalCapacity.setAccessible(true);
        Object capacity = arrivalCapacity.invoke(service, row, orderType);
        Field normal = capacity.getClass().getDeclaredField("normal");
        normal.setAccessible(true);
        Field materialBound = capacity.getClass().getDeclaredField("materialBound");
        materialBound.setAccessible(true);
        return new Capacity((BigDecimal) normal.get(capacity), materialBound.getBoolean(capacity));
    }

    /** arrivalCapacity 只会走 queryForObject 五条标量查询, 按 SQL 片段分发。 */
    private static final class CapacityJdbc extends JdbcTemplate {
        private final BigDecimal supplied;

        private CapacityJdbc(BigDecimal supplied) {
            this.supplied = supplied;
        }

        @Override
        public <T> T queryForObject(String sql, Class<T> requiredType, Object... args) {
            if (requiredType == Boolean.class) return requiredType.cast(supplied != null);
            if (sql.contains("procurement_iqc_replacement_allocations")) return requiredType.cast(BigDecimal.ZERO);
            if (sql.contains("procurement_iqc_rejection_cases")) return requiredType.cast(BigDecimal.ZERO);
            if (sql.contains("subcontract_material_issue_items")) return requiredType.cast(supplied);
            // ADR-114(V688): 委外行已独立结清的损耗量从可到货上限里扣掉; 本用例无损耗。
            if (sql.contains("fn_subcontract_settled_loss_qty")) return requiredType.cast(BigDecimal.ZERO);
            throw new IllegalStateException("unexpected scalar query: " + sql);
        }
    }
}
