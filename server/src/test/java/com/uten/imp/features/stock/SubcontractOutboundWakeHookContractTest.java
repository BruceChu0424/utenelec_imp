package com.uten.imp.features.stock;

import com.uten.imp.features.subcontract.plan.SubcontractMaterialPlanService;
import org.junit.jupiter.api.Test;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * ADR-103 委外路线 B「子件到货即解锁」的唤醒收口到库存内核: 全系统只有
 * {@code StockService.recordMovementInternal} 的 DIR_IN 分支叫醒委外出仓, 各入库单据不再自己调。
 * 用源码顺序断言锁住「先写余额、再叫醒、且只在入库分支」这三件事, 防止后人把调用搬回单据层
 * 或挪到 upsertBalance 之前(那时可动用量还是旧的, 会算错可发数量)。
 */
class SubcontractOutboundWakeHookContractTest {

    @Test
    void stockKernelWakesSubcontractOutboundAfterBalanceUpsertInsideInboundBranch()
            throws Exception {
        String stock = source("features/stock/StockService.java");

        assertThat(stock)
                .contains("ObjectProvider<SubcontractOutboundWakePort> subcontractOutboundWake")
                .contains("subcontractOutboundWake.ifAvailable(")
                .contains("wakeOutboundAfterStockIn(")
                .doesNotContain("catch (");
        assertOrdered(stock, "upsertBalance(", "wakeOutboundAfterStockIn(");
        // Register only inbound dimensions, then wake before the same transaction commits.
        int branch = stock.lastIndexOf("if (req.direction() == DIR_IN) {");
        int wake = stock.indexOf("enqueueSubcontractWake(new");
        assertThat(branch).isGreaterThan(stock.indexOf("upsertBalance("));
        assertThat(wake).isGreaterThan(branch);
        assertThat(stock.substring(branch, wake)).doesNotContain("return ");
        assertThat(stock.indexOf("return m.getId();", wake)).isGreaterThan(wake);
        assertThat(stock).contains("void beforeCommit(boolean readOnly)");
        int delivery = stock.indexOf("wakeOutboundAfterStockIn(");
        assertThat(stock.indexOf("wakeOutboundAfterStockIn(", delivery + 1)).isEqualTo(-1);
    }

    @Test
    void inboundDocumentsNoLongerWakeSubcontractOutboundThemselves() throws Exception {
        String iqc = source("features/warehouse/inbound/ProcurementIqcStockInService.java");

        assertThat(iqc)
                .contains("stockService.recordMovementWithId(")
                .doesNotContain("wakeOutboundAfterStockIn(")
                .doesNotContain("SubcontractOutboundWakePort");
    }

    @Test
    void wakeImplementationRequiresTheInboundTransaction() throws Exception {
        Transactional transactional = SubcontractMaterialPlanService.class
                .getMethod("wakeOutboundAfterStockIn", List.class)
                .getAnnotation(Transactional.class);
        assertThat(transactional).isNotNull();
        assertThat(transactional.propagation()).isEqualTo(Propagation.MANDATORY);
    }

    private static void assertOrdered(String source, String first, String second) {
        assertThat(source.indexOf(first)).isGreaterThanOrEqualTo(0);
        assertThat(source.indexOf(second)).isGreaterThan(source.indexOf(first));
    }

    private static String source(String relative) throws Exception {
        return Files.readString(Path.of("src/main/java/com/uten/imp", relative),
                StandardCharsets.UTF_8);
    }
}
