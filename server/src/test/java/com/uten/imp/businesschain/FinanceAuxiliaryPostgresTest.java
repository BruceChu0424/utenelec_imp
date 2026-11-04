package com.uten.imp.businesschain;

import com.uten.imp.application.port.FinancialAuxiliaryValidationPort.Selection;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.finance.FinanceDocumentAccessPolicy;
import com.uten.imp.features.finance.report.*;
import com.uten.imp.features.finance.statement.*;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.*;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;
import static com.uten.imp.features.finance.statement.FinanceAuxiliaryContracts.*;
import static org.assertj.core.api.Assertions.*;

/** Anonymous data, full migrations, source identity, exact balances and no cross-party netting. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class FinanceAuxiliaryPostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired FinanceAuxiliaryService service;
    @Autowired FinanceAuxiliaryImportService imports;
    @Autowired com.uten.imp.application.port.FinancialAuxiliarySourceReadPort accountingSources;
    @Autowired com.uten.imp.application.port.FinancialChartCurrencyReadPort chartCurrencies;
    @Autowired JdbcTemplate db;
    @Autowired EntityManager em;
    @Autowired FinanceDocumentAccessPolicy access;
    @AfterEach void logout(){SecurityContextHolder.clearContext();}

    @Test void mixedAccountingCurrencyPropertiesFreezePerAccountAndRecheckCreatesAnotherImmutableVersion()throws Exception {
        var fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);var world=fixture.seedWorld("finance-aux-mixed");fixture.loginAs(world.superAdminUserId());
        UUID base=chartCurrencies.choices().stream().filter(com.uten.imp.application.port.FinancialChartCurrencyReadPort.Choice::baseCurrency).findFirst().orElseThrow().id();
        UUID foreign=UUID.randomUUID();db.update("INSERT INTO currencies(id,code,name,exchange_rate,status) VALUES(?,?,'匿名外币属性',7,'使用')",foreign,"AUX-MIX-"+foreign);
        UUID chartSource=UUID.randomUUID();db.update("INSERT INTO finance_chart_imports(id,actor_id,source_name,sha256,storage_provider,storage_key,storage_size,preview) VALUES(?,?,'anonymous.xls',?,'TEST','anonymous',1,'{}')",chartSource,world.superAdminUserId(),"e".repeat(64));
        for(String code:List.of("112201","112202"))db.update("INSERT INTO finance_chart_codes(code,name,currency_name,sort_order,source_row,source_import_id,updated_by) VALUES(?,?,?,1,1,?,?) ON CONFLICT DO NOTHING",code,"匿名原科目",code.equals("112202")?"未映射外币":"",chartSource,world.superAdminUserId());
        db.update("UPDATE finance_chart_codes SET currency_name='',currency_id=?,row_version=row_version+1 WHERE code='112201'",base);
        db.update("UPDATE finance_chart_codes SET currency_name='未映射外币',currency_id=NULL,row_version=row_version+1 WHERE code='112202'");
        byte[] file=auxiliaryMixedFile();var first=imports.preview(true,"辅助混币匿名账套",base,LocalDate.parse("2026-09-01"),LocalDate.parse("2026-09-30"),"mixed.xlsx",file);
        assertThat(first.rows()).hasSize(2);assertThat(first.rows().getFirst().currencyId()).isEqualTo(base);assertThat(first.rows().getLast().currencyId()).isNull();
        assertThat(first.issues()).anySatisfy(issue->assertThat(issue.field()).isEqualTo("科目币别属性"));
        db.update("UPDATE finance_chart_codes SET currency_id=?,row_version=row_version+1 WHERE code='112202'",foreign);
        var checked=imports.recheck(first.importId());assertThat(checked.importId()).isNotEqualTo(first.importId());assertThat(checked.issues()).isEmpty();
        assertThat(checked.rows().getFirst().currencyId()).isEqualTo(base);assertThat(checked.rows().getLast().currencyId()).isEqualTo(foreign);
        assertThat(imports.imported(first.importId()).rows().getLast().currencyId()).isNull();
        assertThat(imports.preview(true,"辅助混币匿名账套",base,LocalDate.parse("2026-09-01"),LocalDate.parse("2026-09-30"),"again.xlsx",file).importId()).isEqualTo(checked.importId());
        var frozen=accountingSources.readForAccounting(checked.importId());assertThat(frozen.rows().getLast().currencyId()).isEqualTo(foreign);assertThat(frozen.rows().getLast().chartVersion()).isNotNull();
        assertThat(accountingSources.readForAccounting(first.importId()).valid()).isFalse();
    }

    @Test void externalAuxiliaryImportStagesDraftsAndComparisonsWithoutPostingSourceAmounts()throws Exception {
        var fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);var world=fixture.seedWorld("finance-aux-import");fixture.loginAs(world.superAdminUserId());
        UUID source=UUID.randomUUID();db.update("INSERT INTO finance_chart_imports(id,actor_id,source_name,sha256,storage_provider,storage_key,storage_size,preview) VALUES(?,?,'anonymous.xls',?,'TEST','anonymous',1,'{}')",source,world.superAdminUserId(),"d".repeat(64));
        db.update("INSERT INTO finance_chart_codes(code,name,sort_order,source_row,source_import_id,updated_by) VALUES('112201','匿名目录',1,1,?,?) ON CONFLICT DO NOTHING",source,world.superAdminUserId());
        int journals=db.queryForObject("SELECT count(*) FROM gl_entries",Integer.class);
        byte[] file=auxiliaryFile();LocalDate from=LocalDate.parse("2026-09-01"),to=LocalDate.parse("2026-09-30");
        var preview=imports.preview(true,"辅助导入匿名账套",world.currencyId(),from,to,"anonymous.xlsx",file);
        assertThat(preview.issues()).isEmpty();assertThat(imports.preview(true,"辅助导入匿名账套",world.currencyId(),from,to,"renamed.xlsx",file).importId()).isEqualTo(preview.importId());
        assertThat(imports.compare(preview.importId()).getFirst().status()).isEqualTo("AUXILIARY_NOT_REGISTERED");
        var applied=imports.applyDirectory(preview.importId());assertThat(applied.auxiliaryCount()).isEqualTo(1);
        assertThat(imports.applyDirectory(preview.importId())).isEqualTo(applied);
        var ref=service.resolveImported("112201","辅助导入匿名账套","CUSTOMER","00099",world.currencyId());assertThat(ref.partyId()).isNull();
        assertThatThrownBy(()->service.validateForPosting(List.of(new Selection("112201",ref.auxiliaryId(),world.currencyId())))).isInstanceOf(ApiException.class);
        assertThat(imports.compare(preview.importId()).getFirst().status()).isEqualTo("LEDGER_EVIDENCE_MISSING");
        assertThat(db.queryForObject("SELECT count(*) FROM gl_entries",Integer.class)).isEqualTo(journals);
        assertThat(imports.imported(preview.importId()).directoryApplied()).isTrue();
        var other=fixture.seedWorld("finance-aux-import-owner");fixture.loginAs(other.superAdminUserId());
        assertThatThrownBy(()->imports.imported(preview.importId())).isInstanceOf(ApiException.class).hasMessageContaining("当前账号");
        var evidence=accountingSources.readForAccounting(preview.importId());
        assertThat(evidence.actorId()).isEqualTo(world.superAdminUserId());assertThat(evidence.valid()).isTrue();
        assertThat(evidence.rows().getFirst().accountName()).isEqualTo("匿名原科目");
    }

    @Test void explicitAuxiliaryIdentityIsReplayableAndFourteenColumnsUseLocalLedgerFacts() {
        var fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);
        var world=fixture.seedWorld("finance-aux");fixture.loginAs(world.superAdminUserId());
        UUID imported=UUID.randomUUID();
        db.update("INSERT INTO finance_chart_imports(id,actor_id,source_name,sha256,storage_provider,storage_key,storage_size,preview) VALUES(?,?,'anonymous.xls',?,'TEST','anonymous',1,'{}')",
                imported,world.superAdminUserId(),"a".repeat(64));
        for(String code:List.of("112201","2202","1221"))db.update("INSERT INTO finance_chart_codes(code,name,sort_order,source_row,source_import_id,updated_by) VALUES(?,? ,1,1,?,?) ON CONFLICT DO NOTHING",
                code,"原目录名称",imported,world.superAdminUserId());
        var draft=service.save(new Save(null,null,"匿名账套","00017","原客户名称","CUSTOMER",null,"原表第17行","112201"));
        assertThat(service.save(new Save(null,null,"匿名账套","00017","原客户名称","CUSTOMER",null,"原表第17行","112201")).id()).isEqualTo(draft.id());
        assertThat(service.inspect(new Selection("112201",draft.id(),world.currencyId())).partyId()).isNull();
        assertThatThrownBy(()->service.validateForPosting(List.of(new Selection("112201",draft.id(),world.currencyId())))).isInstanceOf(ApiException.class).hasMessageContaining("草稿");
        assertThatThrownBy(()->service.resolveImported("112201","匿名账套","CUSTOMER","17",world.currencyId())).isInstanceOf(ApiException.class);
        var mapped=service.save(new Save(draft.id(),draft.version(),"匿名账套","00017","原客户名称","CUSTOMER",world.clientId(),"已核验原编号","112201"));
        assertThat(service.validateForPosting(List.of(new Selection("112201",mapped.id(),world.currencyId()))).getFirst().partyId()).isEqualTo(world.clientId());
        var opposite=service.save(new Save(null,null,"匿名账套","00018","原客户名称","CUSTOMER",world.clientId(),"同名保留独立原编号","112201"));
        assertThat(opposite.id()).isNotEqualTo(mapped.id());
        assertThatThrownBy(()->service.resolveNative("112201","CUSTOMER",world.clientId(),world.currencyId())).isInstanceOf(ApiException.class).hasMessageContaining("多个");
        assertThatThrownBy(()->service.saveRule("112201",new RuleInput(-1,false,List.of("CUSTOMER"),"测试不能关闭"))).isInstanceOf(ApiException.class);
        var supplier=service.save(new Save(null,null,"匿名账套","00017","原供应商名称","SUPPLIER",world.supplierId(),"供应商原编号","2202"));
        assertThatThrownBy(()->service.validateForPosting(List.of(new Selection("112201",supplier.id(),world.currencyId())))).isInstanceOf(ApiException.class);
        UUID style=db.queryForObject("SELECT id FROM payment_styles WHERE NOT is_deleted AND category='ACCOUNT' ORDER BY id LIMIT 1",UUID.class);
        UUID opening=fact(world,style,mapped,"112201",1,"100.1234","2026-08-31");
        UUID contraOpening=fact(world,style,opposite,"112201",-1,"100.1234","2026-08-31");
        fact(world,style,mapped,"112201",1,"20.0001","2026-09-05");
        fact(world,style,mapped,"112201",-1,"7.0000","2026-09-06");
        fact(world,style,mapped,"112201",1,"999.0000","2026-10-01");
        proof(world,mapped,opening,"100.1234","0");proof(world,opposite,contraOpening,"0","100.1234");
        var zero=service.save(new Save(null,null,"匿名账套","00019","受审零余额客户","CUSTOMER",world.clientId(),"已核验零余额","112201"));
        proof(world,zero,null,"0","0");
        db.update("INSERT INTO finance_accounting_period_coverage(period,entries_revision,source_kind,source_sha256,verified_by) SELECT period,revision,'ANONYMOUS_TEST',?,? FROM finance_gl_period_versions WHERE period='2026-09'", "b".repeat(64),world.superAdminUserId());
        var report=FinanceAuxiliaryReports.balances(em,access,true,LocalDate.parse("2026-09-01"),LocalDate.parse("2026-09-30"),"112201",null,world.currencyId(),"匿名账套",1,50,FinanceReportColumnOptions.NONE);
        assertThat(report.columns()).hasSize(14);
        assertThat(report.columns().stream().map(ReportColumn::label)).containsExactly("科目编码","科目名称","客户编号","客户名称","方向","期初借方余额","期初贷方余额","期初余额金额","本期借方金额","本期贷方金额","期末借方余额","期末贷方余额","方向20","期末余额金额");
        assertThat(report.rows()).hasSize(3);
        var row=report.rows().stream().filter(r->"00017".equals(r.get("partyCode"))).findFirst().orElseThrow();
        assertThat(row.get("accountName")).isEqualTo("原用途科目名称");
        decimal(row,"openingDebit","100.1234");decimal(row,"debit","20.0001");decimal(row,"credit","7.0000");decimal(row,"closingBalance","113.1235");
        assertThat(row.get("openingDirection")).isEqualTo("借");
        var contra=report.rows().stream().filter(r->"00018".equals(r.get("partyCode"))).findFirst().orElseThrow();
        decimal(contra,"openingCredit","100.1234");assertThat(contra.get("closingDirection")).isEqualTo("贷");
        var verifiedZero=report.rows().stream().filter(r->"00019".equals(r.get("partyCode"))).findFirst().orElseThrow();
        decimal(verifiedZero,"closingBalance","0");assertThat(verifiedZero.get("closingDirection")).isEqualTo("平");
        db.update("UPDATE finance_accounting_period_coverage SET entries_revision=entries_revision-1 WHERE period='2026-09'");
        var stale=FinanceAuxiliaryReports.balances(em,access,true,LocalDate.parse("2026-09-01"),LocalDate.parse("2026-09-30"),"112201",mapped.id(),world.currencyId(),"匿名账套",1,50,FinanceReportColumnOptions.NONE).rows().getFirst();
        decimal(stale,"openingDebit","100.1234");decimal(stale,"debit","20.0001");decimal(stale,"closingBalance","113.1235");
        assertThatThrownBy(()->service.save(new Save(mapped.id(),mapped.version(),"匿名账套","00017","原客户名称","CUSTOMER",null,"已核验原编号","112201"))).isInstanceOf(ApiException.class).hasMessageContaining("分录引用");
        db.update("UPDATE finance_auxiliary_items SET status='ARCHIVED' WHERE id=?",mapped.id());
        var originalSelection=new Selection("112201",mapped.id(),world.currencyId());
        assertThat(service.inspectHistorical(originalSelection).partyId()).isEqualTo(world.clientId());
        assertThatThrownBy(()->service.inspect(originalSelection)).isInstanceOf(ApiException.class).hasMessageContaining("停用");
        assertThatThrownBy(()->service.validateForPosting(List.of(originalSelection))).isInstanceOf(ApiException.class).hasMessageContaining("停用");
        var archived=FinanceAuxiliaryReports.balances(em,access,true,LocalDate.parse("2026-09-01"),LocalDate.parse("2026-09-30"),"112201",mapped.id(),world.currencyId(),"匿名账套",1,50,FinanceReportColumnOptions.NONE).rows().getFirst();
        decimal(archived,"closingBalance","113.1235");
    }
    private UUID fact(FullChainEndToEndTest.World world,UUID style,Item item,String code,int direction,String amount,String date) {
        UUID voucher=UUID.randomUUID(),entry=UUID.randomUUID();
        db.update("INSERT INTO finance_gl_period_versions(period,revision) VALUES(?,0) ON CONFLICT DO NOTHING",date.substring(0,7));
        db.update("INSERT INTO gl_vouchers(id,voucher_no,period,voucher_date,source,source_type,status) VALUES(?,?,?,?::date,'MANUAL','AUX_TEST',1)",voucher,voucher.toString(),date.substring(0,7),date);
        db.update("INSERT INTO gl_entries(id,voucher_id,style_id,direction,amount,entry_date,period) VALUES(?,?,?,?,?::numeric,?::date,?)",entry,voucher,style,direction,amount,date,date.substring(0,7));
        db.update("INSERT INTO finance_gl_entry_allocations(entry_id,allocation_no,account_code,auxiliary_id,currency_id,amount_local,auxiliary_role,party_id_snapshot,source_system,source_code,source_name,source_account_code,source_account_name,source_entry_id,source_row,source_snapshot,created_by) VALUES(?,1,?,?,?,?,?,?,?,?,?,?,?,'anonymous',1,'{}',?)",
                entry,code,item.id(),world.currencyId(),new BigDecimal(amount),item.role(),item.partyId(),item.sourceSystem(),item.sourceCode(),item.sourceName(),code,"原用途科目名称",world.superAdminUserId());
        return entry;
    }
    private void proof(FullChainEndToEndTest.World world,Item item,UUID entry,String debit,String credit) {
        UUID batch=UUID.randomUUID(),approver=db.queryForObject("SELECT id FROM users WHERE id<>? ORDER BY id LIMIT 1",UUID.class,world.superAdminUserId());
        db.update("INSERT INTO finance_accounting_import_batches(id,actor_id,source_name,storage_provider,storage_key,storage_size,sha256,source_system,preview) VALUES(?,?,'anonymous.xls','TEST',?,1,?,'匿名账套','{}')",batch,world.superAdminUserId(),batch.toString(),batch.toString().replace("-","").repeat(2));
        db.update("INSERT INTO finance_gl_auxiliary_opening_evidence(import_batch_id,account_code,auxiliary_id,currency_id,effective_from,opening_debit,opening_credit,entry_id,auxiliary_role,party_id_snapshot,source_system,source_code,source_name,source_account_code,source_account_name,source_account_path_name,source_sha256,source_row,submitted_by,approved_by) VALUES(?,'112201',?,?,'2026-09-01',?::numeric,?::numeric,?,'CUSTOMER',?,'匿名账套',?,?,'112201','原凭证科目名','原用途科目名称',?,1,?,?)",
                batch,item.id(),world.currencyId(),debit,credit,entry,world.clientId(),item.sourceCode(),item.sourceName(),"c".repeat(64),world.superAdminUserId(),approver);
    }
    private static void decimal(Map<String,Object> row,String key,String expected){assertThat(new BigDecimal(row.get(key).toString())).isEqualByComparingTo(expected);}
    private static byte[] auxiliaryFile()throws Exception {
        try(var workbook=new org.apache.poi.xssf.usermodel.XSSFWorkbook();var bytes=new java.io.ByteArrayOutputStream()) {
            var sheet=workbook.createSheet("匿名明细");var header=sheet.createRow(2);
            for(int col=0;col<14;col++)header.createCell(col).setCellValue(com.uten.imp.features.finance.gl.FinanceTemplateContract.header("receivableAuxiliaryDetail",col));
            var row=sheet.createRow(3);row.createCell(0).setCellValue("112201");row.createCell(1).setCellValue("匿名原科目");row.createCell(2).setCellValue("00099");row.createCell(3).setCellValue("匿名原客户");
            row.createCell(4).setCellValue("借");for(int col=5;col<=11;col++)row.createCell(col).setCellValue(col==5||col==7||col==10?10:0);
            row.createCell(12).setCellValue("借");row.createCell(13).setCellValue(10);workbook.write(bytes);return bytes.toByteArray();
        }
    }
    private static byte[] auxiliaryMixedFile()throws Exception {
        try(var workbook=new org.apache.poi.xssf.usermodel.XSSFWorkbook(new java.io.ByteArrayInputStream(auxiliaryFile()));var bytes=new java.io.ByteArrayOutputStream()) {
            var row=workbook.getSheetAt(0).createRow(4);row.createCell(0).setCellValue("112202");row.createCell(1).setCellValue("匿名外币用途原科目");row.createCell(2).setCellValue("00099");row.createCell(3).setCellValue("匿名原客户");row.createCell(4).setCellValue("借");
            for(int col=5;col<=11;col++){row.createCell(col).setCellValue(col==5||col==7||col==10?"20.123456789012345678901":"0");}row.createCell(12).setCellValue("借");row.createCell(13).setCellValue("20.123456789012345678901");workbook.write(bytes);return bytes.toByteArray();
        }
    }
}
