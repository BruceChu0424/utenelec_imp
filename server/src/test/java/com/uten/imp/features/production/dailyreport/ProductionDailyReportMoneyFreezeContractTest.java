package com.uten.imp.features.production.dailyreport;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * ADR-046 最低验收矩阵「客户端金额拒绝」项的服务端契约：
 * 日报只记录数量事实，单价/金额在写入口即被拒绝，且拒绝先于任何明细持久化。
 */
class ProductionDailyReportMoneyFreezeContractTest {

    @Test
    void saveItemsRejectsClientMoneyBeforePersistingAnything() throws IOException {
        String service = source(
                "src/main/java/com/uten/imp/features/production/dailyreport/"
                        + "ProductionDailyReportService.java");

        int guard = service.indexOf("line.getPrice() != null");
        int rejection = service.indexOf("已停止写入");
        int firstPersist = service.indexOf("new ProductionDailyReportItem()");

        assertThat(guard).isGreaterThanOrEqualTo(0);
        assertThat(rejection).isGreaterThanOrEqualTo(0);
        assertThat(firstPersist).isGreaterThanOrEqualTo(0);
        assertThat(guard).isLessThan(firstPersist);
        assertThat(rejection).isLessThan(firstPersist);
        assertThat(service)
                .contains("ErrorCode.VALIDATION_FAILED")
                .contains("line.getTotal() != null || line.getStotal() != null");
    }

    private static String source(String serverRelativePath) throws IOException {
        Path direct = Path.of(serverRelativePath);
        Path path = Files.exists(direct) ? direct : Path.of("server").resolve(serverRelativePath);
        return Files.readString(path.normalize(), StandardCharsets.UTF_8);
    }
}
