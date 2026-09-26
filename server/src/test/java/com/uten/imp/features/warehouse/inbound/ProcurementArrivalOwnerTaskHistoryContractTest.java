package com.uten.imp.features.warehouse.inbound;

import org.junit.jupiter.api.Test;

import java.lang.reflect.Method;
import java.lang.reflect.Parameter;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.LocalDate;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 2026-09-24 任务中心统一：待退回供应商任务页按任务中心范式分段（待退回 / 历史记录）。
 * 本契约锁住前后端接线的服务端一半：
 *  · /tasks 端点声明 status / dateFrom / dateTo / keyword 查询参数；
 *  · service 提供带这些参数的 ownerTasks 重载（缺省重载保持向后兼容）；
 *  · 历史口径 = return_task.status = 'COMPLETED'（时间门控走 completed_at::date）。
 */
class ProcurementArrivalOwnerTaskHistoryContractTest {

    @Test
    void tasksEndpointDeclaresSegmentAndHistoryParameters() throws Exception {
        Method tasks = ProcurementArrivalExceptionController.class
                .getDeclaredMethod(
                        "tasks",
                        String.class, String.class,
                        LocalDate.class, LocalDate.class,
                        String.class, int.class, int.class);
        assertThat(tasks).isNotNull();
        assertThat(tasks.getParameterCount()).isEqualTo(7);
    }

    @Test
    void serviceKeepsBackCompatibleOverloadAndHistoryOverload() {
        assertThat(ProcurementArrivalControlService.class.getDeclaredMethods())
                .extracting(m -> m.getName() + '/' + m.getParameterCount())
                .contains("ownerTasks/3", "ownerTasks/7");
    }

    @Test
    void historyPredicateStaysOnCompletedStatusWithDateGate() throws Exception {
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/warehouse/inbound/"
                        + "ProcurementArrivalControlService.java"));
        assertThat(source).contains("return_task.status = 'COMPLETED'");
        assertThat(source).contains("return_task.completed_at::date");
        // 缺省仍是待退回队列（向后兼容：不传 status 的旧调用方拿 PENDING_RETURN）。
        assertThat(source).contains("return_task.status = 'PENDING_RETURN'");
    }

    @Test
    void keywordCoversBillsGoodsAndSupplier() throws Exception {
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/warehouse/inbound/"
                        + "ProcurementArrivalControlService.java"));
        assertThat(source).contains("receipt_bill_no_snapshot");
        assertThat(source).contains("order_bill_no_snapshot");
        assertThat(source).contains("goods.name");
        assertThat(source).contains("supplier.name");
    }

    @Test
    void unusedParameterNamesStayStableForReadability() {
        // 参数个数变化会先在这里红，提醒同步前端 ownerTasks 调用。
        for (Method method : ProcurementArrivalControlService.class.getDeclaredMethods()) {
            if (method.getName().equals("ownerTasks") && method.getParameterCount() == 7) {
                Parameter[] params = method.getParameters();
                assertThat(params[3].getName()).isEqualTo("status");
                assertThat(params[4].getName()).isEqualTo("completedFrom");
                assertThat(params[5].getName()).isEqualTo("completedTo");
                assertThat(params[6].getName()).isEqualTo("keyword");
            }
        }
    }
}
