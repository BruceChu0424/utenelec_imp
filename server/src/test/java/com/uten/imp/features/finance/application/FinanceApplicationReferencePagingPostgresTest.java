package com.uten.imp.features.finance.application;

import com.uten.imp.application.port.*;
import com.uten.imp.common.web.*;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.security.*;
import com.uten.imp.support.MigratedProjectionSchema;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;
import java.math.BigDecimal;
import java.time.*;
import java.util.*;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;
import static org.mockito.ArgumentMatchers.*;

/** Actual production candidate SQL over migrated column/function shapes.
 * This isolates read selection; workflow/GL writes retain their full-chain tests. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class FinanceApplicationReferencePagingPostgresTest {
    static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine").withReuse(false);
    static JdbcTemplate db;
    static final String[] TABLES={"expense_claims","finance_applications","business_applications","payroll_batches","suppliers","ar_ap_ledger","employee_identity_aliases","payment_styles","finance_chart_codes","finance_chart_code_styles","finance_report_line_bindings","finance_auxiliary_items","gl_vouchers","gl_entries","finance_gl_entry_allocations"};
    static final UUID EMPLOYEE=UUID.randomUUID(),OTHER=UUID.randomUUID(),CURRENCY=UUID.randomUUID(),SUPPLIER=UUID.randomUUID();
    FinanceApplicationReferences references;SecurityContextCurrentUser current;
    @BeforeAll static void start(){PG.start();db=new JdbcTemplate(new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword()));MigratedProjectionSchema.createCurrentTables(db,TABLES);MigratedProjectionSchema.createCurrentFunctions(db,"fn_canonical_employee_identity","fn_finance_gl_voucher_is_booked","fn_finance_payroll_wage_style_allowed","fn_finance_payroll_employee_settlement_style_allowed");}
    @AfterAll static void stop(){PG.stop();}
    @BeforeEach void empty(){db.execute("TRUNCATE "+String.join(",",TABLES));current=mock(SecurityContextCurrentUser.class);var roles=new FinanceApplicationRoles(db,mock(UserAccountRepository.class),mock(PermissionResolver.class),current,mock(TxSessionVars.class),new FinanceApplicationOperationJournal(db,new com.fasterxml.jackson.databind.ObjectMapper().findAndRegisterModules(),current));references=new FinanceApplicationReferences(db,roles);login(Set.of("expense:apply","payroll:generate",FinanceApplicationPermissions.APPLY,"ar_ap_ledger:view","finance:view:all"));}
    void login(Set<String> permissions){when(current.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(),EMPLOYEE,"reference-reader",permissions,false,true,false)));}

    @Test void suppliersHaveCompleteStablePagesAndLegacySuggestionsKeepTheirOriginalContract(){
        for(int i=0;i<125;i++)insert("suppliers",row("id",UUID.randomUUID(),"code",String.format("S%03d",i),"name","供应商"+i,"status","使用","is_deleted",false));
        insert("suppliers",row("id",UUID.randomUUID(),"code","S999","name","隐藏","status","禁用","is_deleted",false));
        var a=references.sourcesPage("SUPPLIER","",null,null,1,100);var b=references.sourcesPage("SUPPLIER","",null,null,2,100);
        assertEquals(125,a.getTotal());assertEquals(2,a.getTotalPages());assertEquals(100,a.getItems().size());assertEquals(25,b.getItems().size());assertEquals("S100",b.getItems().getFirst().get("code"));
        assertEquals(125,keys(a.getItems(),b.getItems()).size());var legacy=references.sources("SUPPLIER","",null,null);assertEquals(a.getItems(),legacy.get("items"));assertEquals(true,legacy.get("more"));assertEquals(Set.of("id","code","name"),a.getItems().getFirst().keySet());
        login(Set.of("expense:apply"));assertThrows(ApiException.class,()->references.sourcesPage("SUPPLIER","",null,null,1,100));
    }
    @Test void expensePagesApplyCanonicalApplicantStatusAndLiteralSearchBeforeCounting(){
        UUID canonical=UUID.randomUUID();insert("employee_identity_aliases",row("alias_employee_id",EMPLOYEE,"canonical_employee_id",canonical));
        for(int i=0;i<125;i++)insert("expense_claims",row("id",UUID.randomUUID(),"claim_no","C"+i,"title",i==5?"literal%_":"原报销","applicant_id",canonical,"status",i%2==0?"DRAFT":"REJECTED","total_amount",new BigDecimal("10.0001"),"is_deleted",false,"created_at",OffsetDateTime.parse("2026-10-01T00:00:00Z")));
        insert("expense_claims",row("id",UUID.randomUUID(),"claim_no","OTHER","title","原报销","applicant_id",OTHER,"status","DRAFT","is_deleted",false));
        insert("expense_claims",row("id",UUID.randomUUID(),"claim_no","DONE","title","原报销","applicant_id",canonical,"status","PAID","is_deleted",false));
        assertEquals(125,references.sourcesPage("EXPENSE_CLAIM","",null,null,2,100).getTotal());
        var literal=references.sourcesPage("EXPENSE_CLAIM","%_",null,null,1,100);assertEquals(1,literal.getTotal());assertEquals("C5",literal.getItems().getFirst().get("code"));assertFalse(literal.getItems().getFirst().containsKey("created_at"));
    }
    @Test void travelUnionPreservesBothKindsEvenWhenNativeUuidsCoincide(){
        for(int i=0;i<125;i++){UUID id=UUID.randomUUID();for(String table:List.of("finance_applications","business_applications"))insert(table,row("id",id,"application_no",table.startsWith("finance")?"F"+i:"B"+i,"title","差旅","applicant_id",EMPLOYEE,"kind",table.startsWith("finance")?"TRAVEL_APPLICATION":"TRAVEL","status",table.startsWith("finance")?"ARCHIVED":"COMPLETED","created_at",OffsetDateTime.parse("2026-10-01T00:00:00Z")));}
        insert("business_applications",row("id",UUID.randomUUID(),"application_no","FOREIGN","title","差旅","applicant_id",OTHER,"kind","TRAVEL","status","COMPLETED"));
        var all=new ArrayList<Map<String,Object>>();for(int page=1;page<=3;page++){var result=references.sourcesPage("TRAVEL_APPLICATION","",null,null,page,100);assertEquals(250,result.getTotal());all.addAll(result.getItems());}
        assertEquals(250,keys(all).size());assertEquals(125,all.stream().map(r->r.get("id")).distinct().count());assertEquals(100,((List<?>)references.sources("TRAVEL_APPLICATION","",null,null).get("items")).size());
    }
    @Test void payrollAndPayablePagesRetainTheirOriginalOwnerCurrencyAndEligibility(){
        for(int i=0;i<125;i++)for(UUID owner:List.of(EMPLOYEE,OTHER))insert("payroll_batches",row("id",UUID.randomUUID(),"payroll_year",2026,"payroll_month",10,"headcount",1,"net_income",new BigDecimal("1.0001"),"status","APPROVED","generated_by",owner));
        assertEquals(125,references.sourcesPage("PAYROLL_BATCH","",null,null,1,100).getTotal());
        login(Set.of("payroll:generate","payroll:view:all","ar_ap_ledger:view","finance:view:all"));assertEquals(250,references.sourcesPage("PAYROLL_BATCH","",null,null,1,100).getTotal());
        for(int i=0;i<125;i++)insert("ar_ap_ledger",row("id",UUID.randomUUID(),"bill_no",String.format("AP%03d",i),"bill_date",LocalDate.of(2026,10,1),"business_type","PURCHASE","status",1,"direction","AP","open_item_kind","PAYABLE","supplier_id",SUPPLIER,"currency_id",CURRENCY,"amount_balance_original",new BigDecimal("1.0001"),"is_deleted",false));
        insert("ar_ap_ledger",row("id",UUID.randomUUID(),"bill_no","FOREIGN","bill_date",LocalDate.now(),"status",1,"direction","AP","open_item_kind","PAYABLE","supplier_id",OTHER,"currency_id",CURRENCY,"amount_balance_original",BigDecimal.ONE,"is_deleted",false));
        var result=references.sourcesPage("SUPPLIER_AP","",SUPPLIER,CURRENCY,2,100);assertEquals(125,result.getTotal());assertEquals(25,result.getItems().size());assertEquals(0,new BigDecimal(result.getItems().getFirst().get("amount").toString()).compareTo(new BigDecimal("1.0001")));
        assertThrows(ApiException.class,()->references.sourcesPage("SUPPLIER_AP","",null,CURRENCY,1,100));
    }

    record PayrollFixture(FinancePayrollApplicationReferences references,UUID application,UUID batch,UUID style,UUID auxiliary,UUID lease,TaskClaimService claims,FinanceGlSettlementCapacityPort capacity,FinancePayrollPaymentPort payroll){}
    @SuppressWarnings("unchecked") PayrollFixture payroll(boolean deduction){
        UUID application=UUID.randomUUID(),batch=UUID.randomUUID(),style=UUID.randomUUID(),auxiliary=UUID.randomUUID(),lease=UUID.randomUUID();String code=deduction?"1221001":"2211001";
        insert("payment_styles",row("id",style,"code",code,"name","原财务科目","category",deduction?"ACCOUNT":"LIABILITY","status","使用","is_deleted",false));insert("finance_chart_codes",row("code",code,"name","原财务科目"));insert("finance_chart_code_styles",row("code",code,"style_id",style));insert("finance_auxiliary_items",row("id",auxiliary,"role","EMPLOYEE","status","ACTIVE","employee_id",EMPLOYEE));
        var applications=mock(FinanceApplicationService.class);when(applications.lockSourceAndRow(application)).thenReturn(row("source_kind","PAYROLL_BATCH","source_id",batch));
        var roles=mock(FinanceApplicationRoles.class);when(roles.live(FinanceApplicationPermissions.REVIEW)).thenReturn(new AuthUser(UUID.randomUUID(),EMPLOYEE,"reviewer",Set.of(FinanceApplicationPermissions.REVIEW),false,true,false));
        var port=mock(FinancePayrollPaymentPort.class);ObjectProvider<FinancePayrollPaymentPort> provider=mock(ObjectProvider.class);when(provider.getObject()).thenReturn(port);
        var slip=new FinancePayrollPaymentPort.Slip(UUID.randomUUID(),EMPLOYEE,"E","原工资员工",UUID.randomUUID(),BigDecimal.TEN,BigDecimal.TEN,BigDecimal.ZERO,List.of());
        when(port.source(batch,false)).thenReturn(new FinancePayrollPaymentPort.Source(batch,"2026-10","APPROVED",EMPLOYEE,slip.departmentId(),CURRENCY,BigDecimal.TEN,BigDecimal.TEN,BigDecimal.ZERO,"source-proof",List.of(slip)));
        var currencies=mock(FinancialChartCurrencyReadPort.class);when(currencies.read(Set.of(code))).thenReturn(Map.of(code,new FinancialChartCurrencyReadPort.Reference(code,CURRENCY,true,"",1)));
        var capacity=mock(FinanceGlSettlementCapacityPort.class);when(capacity.preview(any(),any(),anyList())).thenAnswer(call->{List<FinanceGlSettlementCapacityPort.SourceRef> refs=call.getArgument(2);return new FinanceGlSettlementCapacityPort.Preview("capacity-proof",new BigDecimal("9.1234"),new BigDecimal("9.1234"),refs.stream().map(ref->new FinanceGlSettlementCapacityPort.SourceAmount(ref,new BigDecimal("100.0001"),new BigDecimal("100.0001"))).toList(),List.of(),"原容量依据");});
        var claims=mock(TaskClaimService.class);return new PayrollFixture(new FinancePayrollApplicationReferences(db,applications,roles,provider,mock(FinanceApplicationPaymentAuthorityPort.class),capacity,currencies,claims),application,batch,style,auxiliary,lease,claims,capacity,port);
    }
    @Test void nonCashVoucherPagesCountGroupedVoucherIdentityAndKeepLegacyCap(){
        var f=payroll(false);for(int i=0;i<125;i++)voucher(f.style(),i,false);
        UUID duplicateVoucher=db.queryForObject("SELECT id FROM gl_vouchers WHERE voucher_no='V000'",UUID.class);insert("gl_entries",row("id",UUID.randomUUID(),"voucher_id",duplicateVoucher,"style_id",f.style(),"direction",1,"line_no",2,"entry_date",LocalDate.now(),"amount",new BigDecimal("100.0001"),"is_deleted",false));
        UUID hidden=voucher(f.style(),999,false);db.update("UPDATE gl_vouchers SET status=0 WHERE id=(SELECT voucher_id FROM gl_entries WHERE id=?)",hidden);
        var a=f.references().candidatesPage(f.application(),"source-proof",f.lease(),f.style(),null,null,"EXISTING_NON_CASH_VOUCHER",LocalDate.now(),"",null,null,1,100);
        var b=f.references().candidatesPage(f.application(),"source-proof",f.lease(),f.style(),null,null,"EXISTING_NON_CASH_VOUCHER",LocalDate.now(),"",null,null,2,100);
        assertEquals(125L,a.get("total"));var first=(Map<?,?>)((List<?>)a.get("items")).getFirst();assertEquals(0,new BigDecimal(first.get("sourceAmountLocal").toString()).compareTo(new BigDecimal("200.0002")));assertEquals(100,((List<?>)a.get("items")).size());assertEquals(25,((List<?>)b.get("items")).size());assertEquals(true,f.references().candidates(f.application(),"source-proof",f.lease(),f.style(),null,null,"EXISTING_NON_CASH_VOUCHER",LocalDate.now(),"",null,null).get("more"));
        verify(f.claims(),times(3)).requireActiveClaimByMe(FinanceApplicationService.CLAIM,f.application().toString(),f.lease());
    }
    @Test void allocationPagesKeepExactIdentitySelectedCapacityAndFirstOnlyBalancePool(){
        var f=payroll(true);UUID selected=null;for(int i=0;i<125;i++)selected=voucher(f.style(),i,true);
        insert("finance_gl_entry_allocations",row("entry_id",selected,"allocation_no",1,"account_code","1221001","auxiliary_id",f.auxiliary(),"currency_id",CURRENCY,"original_currency_id",CURRENCY,"amount_local",new BigDecimal("0.0001"),"amount_original",new BigDecimal("0.0001")));
        var a=f.references().candidatesPage(f.application(),"source-proof",f.lease(),f.style(),f.auxiliary(),EMPLOYEE,"DEDUCTION",LocalDate.now(),"",null,null,1,100);
        var b=f.references().candidatesPage(f.application(),"source-proof",f.lease(),f.style(),f.auxiliary(),EMPLOYEE,"DEDUCTION",LocalDate.now(),"",null,null,2,100);
        assertEquals(126L,a.get("total"));assertEquals(26,((List<?>)b.get("items")).size());assertNotNull(a.get("balancePool"));assertFalse(b.containsKey("balancePool"));verify(f.capacity(),times(1)).preview(any(),eq(FinanceGlSettlementCapacityPort.Mode.AUXILIARY_BALANCE_POOL),eq(List.of()));
        final UUID exactEntry=selected;
        var exact=f.references().candidates(f.application(),"source-proof",f.lease(),f.style(),f.auxiliary(),EMPLOYEE,"DEDUCTION",LocalDate.now(),"",exactEntry,0);
        var picked=(Map<?,?>)((List<?>)exact.get("items")).getFirst();assertEquals(selected,picked.get("entryId"));assertEquals(0,picked.get("allocationNo"));assertEquals("9.1234",picked.get("amountLocal"));assertEquals("capacity-proof",picked.get("sourceFingerprint"));
        doThrow(new ApiException(ErrorCode.FORBIDDEN)).when(f.claims()).requireActiveClaimByMe(FinanceApplicationService.CLAIM,f.application().toString(),f.lease());assertThrows(ApiException.class,()->f.references().candidatesPage(f.application(),"source-proof",f.lease(),f.style(),f.auxiliary(),EMPLOYEE,"DEDUCTION",LocalDate.now(),"",null,null,1,100));
    }
    UUID voucher(UUID style,int number,boolean allocation){UUID voucher=UUID.randomUUID(),entry=UUID.randomUUID();insert("gl_vouchers",row("id",voucher,"voucher_no",String.format("V%03d",number),"voucher_date",LocalDate.now(),"status",1,"is_deleted",false));insert("gl_entries",row("id",entry,"voucher_id",voucher,"style_id",style,"direction",1,"entry_date",LocalDate.now(),"line_no",1,"source_bill_no","B"+number,"amount",new BigDecimal("100.0001"),"is_deleted",false));if(allocation){UUID auxiliary=db.queryForObject("SELECT id FROM finance_auxiliary_items LIMIT 1",UUID.class);insert("finance_gl_entry_allocations",row("entry_id",entry,"allocation_no",0,"account_code","1221001","auxiliary_id",auxiliary,"currency_id",CURRENCY,"original_currency_id",CURRENCY,"amount_local",new BigDecimal("100.0001"),"amount_original",new BigDecimal("100.0001")));}return entry;}
    @SafeVarargs static Set<String> keys(List<Map<String,Object>>... lists){var keys=new HashSet<String>();for(var rows:lists)for(var r:rows)assertTrue(keys.add(r.getOrDefault("sourceKind","")+"|"+r.get("id")));return keys;}
    static Map<String,Object> row(Object...values){var row=new LinkedHashMap<String,Object>();for(int i=0;i<values.length;i+=2)row.put(values[i].toString(),values[i+1]);return row;}
    static void insert(String table,Map<String,Object> row){db.update("INSERT INTO "+table+"("+String.join(",",row.keySet())+") VALUES("+String.join(",",Collections.nCopies(row.size(),"?"))+")",row.values().toArray());}
}
