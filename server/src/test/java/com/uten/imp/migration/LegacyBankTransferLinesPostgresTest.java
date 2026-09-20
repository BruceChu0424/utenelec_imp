package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.sql.SQLException;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;

/** Existing bank history remains immutable even though the bootstrap rejects new nonempty M_Bank imports. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class LegacyBankTransferLinesPostgresTest {
    private static final PostgreSQLContainer<?> PG=new PostgreSQLContainer<>("postgres:16-alpine")
            .withUsername("uten").withPassword("synthetic-bank-history-only");
    private static final UUID HISTORY=UUID.randomUUID(),NATIVE=UUID.randomUUID(),OLD_LINE=UUID.randomUUID();
    private static JdbcTemplate jdbc;
    private static List<String> oldHeader,oldLines;

    @BeforeAll static void start() {
        PG.start();
        jdbc=new JdbcTemplate(new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword()));
        Flyway.configure().dataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword()).target("625").load().migrate();
        UUID currency=UUID.randomUUID(),style=UUID.randomUUID(),account=UUID.randomUUID();
        jdbc.update("INSERT INTO currencies(id,code,name,exchange_rate,status) VALUES (?,'BANK-HISTORY-CNY','人民币',1,'使用')",currency);
        jdbc.update("INSERT INTO payment_styles(id,code,name,category,level) VALUES (?,'BANK-HISTORY-STYLE','银行历史科目','ACCOUNT',0)",style);
        jdbc.update("INSERT INTO accounts(id,code,name,account_type,status,currency_id,style_id) VALUES (?,'BANK-HISTORY-ACCOUNT','银行历史账户','BANK','使用',?,?)",account,currency,style);
        jdbc.update("""
                INSERT INTO finance_bank_transfers(id,legacy_id,bill_no,bill_date,out_account_id,currency_id,exchange_rate,amount_original,amount_local,status)
                VALUES (?,906200,'YC20250102000001','2025-01-02',?,?,1,3,3,1),
                       (?,NULL,'YC20250102000002','2025-01-02',?,?,1,0,0,0)
                """,HISTORY,account,currency,NATIVE,account,currency);
        line(OLD_LINE,HISTORY,"YC20250102000001","3");
        oldHeader=rows("finance_bank_transfers","id",HISTORY);
        oldLines=rows("finance_bank_transfer_lines","transfer_id",HISTORY);
        Flyway.configure().dataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword()).load().migrate();
    }
    @AfterAll static void stop(){PG.stop();}

    @Test void legacyParentProtectsInsertEditDeleteAndBothRebindingDirectionsButNativeDraftLinesRemainMutable() {
        assertThat(rows("finance_bank_transfers","id",HISTORY)).isEqualTo(oldHeader);
        assertThat(rows("finance_bank_transfer_lines","transfer_id",HISTORY)).isEqualTo(oldLines);
        rejected(()->line(UUID.randomUUID(),HISTORY,"YC20250102000001","1"));
        rejected(()->jdbc.update("UPDATE finance_bank_transfer_lines SET amount_original=4,amount_local=4 WHERE id=?",OLD_LINE));
        rejected(()->jdbc.update("DELETE FROM finance_bank_transfer_lines WHERE id=?",OLD_LINE));
        rejected(()->jdbc.update("UPDATE finance_bank_transfer_lines SET transfer_id=? WHERE id=?",NATIVE,OLD_LINE));
        UUID nativeLine=UUID.randomUUID();
        line(nativeLine,NATIVE,"YC20250102000002","2");
        rejected(()->jdbc.update("UPDATE finance_bank_transfer_lines SET transfer_id=? WHERE id=?",HISTORY,nativeLine));
        assertThat(jdbc.update("UPDATE finance_bank_transfer_lines SET amount_original=4,amount_local=4 WHERE id=?",nativeLine)).isEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT amount_local FROM finance_bank_transfer_lines WHERE id=?",BigDecimal.class,nativeLine)).isEqualByComparingTo("4");
        assertThat(jdbc.update("DELETE FROM finance_bank_transfer_lines WHERE id=?",nativeLine)).isEqualTo(1);
        assertThat(rows("finance_bank_transfers","id",HISTORY)).isEqualTo(oldHeader);
        assertThat(rows("finance_bank_transfer_lines","transfer_id",HISTORY)).isEqualTo(oldLines);
    }
    private static void line(UUID id,UUID parent,String billNo,String amount) {
        jdbc.update("INSERT INTO finance_bank_transfer_lines(id,transfer_id,bill_no,bill_date,amount_original,amount_local,line_no) VALUES (?,?,?,'2025-01-02',?,?,1)",
                id,parent,billNo,new BigDecimal(amount),new BigDecimal(amount));
    }
    private static List<String> rows(String table,String column,UUID id) {
        return jdbc.queryForList("SELECT to_jsonb(fact)::text FROM "+table+" fact WHERE "+column+"=? ORDER BY id",String.class,id);
    }
    private static void rejected(Runnable action) {
        DataAccessException error=assertThrows(DataAccessException.class,action::run);
        assertThat(error.getMostSpecificCause()).isInstanceOf(SQLException.class);
        assertThat(((SQLException)error.getMostSpecificCause()).getSQLState()).isEqualTo("55000");
        assertThat(error.getMostSpecificCause().getMessage()).contains("legacy finance lines");
    }
}
