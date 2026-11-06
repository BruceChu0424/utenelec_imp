package com.uten.imp.businesschain;

import com.uten.imp.features.finance.gl.*;
import org.apache.poi.hssf.usermodel.HSSFWorkbook;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.math.BigDecimal;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

/** Historical chart metadata is distinct from creating a new cash/bank transaction. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@FinanceScopedChain
class FinanceChartInactiveCurrencyAccountingPostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry r){FinanceScopedChainDatabase.register(r,FinanceChartInactiveCurrencyAccountingPostgresTest.class);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired FinanceChartService chart;
    @Autowired FinanceAccountingImportService accounting;
    @Test void inactiveExplicitUuidCanBeMappedBeforeActualTwoPersonHistoricalGlContinuationWithoutGuessingMissingOriginalOpening()throws Exception {
        var fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);var owner=fixture.seedWorld("inactive-chart-owner");var reviewer=fixture.seedWorld("inactive-chart-reviewer");fixture.loginAs(owner.superAdminUserId());
        UUID foreign=UUID.randomUUID();db.update("INSERT INTO currencies(id,code,name,exchange_rate,status)VALUES(?,?,'匿名历史USD',7,'禁用')",foreign,"HIST-"+foreign);
        int accounts=db.queryForObject("SELECT count(*) FROM accounts",Integer.class);
        try {
            var categories=Map.of("1001","ACCOUNT","3001","EQUITY","5001","INCOME","3103","EQUITY","560301","EXPENSE");
            for(var code:List.of("1001","3001","5001","3103","560301"))chart.createAccount(new FinanceChartContracts.CreateAccount(UUID.randomUUID(),code,"匿名历史科目-"+code,code.equals("1001")?"匿名历史USD":"",categories.get(code),"原历史账套明确目录"));
            assertThat(db.queryForObject("SELECT currency_id FROM finance_chart_codes WHERE code='1001'",UUID.class)).isNull();
            assertThat(db.queryForObject("SELECT count(*) FROM gl_entries",Integer.class)).isZero();
            for(var account:chart.list()) {
                String balance=switch(account.code()){case "1001"->"BS_1";case "3001"->"BS_48";case "3103"->"BS_51";default->null;};
                String profit=switch(account.code()){case "5001"->"PL_1";case "560301"->"PL_FINANCE";default->null;};
                chart.map(account.code(),new FinanceChartContracts.Mapping(account.version(),account.targets().stream().map(FinanceChartContracts.Target::id).toList(),balance,profit,account.classification(),account.code().equals("1001")?foreign:account.currencyId()));
            }
            assertThat(chart.account("1001").currencyId()).isEqualTo(foreign);assertThat(db.queryForObject("SELECT status FROM currencies WHERE id=?",String.class,foreign)).isEqualTo("禁用");
            assertThat(db.queryForObject("SELECT count(*) FROM accounts",Integer.class)).isEqualTo(accounts);assertThat(db.queryForObject("SELECT count(*) FROM gl_entries",Integer.class)).isZero();
            var balances=accounting.preview("BALANCE","匿名历史USD账套","historical-balance.xls",foreignBalance());
            var journals=accounting.preview("VOUCHERS","匿名历史USD账套","historical-journals.xls",foreignJournals());
            assertThat(balances.source().issues()).isEmpty();assertThat(journals.source().issues()).isEmpty();assertThat(accounting.compare(journals.importId(),balances.importId())).hasSize(2);
            var selected=chart.list().stream().map(account->new FinanceAccountingContracts.AccountSelection(account.code(),account.targets().getFirst().id(),account.version(),account.currencyId())).toList();
            var purposes=new LinkedHashMap<String,String>();journals.source().vouchers().forEach(voucher->purposes.put(voucher.key(),voucher.closingCandidate()?"PNL_CLOSE":"OPERATING"));
            var request=new FinanceAccountingContracts.Submit(journals.version(),balances.importId(),balances.version(),selected,purposes,Map.of(),List.of(),Set.of("560301"),false,true,"完整原期间；历史停用USD按明确UUID接续，原币原额仅取原分录，不补缺失期初",List.of(),Map.of("匿名历史USD",foreign));
            var submitted=accounting.submit(journals.importId(),request);fixture.loginAs(reviewer.superAdminUserId());
            var result=accounting.approve(journals.importId(),new FinanceAccountingContracts.Review(submitted.version(),"不同人员核原文件、原币UUID及原额，未激活旧币种"));
            assertThat(result.entries()).isEqualTo(8);assertThat(result.voucherIds()).hasSize(4);
            assertThat(db.queryForObject("SELECT count(*) FROM gl_entries",Integer.class)).isEqualTo(8);
            assertThat(db.queryForObject("SELECT count(*) FROM finance_gl_entry_allocations WHERE account_code='1001' AND currency_id=?",Integer.class,foreign)).isEqualTo(3);
            assertThat(db.queryForObject("SELECT count(*) FROM finance_gl_entry_allocations a JOIN gl_entries e ON e.id=a.entry_id WHERE a.account_code='1001' AND a.original_currency_id=? AND a.amount_original IS NOT NULL AND e.amount IN(100,5)",Integer.class,foreign)).isEqualTo(2);
            assertThat(db.queryForObject("SELECT a.amount_original FROM finance_gl_entry_allocations a JOIN gl_entries e ON e.id=a.entry_id WHERE a.account_code='1001' AND e.amount=100",BigDecimal.class)).isEqualByComparingTo("100");
            assertThat(db.queryForObject("SELECT a.amount_original FROM finance_gl_entry_allocations a JOIN gl_entries e ON e.id=a.entry_id WHERE a.account_code='1001' AND e.amount=5",BigDecimal.class)).isEqualByComparingTo("5");
            assertThat(db.queryForObject("SELECT a.amount_original FROM finance_gl_entry_allocations a JOIN gl_entries e ON e.id=a.entry_id WHERE a.account_code='1001' AND e.amount=500",BigDecimal.class)).isNull();
            assertThat(db.queryForObject("SELECT a.original_currency_id FROM finance_gl_entry_allocations a JOIN gl_entries e ON e.id=a.entry_id WHERE a.account_code='1001' AND e.amount=500",UUID.class)).isNull();
            assertThat(db.queryForObject("SELECT status FROM currencies WHERE id=?",String.class,foreign)).isEqualTo("禁用");assertThat(db.queryForObject("SELECT count(*) FROM accounts",Integer.class)).isEqualTo(accounts);
            assertThat(db.queryForObject("SELECT exchange_rate FROM currencies WHERE id=?",BigDecimal.class,foreign)).isEqualByComparingTo("7");
        }finally{SecurityContextHolder.clearContext();}
    }
    private static byte[] foreignBalance()throws Exception {
        try(var book=new HSSFWorkbook(new ByteArrayInputStream(FinanceAccountingContinuationPostgresTest.balance()));var output=new ByteArrayOutputStream()){
            book.getSheetAt(0).getRow(1).getCell(4).setCellValue("匿名历史USD");book.write(output);return output.toByteArray();
        }
    }
    private static byte[] foreignJournals()throws Exception {
        try(var book=new HSSFWorkbook(new ByteArrayInputStream(FinanceAccountingContinuationPostgresTest.journals()));var output=new ByteArrayOutputStream()){
            var sheet=book.getSheetAt(0);for(int index=1;index<=sheet.getLastRowNum();index++){
                var row=sheet.getRow(index);if(!"1001".equals(row.getCell(5).getStringCellValue()))continue;
                double amount=row.getCell(6)==null?row.getCell(7).getNumericCellValue():row.getCell(6).getNumericCellValue();
                row.createCell(9).setCellValue(amount);row.createCell(10).setCellValue(1);row.createCell(59).setCellValue("匿名历史USD");
            }
            book.write(output);return output.toByteArray();
        }
    }
}
