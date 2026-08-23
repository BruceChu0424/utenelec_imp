package com.uten.imp.features.finance.payables;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class SupplierOpenItemOffsetSqlContractTest {

    @Test
    void offsetInsertHasOneColumnPerValueAndMatchesForwardConstraints() throws IOException {
        String service = Files.readString(Path.of("src", "main", "java", "com", "uten", "imp",
                "features", "finance", "payables", "SupplierOpenItemOffsetService.java"));
        int insert = service.indexOf("INSERT INTO supplier_open_item_offsets(");
        int values = service.indexOf("VALUES (", insert);
        int columnsEnd = service.lastIndexOf(')', values);
        int queryEnd = service.indexOf("\"\"\")", values);
        int valuesEnd = service.lastIndexOf(')', queryEnd);
        String columns = service.substring(
                insert + "INSERT INTO supplier_open_item_offsets(".length(), columnsEnd);
        String boundValues = service.substring(values + "VALUES (".length(), valuesEnd);

        assertThat(columns.split("resolution_id", -1)).hasSize(2);
        assertThat(columns.split("effective_date", -1)).hasSize(2);
        assertThat(fieldCount(columns)).isEqualTo(23);
        assertThat(fieldCount(boundValues)).isEqualTo(23);

        String batching = migration("V342__supplier_open_item_offset_batches.sql");
        String sequencing = migration("V368__supplier_claim_offset_stable_sequences.sql");
        String snapshots = migration("V365__supplier_offset_snapshot_shape_guard.sql");
        String rates = migration("V372__supplier_offset_rate_guard.sql");
        assertThat(batching).contains("offset_batch_id");
        assertThat(sequencing).contains("line_sequence", "UNIQUE(offset_batch_id,line_sequence)");
        assertThat(snapshots).contains(
                "source_balance_before_original", "target_balance_before_original");
        assertThat(rates).contains("source_rate", "target_rate");
    }

    private static int fieldCount(String value) {
        return 1 + (int) value.chars().filter(ch -> ch == ',').count();
    }

    private static String migration(String name) throws IOException {
        return Files.readString(Path.of("src", "main", "resources", "db", "migration", name));
    }
}
