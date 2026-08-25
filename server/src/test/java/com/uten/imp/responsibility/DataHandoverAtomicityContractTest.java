package com.uten.imp.responsibility;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class DataHandoverAtomicityContractTest {

    @Test
    void blockerCheckAndIdempotentReplayPrecedeEveryBatchWrite() throws Exception {
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/responsibility/DataHandoverService.java"),
                StandardCharsets.UTF_8);

        int transaction = source.indexOf(
                "@Transactional(isolation = Isolation.REPEATABLE_READ)\n"
                        + "    public DataHandoverResult executeManual");
        int coordinator = source.indexOf("handoverCoordinatorLock()", transaction);
        int advisoryLock = source.indexOf("advisoryLock(request.requestId())", coordinator);
        int replay = source.indexOf("Optional<DataHandoverResult> replay = replay(");
        int blocker = source.indexOf(
                "requireNoBlockers(preview, \"数据交接被阻止：\")", replay);
        int batchInsert = source.indexOf("INSERT INTO employee_data_handovers");
        int transfer = source.indexOf("applyTransfers(");

        assertThat(transaction).isGreaterThan(0);
        assertThat(coordinator).isGreaterThan(transaction);
        assertThat(advisoryLock).isGreaterThan(coordinator);
        assertThat(replay).isGreaterThan(advisoryLock);
        assertThat(blocker).isGreaterThan(replay);
        assertThat(batchInsert).isGreaterThan(blocker);
        assertThat(transfer).isGreaterThan(batchInsert);
        assertThat(source).contains(
                "requestId 已用于不同的数据交接请求",
                "数据交接被阻止：",
                "Set<String> graphScopes = effectiveGraphScopes(preview, scopes)",
                "requested_scopes",
                "for (String scope : graphScopes)",
                "throw conflict(\"交接预览后数据已变化");
    }
}
