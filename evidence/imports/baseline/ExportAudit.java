package com.uten.imp.businesschain;
import java.nio.file.*;
import java.io.*;
import java.util.*;
import java.util.concurrent.atomic.*;
import java.math.BigDecimal;
import org.junit.jupiter.api.Test;
import com.uten.imp.common.export.*;
import com.uten.imp.features.reporting.export.ReportExportRequest;
import com.uten.imp.features.master.mould.*;
import com.uten.imp.features.master.mould.dto.*;
import org.apache.poi.ss.usermodel.WorkbookFactory;
import static org.assertj.core.api.Assertions.*;

@org.junit.jupiter.api.TestMethodOrder(org.junit.jupiter.api.MethodOrderer.OrderAnnotation.class)
public class ExportAudit extends MasterDirectoryExportPostgresTest {
    @Test @org.junit.jupiter.api.Order(1) void requestedMouldSortMatchesTheRenderedWorkbook() throws Exception {
        UUID cat=UUID.randomUUID();String prefix="S"+cat.toString().substring(0,7);
        jdbc.update("INSERT INTO mould_categories(id,code,name) VALUES(?,?,?)",cat,"K"+prefix,prefix);
        long base=jdbc.queryForObject("SELECT coalesce(max(code_sequence),0) FROM moulds", Long.class);
        for(int i=1;i<=2;i++) jdbc.update("INSERT INTO moulds(id,code,name,status,category_id,code_sequence,code_managed,tqty) VALUES(gen_random_uuid(),?,?,'使用',?,?,false,?)",prefix+i,"样件"+i,cat,base+i,i);
        exporter("mould");
        var filter=new MouldQueryFilter(cat,null,null,null,null,null,null,null,null,null,null);
        var direct=context.getBean(MouldService.class).export(filter,"tqty","desc");
        var filterJson=objectMapper.writeValueAsString(Map.of("categoryId",cat));
        var req=new ReportExportRequest(UUID.randomUUID(),"master","mould",Map.of("filter",filterJson),"tqty","desc",null);
        var w=context.getBean(XlsxExportService.class).buildSource(()->master.read(req),null,"master_mould");
        Path artifact=Path.of(System.getProperty("audit.dir"),"mould-desc.xlsx");Files.write(artifact,w.bytes());
        var actual=new ArrayList<String>();
        try(var book=WorkbookFactory.create(new ByteArrayInputStream(w.bytes()))){var sheet=book.getSheetAt(0);
            for(int i=1;i<=2;i++)actual.add(sheet.getRow(i).getCell(3).getStringCellValue());}
        var expected=direct.rows().stream().map(row->row.get("tqty").toString()).toList();
        System.out.println("AUDIT_MOULD_DESC direct="+expected+" workbook="+actual+" filter=same category only; regular mould:export");
        assertThat(actual).containsExactlyElementsOf(expected);
    }
    void financeActor(Employee actor) {
        var user=new com.uten.imp.security.AuthUser(UUID.fromString(actor.userId()),UUID.fromString(actor.employeeId()),actor.loginAccount(),
            Set.of("finance:view:all","finance_report:view","payment_style:edit"),false,true,false);
        org.springframework.security.core.context.SecurityContextHolder.getContext().setAuthentication(
            new org.springframework.security.authentication.UsernamePasswordAuthenticationToken(user,null,user.getAuthorities()));
    }
    @Test @org.junit.jupiter.api.Order(2) void publicImportWithUnknownColumnsAndLockedReceipt() throws Exception {
        String admin=adminToken(); Employee one=newEmployee(admin),two=newEmployee(admin);
        financeActor(one);
        var path=Path.of(System.getProperty("audit.dir"));
        var chart=context.getBean(com.uten.imp.features.finance.gl.FinanceChartService.class);
        var preview=chart.preview("chart.xlsx",Files.readAllBytes(path.resolve("chart-true.xlsx")));
        var res=chart.apply(new com.uten.imp.features.finance.gl.FinanceChartContracts.Apply(preview.importId()));
        System.out.println("AUDIT_CHART_APPLY issues="+preview.issues().size()+" state="+res+" appliedRows="+jdbc.queryForObject("SELECT count(*) FROM finance_chart_codes WHERE source_import_id=?",Integer.class,preview.importId()));
        var notes=context.getBean(com.uten.imp.features.finance.gl.FinanceExpenseAnalysisService.class);
        var p=notes.previewNotes("2026-09","note.xlsx",Files.readAllBytes(path.resolve("note-duplicate.xlsx")));
        var command=new com.uten.imp.features.finance.gl.FinanceExpenseAnalysisContracts.ImportApply(p.importId());
        notes.applyNotes(command);
        String expected=jdbc.queryForObject("SELECT applied_result::text FROM finance_expense_note_imports WHERE id=?",String.class,p.importId());
        notes.savePolicy(new com.uten.imp.features.finance.gl.FinanceExpenseAnalysisContracts.PolicyInput("2026-09",-1,true,"合成期间实际核对并排除资本化重复",true,""));
        var replay=objectMapper.valueToTree(notes.applyNotes(command));assertThat(replay).isEqualTo(objectMapper.readTree(expected));
        assertThat(jdbc.queryForObject("SELECT count(*) FROM finance_operating_report_notes WHERE period='2026-09'",Integer.class)).isEqualTo(1);
        financeActor(two);
        assertThatThrownBy(()->notes.applyNotes(command)).isInstanceOf(com.uten.imp.common.web.ApiException.class).hasMessageContaining("当前账号");
        System.out.println("AUDIT_NOTES_APPLY_FROM_XLSX issues="+p.issues().size()+" changedRows=1 originalReceiptAfterLock=true otherOwnerDenied=true");
    }
    @Test @org.junit.jupiter.api.Order(3) void hundredThousandGoodsFromPostgres() throws Exception {
        UUID cat=UUID.randomUUID();String prefix="AX"+cat.toString().substring(0,6);
        jdbc.update("INSERT INTO material_categories(id,code,name) VALUES(?,?,?)",cat,"K"+prefix,prefix);
        final long seq=jdbc.queryForObject("SELECT coalesce(max(code_sequence),0) FROM goods",Long.class);
        final int total=100000; long start=System.nanoTime();int n=0;
        for(int i=0;i<total;i+=1000) {
          n+=jdbc.update("""
            INSERT INTO goods(id,code,name,status,category_id,code_sequence,auto_created,price,zk)
            SELECT gen_random_uuid(),?||lpad(i::text,6,'0'),?||lpad(i::text,6,'0'),'使用',?,?+i+1,false,1.234567,0.9500
            FROM generate_series(?,?) AS i
            """,prefix,prefix,cat,seq,i,i+999);
          if(n%10000==0||n==1000)System.out.println("AUDIT_100K_SEED "+n+" ms="+(System.nanoTime()-start)/1000000);
        }
        long prepared=(System.nanoTime()-start)/1000000;start=System.nanoTime();
        exporter("goods","goods:price:view","goods:discount:view");
        var req=request("goods",Map.of("keyword",prefix));AtomicInteger rows=new AtomicInteger(), batches=new AtomicInteger(),peak=new AtomicInteger();
        final BigDecimal[] sum={BigDecimal.ZERO};
        try(var sink=ExportPageSink.open(page->{
           assertThat(page.rows().size()).isLessThanOrEqualTo(100);batches.incrementAndGet();
           peak.accumulateAndGet(em.unwrap(org.hibernate.Session.class).getStatistics().getEntityCount(), Math::max);
           for(var row:page.rows()) {int i=rows.getAndIncrement();assertThat(row.get("code")).isEqualTo(prefix+"%06d".formatted(i));sum[0]=sum[0].add((BigDecimal)row.get("price"));}
        })){var result=master.read(req);assertThat(result.total()).isEqualTo(total);assertThat(result.rows()).isEmpty();}
        long read=(System.nanoTime()-start)/1000000;
        System.out.println("AUDIT_100K total="+rows+" batches="+batches+" sum="+sum[0]+" peakManaged="+peak+" preparationMs="+prepared+" sourceMs="+read);
        assertThat(rows).hasValue(total);assertThat(sum[0]).isEqualByComparingTo("123456.7");assertThat(peak.get()).isLessThan(2000);
    }
}


