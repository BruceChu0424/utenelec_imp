package com.uten.imp.businesschain;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.finance.gl.*;
import com.uten.imp.testsupport.FixtureDatabaseProperties;
import org.apache.poi.hssf.usermodel.HSSFWorkbook;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.*;
import org.testcontainers.postgresql.PostgreSQLContainer;
import java.io.*;
import java.math.BigDecimal;
import java.nio.file.Files;
import java.time.LocalDate;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

/** Anonymous real transactions: zero-ending P&L omission, two-person review and one authoritative GL. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=accounting-continuation-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class FinanceAccountingContinuationPostgresTest {
    private static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine");
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry)throws IOException {
        PG.start();FixtureDatabaseProperties.bindSameRole(registry,PG::getJdbcUrl,PG::getUsername,PG::getPassword);
        String directory=Files.createTempDirectory("uten-accounting-source-test-").toString();registry.add("uten.storage.local-dir",()->directory);
    }
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired FinanceChartService chart;
    @Autowired FinanceAccountingImportService imports;
    @Autowired GlReportService reports;
    @Autowired JdbcTemplate db;
    @AfterEach void logout(){SecurityContextHolder.clearContext();}
    @Test void manualAccountsAndReviewedZeroEndingProfitOmissionRetainThePeriodOccurrenceAndPostExactlyOnce()throws Exception {
        var fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);var owner=fixture.seedWorld("accounting-owner");var reviewer=fixture.seedWorld("accounting-reviewer");fixture.loginAs(owner.superAdminUserId());
        var categories=Map.of("1001","ACCOUNT","3001","EQUITY","5001","INCOME","3103","EQUITY","560301","EXPENSE");
        var names=Map.of("1001","库存现金","3001","实收资本","5001","主营业务收入","3103","本年利润","560301","匿名损益明细");
        for(String code:List.of("1001","3001","5001","3103","560301")) {
            var request=new FinanceChartContracts.CreateAccount(UUID.randomUUID(),code,names.get(code),"",categories.get(code),"匿名测试：财务自行新增代码");
            assertThat(chart.createAccount(request)).isEqualTo(chart.createAccount(request));
        }
        assertThat(db.queryForObject("SELECT count(*) FROM gl_entries",Integer.class)).isZero();
        for(var account:chart.list()) {
            String bs=switch(account.code()){case "1001"->"BS_1";case "3001"->"BS_48";case "3103"->"BS_51";default->null;};
            String pl=switch(account.code()){case "5001"->"PL_1";case "560301"->"PL_FINANCE";default->null;};
            chart.map(account.code(),new FinanceChartContracts.Mapping(account.version(),account.targets().stream().map(target->target.id()).toList(),bs,pl));
        }
        var balance=imports.preview("BALANCE","匿名账套","balance.xls",balance());var journals=imports.preview("VOUCHERS","匿名账套","journals.xls",journals());
        assertThat(balance.source().issues()).isEmpty();assertThat(journals.source().issues()).isEmpty();
        assertThat(imports.preview("VOUCHERS","匿名账套","renamed.xls",journals()).importId()).isEqualTo(journals.importId());
        assertThat(imports.compare(journals.importId(),balance.importId())).hasSize(2);
        var selected=chart.list().stream().map(account->new FinanceAccountingContracts.AccountSelection(account.code(),account.targets().getFirst().id(),account.version(),account.currencyId())).toList();
        Map<String,String> purposes=new LinkedHashMap<>();for(var voucher:journals.source().vouchers())purposes.put(voucher.key(),voucher.closingCandidate()?"PNL_CLOSE":"OPERATING");
        var incomplete=new FinanceAccountingContracts.Submit(journals.version(),balance.importId(),balance.version(),selected,purposes,Map.of(),List.of(),Set.of(),false,true,"匿名完整9月来源核对");
        assertThatThrownBy(()->imports.submit(journals.importId(),incomplete)).isInstanceOf(ApiException.class).hasMessageContaining("逐科目发生额");
        var request=new FinanceAccountingContracts.Submit(journals.version(),balance.importId(),balance.version(),selected,purposes,Map.of(),List.of(),Set.of("560301"),false,true,"已复核原表省略的零余额损益科目，按完整凭证发生额接续");
        var submitted=imports.submit(journals.importId(),request);assertThat(imports.submit(journals.importId(),request).version()).isEqualTo(submitted.version());
        assertThatThrownBy(()->imports.approve(journals.importId(),new FinanceAccountingContracts.Review(submitted.version(),"本人复核"))).isInstanceOf(ApiException.class).hasMessageContaining("不同账号");
        fixture.loginAs(reviewer.superAdminUserId());
        var action=new FinanceAccountingContracts.Review(submitted.version(),"另一人核对原始文件、科目、结转和零余额例外");
        var result=imports.approve(journals.importId(),action);assertThat(imports.approve(journals.importId(),action)).isEqualTo(result);
        assertThat(result.entries()).isEqualTo(8);assertThat(result.voucherIds()).hasSize(4);
        assertThat(db.queryForObject("SELECT count(*) FROM gl_entries",Integer.class)).isEqualTo(8);
        assertThat(db.queryForObject("SELECT count(*) FROM gl_entries e LEFT JOIN finance_gl_entry_allocations a ON a.entry_id=e.id WHERE a.entry_id IS NULL",Integer.class)).isZero();
        var profit=reports.profitMonthly(2026,9);
        var income=profit.rows().stream().filter(row->Integer.valueOf(1).equals(row.get("lineNo"))).findFirst().orElseThrow();
        assertThat((BigDecimal)income.get("monthAmount")).isEqualByComparingTo("100");assertThat(income.get("yearAmount")).isNull();
        var expense=profit.rows().stream().filter(row->Integer.valueOf(18).equals(row.get("lineNo"))).findFirst().orElseThrow();
        assertThat((BigDecimal)expense.get("monthAmount")).isEqualByComparingTo("5");
        UUID expenseStyle=selected.stream().filter(account->account.accountCode().equals("560301")).findFirst().orElseThrow().styleId();
        assertThat(db.queryForObject("SELECT sum(direction*amount) FROM gl_entries WHERE style_id=?",BigDecimal.class,expenseStyle)).isEqualByComparingTo("0");
        var trial=reports.trialBalance(LocalDate.parse("2026-09-01"),LocalDate.parse("2026-09-30"),1,50);
        var closedExpense=trial.rows().stream().filter(row->row.get("styleCode").equals("560301")).findFirst().orElseThrow();
        assertThat((BigDecimal)closedExpense.get("debit")).isEqualByComparingTo("5");
        assertThat((BigDecimal)closedExpense.get("credit")).isEqualByComparingTo("5");
        assertThat((BigDecimal)closedExpense.get("closingDebit")).isEqualByComparingTo("0");
        String fingerprint=db.queryForObject("SELECT fn_finance_style_balance_evidence_fingerprint(?,DATE '2026-09-30')",String.class,expenseStyle);
        assertThat(fingerprint).matches("[0-9a-f]{64}");
        assertThat(db.queryForObject("SELECT fn_finance_style_balance_asof(?,DATE '2026-09-30')",BigDecimal.class,expenseStyle)).isEqualByComparingTo("0");
        assertThat(db.queryForObject("SELECT fn_finance_balance_asof_complete(DATE '2025-12-31')",Boolean.class)).isFalse();
        assertThatThrownBy(()->db.update("UPDATE gl_entries SET amount=amount+1 WHERE id=(SELECT id FROM gl_entries LIMIT 1)")).isInstanceOf(org.springframework.dao.DataIntegrityViolationException.class);
        assertThatThrownBy(()->db.update("UPDATE finance_accounting_import_batches SET preview='{}' WHERE id=?",journals.importId())).isInstanceOf(org.springframework.dao.DataIntegrityViolationException.class);
        // Continuing a month verifies the previous closing and does not post another opening.
        fixture.loginAs(owner.superAdminUserId());
        var octoberBalance=imports.preview("BALANCE","匿名账套","october-balance.xls",octoberBalance());
        var october=imports.preview("VOUCHERS","匿名账套","october-journals.xls",octoberJournals());
        var octoberPurposes=new LinkedHashMap<String,String>();october.source().vouchers().forEach(voucher->octoberPurposes.put(voucher.key(),"OPERATING"));
        var continuation=new FinanceAccountingContracts.Submit(october.version(),octoberBalance.importId(),octoberBalance.version(),selected,octoberPurposes,Map.of(),List.of(),Set.of(),true,true,"10月原期初已与9月已核对期末逐科目一致");
        var octoberSubmitted=imports.submit(october.importId(),continuation);fixture.loginAs(reviewer.superAdminUserId());
        var continued=imports.approve(october.importId(),new FinanceAccountingContracts.Review(octoberSubmitted.version(),"另一人复核后续月份，不重复期初"));
        assertThat(continued.entries()).isEqualTo(2);assertThat(continued.voucherIds()).hasSize(1);
        assertThat(db.queryForObject("SELECT count(*) FROM finance_gl_opening_baselines",Integer.class)).isEqualTo(1);
        assertThat(db.queryForObject("SELECT count(*) FROM gl_entries",Integer.class)).isEqualTo(10);
        assertThat(db.queryForObject("SELECT fn_finance_style_balance_evidence_fingerprint(?,DATE '2026-09-30')",String.class,expenseStyle)).isEqualTo(fingerprint);
        // A future existing baseline must also stop a second initial import into an earlier month.
        fixture.loginAs(owner.superAdminUserId());
        var januaryBalance=imports.preview("BALANCE","匿名账套","january-balance.xls",january(balance(),false));
        var january=imports.preview("VOUCHERS","匿名账套","january-journals.xls",january(journals(),true));
        var januaryPurposes=new LinkedHashMap<String,String>();january.source().vouchers().forEach(voucher->januaryPurposes.put(voucher.key(),voucher.closingCandidate()?"PNL_CLOSE":"OPERATING"));
        var restart=new FinanceAccountingContracts.Submit(january.version(),januaryBalance.importId(),januaryBalance.version(),selected,januaryPurposes,Map.of(),List.of(),Set.of("560301"),false,true,"不能重复建立期初的反例");
        var januarySubmitted=imports.submit(january.importId(),restart);fixture.loginAs(reviewer.superAdminUserId());
        assertThatThrownBy(()->imports.approve(january.importId(),new FinanceAccountingContracts.Review(januarySubmitted.version(),"另一人复核错误的重复首次接续")))
                .isInstanceOf(ApiException.class).hasMessageContaining("再次首次接续");
        assertThat(db.queryForObject("SELECT count(*) FROM gl_entries",Integer.class)).isEqualTo(10);
        db.update("UPDATE finance_gl_period_versions SET revision=revision+1 WHERE period='2026-09'");
        assertThat(db.queryForObject("SELECT fn_finance_style_balance_asof(?,DATE '2026-09-30')",BigDecimal.class,expenseStyle)).isNull();
        assertThat(db.queryForObject("SELECT fn_finance_style_balance_evidence_fingerprint(?,DATE '2026-09-30')",String.class,expenseStyle)).isNull();
    }
    static byte[] january(byte[] bytes,boolean vouchers)throws IOException {
        try(var book=new HSSFWorkbook(new ByteArrayInputStream(bytes));var out=new ByteArrayOutputStream()) {
            var sheet=book.getSheetAt(0);for(int rowNo=1;rowNo<=sheet.getLastRowNum();rowNo++){var row=sheet.getRow(rowNo);if(vouchers){row.getCell(0).setCellValue("2026-01-30");row.getCell(51).setCellValue(1);}else row.getCell(1).setCellValue("月份：2026.01-2026.01");}
            book.write(out);return out.toByteArray();
        }
    }
    private static byte[] octoberBalance()throws IOException {
        try(var book=new HSSFWorkbook(new ByteArrayInputStream(balance()));var out=new ByteArrayOutputStream()) {
            var sheet=book.getSheetAt(0);double[][] amounts={{595,0,50,0,645,0},{0,500,0,0,0,500},{0,100,0,50,0,150},{5,0,0,0,5,0},{0,0,0,0,0,0}};
            var fee=sheet.createRow(5);fee.createCell(0).setCellValue(2026);fee.createCell(2).setCellValue("560301");fee.createCell(3).setCellValue("匿名损益明细");fee.createCell(4).setCellValue("");
            for(int index=0;index<5;index++){var row=sheet.getRow(index+1);if(row.getCell(1)==null){row.createCell(1);}row.getCell(1).setCellValue("月份：2026.10-2026.10");for(int col=0;col<6;col++){if(row.getCell(col+5)==null){row.createCell(col+5);}row.getCell(col+5).setCellValue(amounts[index][col]);}}
            book.write(out);return out.toByteArray();
        }
    }
    private static byte[] octoberJournals()throws IOException {
        try(var book=new HSSFWorkbook(new ByteArrayInputStream(journals()));var out=new ByteArrayOutputStream()) {
            var sheet=book.getSheetAt(0);for(int rowNo=sheet.getLastRowNum();rowNo>=3;rowNo--)sheet.removeRow(sheet.getRow(rowNo));
            for(int rowNo=1;rowNo<=2;rowNo++){var row=sheet.getRow(rowNo);row.getCell(0).setCellValue("2026-10-31");row.getCell(51).setCellValue(10);row.getCell(rowNo==1?6:7).setCellValue(50);}
            book.write(out);return out.toByteArray();
        }
    }
    static byte[] balance()throws IOException {
        try(var book=new HSSFWorkbook();var out=new ByteArrayOutputStream()) {
            var sheet=book.createSheet("科目余额");var header=sheet.createRow(0);
            var labels=List.of("会计年度","会计期间","科目编码","科目名称","外币名称","期初借方","期初贷方","本期发生借方","本期发生贷方","期末借方","期末贷方");
            for(int col=0;col<labels.size();col++)header.createCell(col).setCellValue(labels.get(col));
            String[] codes={"1001","3001","5001","3103"},names={"库存现金","实收资本","主营业务收入","本年利润"};
            double[][] amounts={{500,0,100,5,595,0},{0,500,0,0,0,500},{0,0,0,100,0,100},{0,0,5,0,5,0}};
            for(int index=0;index<codes.length;index++){var row=sheet.createRow(index+1);row.createCell(0).setCellValue(2026);row.createCell(1).setCellValue("月份：2026.09-2026.09");row.createCell(2).setCellValue(codes[index]);row.createCell(3).setCellValue(names[index]);row.createCell(4).setCellValue("");for(int col=0;col<6;col++)row.createCell(col+5).setCellValue(amounts[index][col]);}
            book.write(out);return out.toByteArray();
        }
    }
    static byte[] journals()throws IOException {
        try(var book=new HSSFWorkbook();var out=new ByteArrayOutputStream()) {
            var sheet=book.createSheet("凭证");var header=sheet.createRow(0);for(int col=0;col<82;col++){header.createCell(col).setCellValue("F"+(col+1)+"原字段");}header.createCell(82).setCellValue("凭证输出：V800：T01：匿名：2026");
            String[][] codes={{"1001","5001"},{"560301","1001"},{"3103","560301"}};double[] values={100,5,5};
            for(int voucher=0;voucher<3;voucher++)for(int line=0;line<2;line++){
                int index=voucher*2+line+1;var row=sheet.createRow(index);
                Map<Integer,String> text=Map.of(0,"2026-09-30",1,"记",2,"000"+(voucher+1),4,"匿名分录",5,codes[voucher][line],48,"T01",49,"匿名",61,"匿名原科目");
                text.forEach((col,value)->row.createCell(col).setCellValue(value));row.createCell(line==0?6:7).setCellValue(values[voucher]);row.createCell(50).setCellValue(2026);row.createCell(51).setCellValue(9);row.createCell(58).setCellValue(line+1);row.createCell(80).setCellValue(index);row.createCell(81).setCellValue(voucher+1);
            }
            book.write(out);return out.toByteArray();
        }
    }
}
