package com.uten.imp.features.stock;

import com.uten.imp.features.subcontract.draw.SubcontractDrawRecheckQueue;
import org.junit.jupiter.api.Test;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Collection;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * ADR-143 §4.4 委外领料「重算可领」的唤醒收口到库存内核: 全系统只有
 * {@code StockService.recordMovementInternal} 的 DIR_IN 分支登记入库货色, 提交前交给委外模块追加一条
 * outbox 重算事件; 各入库单据不再自己调。实现只追加 outbox, 不读齐套、不加锁、不发通知。
 */
class SubcontractOutboundWakeHookContractTest {

    @Test
    void stockKernelEnqueuesDrawRecheckAfterBalanceUpsertInsideInboundBranch() throws Exception {
        String stock = source("features/stock/StockService.java");

        assertThat(stock)
                .contains("ObjectProvider<SubcontractOutboundWakePort> subcontractOutboundWake")
                .contains("subcontractOutboundWake.ifAvailable(")
                .contains("enqueueDrawRecheck(")
                .doesNotContain("wakeOutboundAfterStockIn(")
                .doesNotContain("catch (");
        assertOrdered(stock, "upsertBalance(", "enqueueDrawRecheck(");
        int branch = stock.lastIndexOf("if (req.direction() == DIR_IN) {");
        int wake = stock.indexOf("enqueueSubcontractWake(new");
        assertThat(branch).isGreaterThan(stock.indexOf("upsertBalance("));
        assertThat(wake).isGreaterThan(branch);
        assertThat(stock.substring(branch, wake)).doesNotContain("return ");
        assertThat(stock).contains("void beforeCommit(boolean readOnly)");
        int delivery = stock.indexOf("enqueueDrawRecheck(");
        assertThat(stock.indexOf("enqueueDrawRecheck(", delivery + 1)).isEqualTo(-1);
    }

    @Test
    void inboundDocumentsNoLongerWakeSubcontractThemselves() throws Exception {
        String iqc = source("features/warehouse/inbound/ProcurementIqcStockInService.java");

        assertThat(iqc)
                .contains("stockService.recordMovementWithId(")
                .doesNotContain("enqueueDrawRecheck(")
                .doesNotContain("SubcontractOutboundWakePort");
    }

    @Test
    void recheckQueueOnlyAppendsOutboxInsideTheCallerTransaction() throws Exception {
        Transactional transactional = SubcontractDrawRecheckQueue.class
                .getMethod("enqueueDrawRecheck", Collection.class)
                .getAnnotation(Transactional.class);
        assertThat(transactional).isNotNull();
        assertThat(transactional.propagation()).isEqualTo(Propagation.MANDATORY);

        String queue = source("features/subcontract/draw/SubcontractDrawRecheckQueue.java");
        assertThat(queue)
                .contains("publishOnce(")
                .contains("\"SC_DRAW_RECHECK:\" + transactionId")
                .doesNotContain("fn_subcontract_draw_summary")
                .doesNotContain("FOR UPDATE")
                .doesNotContain("lockAll(")
                .doesNotContain("chainNotice");
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
