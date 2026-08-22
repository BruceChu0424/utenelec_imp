package com.uten.imp.features.finance.payables;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ProcurementPayablesAmountSqlContractTest {

    @Test
    void summarySeparatesCashBookFxAndOffsetWithoutBreakingTheSelectList() throws Exception {
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/finance/payables/ProcurementPayablesService.java"))
                .replace("\r\n", "\n");

        assertThat(source)
                .doesNotContain("CASE WHEN ledger.open_item_kind = 'PAYABLE'\n"
                        + "                    COALESCE(SUM(CASE WHEN ledger.open_item_kind = 'PAYABLE'")
                .contains("THEN ledger.amount_received_local-ledger.amount_settled")
                .contains("THEN GREATEST(ledger.amount_offset_local, 0) ELSE 0 END), 0)");
    }
}
