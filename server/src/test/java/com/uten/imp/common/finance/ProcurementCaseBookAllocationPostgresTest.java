package com.uten.imp.common.finance;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.sql.DriverManager;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/** The case balance chain must use the same ordering as the database guard. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS", matches="(?i)true")
class ProcurementCaseBookAllocationPostgresTest {
    @Test void bothUuidSignBoundariesMatchDatabaseAndConserveTheFinalRemainder() throws Exception {
        List<UUID> ids=List.of(
                UUID.fromString("80000000-0000-0000-0000-000000000000"),
                UUID.fromString("00000000-0000-0000-8000-000000000000"),
                UUID.fromString("00000000-0000-0000-0000-000000000001"));
        var inputs=ids.stream().map(id->new ProcurementReceiptConsiderationService.CaseCreditInput(
                id,1,BigDecimal.ONE,BigDecimal.ONE)).toList();
        var allocated=ProcurementReceiptConsiderationService.caseBookAllocations(
                new BigDecimal("3"),new BigDecimal("100"),inputs);
        try(var database=new PostgreSQLContainer<>("postgres:16-alpine")) {
            database.start();
            try(var connection=DriverManager.getConnection(database.getJdbcUrl(),database.getUsername(),database.getPassword());
                var query=connection.prepareStatement("SELECT id FROM unnest(?::uuid[]) AS ids(id) ORDER BY id")) {
                query.setArray(1,connection.createArrayOf("uuid",ids.toArray()));
                List<UUID> databaseOrder=new ArrayList<>();
                try(var rows=query.executeQuery()){while(rows.next())databaseOrder.add(rows.getObject(1,UUID.class));}
                assertThat(allocated.stream().map(row->row.input().caseId()).toList()).isEqualTo(databaseOrder);
            }
        }
        assertThat(allocated.stream().map(ProcurementReceiptConsiderationService.CaseBookAllocation::amountLocal)
                .reduce(BigDecimal.ZERO,BigDecimal::add)).isEqualByComparingTo("100");
        for(int i=1;i<allocated.size();i++) {
            assertThat(allocated.get(i).beforeOriginal()).isEqualByComparingTo(allocated.get(i-1).afterOriginal());
            assertThat(allocated.get(i).beforeLocal()).isEqualByComparingTo(allocated.get(i-1).afterLocal());
        }
        assertThat(allocated.getLast().afterOriginal()).isZero();
        assertThat(allocated.getLast().afterLocal()).isZero();
        assertThat(allocated.getLast().amountLocal()).isGreaterThan(allocated.getFirst().amountLocal());
        assertThat(ProcurementReceiptConsiderationService.caseBookAllocations(
                new BigDecimal("3"),new BigDecimal("100"),inputs.reversed())).isEqualTo(allocated);
    }
}
