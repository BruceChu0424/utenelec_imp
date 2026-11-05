package com.uten.imp.businesschain;

import com.uten.imp.application.port.*;
import com.uten.imp.application.port.FinancePayrollPaymentPort.*;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.finance.gl.FinanceControlledJournalService;
import com.uten.imp.features.finance.statement.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.*;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.transaction.support.TransactionTemplate;
import java.math.BigDecimal;
import java.time.*;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Real migrated payroll/account/GL/capacity integration; approval permission is a separate trusted-port oracle. */
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
class FinancePayrollPaymentPostgresTest {
 @DynamicPropertySource static void database(DynamicPropertyRegistry r){FinanceScopedChainDatabase.register(r,FinancePayrollPaymentPostgresTest.class);}
 @Autowired AutowireCapableBeanFactory beans;@Autowired JdbcTemplate db;@Autowired TransactionTemplate transactions;
 @Autowired com.uten.imp.common.docnumber.DocNumberService numbers;
 @Autowired FinancePayrollPaymentPort payroll;@Autowired FinanceControlledJournalService journals;
 @Autowired FinanceGlSettlementCapacityPort capacity;@Autowired FinanceAuxiliaryService auxiliaries;
 @MockitoBean FinanceApplicationPaymentAuthorityPort authority;
 FullChainEndToEndTest fixture;FullChainEndToEndTest.World w;UUID base,account,cash,wage,cost,tax,fee;
 @BeforeEach void setup(){
  fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);w=fixture.seedWorld("payroll-"+UUID.randomUUID().toString().substring(0,8));fixture.loginAs(w.superAdminUserId());
  base=db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND status='使用' AND NOT is_deleted",UUID.class);
  cash=style("ACCOUNT","1002","ASSET");wage=style("LIABILITY","2211","LIABILITY");cost=style("EXPENSE","5602","PROFIT");tax=style("LIABILITY","2221","LIABILITY");fee=style("EXPENSE","5603","PROFIT");
  account=UUID.randomUUID();db.update("INSERT INTO accounts(id,code,name,account_type,currency_id,init_balance,receipts_total,payments_total,balance_current,status,style_id) VALUES(?,?,'匿名工资付款账户','BANK',?,10000,0,0,10000,'使用',?)",account,"PR-"+account,base,cash);
  reset(authority);when(authority.requirePayrollPreparation(any(),any(),any())).thenAnswer(call->permit(call.getArgument(0),call.getArgument(1),call.getArgument(2),null));
  when(authority.requirePayrollExecution(any())).thenAnswer(call->{Execute c=call.getArgument(0);return permit(c.applicationId(),c.batchId(),c.sourceFingerprint(),c.instructionFingerprint());});
  when(authority.requirePayrollConfirmation(any(),any(),any())).thenAnswer(call->permit(call.getArgument(0),call.getArgument(1),null,null));
  when(authority.requirePayrollReversal(any(),any(),any())).thenAnswer(call->permit(call.getArgument(0),call.getArgument(1),null,null));
 }
 @AfterEach void logout(){SecurityContextHolder.clearContext();}
 @Test void exactNativePayDeductionByItemAndRedCostKeepOneAccrualAcrossPaymentReversalAndRepayment(){
  UUID other=UUID.randomUUID();db.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) VALUES(?,?,'匿名原工资员工二','其他',?,DATE '2026-01-01','active','regular')",other,"PR-"+other,w.departmentId());
  Batch batch=batch(List.of(new Pay(w.employeeId(),"1000","100"),new Pay(other,"500","50")));
  var allocations=new HashMap<UUID,List<DeductionAllocation>>();allocations.put(batch.deductions().getFirst(),List.of(allocation(DeductionPurpose.STANDARD_LIABILITY,tax,"100",null,null)));
  allocations.put(batch.deductions().getLast(),List.of(allocation(DeductionPurpose.EXPENSE_REDUCTION,cost,"50",null,null)));
  Instruction instruction=instruction(AccrualMode.NATIVE_APPROVED_PAYROLL,allocations,null,List.of());
  var prepared=payroll.prepare(batch.application(),batch.id(),batch.source().fingerprint(),instruction);assertThat(prepared.issues()).isEmpty();
  Execute command=execute(batch,prepared,"1350.25","0.25");var paid=payroll.execute(command);
  assertThat(payroll.execute(command).paymentId()).isEqualTo(paid.paymentId());assertThat(paid.netAmount()).isEqualByComparingTo("1350");
  assertThat(balance()).isEqualByComparingTo("8649.75");assertThat(count("SELECT count(*) FROM finance_payroll_accruals WHERE batch_id=?",batch.id())).isEqualTo(1);
  assertThat(db.queryForObject("SELECT SUM(gross_cost_signed) FROM v_finance_payroll_cost_facts WHERE gl_entry_id IN(SELECT entry_id FROM finance_payroll_accrual_lines WHERE batch_id=?)",BigDecimal.class,batch.id())).isEqualByComparingTo("1450");
  assertThat(count("SELECT count(*) FROM v_finance_payroll_cost_facts WHERE pending AND gl_entry_id IN(SELECT entry_id FROM finance_payroll_accrual_lines WHERE batch_id=?)",batch.id())).isZero();
  assertThatThrownBy(()->db.update("UPDATE payroll_items SET amount=amount+1 WHERE id=?",batch.deductions().getFirst())).hasMessageContaining("原工资已用于会计计提");
  UUID confirm=UUID.randomUUID();assertThat(payroll.confirm(batch.application(),confirm,paid.paymentVoucherId()).state()).isEqualTo("CONFIRMED");assertThat(payroll.confirm(batch.application(),confirm,paid.paymentVoucherId()).state()).isEqualTo("CONFIRMED");
  Reverse reverse=new Reverse(UUID.randomUUID(),batch.application(),paid.paymentVoucherId(),"原工资付款回单对称反审");var reversed=payroll.reverse(reverse);assertThat(payroll.reverse(reverse).paymentId()).isEqualTo(reversed.paymentId());assertThat(balance()).isEqualByComparingTo("10000");
  var again=payroll.prepare(batch.application(),batch.id(),batch.source().fingerprint(),instruction);assertThat(again.issues()).isEmpty();var repaid=payroll.execute(execute(batch,again,"1350.25","0.25"));
  assertThat(repaid.accrualVoucherId()).isEqualTo(paid.accrualVoucherId());assertThat(repaid.paymentId()).isNotEqualTo(paid.paymentId());assertThat(count("SELECT count(*) FROM finance_payroll_accruals WHERE batch_id=?",batch.id())).isEqualTo(1);
  assertThat(db.queryForObject("SELECT SUM(e.amount*e.direction) FROM gl_entries e WHERE e.style_id=? AND NOT e.is_deleted",BigDecimal.class,cost)).isEqualByComparingTo("1450");
  assertThatThrownBy(()->payroll.execute(new Execute(command.requestId(),command.applicationId(),command.batchId(),command.sourceFingerprint(),command.instructionFingerprint(),account,command.paymentDate(),"different",command.bankAmount(),command.bankFee(),fee,command.bankBookedAt()))).hasMessageContaining("不同内容");
 }
 @Test void realEmployeeLoanIsClearedOnceAtNativeAccrualAndNotRestoredByBankPaymentReversal(){
  UUID loan=style("ACCOUNT","1221","ASSET");String code=code(loan);var aux=auxiliaries.save(new FinanceAuxiliaryContracts.Save(null,null,"匿名工资借款账套","E-"+w.employeeId(),"匿名员工借款","EMPLOYEE",w.employeeId(),"明确原员工及已记账借款来源",code));
  var ref=auxiliaries.resolveNative(code,"EMPLOYEE",w.employeeId(),base);
  var old=transactions.execute(status->journals.post("PR-LOAN-"+UUID.randomUUID(),BusinessTime.today(),"ANON_PAYROLL_LOAN",w.employeeId(),"ANON_PAYROLL_LOAN","匿名原借款已入账",List.of(new FinanceControlledJournalService.Entry(loan,1,new BigDecimal("40"),"原员工借款",new FinanceControlledJournalService.Allocation(code,base,ref,"ANON",1,"{}",base,new BigDecimal("40"),BigDecimal.ONE)),new FinanceControlledJournalService.Entry(cash,-1,new BigDecimal("40"),"原借款资金对方")),w.superAdminUserId()));
  var scope=new FinanceGlSettlementCapacityPort.Scope(loan,code,aux.id(),base,base,1,BusinessTime.today());var origin=new FinanceGlSettlementCapacityPort.SourceRef(old.entryIds().getFirst(),1);var preview=capacity.preview(scope,FinanceGlSettlementCapacityPort.Mode.EXPLICIT_GL_SOURCE,List.of(origin));assertThat(preview.ready()).isTrue();
  Batch batch=batch(List.of(new Pay(w.employeeId(),"100","20")));var typed=allocation(DeductionPurpose.EMPLOYEE_SETTLEMENT,loan,"20",aux.id(),new OpenItemReference("GL_ALLOCATION",origin.entryId(),1,preview.fingerprint()));
  var instruction=instruction(AccrualMode.NATIVE_APPROVED_PAYROLL,Map.of(batch.deductions().getFirst(),List.of(typed)),null,List.of());var prepared=payroll.prepare(batch.application(),batch.id(),batch.source().fingerprint(),instruction);assertThat(prepared.issues()).isEmpty();
  var paid=payroll.execute(execute(batch,prepared,"80","0"));assertThat(capacity.preview(scope,FinanceGlSettlementCapacityPort.Mode.AUXILIARY_BALANCE_POOL,List.of()).availableLocal()).isEqualByComparingTo("20");
  payroll.reverse(new Reverse(UUID.randomUUID(),batch.application(),paid.paymentVoucherId(),"只反银行实际支付，工资计提保留"));
  assertThat(capacity.preview(scope,FinanceGlSettlementCapacityPort.Mode.AUXILIARY_BALANCE_POOL,List.of()).availableLocal()).isEqualByComparingTo("20");
  var next=payroll.prepare(batch.application(),batch.id(),batch.source().fingerprint(),instruction);assertThat(next.issues()).isEmpty();payroll.execute(execute(batch,next,"80","0"));
  assertThat(count("SELECT count(*) FROM finance_gl_settlement_reservations WHERE owner_kind='PAYROLL_DEDUCTION_ACCRUAL' AND owner_id=?",batch.id())).isEqualTo(1);
 }
 @Test void zeroNetUsesActualNoncashAccrualAndAllZeroCreatesNoFakeVoucherOrBankFlow(){
  Batch deducted=batch(List.of(new Pay(w.employeeId(),"100","100")));var instruction=instruction(AccrualMode.NATIVE_APPROVED_PAYROLL,Map.of(deducted.deductions().getFirst(),List.of(allocation(DeductionPurpose.STANDARD_LIABILITY,tax,"100",null,null))),null,List.of());
  var prepared=payroll.prepare(deducted.application(),deducted.id(),deducted.source().fingerprint(),instruction);assertThat(prepared.issues()).isEmpty();var result=payroll.execute(execute(deducted,prepared,"0","0"));
  assertThat(result.receiptKind()).isEqualTo(ReceiptKind.NON_CASH_CLEARED);assertThat(result.nonCashVoucherId()).isNotNull();assertThat(result.accountFlowId()).isNull();assertThat(result.paymentVoucherId()).isNull();assertThat(balance()).isEqualByComparingTo("10000");
  payroll.reverse(new Reverse(UUID.randomUUID(),deducted.application(),result.nonCashVoucherId(),"撤回原非现金办理回执，保留真实计提"));
  assertThat(db.queryForObject("SELECT status FROM gl_vouchers WHERE id=?",Integer.class,result.nonCashVoucherId())).isEqualTo(1);
 }
 @Test void zeroGrossHasNoFinancialEventAndBrokenOrMixedItemMappingNeverApprovesPreparation(){
  Batch batch=batch(List.of(new Pay(w.employeeId(),"0","0")));var instruction=instruction(AccrualMode.NATIVE_APPROVED_PAYROLL,Map.of(),null,List.of());var prepared=payroll.prepare(batch.application(),batch.id(),batch.source().fingerprint(),instruction);assertThat(prepared.ready()).isTrue();
  var result=payroll.execute(execute(batch,prepared,"0","0"));assertThat(result.receiptKind()).isEqualTo(ReceiptKind.NO_FINANCIAL_EVENT);assertThat(result.accrualVoucherId()).isNull();assertThat(result.accountFlowId()).isNull();
  assertThat(count("SELECT count(*) FROM gl_entries WHERE source_doc_id=?",result.paymentId())).isZero();
 }
 private record Pay(UUID employee,String gross,String deduction) { }
 private record Batch(UUID id,UUID application,Source source,List<UUID> deductions) { }
 private Batch batch(List<Pay> employees){UUID id=UUID.randomUUID(),app=UUID.randomUUID();var now=BusinessTime.today();BigDecimal gross=employees.stream().map(p->new BigDecimal(p.gross())).reduce(BigDecimal.ZERO,BigDecimal::add),deductions=employees.stream().map(p->new BigDecimal(p.deduction())).reduce(BigDecimal.ZERO,BigDecimal::add);
  db.update("INSERT INTO payroll_batches(id,payroll_year,payroll_month,department_id,status,headcount,gross_income,total_deduction,net_income,generated_by) VALUES(?,?,?,?,'APPROVED',?,?,?,?,?)",id,now.getYear(),now.getMonthValue(),w.departmentId(),employees.size(),gross,deductions,gross.subtract(deductions),w.employeeId());
  var items=new ArrayList<UUID>();int n=0;for(var person:employees){UUID slip=UUID.randomUUID();BigDecimal g=new BigDecimal(person.gross()),d=new BigDecimal(person.deduction());db.update("INSERT INTO payroll_slips(id,batch_id,employee_id,employee_code_snapshot,employee_name_snapshot,department_id_snapshot,department_name_snapshot,payroll_year,payroll_month,gross_income,total_deduction,net_income) VALUES(?,?,?,?,?,?,?, ?,?,?,?,?)",slip,id,person.employee(),"ANON-"+(++n),"匿名原工资员工",w.departmentId(),"匿名原工资部门",now.getYear(),now.getMonthValue(),g,d,g.subtract(d));
   db.update("INSERT INTO payroll_items(slip_id,line_no,item_code,name,item_type,amount,source_type) VALUES(?,1,'BASE','原工资','EARNING',?,'COMPENSATION_SNAPSHOT')",slip,g);if(d.signum()!=0){UUID item=UUID.randomUUID();items.add(item);db.update("INSERT INTO payroll_items(id,slip_id,line_no,item_code,name,item_type,amount,source_type,description) VALUES(?,?,2,'OTHER_DEDUCTION','原扣款','DEDUCTION',?,'VARIABLE_INPUT','逐原项目明确会计用途')",item,slip,d);}}
  String applicationNo=numbers.nextNumber(com.uten.imp.common.docnumber.DocNumberPrefix.FIN_APPLICATION);
  db.update("INSERT INTO finance_applications(id,application_no,kind,source_kind,source_id,applicant_id,applicant_name_snapshot,department_id,title,requested_date,request_fingerprint,created_by,updated_by) VALUES(?,?,'PAYROLL_PAYMENT','PAYROLL_BATCH',?,?,'匿名人事',?,'原工资付款',?,repeat('0',64),?,?)",app,applicationNo,id,w.employeeId(),w.departmentId(),now,w.superAdminUserId(),w.superAdminUserId());
  return new Batch(id,app,payroll.source(id,false),items);
 }
 private Instruction instruction(AccrualMode mode,Map<UUID,List<DeductionAllocation>> parts,ExistingLiabilityBasis basis,List<ExistingLiabilityLine> lines){return new Instruction(mode,wage,Map.of(w.departmentId(),cost),Map.of(),null,"按原工资批次逐项目核对准备",basis,lines,List.of(),List.of(),BusinessTime.today(),parts);}
 private DeductionAllocation allocation(DeductionPurpose purpose,UUID style,String amount,UUID auxiliary,OpenItemReference original){return new DeductionAllocation(UUID.randomUUID(),purpose,style,amount,auxiliary,original,"原工资项目明确份额依据");}
 private Execute execute(Batch batch,Prepared prepared,String bank,String feeAmount){OffsetDateTime time=OffsetDateTime.now();boolean zero=batch.source().netIncome().signum()==0;return new Execute(UUID.randomUUID(),batch.application(),batch.id(),batch.source().fingerprint(),prepared.instructionFingerprint(),zero?null:account,BusinessTime.today(),"ANON-BANK-REF",bank,feeAmount,new BigDecimal(feeAmount).signum()==0?null:fee,zero?null:time);}
 private UUID style(String category,String prefix,String classification){UUID id=UUID.randomUUID();String code=prefix+new java.math.BigInteger(id.toString().replace("-",""),16).toString().substring(0,18);db.update("INSERT INTO payment_styles(id,code,name,category,status) VALUES(?,?,?,?,'使用')",id,"PR-STYLE-"+id,"匿名原会计科目"+id.toString().substring(0,8),category);db.update("INSERT INTO finance_chart_codes(code,name,currency_name,currency_id,classification,source_kind,source_reference,sort_order,source_row,updated_by) VALUES(?,'匿名财务科目','',?,?,'MANUAL','匿名原科目明确依据',1,1,?)",code,base,classification,w.superAdminUserId());db.update("INSERT INTO finance_chart_code_styles(code,style_id,created_by) VALUES(?,?,?)",code,id,w.superAdminUserId());return id;}
 private String code(UUID style){return db.queryForObject("SELECT code FROM finance_chart_code_styles WHERE style_id=?",String.class,style);}
 private BigDecimal balance(){return db.queryForObject("SELECT balance_current FROM accounts WHERE id=?",BigDecimal.class,account);}
 private int count(String sql,Object value){return db.queryForObject(sql,Integer.class,value);}
 private FinanceApplicationPaymentAuthorityPort.Permit permit(UUID app,UUID batch,String source,String instruction){return new FinanceApplicationPaymentAuthorityPort.Permit(app,batch,w.superAdminUserId(),w.employeeId(),"匿名财务操作人",UUID.randomUUID(),UUID.randomUUID(),source,instruction,List.of(new FinanceApplicationPaymentAuthorityPort.Evidence(UUID.randomUUID(),"0".repeat(64),"anonymous-proof.pdf")));}
}
