package com.uten.imp.common.report;

import com.uten.imp.common.export.ExportPageSink;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.features.admin.systemsetting.SystemSettingKey;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.finance.FinanceDocumentAccessPolicy;
import com.uten.imp.features.finance.report.FinanceReportService;
import com.uten.imp.features.stock.StockCostMasker;
import com.uten.imp.features.stock.StockQueryService;
import com.uten.imp.features.stock.report.StockReportService;
import com.uten.imp.security.OwnerVisibility.OwnerScope;
import com.uten.imp.support.MigratedProjectionSchema;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.DriverManager;
import java.time.LocalDate;
import java.util.*;
import java.util.function.Supplier;
import java.util.stream.IntStream;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Actual service.export adapters: complete rows, opening facts and terminal balances across 3 pages. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ReportExportSpecialSourcesPostgresTest {
    private static final PostgreSQLContainer PG = new PostgreSQLContainer("postgres:16-alpine")
            .withDatabaseName("b1_special_readers").withReuse(false)
            .withCreateContainerCmdModifier(cmd -> cmd.getHostConfig().withMemory(768L * 1024 * 1024).withNanoCPUs(1_000_000_000L));
    private static final String[] TABLES = {"currencies","clients","suppliers","accounts","units","colors","departments",
            "goods","material_categories","payment_styles","gl_entries","stock_balances","stock_measurement_holds",
            "procurement_inspection_items","goods_weight_estimates","production_plans","production_plan_items",
            "warehouses","warehouse_goods_place_preferences","finance_reconciliations","account_flow_monthly_summaries",
            "finance_receipts","finance_receipt_lines","finance_payments","finance_payment_lines","ar_ap_ledger",
            "legacy_finance_import_sources","customer_open_item_offsets","customer_open_item_offset_batches",
            "purchase_receipts","purchase_receipt_items","purchase_returns","purchase_return_items","v_stock_actual_finished_receipts"};
    private static final UUID CURRENCY=UUID.randomUUID(),CLIENT=UUID.randomUUID(),SUPPLIER=UUID.randomUUID(),
            ACCOUNT=UUID.randomUUID(),UNIT=UUID.randomUUID();
    private static final LocalDate DATE=LocalDate.of(2026,10,12);
    private static JdbcTemplate db;

    @BeforeAll static void start() {
        PG.start();db=new JdbcTemplate(new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword()));
        MigratedProjectionSchema.createCurrentTables(db,TABLES);
    }
    @AfterAll static void stop() { PG.stop(); }
    @BeforeEach void facts() {
        db.execute("TRUNCATE "+String.join(",",TABLES));
        db.update("INSERT INTO currencies(id,name,code) VALUES (?,'美金','USD')",CURRENCY);
        db.update("INSERT INTO clients(id,code,name) VALUES (?,'B1-CLIENT','真实客户')",CLIENT);
        db.update("INSERT INTO suppliers(id,code,name) VALUES (?,'B1-SUPPLIER','真实供应商')",SUPPLIER);
        db.update("INSERT INTO units(id,code,name) VALUES (?,'B1-UNIT','个')",UNIT);
        db.update("INSERT INTO accounts(id,name,currency_id,init_balance) VALUES (?,'读取账户',?,3.0002)",ACCOUNT,CURRENCY);
        db.update("""
                INSERT INTO goods(id,code,name,unit_id,stock_place,status,is_deleted,c_total,total)
                SELECT gen_random_uuid(),'G-'||lpad(n::text,5,'0'),'货品-'||lpad(n::text,5,'0'),?,'A-1-1','使用',false,1,1
                FROM generate_series(1,1001) n
                """,UNIT);
        UUID receipt=UUID.randomUUID();
        db.update("INSERT INTO purchase_receipts(id,bill_no,bill_date,supplier_id,status,is_deleted,currency_id) VALUES (?,'B1-RECEIPT',?,?,1,false,?)",receipt,DATE,SUPPLIER,CURRENCY);
        db.update("""
                INSERT INTO purchase_receipt_items(id,receipt_id,goods_id,bill_no,bill_date,line_no,unit_id,qty,price,amount_original,is_deleted)
                SELECT gen_random_uuid(),?,id,'B1-RECEIPT',?,row_number() OVER(ORDER BY code),?,1,2.0001,2.0001,false FROM goods
                """,receipt,DATE,UNIT);
        db.update("INSERT INTO finance_reconciliations(id,account_id,bill_date,bill_no,posting_seq,in_amount,out_amount,is_deleted) VALUES (gen_random_uuid(),?,?,'BEFORE',1,7.0003,0,false)",ACCOUNT,DATE.minusDays(1));
        db.update("""
                INSERT INTO finance_reconciliations(id,account_id,bill_date,bill_no,posting_seq,in_amount,out_amount,is_deleted)
                SELECT gen_random_uuid(),?,?,'AC-'||lpad(n::text,5,'0'),n+1,1.0001,0,false FROM generate_series(1,1001) n
                """,ACCOUNT,DATE);
        db.update("""
                INSERT INTO ar_ap_ledger(id,direction,client_id,currency_id,bill_no,bill_date,exchange_rate,
                    amount_original,amount_original_local,amount_balance_original,amount_balance,status,is_deleted)
                VALUES (gen_random_uuid(),'AR',?,?,'BEFORE',?,7,3.0002,21.0014,3.0002,21.0014,1,false)
                """,CLIENT,CURRENCY,DATE.minusDays(1));
        db.update("""
                INSERT INTO ar_ap_ledger(id,direction,client_id,currency_id,bill_no,bill_date,exchange_rate,
                    amount_original,amount_original_local,amount_balance_original,amount_balance,status,is_deleted)
                SELECT gen_random_uuid(),'AR',?,?,'EVT-'||lpad(n::text,5,'0'),?,7,2.0001,14.0007,2.0001,14.0007,1,false
                FROM generate_series(1,1001) n
                """,CLIENT,CURRENCY,DATE);
        db.execute("INSERT INTO payment_styles(id,code,name,category,level) SELECT gen_random_uuid(),'GL-'||lpad(n::text,5,'0'),'科目','EXPENSE',0 FROM generate_series(1,1001) n");
        db.update("INSERT INTO gl_entries(id,voucher_id,style_id,direction,amount,entry_date,period,is_deleted) SELECT gen_random_uuid(),gen_random_uuid(),id,1,1.0001,?,'2026-10',false FROM payment_styles",DATE);
    }

    private static final class Context implements AutoCloseable {
        final Connection connection;
        final org.hibernate.SessionFactory factory;
        final org.hibernate.Session session;
        final List<String> sql=new ArrayList<>();
        final FinanceReportService finance;
        final StockReportService stock;
        Context() throws Exception {
            connection=DriverManager.getConnection(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());
            connection.setTransactionIsolation(Connection.TRANSACTION_REPEATABLE_READ);connection.setReadOnly(true);connection.setAutoCommit(false);
            var configuration=new org.hibernate.cfg.Configuration().setProperty("hibernate.hbm2ddl.auto","none")
                    .setProperty("hibernate.show_sql","false").setProperty("hibernate.connection.provider_disables_autocommit","true");
            configuration.getProperties().put("hibernate.connection.datasource",new SingleConnectionDataSource(connection,true));
            configuration.setStatementInspector(statement->{sql.add(statement);return statement;});
            factory=configuration.buildSessionFactory();session=factory.openSession();session.setDefaultReadOnly(true);session.beginTransaction();
            var access=mock(FinanceDocumentAccessPolicy.class);when(access.scope()).thenReturn(new OwnerScope(true,Set.of()));
            when(access.hasAuthority(anyString())).thenReturn(true);
            when(access.nativeReadScope(anyString(),anyString(),any(OwnerScope.class)))
                    .thenReturn(new com.uten.imp.security.DocumentAccessPolicy.NativeReadScope("1=1",null,Set.of()));
            var settings=mock(SystemSettingsService.class);when(settings.readInt(SystemSettingKey.EXPORT_MAX_ROWS)).thenReturn(100_000);
            Class<?> lines=Class.forName("com.uten.imp.features.finance.gl.GlReportLineSource");
            var constructor=lines.getDeclaredConstructor(jakarta.persistence.EntityManager.class);constructor.setAccessible(true);
            var gl=(com.uten.imp.features.finance.gl.GlReportService)com.uten.imp.features.finance.gl.GlReportService.class
                    .getConstructors()[0].newInstance(session,constructor.newInstance(session));
            finance=new FinanceReportService(session,access,settings,
                    new com.uten.imp.features.finance.statement.FinanceStatementService(session),
                    new com.uten.imp.features.finance.cost.FinanceCostService(session),gl,
                    new com.uten.imp.features.finance.asset.FixedAssetService(session,mock(com.uten.imp.security.TxSessionVars.class)));
            var costs=mock(StockCostMasker.class);when(costs.canView()).thenReturn(true);
            var query=new StockQueryService(mock(com.uten.imp.features.stock.StockBalanceRepository.class),session,costs);
            stock=new StockReportService(session,settings,query,costs);
            TransactionSynchronizationManager.setActualTransactionActive(true);
            TransactionSynchronizationManager.setCurrentTransactionReadOnly(true);
            TransactionSynchronizationManager.setCurrentTransactionIsolationLevel(Connection.TRANSACTION_REPEATABLE_READ);
        }
        @Override public void close() throws Exception {
            try {
                if (session.getTransaction().isActive()) {
                    session.getTransaction().rollback();
                }
                session.close();
                factory.close();
            }
            finally {TransactionSynchronizationManager.clear();connection.close();}
        }
    }

    @ParameterizedTest @ValueSource(strings={"account/statement","statement/flow","statement/detail","statements/supplier",
            "cost/product","gl/trial-balance","stock/instant-inventory","stock/shelf-labels"})
    void completeServiceExportMatchesTheOriginalPagesIncludingOpeningFactsAndLastBalances(String report) throws Exception {
        try(var context=new Context()){
            Map<String,String> parameters=new HashMap<>(Map.of("dateFrom",DATE.toString(),"dateTo",DATE.toString()));
            if(report.equals("account/statement"))parameters.put("accountId",ACCOUNT.toString());
            if(report.startsWith("statement/")){parameters.put("partyId",CLIENT.toString());parameters.put("side","AR");}
            Supplier<ExportPayload> load=report.startsWith("stock/")
                    ?()->context.stock.export(report.substring(6),parameters,"goodsCode","asc")
                    :()->context.finance.export(report,parameters,null,null);
            ExportPayload original=load.get();assertThat(original.total()).isEqualTo(1001);assertThat(original.rows()).hasSize(1001);
            int originalStatements=context.sql.size();
            context.sql.clear();List<ExportPayload> batches=new ArrayList<>();ExportPayload result;
            try(var sink=ExportPageSink.open(batches::add);var cursor=ReportExportCursor.open()){result=load.get();}
            assertThat(result.total()).isEqualTo(1001);assertThat(result.rows()).isEmpty();
            assertThat(batches).extracting(batch->batch.rows().size()).containsExactly(500,500,1);
            var streamed=batches.stream().flatMap(batch->batch.rows().stream()).toList();
            assertThat(streamed).containsExactlyElementsOf(original.rows());
            // Preflight proof queries may remain; there is one unbounded data SELECT, never repeated OFFSET scans.
            var dataStatements=context.sql.stream().filter(statement->!statement.toLowerCase(Locale.ROOT).startsWith("select count(*)")
                    && statement.matches("(?is).*\\bORDER\\s+BY\\b.*")).toList();
            assertThat(dataStatements)
                    .hasSize(1).allSatisfy(statement->assertThat(statement).doesNotContain("LIMIT ? OFFSET ?"));
            if(report.equals("account/statement")){
                assertThat(streamed).extracting(row->row.get("billNo")).containsExactlyElementsOf(
                        IntStream.rangeClosed(1,1001).mapToObj(value->String.format("AC-%05d",value)).toList());
                assertThat((BigDecimal)streamed.getFirst().get("balance")).isEqualByComparingTo("11.0006");
                assertThat((BigDecimal)streamed.getLast().get("balance")).isEqualByComparingTo("1011.1006");
            }else if(report.startsWith("statement/")){
                assertThat(streamed).extracting(row->row.get("refNo")).containsExactlyElementsOf(
                        IntStream.rangeClosed(1,1001).mapToObj(value->String.format("EVT-%05d",value)).toList());
                assertThat((BigDecimal)streamed.getFirst().get("balanceOriginal")).isEqualByComparingTo("5.0003");
                assertThat((BigDecimal)streamed.getLast().get("balanceOriginal")).isEqualByComparingTo("2005.1003");
                assertThat((BigDecimal)streamed.getLast().get("balanceLocal")).isEqualByComparingTo("14035.7021");
            }else{
                String key=report.equals("gl/trial-balance")?"styleCode":"goodsCode";
                String prefix=report.equals("gl/trial-balance")?"GL-":"G-";
                assertThat(streamed).extracting(row->row.get(key)).containsExactlyElementsOf(
                        IntStream.rangeClosed(1,1001).mapToObj(value->String.format(prefix+"%05d",value)).toList());
            }
            var output=java.nio.file.Path.of("target-b1-report-special-sources");java.nio.file.Files.createDirectories(output);
            new com.fasterxml.jackson.databind.ObjectMapper().writerWithDefaultPrettyPrinter().writeValue(
                    output.resolve(report.replace('/','_')+".json").toFile(),Map.of(
                            "report",report,"rows",1001,"originalPageStatements",originalStatements,
                            "cursorStatementsIncludingProofReads",context.sql.size(),"cursorDataStatements",dataStatements.size(),
                            "batchSizes",batches.stream().map(batch->batch.rows().size()).toList(),
                            "scope","Isolated migrated-column projection; real Hibernate and real SQL, unchanged preflight proofs retained",
                            "sql",context.sql));
        }
    }
    @Test void actualAccountFacetServiceReadsAllDistinctCandidatesBeyondLegacyFiveHundredWithLiteralSearch() throws Exception {
        db.update("UPDATE finance_reconciliations SET bill_no=? WHERE account_id=? AND posting_seq=1002","百分%_\\原文",ACCOUNT);
        db.update("UPDATE finance_reconciliations SET bill_no=NULL WHERE account_id=? AND posting_seq=2",ACCOUNT);
        db.update("UPDATE finance_reconciliations SET bill_no='' WHERE account_id=? AND posting_seq=3",ACCOUNT);
        db.update("UPDATE finance_reconciliations SET bill_no='AC-00003' WHERE account_id=? AND posting_seq=5",ACCOUNT);
        try(var context=new Context()) {
            var expected=db.queryForList("SELECT COALESCE(bill_no,'') FROM finance_reconciliations WHERE account_id=? AND bill_date>=? GROUP BY 1 ORDER BY 1",String.class,ACCOUNT,DATE);
            List<String> actual=new ArrayList<>();Map<String,Long> counts=new LinkedHashMap<>();context.sql.clear();
            for(int page=1;;page++)try(var candidates=com.uten.imp.common.web.NativeFacetCandidates.open("billNo","",page,100)) {
                var response=context.finance.accountStatementFacets(ACCOUNT,DATE,DATE,null);
                var result=candidates.result(response,"account-current");
                assertThat(result.items()).hasSizeLessThanOrEqualTo(100);
                assertThat(result.items()).allSatisfy(item->assertThat(((Number)item.get("count")).longValue()).isBetween(1L,2L));
                actual.addAll(result.items().stream().map(item->item.get("value").toString()).toList());
                result.items().forEach(item->counts.put(item.get("value").toString(),((Number)item.get("count")).longValue()));
                if(!result.hasMore())break;
            }
            assertThat(actual).hasSize(999).containsExactlyElementsOf(expected);
            assertThat(actual.getFirst()).isEmpty();assertThat(actual).doesNotHaveDuplicates();
            assertThat(counts.get("")).isEqualTo(2L);assertThat(counts.get("AC-00003")).isEqualTo(2L);
            assertThat(counts.values().stream().mapToLong(Long::longValue).sum()).isEqualTo(1001L);
            assertThat(context.sql).hasSize(10).allSatisfy(sql->assertThat(sql).contains("candidate.bucket_count"));
            try(var candidates=com.uten.imp.common.web.NativeFacetCandidates.open("billNo","%_\\原文",1,100)) {
                var response=context.finance.accountStatementFacets(ACCOUNT,DATE,DATE,null);
                assertThat(candidates.result(response,"account-current").items()).extracting(item->item.get("value")).containsExactly("百分%_\\原文");
            }
        }
    }

}
