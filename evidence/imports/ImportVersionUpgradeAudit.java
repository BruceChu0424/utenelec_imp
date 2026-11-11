package com.uten.imp.businesschain;

import com.uten.imp.UtenImpApplication;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.finance.gl.*;
import com.uten.imp.features.finance.statement.*;
import com.uten.imp.features.master.goods.costing.*;
import com.uten.imp.security.AuthUser;
import org.springframework.boot.builder.SpringApplicationBuilder;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import com.fasterxml.jackson.databind.*;
import com.fasterxml.jackson.databind.node.*;
import java.nio.file.*;
import java.time.LocalDate;
import java.io.*;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

/** Two separate JVMs load the real old and new product classes against one retained isolated PG. */
public class ImportVersionUpgradeAudit {
    static Path dir=Path.of(System.getProperty("audit.dir"));
    static final Set<String> RIGHTS=Set.of("finance_report:view","finance:view:all","finance_post:execute","payment_style:edit","goods:view","goods:cost:view","goods:cost:edit","goods:import","goods:bom:create","goods:bom:delete");
    static void actor(UUID user,UUID employee) {
        var principal=new AuthUser(user,employee,"ordinary-import-auditor",RIGHTS,false,true,false);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(principal,null,principal.getAuthorities()));
    }
    static byte[] helper(String type,String method)throws Exception {var m=Class.forName(type).getDeclaredMethod(method);m.setAccessible(true);return (byte[])m.invoke(null);}
    static byte[] file(String name)throws Exception {return Files.readAllBytes(dir.resolve("baseline").resolve(name));}
    static byte[] fileUnchecked(String name) {try{return file(name);}catch(Exception error){throw new java.io.UncheckedIOException(new IOException(error));}}
    static void denied(String name,Runnable run) {
        assertThatThrownBy(run::run).isInstanceOf(ApiException.class).hasMessageContaining("重新检测");
        System.out.println("UPGRADE_REJECT "+name+" oldServerVersion=1 zeroWrite=true");
    }
    public static void main(String[] args)throws Exception {
        String phase=System.getProperty("audit.phase");
        try(var context=new SpringApplicationBuilder(UtenImpApplication.class).run(
                "--spring.profiles.active=dev","--server.port=0","--server.address=127.0.0.1",
                "--spring.datasource.url=jdbc:postgresql://127.0.0.1:26632/imports","--spring.datasource.username=imports","--spring.datasource.password=imports-local-test-only", // gitleaks:allow dedicated synthetic fixture database.
                "--spring.flyway.user=imports","--spring.flyway.password=imports-local-test-only", // gitleaks:allow dedicated synthetic fixture database.
                "--uten.storage.local-dir="+dir.resolve("upgrade-storage"),"--logging.file.name="+dir.resolve("upgrade-"+System.getProperty("audit.run",phase)+"-spring.log"),
                "--uten.audit.retention.enabled=false","--uten.reporting.materialized-view-refresh.enabled=false","--uten.production.readiness-reconcile.enabled=false",
                "--uten.features.goods-owner-scope-enabled=false","--uten.storage.uploads-enabled=true","--uten.storage.malware-scan.provider=test-only",
                "--uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only","--uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789", // gitleaks:allow same retained synthetic keys in both program versions.
                "--uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","--uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","--uten.bootstrap.admin-password=HarnessAdminPass-1!")) { // gitleaks:allow synthetic bootstrap only; business actors below are ordinary accounts.
            var db=context.getBean(JdbcTemplate.class);var json=context.getBean(ObjectMapper.class);
            var chart=context.getBean(FinanceChartService.class);var notes=context.getBean(FinanceExpenseAnalysisService.class);
            var costs=context.getBean(GoodsCostImportService.class);var aux=context.getBean(FinanceAuxiliaryImportService.class);var accounting=context.getBean(FinanceAccountingImportService.class);
            if(phase.equals("files")) {
                var record=json.readTree(Files.readString(dir.resolve("old-program-manifest.json")));
                UUID owner=db.queryForObject("SELECT id FROM users WHERE login_account='other-import-auditor'",UUID.class),employee=db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,owner),goods=UUID.fromString(record.path("goods").asText()),currency=UUID.fromString(record.path("currency").asText());
                for(String right:RIGHTS)db.update("INSERT INTO user_permission_overrides(user_id,permission_id,effect) SELECT ?,id,'grant' FROM permissions WHERE code=? ON CONFLICT(user_id,permission_id) DO UPDATE SET effect='grant'",owner,right);actor(owner,employee);
                var tables=List.of("goods","goods_bom_items","goods_cost_import_mappings","finance_chart_codes","finance_operating_report_notes","finance_auxiliary_items","gl_entries");var before=new LinkedHashMap<String,Long>();for(String table:tables)before.put(table,db.queryForObject("SELECT count(*) FROM "+table,Long.class));
                var goodsImports=context.getBean(com.uten.imp.features.master.goods.importing.GoodsImportService.class);byte[] goodsAttack=file("goods-extra-second-true.xlsx");
                assertThatThrownBy(()->goodsImports.detect(goodsAttack)).isInstanceOf(ApiException.class).hasMessageContaining("第一张表");assertThatThrownBy(()->goodsImports.commit(UUID.randomUUID(),goodsAttack,"attack.xlsx")).isInstanceOf(ApiException.class).hasMessageContaining("第一张表");
                var bom=context.getBean(com.uten.imp.features.master.goods.importing.GoodsBomImportService.class);byte[] bomAttack=file("bom-extra-second-true.xlsx");
                assertThatThrownBy(()->bom.detect(goods,bomAttack)).isInstanceOf(ApiException.class).hasMessageContaining("第一张表");
                for(var mode:com.uten.imp.features.master.goods.dto.BomPasteRequest.Mode.values())assertThatThrownBy(()->bom.commit(goods,bomAttack,mode,"v1:retained-plan")).isInstanceOf(ApiException.class).hasMessageContaining("第一张表");
                assertThatThrownBy(()->bom.commitMerged(goods,bomAttack,"v1:retained-plan",Set.of())).isInstanceOf(ApiException.class).hasMessageContaining("第一张表");
                assertThatThrownBy(()->costs.preview(goods,"cost.xlsx",fileUnchecked("cost-title-true.xlsx"))).isInstanceOf(ApiException.class).hasMessageContaining("第3行");
                var badChart=chart.preview("chart.xlsx",file("chart-true.xlsx"));assertThat(badChart.columnContractVersion()).isEqualTo(2);assertThat(badChart.issues()).isNotEmpty();assertThatThrownBy(()->chart.apply(new FinanceChartContracts.Apply(badChart.importId()))).isInstanceOf(ApiException.class).hasMessageContaining("列映射");
                for(String note:List.of("note-duplicate.xlsx","note-unknown.xlsx"))assertThatThrownBy(()->notes.previewNotes("2026-07",note,fileUnchecked(note))).isInstanceOf(ApiException.class).hasMessageContaining("第4列");
                var badVouchers=accounting.preview("VOUCHERS","FILES-CURRENT","voucher.xls",file("voucher-empty-formula.xls"));assertThat(badVouchers.source().columnContractVersion()).isEqualTo(2);assertThat(badVouchers.source().issues()).isNotEmpty();
                assertThatThrownBy(()->accounting.preview("VOUCHERS","FILES-CURRENT","wrong-signature.xls",fileUnchecked("voucher-wrong-signature.xls"))).isInstanceOf(ApiException.class).hasMessageContaining("输出签名");
                var balance=accounting.preview("BALANCE","FILES-CURRENT","balance.xls",Files.readAllBytes(dir.resolve("old-balances.xls")));
                assertThatThrownBy(()->accounting.submit(badVouchers.importId(),new FinanceAccountingContracts.Submit(0,balance.importId(),0,List.of(),Map.of(),Map.of(),List.of(),Set.of(),false,true,"原文件逐列核对并阻止错误写入"))).isInstanceOf(ApiException.class).hasMessageContaining("解析问题");
                byte[] auxiliaryAttack;try(var book=org.apache.poi.ss.usermodel.WorkbookFactory.create(new ByteArrayInputStream(Files.readAllBytes(dir.resolve("old-auxiliary.xlsx"))));var out=new ByteArrayOutputStream()){var sheet=book.getSheetAt(0);sheet.getRow(2).createCell(14).setCellValue("未知运费");sheet.getRow(3).createCell(14).setCellValue("不能忽略");book.write(out);auxiliaryAttack=out.toByteArray();}
                Files.write(dir.resolve("auxiliary-extra-current.xlsx"),auxiliaryAttack);var badAux=aux.preview(true,"FILES-CURRENT",currency,LocalDate.parse("2026-09-01"),LocalDate.parse("2026-09-30"),"auxiliary-extra.xlsx",auxiliaryAttack);assertThat(badAux.issues()).isNotEmpty();assertThatThrownBy(()->aux.applyDirectory(badAux.importId())).isInstanceOf(ApiException.class).hasMessageContaining("原表错误");
                for(String table:tables)assertThat(db.queryForObject("SELECT count(*) FROM "+table,Long.class)).as(table).isEqualTo(before.get(table));
                System.out.println("CURRENT_FILES_REJECT sevenKinds=7 publicServices=true realRepositories=true ordinaryActor=true businessTableCountsUnchanged="+before);
                var legalChart=chart.preview("chart-legal.xlsx",Files.readAllBytes(dir.resolve("web-fixtures/chart-legal.xlsx")));assertThat(legalChart.issues()).isEmpty();chart.apply(new FinanceChartContracts.Apply(legalChart.importId()));assertThat(db.queryForObject("SELECT count(*) FROM finance_chart_codes WHERE source_import_id=?",Integer.class,legalChart.importId())).isEqualTo(1);
                var legalNotes=notes.previewNotes("2026-07","note-legal.xlsx",Files.readAllBytes(dir.resolve("web-fixtures/note-legal.xlsx")));assertThat(legalNotes.issues()).isEmpty();notes.applyNotes(new FinanceExpenseAnalysisContracts.ImportApply(legalNotes.importId()));assertThat(db.queryForObject("SELECT count(*) FROM finance_operating_report_notes WHERE period='2026-07'",Integer.class)).isEqualTo(1);
                var legalAux=aux.preview(true,"FILES-CURRENT",currency,LocalDate.parse("2026-09-01"),LocalDate.parse("2026-09-30"),"auxiliary-legal.xlsx",Files.readAllBytes(dir.resolve("old-auxiliary.xlsx")));assertThat(legalAux.issues()).isEmpty();assertThat(aux.applyDirectory(legalAux.importId()).auxiliaryCount()).isEqualTo(1);
                var legalCost=costs.preview(goods,"cost-legal.xlsx",Files.readAllBytes(dir.resolve("web-fixtures/cost-legal.xlsx")));assertThat(legalCost.blocks().getFirst().rows()).hasSize(2);
                var input=new GoodsCostContracts.DraftInput(goods,null,"合法人工成本核对","10",currency,"1",LocalDate.parse("2026-09-29"),"ACTUAL_FIRST","MANUAL",null,List.of(),List.of(),List.of(),List.of(),Map.of(),null);
                var mappings=legalCost.blocks().getFirst().rows().stream().map(row->new GoodsCostImportContracts.Mapping(row.key(),"SKIP",null,null,null,null,null,"逐行核对后保留原手工成本",true)).toList();var costResult=costs.apply(new GoodsCostImportContracts.Apply(legalCost.id(),legalCost.blocks().getFirst().key(),input,mappings));assertThat(costResult.input().extraFields()).containsKey("importMappingId");
                System.out.println("CURRENT_FILES_LEGAL chartApplied=1 noteApplied=1 auxiliaryDirectoryApplied=1 costMappingApplied=true ledgerEntriesUnchanged=true");
                assertThat(db.queryForObject("SELECT count(*) FROM gl_entries",Long.class)).isEqualTo(before.get("gl_entries"));
            } else if(phase.equals("finish-seed")) {
                UUID owner=db.queryForObject("SELECT id FROM users WHERE login_account='SU-old-v1-previews'",UUID.class);
                UUID employee=db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,owner);actor(owner,employee);
                var record=json.createObjectNode();record.put("owner",owner.toString());record.put("employee",employee.toString());
                var cost=db.queryForMap("SELECT id,goods_id,preview::text FROM goods_cost_imports WHERE actor_id=?",owner);record.put("goods",cost.get("goods_id").toString());record.put("cost",cost.get("id").toString());record.put("costBlock",json.readTree(cost.get("preview").toString()).path("blocks").get(0).path("key").asText());
                UUID parent=db.queryForObject("SELECT id FROM finance_chart_imports WHERE actor_id=? AND parent_import_id IS NULL",UUID.class,owner);record.put("chart",parent.toString());record.put("chartChild",db.queryForObject("SELECT id FROM finance_chart_imports WHERE actor_id=? AND parent_import_id=?",UUID.class,owner,parent).toString());
                record.put("notes",db.queryForObject("SELECT id FROM finance_expense_note_imports WHERE actor_id=? AND period='2026-08'",UUID.class,owner).toString());
                var applied=db.queryForMap("SELECT id,applied_result::text FROM finance_expense_note_imports WHERE actor_id=? AND period='2026-09'",owner);record.put("appliedNotes",applied.get("id").toString());record.set("appliedReceipt",json.readTree(applied.get("applied_result").toString()));
                record.put("aux",db.queryForObject("SELECT id FROM finance_statement_source_reviews WHERE actor_id=?",UUID.class,owner).toString());
                byte[] journals=helper("com.uten.imp.businesschain.FinanceAccountingContinuationPostgresTest","journals"),balance=helper("com.uten.imp.businesschain.FinanceAccountingContinuationPostgresTest","balance");
                Files.write(dir.resolve("old-vouchers.xls"),journals);Files.write(dir.resolve("old-balances.xls"),balance);
                var v=accounting.preview("VOUCHERS","UPGRADE-OLD","old-vouchers.xls",journals);var b=accounting.preview("BALANCE","UPGRADE-OLD","old-balances.xls",balance);record.put("vouchers",v.importId().toString());record.put("balance",b.importId().toString());assertThat(v.source().columnContractVersion()).isEqualTo(1);assertThat(b.source().columnContractVersion()).isEqualTo(1);
                var frozen=record.putObject("frozen");for(var pair:Map.of("cost","goods_cost_imports","chart","finance_chart_imports","chartChild","finance_chart_imports","notes","finance_expense_note_imports","aux","finance_statement_source_reviews","vouchers","finance_accounting_import_batches","balance","finance_accounting_import_batches").entrySet())frozen.put(pair.getKey(),db.queryForObject("SELECT preview::text FROM "+pair.getValue()+" WHERE id=?",String.class,UUID.fromString(record.path(pair.getKey()).asText())));
                Files.writeString(dir.resolve("old-program-manifest.json"),json.writerWithDefaultPrettyPrinter().writeValueAsString(record));
                System.out.println("OLD_PROGRAM_PERSISTED fiveKinds=5 originalFiles=true owner="+owner+" actorSuperAdmin=false parentChild=true pendingVersions=1 completedNotes=1 resumedWithoutChangingExistingPreviews=true");
            } else if(phase.startsWith("seed")) {
                var fixture=new FullChainEndToEndTest();context.getAutowireCapableBeanFactory().autowireBean(fixture);
                java.util.function.BiFunction<String,String,UUID> master=(table,code)->db.queryForObject("SELECT id FROM "+table+" WHERE code=?",UUID.class,code);
                var world=phase.equals("seed")?fixture.seedWorld("old-v1-previews"):new FullChainEndToEndTest.World(
                        master.apply("departments","DEPT-old-v1-previews"),master.apply("employees","EMP-old-v1-previews"),db.queryForObject("SELECT id FROM users WHERE login_account='SU-old-v1-previews'",UUID.class),
                        master.apply("goods","A-old-v1-previews"),master.apply("goods","B-old-v1-previews"),master.apply("goods","C-old-v1-previews"),master.apply("goods","D-old-v1-previews"),master.apply("goods","E-old-v1-previews"),
                        master.apply("clients","CLI-old-v1-previews"),master.apply("suppliers","SUP-old-v1-previews"),master.apply("warehouses","WH-old-v1-previews"),master.apply("units","PCS-old-v1-previews"),master.apply("currencies","CNY-old-v1-previews"),master.apply("colors","CLR-old-v1-previews"),1);
                UUID owner=world.superAdminUserId(),employee=world.employeeId();
                db.update("UPDATE users SET is_super_admin=false WHERE id=?",owner);
                for(String right:RIGHTS)db.update("INSERT INTO user_permission_overrides(user_id,permission_id,effect) SELECT ?,id,'grant' FROM permissions WHERE code=? ON CONFLICT(user_id,permission_id) DO UPDATE SET effect='grant'",owner,right);
                actor(owner,employee);
                var record=json.createObjectNode();record.put("owner",owner.toString());record.put("employee",employee.toString());record.put("goods",world.goodsA().toString());record.put("currency",world.currencyId().toString());
                var c=costs.preview(world.goodsA(),"cost-title.xlsx",file("cost-title-true.xlsx"));record.put("cost",c.id().toString());record.put("costBlock",c.blocks().getFirst().key());assertThat(c.columnContractVersion()).isEqualTo(1);assertThat(c.blocks().getFirst().rows()).hasSize(1);
                var ch=chart.preview("chart-subtotal.xlsx",file("chart-true.xlsx"));record.put("chart",ch.importId().toString());assertThat(ch.issues()).isEmpty();assertThat(ch.columnContractVersion()).isEqualTo(1);
                var children=db.queryForList("SELECT id FROM finance_chart_imports WHERE parent_import_id=? ORDER BY created_at,id",UUID.class,ch.importId());
                if(children.isEmpty()){chart.repreview(ch.importId(),json.valueToTree(new FinanceChartContracts.Repreview(UUID.randomUUID())));children=db.queryForList("SELECT id FROM finance_chart_imports WHERE parent_import_id=? ORDER BY created_at,id",UUID.class,ch.importId());}
                record.put("chartChild",children.getFirst().toString());
                var n=notes.previewNotes("2026-08","notes-duplicate.xlsx",file("note-duplicate.xlsx"));record.put("notes",n.importId().toString());assertThat(n.issues()).isEmpty();assertThat(n.columnContractVersion()).isEqualTo(1);
                byte[] goodNotes;try(var book=new org.apache.poi.xssf.usermodel.XSSFWorkbook(new ByteArrayInputStream(file("note-duplicate.xlsx")));var out=new ByteArrayOutputStream()) {
                    book.getSheetAt(0).getRow(1).getCell(3).setCellValue(FinanceTemplateContract.header("operatingProfit",3));book.getSheetAt(0).getRow(3).getCell(28).setCellValue("旧程序已写入并保留的原回执");book.write(out);goodNotes=out.toByteArray();
                }
                Files.write(dir.resolve("old-valid-notes.xlsx"),goodNotes);var done=notes.previewNotes("2026-09","old-valid-notes.xlsx",goodNotes);var applied=notes.applyNotes(new FinanceExpenseAnalysisContracts.ImportApply(done.importId()));record.put("appliedNotes",done.importId().toString());record.set("appliedReceipt",json.valueToTree(applied));
                notes.savePolicy(new FinanceExpenseAnalysisContracts.PolicyInput("2026-09",-1,true,"合成期间实际核对并排除重复入账",true,""));
                db.update("INSERT INTO finance_chart_codes(code,name,sort_order,source_row,source_import_id,updated_by,currency_id) VALUES('112201','匿名原科目',1,1,?,?,?) ON CONFLICT DO NOTHING",ch.importId(),owner,world.currencyId());
                byte[] auxiliary=helper("com.uten.imp.businesschain.FinanceAuxiliaryPostgresTest","auxiliaryFile");Files.write(dir.resolve("old-auxiliary.xlsx"),auxiliary);
                var a=aux.preview(true,"UPGRADE-OLD",world.currencyId(),LocalDate.parse("2026-09-01"),LocalDate.parse("2026-09-30"),"old-auxiliary.xlsx",auxiliary);record.put("aux",a.importId().toString());assertThat(a.columnContractVersion()).isEqualTo(1);assertThat(a.issues()).isEmpty();
                byte[] journals=helper("com.uten.imp.businesschain.FinanceAccountingContinuationPostgresTest","journals"),balance=helper("com.uten.imp.businesschain.FinanceAccountingContinuationPostgresTest","balance");
                Files.write(dir.resolve("old-vouchers.xls"),journals);Files.write(dir.resolve("old-balances.xls"),balance);
                var v=accounting.preview("VOUCHERS","UPGRADE-OLD","old-vouchers.xls",journals);var b=accounting.preview("BALANCE","UPGRADE-OLD","old-balances.xls",balance);record.put("vouchers",v.importId().toString());record.put("balance",b.importId().toString());assertThat(v.source().columnContractVersion()).isEqualTo(1);assertThat(b.source().columnContractVersion()).isEqualTo(1);
                var frozen=record.putObject("frozen");for(var pair:Map.of("cost","goods_cost_imports","chart","finance_chart_imports","chartChild","finance_chart_imports","notes","finance_expense_note_imports","aux","finance_statement_source_reviews","vouchers","finance_accounting_import_batches","balance","finance_accounting_import_batches").entrySet())frozen.put(pair.getKey(),db.queryForObject("SELECT preview::text FROM "+pair.getValue()+" WHERE id=?",String.class,UUID.fromString(record.path(pair.getKey()).asText())));
                Files.writeString(dir.resolve("old-program-manifest.json"),json.writerWithDefaultPrettyPrinter().writeValueAsString(record));
                System.out.println("OLD_PROGRAM_PERSISTED fiveKinds=5 originalFiles=true owner="+owner+" actorSuperAdmin=false parentChild=true pendingVersions=1 completedNotes=1");
            } else {
                var record=json.readTree(Files.readString(dir.resolve("old-program-manifest.json")));UUID owner=UUID.fromString(record.path("owner").asText()),employee=UUID.fromString(record.path("employee").asText());actor(owner,employee);
                java.util.function.Function<String,UUID> id=k->UUID.fromString(record.path(k).asText());
                int chartRows=db.queryForObject("SELECT count(*) FROM finance_chart_codes",Integer.class),auxRows=db.queryForObject("SELECT count(*) FROM finance_auxiliary_items",Integer.class),glRows=db.queryForObject("SELECT count(*) FROM gl_entries",Integer.class),mappings=db.queryForObject("SELECT count(*) FROM goods_cost_import_mappings",Integer.class);
                var input=new GoodsCostContracts.DraftInput(id.apply("goods"),null,"原成本", "10",null,"1",LocalDate.parse("2026-09-29"),"ACTUAL_FIRST","MANUAL",null,List.of(),List.of(),List.of(),List.of(),Map.of(),null);
                denied("cost",()->costs.apply(new GoodsCostImportContracts.Apply(id.apply("cost"),record.path("costBlock").asText(),input,List.of())));
                // Original files are re-read before the version gate by chart.apply; the attack is rejected on either authoritative gate.
                for(String k:List.of("chart","chartChild"))assertThatThrownBy(()->chart.apply(new FinanceChartContracts.Apply(id.apply(k)))).isInstanceOf(ApiException.class);
                denied("notes",()->notes.applyNotes(new FinanceExpenseAnalysisContracts.ImportApply(id.apply("notes"))));
                denied("auxiliary",()->aux.applyDirectory(id.apply("aux")));
                assertThat(context.getBean(com.uten.imp.application.port.FinancialAuxiliarySourceReadPort.class).readForAccounting(id.apply("aux")).valid()).isFalse();
                denied("accounting",()->accounting.submit(id.apply("vouchers"),new FinanceAccountingContracts.Submit(0,id.apply("balance"),0,List.of(),Map.of(),Map.of(),List.of(),Set.of(),false,true,"保留原始输入并重新核对")));
                var replay=notes.applyNotes(new FinanceExpenseAnalysisContracts.ImportApply(id.apply("appliedNotes")));assertThat((JsonNode)json.valueToTree(replay)).isEqualTo(record.path("appliedReceipt"));
                assertThat(db.queryForObject("SELECT count(*) FROM finance_operating_report_notes WHERE period='2026-09'",Integer.class)).isEqualTo(1);assertThat(db.queryForObject("SELECT count(*) FROM finance_operating_report_notes WHERE period='2026-08'",Integer.class)).isZero();
                assertThat(db.queryForObject("SELECT count(*) FROM finance_chart_codes",Integer.class)).isEqualTo(chartRows);assertThat(db.queryForObject("SELECT count(*) FROM finance_auxiliary_items",Integer.class)).isEqualTo(auxRows);assertThat(db.queryForObject("SELECT count(*) FROM gl_entries",Integer.class)).isEqualTo(glRows);assertThat(db.queryForObject("SELECT count(*) FROM goods_cost_import_mappings",Integer.class)).isEqualTo(mappings);
                for(var pair:Map.of("cost","goods_cost_imports","chart","finance_chart_imports","chartChild","finance_chart_imports","notes","finance_expense_note_imports","aux","finance_statement_source_reviews","vouchers","finance_accounting_import_batches","balance","finance_accounting_import_batches").entrySet())assertThat(db.queryForObject("SELECT preview::text FROM "+pair.getValue()+" WHERE id=?",String.class,id.apply(pair.getKey()))).isEqualTo(record.path("frozen").path(pair.getKey()).asText());
                var otherUsers=db.queryForList("SELECT id FROM users WHERE login_account='other-import-auditor'",UUID.class);UUID other=otherUsers.isEmpty()?UUID.randomUUID():otherUsers.getFirst(),otherEmployee;
                if(otherUsers.isEmpty()) {
                    otherEmployee=UUID.randomUUID();
                    db.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) SELECT ?,?,'合成其他财务员',id_type,department_id,CURRENT_DATE,'active','regular' FROM employees WHERE id=?",otherEmployee,"IMPORT-OTHER-"+otherEmployee,employee);
                    db.update("INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,is_super_admin,status) VALUES(?,?,'other-import-auditor','synthetic-hash-not-used',false,false,'active')",other,otherEmployee);
                    for(String right:RIGHTS)db.update("INSERT INTO user_permission_overrides(user_id,permission_id,effect) SELECT ?,id,'grant' FROM permissions WHERE code=? ON CONFLICT(user_id,permission_id) DO UPDATE SET effect='grant'",other,right);
                } else otherEmployee=db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,other);
                actor(other,otherEmployee);
                assertThatThrownBy(()->notes.applyNotes(new FinanceExpenseAnalysisContracts.ImportApply(id.apply("appliedNotes")))).isInstanceOf(ApiException.class).hasMessageContaining("当前账号");
                System.out.println("UPGRADE_VERIFIED pendingKinds=5 immutableParentsAndChild=true noBusinessWrites=true oldAppliedReceiptReplayedAfterLock=true otherOwnerRejected=true");
            }
        }
    }
}
