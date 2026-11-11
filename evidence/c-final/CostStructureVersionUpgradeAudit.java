package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.UtenImpApplication;
import com.uten.imp.common.importing.ImportColumnGuard;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.master.goods.costing.*;
import com.uten.imp.security.AuthUser;
import java.nio.file.*;
import java.time.LocalDate;
import java.util.*;
import org.springframework.boot.builder.SpringApplicationBuilder;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import static org.assertj.core.api.Assertions.*;

/** Real old/new JVM public service calls against only retained synthetic PG 26632. */
public class CostStructureVersionUpgradeAudit {
  static final Set<String> RIGHTS=Set.of("finance_report:view","finance:view:all","finance_post:execute","payment_style:edit","goods:view","goods:cost:view","goods:cost:edit","goods:import","goods:bom:create","goods:bom:delete");
  static void actor(UUID user,UUID employee) {
    var principal=new AuthUser(user,employee,"ordinary-import-auditor",RIGHTS,false,true,false);
    SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(principal,null,principal.getAuthorities()));
  }
  static Map<String,Long> counts(JdbcTemplate db) {
    var result=new LinkedHashMap<String,Long>();
    for(String table:List.of("goods","goods_bom_items","goods_cost_import_mappings","finance_chart_codes","finance_operating_report_notes","finance_auxiliary_items","gl_entries"))
      result.put(table,db.queryForObject("SELECT count(*) FROM "+table,Long.class));
    return result;
  }
  public static void main(String[] arguments)throws Exception {
    Path dir=Path.of(System.getProperty("audit.dir")), previous=Path.of(System.getProperty("audit.previous"));
    String phase=System.getProperty("audit.phase"),run=System.getProperty("audit.run");
    try(var context=new SpringApplicationBuilder(UtenImpApplication.class).run(
        "--spring.profiles.active=dev","--server.port=0","--server.address=127.0.0.1",
        "--spring.datasource.url=jdbc:postgresql://127.0.0.1:26632/imports","--spring.datasource.username=imports","--spring.datasource.password=imports-local-test-only", // gitleaks:allow isolated synthetic database only.
        "--spring.flyway.user=imports","--spring.flyway.password=imports-local-test-only", // gitleaks:allow isolated synthetic database only.
        "--uten.storage.local-dir="+previous.resolve("upgrade-storage"),"--logging.file.name="+dir.resolve(run+"-spring.log"),
        "--uten.audit.retention.enabled=false","--uten.reporting.materialized-view-refresh.enabled=false","--uten.production.readiness-reconcile.enabled=false",
        "--uten.features.goods-owner-scope-enabled=false","--uten.storage.uploads-enabled=true","--uten.storage.malware-scan.provider=test-only",
        "--uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only","--uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789", // gitleaks:allow exact retained synthetic old/new key lineage.
        "--uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","--uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","--uten.bootstrap.admin-password=HarnessAdminPass-1!")) { // gitleaks:allow synthetic bootstrap only; test actor is ordinary.
      var db=context.getBean(JdbcTemplate.class);var json=context.getBean(ObjectMapper.class);var service=context.getBean(GoodsCostImportService.class);
      var original=json.readTree(Files.readString(previous.resolve("old-program-manifest.json")));
      UUID owner=UUID.fromString(original.path("owner").asText()),employee=UUID.fromString(original.path("employee").asText()),goods=UUID.fromString(original.path("goods").asText()),currency=UUID.fromString(original.path("currency").asText());
      assertThat(db.queryForObject("SELECT is_super_admin FROM users WHERE id=?",Boolean.class,owner)).isFalse();actor(owner,employee);
      var input=new GoodsCostContracts.DraftInput(goods,null,"结构行升级核对","10",currency,"1",LocalDate.parse("2026-09-29"),"ACTUAL_FIRST","MANUAL",null,List.of(),List.of(),List.of(),List.of(),Map.of(),null);
      if(phase.equals("seed")) {
        assertThat(ImportColumnGuard.VERSION).isEqualTo(2);
        assertThat(Files.exists(dir.resolve("old-v2-program.json"))).isFalse();
        var manifest=json.createObjectNode();manifest.put("serverSafetyVersion",ImportColumnGuard.VERSION);manifest.put("owner",owner.toString());manifest.put("employee",employee.toString());manifest.put("goods",goods.toString());manifest.put("currency",currency.toString());manifest.put("actorSuperAdmin",false);manifest.put("originalV1Manifest",previous.resolve("old-program-manifest.json").toString());
        for(String name:List.of("mixed-header-tail","subtotal-name-control")) {
          var preview=service.preview(goods,name+".xlsx",Files.readAllBytes(dir.resolve("originals").resolve(name+".xlsx")));
          assertThat(preview.columnContractVersion()).isEqualTo(2);assertThat(preview.blocks().getFirst().rows()).hasSize(1);
          var node=manifest.putObject(name);node.put("id",preview.id().toString());node.put("block",preview.blocks().getFirst().key());node.put("sha256",preview.sha256());node.put("frozenPreview",db.queryForObject("SELECT preview::text FROM goods_cost_imports WHERE id=?",String.class,preview.id()));
          node.set("source",json.valueToTree(db.queryForMap("SELECT actor_id,goods_id,source_name,storage_provider,storage_key,storage_version,storage_size,storage_sha256 FROM goods_cost_imports WHERE id=?",preview.id())));
          System.out.println("OLD_V2_PUBLIC_PREVIEW file="+name+" id="+preview.id()+" owner="+owner+" rows="+preview.blocks().getFirst().rows().size()+" sha256="+preview.sha256()+" serverVersion="+preview.columnContractVersion()+" actorSuperAdmin=false");
        }
        manifest.set("businessCounts",json.valueToTree(counts(db)));
        Files.writeString(dir.resolve("old-v2-program.json"),json.writerWithDefaultPrettyPrinter().writeValueAsString(manifest),StandardOpenOption.CREATE_NEW);
      } else if(phase.equals("seed-finance")) {
        assertThat(ImportColumnGuard.VERSION).isEqualTo(2);
        assertThat(Files.exists(dir.resolve("old-v2-finance.json"))).isFalse();
        var chart=context.getBean(com.uten.imp.features.finance.gl.FinanceChartService.class);
        var notes=context.getBean(com.uten.imp.features.finance.gl.FinanceExpenseAnalysisService.class);
        var auxiliary=context.getBean(com.uten.imp.features.finance.statement.FinanceAuxiliaryImportService.class);
        var accounting=context.getBean(com.uten.imp.features.finance.gl.FinanceAccountingImportService.class);
        var manifest=json.createObjectNode();manifest.put("owner",owner.toString());manifest.put("actorSuperAdmin",false);
        var ch=chart.preview("v2-chart.xls",Files.readAllBytes(dir.getParent().getParent().resolve("server/src/test/resources/finance/finance-chart-codes.xls")));
        assertThat(ch.columnContractVersion()).isEqualTo(2);assertThat(ch.issues()).isEmpty();manifest.put("chart",ch.importId().toString());
        chart.repreview(ch.importId(),json.valueToTree(new com.uten.imp.features.finance.gl.FinanceChartContracts.Repreview(UUID.randomUUID())));
        manifest.put("chartChild",db.queryForObject("SELECT id FROM finance_chart_imports WHERE parent_import_id=?",UUID.class,ch.importId()).toString());
        var note=notes.previewNotes("2026-10","v2-note.xlsx",Files.readAllBytes(previous.resolve("old-valid-notes.xlsx")));
        assertThat(note.columnContractVersion()).isEqualTo(2);assertThat(note.issues()).isEmpty();manifest.put("notes",note.importId().toString());
        var aux=auxiliary.preview(true,"UPGRADE-V2",currency,LocalDate.parse("2026-09-01"),LocalDate.parse("2026-09-30"),"v2-aux.xlsx",Files.readAllBytes(previous.resolve("old-auxiliary.xlsx")));
        assertThat(aux.columnContractVersion()).isEqualTo(2);assertThat(aux.issues()).isEmpty();manifest.put("auxiliary",aux.importId().toString());
        var vouchers=accounting.preview("VOUCHERS","UPGRADE-V2","v2-vouchers.xls",Files.readAllBytes(previous.resolve("old-vouchers.xls")));
        var balance=accounting.preview("BALANCE","UPGRADE-V2","v2-balance.xls",Files.readAllBytes(previous.resolve("old-balances.xls")));
        assertThat(vouchers.source().columnContractVersion()).isEqualTo(2);assertThat(balance.source().columnContractVersion()).isEqualTo(2);
        manifest.put("vouchers",vouchers.importId().toString());manifest.put("balance",balance.importId().toString());
        var frozen=manifest.putObject("frozen");
        for(var pair:Map.of("chart","finance_chart_imports","chartChild","finance_chart_imports","notes","finance_expense_note_imports","auxiliary","finance_statement_source_reviews","vouchers","finance_accounting_import_batches","balance","finance_accounting_import_batches").entrySet())
          frozen.put(pair.getKey(),db.queryForObject("SELECT preview::text FROM "+pair.getValue()+" WHERE id=?",String.class,UUID.fromString(manifest.path(pair.getKey()).asText())));
        manifest.set("businessCounts",json.valueToTree(counts(db)));
        Files.writeString(dir.resolve("old-v2-finance.json"),json.writerWithDefaultPrettyPrinter().writeValueAsString(manifest),StandardOpenOption.CREATE_NEW);
        System.out.println("OLD_V2_FINANCE_PUBLIC_PREVIEWS chartParentChild=true notes=true auxiliary=true vouchersBalance=true serverVersion=2 owner="+owner+" actorSuperAdmin=false ids="+manifest.path("chart").asText()+","+manifest.path("chartChild").asText()+","+manifest.path("notes").asText()+","+manifest.path("auxiliary").asText()+","+manifest.path("vouchers").asText()+","+manifest.path("balance").asText());
      } else {
        assertThat(ImportColumnGuard.VERSION).isEqualTo(3);
        var manifest=json.readTree(Files.readString(dir.resolve("old-v2-program.json")));var before=counts(db);
        for(String name:List.of("mixed-header-tail","subtotal-name-control")) {
          var old=manifest.path(name);UUID id=UUID.fromString(old.path("id").asText());
          var preview=json.readValue(old.path("frozenPreview").asText(),GoodsCostImportContracts.Preview.class);
          var mappings=preview.blocks().getFirst().rows().stream().map(row->new GoodsCostImportContracts.Mapping(row.key(),"SKIP",null,null,null,null,null,"原始一行按合法映射请求验证安全版本门禁",true)).toList();
          assertThatThrownBy(()->service.apply(new GoodsCostImportContracts.Apply(id,old.path("block").asText(),input,mappings))).isInstanceOf(ApiException.class).hasMessageContaining("重新检测");
          assertThatThrownBy(()->service.preview(goods,"只改文件名.xlsx",Files.readAllBytes(dir.resolve("originals").resolve(name+".xlsx")))).isInstanceOf(ApiException.class).hasMessageContaining("重新检测");
          assertThat(db.queryForObject("SELECT preview::text FROM goods_cost_imports WHERE id=?",String.class,id)).isEqualTo(old.path("frozenPreview").asText());
          assertThat(json.readTree(json.writeValueAsString(db.queryForMap("SELECT actor_id,goods_id,source_name,storage_provider,storage_key,storage_version,storage_size,storage_sha256 FROM goods_cost_imports WHERE id=?",id)))).isEqualTo(old.path("source"));
          assertThat(counts(db)).isEqualTo(before);
          System.out.println("V3_PUBLIC_APPLY_REJECT file="+name+" originalId="+id+" legalRequest=true storedServerVersion=2 zeroBusinessWrites=true immutablePreviewAndSource=true renameReplayRejected=true");
        }
        var finance=json.readTree(Files.readString(dir.resolve("old-v2-finance.json")));
        java.util.function.Function<String,UUID> financeId=key->UUID.fromString(finance.path(key).asText());
        var chart=context.getBean(com.uten.imp.features.finance.gl.FinanceChartService.class);
        var notes=context.getBean(com.uten.imp.features.finance.gl.FinanceExpenseAnalysisService.class);
        var auxiliary=context.getBean(com.uten.imp.features.finance.statement.FinanceAuxiliaryImportService.class);
        var accounting=context.getBean(com.uten.imp.features.finance.gl.FinanceAccountingImportService.class);
        for(String kind:List.of("chart","chartChild"))assertThatThrownBy(()->chart.apply(new com.uten.imp.features.finance.gl.FinanceChartContracts.Apply(financeId.apply(kind)))).isInstanceOf(ApiException.class).hasMessageContaining("重新检测");
        assertThatThrownBy(()->notes.applyNotes(new com.uten.imp.features.finance.gl.FinanceExpenseAnalysisContracts.ImportApply(financeId.apply("notes")))).isInstanceOf(ApiException.class).hasMessageContaining("重新检测");
        assertThatThrownBy(()->auxiliary.applyDirectory(financeId.apply("auxiliary"))).isInstanceOf(ApiException.class).hasMessageContaining("重新检测");
        assertThat(context.getBean(com.uten.imp.application.port.FinancialAuxiliarySourceReadPort.class).readForAccounting(financeId.apply("auxiliary")).valid()).isFalse();
        assertThatThrownBy(()->accounting.submit(financeId.apply("vouchers"),new com.uten.imp.features.finance.gl.FinanceAccountingContracts.Submit(0,financeId.apply("balance"),0,List.of(),Map.of(),Map.of(),List.of(),Set.of(),false,true,"保留v2原件并执行当前安全重检"))).isInstanceOf(ApiException.class).hasMessageContaining("重新检测");
        for(var pair:Map.of("chart","finance_chart_imports","chartChild","finance_chart_imports","notes","finance_expense_note_imports","auxiliary","finance_statement_source_reviews","vouchers","finance_accounting_import_batches","balance","finance_accounting_import_batches").entrySet())
          assertThat(db.queryForObject("SELECT preview::text FROM "+pair.getValue()+" WHERE id=?",String.class,financeId.apply(pair.getKey()))).isEqualTo(finance.path("frozen").path(pair.getKey()).asText());
        assertThat(counts(db)).isEqualTo(before);
        System.out.println("V3_REJECT_ACTUAL_V2_ALL_FIVE_KINDS=true chartParentChildPreserved=true auxiliaryAdapterInvalid=true zeroBusinessWrites=true immutableOriginalJson=true");
        UUID other=db.queryForObject("SELECT id FROM users WHERE login_account='other-import-auditor'",UUID.class),otherEmployee=db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,other);actor(other,otherEmployee);
        var old=manifest.path("mixed-header-tail");
        assertThatThrownBy(()->service.apply(new GoodsCostImportContracts.Apply(UUID.fromString(old.path("id").asText()),old.path("block").asText(),input,List.of()))).isInstanceOf(ApiException.class).hasMessageContaining("本人");
        actor(owner,employee);
        var legal=service.preview(goods,"v3-ordinary-control.xlsx",Files.readAllBytes(dir.resolve("originals/ordinary-control.xlsx")));
        assertThat(legal.columnContractVersion()).isEqualTo(3);assertThat(legal.blocks().getFirst().rows()).hasSize(2);
        var mappings=legal.blocks().getFirst().rows().stream().map(row->new GoodsCostImportContracts.Mapping(row.key(),"SKIP",null,null,null,null,null,"真实逐行核对合法成本来源",true)).toList();
        var result=service.apply(new GoodsCostImportContracts.Apply(legal.id(),legal.blocks().getFirst().key(),input,mappings));
        assertThat(result.input().extraFields()).containsKey("importMappingId");
        var after=counts(db);for(String table:before.keySet())assertThat(after.get(table)).as(table).isEqualTo(before.get(table)+(table.equals("goods_cost_import_mappings")?1:0));
        System.out.println("V3_PUBLIC_LEGAL rows=2 serverVersion=3 mappingReceipt=true mappingDelta=1 otherBusinessCountsUnchanged=true otherOwnerRejectedBeforeVersion=true counts="+after);
        Files.writeString(dir.resolve(run+"-result.json"),json.writerWithDefaultPrettyPrinter().writeValueAsString(Map.of("before",before,"after",after,"legalImport",legal.id().toString(),"legalMapping",result.input().extraFields().get("importMappingId"))),StandardOpenOption.CREATE_NEW);
      }
    }
  }
}
