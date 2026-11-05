package com.uten.imp.features.finance.statement;

import com.uten.imp.support.MigratedProjectionSchema;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import static org.assertj.core.api.Assertions.assertThat;

/** Actual query oracle: removing a draft line never makes it an approved or reversed fact. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class FinanceNativeStatementDeletedRowsPostgresTest {
    private static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine")
            .withCreateContainerCmdModifier(cmd->cmd.getHostConfig().withMemory(768L*1024*1024).withNanoCPUs(1_000_000_000L));
    private static final LocalDate ORIGINAL=LocalDate.of(2026,9,18),REVERSED=LocalDate.of(2026,10,9);
    private static final UUID PARTY=UUID.randomUUID(),CURRENCY=UUID.randomUUID(),GOODS=UUID.randomUUID(),UNIT=UUID.randomUUID();
    private static JdbcTemplate db;
    private static NamedParameterJdbcTemplate named;

    @BeforeAll static void start(){
        PG.start();var source=new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());
        db=new JdbcTemplate(source);named=new NamedParameterJdbcTemplate(source);
        MigratedProjectionSchema.createCurrentTables(db,"sales_shipments","sales_shipment_items","sales_returns","sales_return_items",
                "purchase_receipts","purchase_receipt_items","purchase_returns","purchase_return_items",
                "clients","suppliers","currencies","goods","colors","units","ar_ap_ledger","stock_movements");
        db.update("INSERT INTO currencies(id,code,name)VALUES(?,'CNY','人民币')",CURRENCY);
        db.update("INSERT INTO clients(id,code,name)VALUES(?,'ANON-CLIENT','匿名客户')",PARTY);
        db.update("INSERT INTO suppliers(id,code,name)VALUES(?,'ANON-SUPPLIER','匿名供应商')",PARTY);
        db.update("INSERT INTO goods(id,code,name)VALUES(?,'ANON-GOODS','匿名货品')",GOODS);
        db.update("INSERT INTO units(id,name)VALUES(?,'件')",UNIT);
    }
    @AfterAll static void stop(){PG.stop();}

    @ParameterizedTest @ValueSource(strings={"SALES_SHIPMENT","SALES_RETURN","PURCHASE_RECEIPT","PURCHASE_RETURN"})
    void draftDeletedLineNeverReturnsWhenTheApprovedDocumentIsReversed(String kind){
        boolean client=kind.startsWith("SALES"),returned=kind.endsWith("RETURN");
        String headers=switch(kind){case "SALES_SHIPMENT"->"sales_shipments";case "SALES_RETURN"->"sales_returns";
            case "PURCHASE_RECEIPT"->"purchase_receipts";default->"purchase_returns";};
        String items=headers.substring(0,headers.length()-1)+"_items";
        String parent=returned?"return_id":client?"shipment_id":"receipt_id";
        UUID document=UUID.randomUUID(),kept=UUID.randomUUID(),removed=UUID.randomUUID();
        db.update("INSERT INTO "+headers+"(id,bill_no,bill_date,status,currency_id,"+(client?"client_id":"supplier_id")+")VALUES(?,? ,?,1,?,?)",
                document,"ANON-"+kind+"-"+document,ORIGINAL,CURRENCY,PARTY);
        for(UUID line:List.of(kept,removed))db.update("INSERT INTO "+items+"(id,"+parent+",goods_id,unit_id,bill_date,qty,price,amount_original,is_deleted)VALUES(?,?,?,?,?,1,?,?,?)",
                line,document,GOODS,UNIT,ORIGINAL,line.equals(kept)?new BigDecimal("7.123456789012345678901234"):new BigDecimal("99"),
                line.equals(kept)?new BigDecimal("7.123456789012345678901234"):new BigDecimal("99"),line.equals(removed));
        int naturalSign=returned?-1:1;
        assertOnlyKept(client,document,kept,removed,ORIGINAL,naturalSign);
        // This is the persisted terminal document state. The native lifecycle leaves its
        // approved lines intact; the earlier draft removal keeps its own is_deleted flag.
        db.update("UPDATE "+headers+" SET status=-1 WHERE id=?",document);
        db.update("INSERT INTO ar_ap_ledger(id,source_doc_type,source_doc_id,status,is_deleted,deleted_at)VALUES(?,?,?,-1,true,?)",
                UUID.randomUUID(),kind,document,OffsetDateTime.parse("2026-10-09T01:00:00Z"));
        assertOnlyKept(client,document,kept,removed,ORIGINAL,naturalSign);
        assertOnlyKept(client,document,kept,removed,REVERSED,-naturalSign);
        var full=rows(client,document,ORIGINAL,REVERSED);
        assertThat(full).hasSize(2).noneMatch(row->removed.equals(row.get("source_id")));
        assertThat(full.stream().map(row->(BigDecimal)row.get("amount")).reduce(BigDecimal.ZERO,BigDecimal::add)).isZero();
        assertThat(rows(client,document,ORIGINAL.minusDays(1),ORIGINAL.minusDays(1))).isEmpty();
        // Native delete is draft-only and never soft-deletes approved item rows.
        // Some historical reversed headers carry a deletion flag; preserve their
        // real original and reverse facts without reviving draft-deleted lines.
        db.update("UPDATE "+headers+" SET is_deleted=true WHERE id=?",document);
        assertOnlyKept(client,document,kept,removed,ORIGINAL,naturalSign);
        assertOnlyKept(client,document,kept,removed,REVERSED,-naturalSign);
    }
    private static void assertOnlyKept(boolean client,UUID document,UUID kept,UUID removed,LocalDate date,int sign){
        var rows=rows(client,document,date,date);
        assertThat(rows).singleElement().satisfies(row->{
            assertThat(row.get("source_id")).isEqualTo(kept).isNotEqualTo(removed);
            assertThat((BigDecimal)row.get("amount")).isEqualByComparingTo(new BigDecimal("7.123456789012345678901234").multiply(BigDecimal.valueOf(sign)));
            assertThat((BigDecimal)row.get("qty")).isEqualByComparingTo(BigDecimal.valueOf(sign));
            assertThat(row.get("pending")).isEqualTo(false);
        });
    }
    private static List<Map<String,Object>> rows(boolean client,UUID document,LocalDate from,LocalDate to){
        return named.queryForList("SELECT event.* FROM ("+FinanceNativeStatementSql.sql(client)+") event WHERE source_id IN(SELECT id FROM "+
                (client?"sales_shipment_items WHERE shipment_id=:document UNION ALL SELECT id FROM sales_return_items WHERE return_id=:document":
                    "purchase_receipt_items WHERE receipt_id=:document UNION ALL SELECT id FROM purchase_return_items WHERE return_id=:document")+") ORDER BY bill_date,event_order,source_id",
                Map.of("from",from,"to",to,"partyId",PARTY,"currencyId",CURRENCY,"document",document));
    }
}
