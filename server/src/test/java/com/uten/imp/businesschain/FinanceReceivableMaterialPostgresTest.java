package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.finance.receipt.FinanceReceiptService;
import com.uten.imp.features.finance.receivables.CustomerPrepaymentContracts;
import com.uten.imp.features.finance.receivables.CustomerPrepaymentOffsetService;
import com.uten.imp.features.finance.report.*;
import com.uten.imp.features.finance.statement.*;
import com.uten.imp.features.sales.shipment.SalesShipmentService;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.*;
import org.springframework.transaction.support.TransactionTemplate;
import java.math.BigDecimal;
import java.util.*;
import static com.uten.imp.features.finance.statement.FinanceOpenItemClassificationContracts.*;
import static com.uten.imp.features.finance.statement.FinanceReceivableClassificationContracts.*;
import static org.assertj.core.api.Assertions.*;

/** Actual manufacture, warehouse shipment, bank receipts, advance and ordered reversals. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
    "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
    "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
    "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
    "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
    "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
    "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
    "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class FinanceReceivableMaterialPostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired FinanceOpenItemClassificationService sources;
    @Autowired FinanceReceivableClassificationService categories;
    @Autowired FinanceClassificationCorrectionService corrections;
    @Autowired FinanceReportService reports;
    @Autowired FinanceReceiptService receipts;
    @Autowired CustomerPrepaymentOffsetService advances;
    @Autowired SalesShipmentService shipments;
    @Autowired JdbcTemplate db;
    @Autowired TransactionTemplate transactions;
    @Autowired TxSessionVars tx;
    @AfterEach void logout(){SecurityContextHolder.clearContext();}

    @Test void materialDebtFollowsTheActualBookSharesAndAdvanceIsNeverAnotherReceivable(){
        var fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);
        var world=fixture.seedWorld("fin08-material");fixture.loginAs(world.superAdminUserId());fixture.seedChartOfAccounts();
        db.update("UPDATE currencies SET code=?,name='匿名实际外币',exchange_rate=7 WHERE id=?","FIN08-"+world.currencyId(),world.currencyId());
        UUID orderItem=fixture.produceFinishedFromOpeningInputs(world,world.goodsA(),"20","20").orderItemId();
        UUID order=fixture.orderIdOfItem(orderItem);fixture.loginAs(world.superAdminUserId());
        var shipment=fixture.shipmentRequest(world,orderItem,world.goodsA(),"10");shipment.setBillDate(BusinessTime.today());
        UUID shipmentId=shipments.create(shipment).getId();fixture.shipThroughWarehouse(shipmentId);fixture.loginAs(world.superAdminUserId());
        UUID ledger=db.queryForObject("SELECT id FROM ar_ap_ledger WHERE source_doc_type='SALES_SHIPMENT' AND source_doc_id=?",UUID.class,shipmentId);
        String keyword=db.queryForObject("SELECT code FROM clients WHERE id=?",String.class,world.clientId());
        decimal(summary(keyword),"balance","7000");assertThat(summary(keyword).get("materialAmount")).isNull();
        var source=sources.classifySource(ledger,new SourceInput(UUID.randomUUID(),-1,null,"匿名原应收货款与物料份额",
            List.of(new Part("GOODS",n("600"),n("4200")),new Part("MATERIAL",n("400"),n("2800")))));
        decimal(summary(keyword),"materialAmount","2800");
        UUID bankStyle=UUID.randomUUID(),bank=UUID.randomUUID();
        db.update("INSERT INTO payment_styles(id,code,name,category,level,status) VALUES(?,?,'匿名实收账户科目','ACCOUNT',0,'使用')",bankStyle,"FIN08-BANK-"+bankStyle);
        db.update("INSERT INTO accounts(id,code,name,account_type,currency_id,status,style_id) VALUES(?,?,'匿名实收账户','BANK',?,'使用',?)",bank,"FIN08-BANK-"+bank,world.currencyId(),bankStyle);
        UUID reviewer=fixture.createUserWithPerms(world,"fin08-bank-reviewer","finance_receipt:view","finance_receipt:approve","finance_receipt:reverse","customer_prepayment:view","finance:view:all");fixture.grantDataScope(reviewer,"finance",world.employeeId());
        var advance=fixture.receiptRequest(world,null,bank,null,"100","100","0","0",n("6.8"),BusinessTime.today());
        advance.setReceiptKind("CUSTOMER_PREPAYMENT");advance.setSalesOrderId(order);advance.setCurrencyId(world.currencyId());
        advance.setExchangeRate(n("6.8"));advance.setAmountOriginal(n("100"));advance.setItems(List.of());
        UUID advanceId=receipts.create(advance).getId();fixture.loginAs(reviewer);receipts.approve(advanceId);fixture.loginAs(world.superAdminUserId());
        UUID advanceLedger=db.queryForObject("SELECT id FROM ar_ap_ledger WHERE source_doc_type='DIRECT_RECEIPT' AND source_doc_id=?",UUID.class,advanceId);
        decimal(summary(keyword),"balance","7000");decimal(summary(keyword),"materialAmount","2800");
        assertThat(sources.source(advanceLedger).get("sourceVerified")).isEqualTo(false);
        var offset=advances.apply(new CustomerPrepaymentContracts.ApplyRequest("FIN08-ADV-"+UUID.randomUUID(),advanceLedger,
            List.of(new CustomerPrepaymentContracts.Target(ledger,order,n("50"))),"真实预收抵物料款"));
        UUID offsetId=offset.allocations().getFirst().id();
        decimal(summary(keyword),"balance","6650");assertThat(summary(keyword).get("materialAmount")).isNull();
        var offsetInput=new CustomerOffsetInput(UUID.randomUUID(),-1,null,source.batchId(),"原预收份额6.8及原应收份额7分别保留",
            List.of(new OffsetPart("PREPAYMENT","MATERIAL",n("50"),n("340"),n("350"))));
        var originalOffset=categories.classifyOffset(offsetId,offsetInput);
        decimal(summary(keyword),"materialAmount","2450");
        UUID receiptId=receipts.create(fixture.receiptRequest(world,ledger,bank,null,"100","100","0","0",n("7.2"),BusinessTime.today())).getId();
        fixture.loginAs(reviewer);receipts.approve(receiptId);fixture.loginAs(world.superAdminUserId());
        UUID line=db.queryForObject("SELECT id FROM finance_receipt_lines WHERE receipt_id=?",UUID.class,receiptId);
        decimal(summary(keyword),"balance","5950");decimal(summary(keyword),"receivedAmount","720");
        assertThat(summary(keyword).get("materialAmount")).isNull();
        var receiptInput=new ReceiptInput(UUID.randomUUID(),-1,source.batchId(),"实际收款现金及账面核销独立归属",
            List.of(receiptPart("GOODS","60","432","420"),receiptPart("MATERIAL","40","288","280")));
        var classified=categories.classifyReceipt(line,receiptInput);assertThat(categories.classifyReceipt(line,receiptInput)).isEqualTo(classified);
        decimal(summary(keyword),"materialAmount","2170");
        long cashCount=db.queryForObject("SELECT count(*) FROM finance_receipts WHERE client_id=?",Long.class,world.clientId());
        long glCount=db.queryForObject("SELECT count(*) FROM gl_vouchers WHERE source_doc_id IN(?,?)",Long.class,receiptId,advanceId);
        assertThatThrownBy(()->sources.classifySource(ledger,new SourceInput(UUID.randomUUID(),0,null,"不能独立重分已被引用来源",
            List.of(new Part("MATERIAL",n("1000"),n("7000")))))).isInstanceOf(ApiException.class).hasMessageContaining("引用");
        UUID second=receipts.create(fixture.receiptRequest(world,ledger,bank,null,"400","400","0","0",n("7.2"),BusinessTime.today())).getId();
        fixture.loginAs(reviewer);receipts.approve(second);fixture.loginAs(world.superAdminUserId());
        UUID secondLine=db.queryForObject("SELECT id FROM finance_receipt_lines WHERE receipt_id=?",UUID.class,second);
        assertThatThrownBy(()->categories.classifyReceipt(secondLine,new ReceiptInput(UUID.randomUUID(),-1,source.batchId(),"超额误归物料",
            List.of(receiptPart("MATERIAL","400","2880","2800"))))).isInstanceOf(ApiException.class).hasMessageContaining("超过");
        // Direct SQL cannot bypass the same dated budget by presenting a conserved whole receipt.
        assertThatThrownBy(()->transactions.executeWithoutResult(status->{
            tx.bind();UUID bad=UUID.randomUUID();
            db.update("""
                INSERT INTO finance_receipt_classification_batches(id,request_id,receipt_line_id,revision,source_classification_id,
                  currency_id,amount_original,write_off_original,cash_local,write_off_local,book_local,source_reference,fingerprint,created_by)
                SELECT ?,?,line.id,0,?,receipt.currency_id,line.amount_original,line.write_off_amount,line.amount_local,line.write_off_local,
                  line.applied_amount_local,'匿名直接SQL超额应被拒绝',?,? FROM finance_receipt_lines line JOIN finance_receipts receipt ON receipt.id=line.receipt_id WHERE line.id=?
                """,bad,UUID.randomUUID(),source.batchId(),"a".repeat(64),world.superAdminUserId(),secondLine);
            db.update("INSERT INTO finance_receipt_classification_parts(batch_id,category,amount_original,write_off_original,cash_local,write_off_local,book_local) VALUES(?,'MATERIAL',400,0,2880,0,2800)",bad);
        })).hasStackTraceContaining("超过");
        categories.classifyReceipt(secondLine,new ReceiptInput(UUID.randomUUID(),-1,source.batchId(),"按原货款份额清偿",List.of(receiptPart("GOODS","400","2880","2800"))));
        decimal(summary(keyword),"materialAmount","2170");decimal(summary(keyword),"balance","3150");
        var filtered=reports.arApSummaryTemplate("AR",BusinessTime.today().withDayOfMonth(1),BusinessTime.today(),keyword,1,1,
            new FinanceReportColumnOptions(Map.of("search.materialAmount","2170"),null,null));
        assertThat(filtered.total()).isEqualTo(1);assertThat(filtered.columns()).hasSize(17);
        assertThat(db.queryForObject("SELECT count(*) FROM finance_receipts WHERE client_id=?",Long.class,world.clientId())).isEqualTo(cashCount+1);
        assertThat(db.queryForObject("SELECT count(*) FROM gl_vouchers WHERE source_doc_id IN(?,?)",Long.class,receiptId,advanceId)).isEqualTo(glCount);
        // Live source + two real FX cash lines + the actual prepayment target move together; zero write-off remains real zero.
        String factsBefore=financialFacts(ledger,bank,world.clientId());var originalGraph=corrections.graph(List.of(ledger));var swapped=swap(originalGraph);
        var invalidNodes=new ArrayList<FinanceClassificationCorrectionService.Node>();boolean tampered=false;for(var node:swapped.nodes()){if(!tampered&&node.kind().equals("AR_RECEIPT")){var parts=new ArrayList<Map<String,String>>();for(var part:node.parts()){var next=new LinkedHashMap<>(part);if(parts.isEmpty()){next.put("writeOffOriginal","0.1");}parts.add(next);}invalidNodes.add(new FinanceClassificationCorrectionService.Node(node.kind(),node.objectId(),node.expectedBatchId(),node.expectedRevision(),parts));tampered=true;}else invalidNodes.add(node);}
        var badGraph=new FinanceClassificationCorrectionService.Command(UUID.randomUUID(),List.of(ledger),swapped.expectedGraphFingerprint(),"不能把真实零冲销改成非零",invalidNodes);
        assertThatThrownBy(()->corrections.submit(badGraph)).isInstanceOf(ApiException.class).hasMessageContaining("冲销原币");assertThat(financialFacts(ledger,bank,world.clientId())).isEqualTo(factsBefore);
        var correctionReceipt=corrections.submit(swapped);decimal(summary(keyword),"materialAmount","980");decimal(summary(keyword),"balance","3150");assertThat(financialFacts(ledger,bank,world.clientId())).isEqualTo(factsBefore);
        assertThat(categories.classifyReceipt(line,receiptInput)).isEqualTo(classified);assertThat(categories.classifyOffset(offsetId,offsetInput)).isEqualTo(originalOffset);
        corrections.submit(swap(corrections.graph(List.of(ledger))));assertThat(corrections.submit(swapped)).isEqualTo(correctionReceipt);assertThat(categories.classifyReceipt(line,receiptInput)).isEqualTo(classified);decimal(summary(keyword),"materialAmount","2170");assertThat(financialFacts(ledger,bank,world.clientId())).isEqualTo(factsBefore);
        fixture.loginAs(reviewer);receipts.reverse(second);fixture.loginAs(world.superAdminUserId());
        decimal(summary(keyword),"balance","5950");decimal(summary(keyword),"materialAmount","2170");
        fixture.loginAs(reviewer);receipts.reverse(receiptId);fixture.loginAs(world.superAdminUserId());
        decimal(summary(keyword),"balance","6650");decimal(summary(keyword),"materialAmount","2450");
        advances.reverse(offset.batchId(),new CustomerPrepaymentContracts.ReverseRequest(offset.rowVersion(),"按原预收两端份额反审"));
        decimal(summary(keyword),"balance","7000");decimal(summary(keyword),"materialAmount","2800");
        fixture.loginAs(reviewer);receipts.reverse(advanceId);fixture.loginAs(world.superAdminUserId());
        assertThat(db.queryForObject("SELECT balance_current FROM accounts WHERE id=?",BigDecimal.class,bank)).isZero();
        decimal(summary(keyword),"materialAmount","2800");
    }
    @SuppressWarnings("unchecked") private FinanceClassificationCorrectionService.Command swap(Map<String,Object> graph){var nodes=new ArrayList<FinanceClassificationCorrectionService.Node>();for(var row:(List<Map<String,Object>>)graph.get("nodes")){var parts=new ArrayList<Map<String,String>>();for(var original:(List<Map<String,Object>>)row.get("parts")){var part=new LinkedHashMap<String,String>();original.forEach((k,v)->part.put(k,v.toString()));for(String category:List.of("category","sourceCategory","targetCategory")){String current=part.get(category);if("GOODS".equals(current))part.put(category,"MATERIAL");else if("MATERIAL".equals(current))part.put(category,"GOODS");}parts.add(part);}nodes.add(new FinanceClassificationCorrectionService.Node(row.get("kind").toString(),(UUID)row.get("objectId"),(UUID)row.get("expectedBatchId"),((Number)row.get("expectedRevision")).longValue(),parts));}return new FinanceClassificationCorrectionService.Command(UUID.randomUUID(),(List<UUID>)graph.get("ledgerIds"),graph.get("graphFingerprint").toString(),"整份实际来源、FX回款和预收两端明确交换归属",nodes);}
    private String financialFacts(UUID ledger,UUID bank,UUID client){return db.queryForObject("SELECT jsonb_build_object('ledger',(SELECT to_jsonb(a)FROM ar_ap_ledger a WHERE id=?),'bank',(SELECT to_jsonb(a)FROM accounts a WHERE id=?),'receipts',(SELECT jsonb_agg(to_jsonb(r)ORDER BY r.id)FROM finance_receipts r WHERE client_id=?),'lines',(SELECT jsonb_agg(to_jsonb(l)ORDER BY l.id)FROM finance_receipt_lines l),'offsets',(SELECT jsonb_agg(to_jsonb(o)ORDER BY o.id)FROM customer_open_item_offsets o),'gl',(SELECT jsonb_agg(to_jsonb(e)ORDER BY e.id)FROM gl_entries e),'stock',(SELECT jsonb_agg(to_jsonb(m)ORDER BY m.id)FROM stock_movements m))::text",String.class,ledger,bank,client);}
    private Map<String,Object> summary(String keyword){var response=reports.arApSummaryTemplate("AR",BusinessTime.today().withDayOfMonth(1),BusinessTime.today(),keyword,1,50,FinanceReportColumnOptions.NONE);assertThat(response.rows()).hasSize(1);return response.rows().getFirst();}
    private static ReceiptPart receiptPart(String category,String original,String cash,String book){return new ReceiptPart(category,n(original),BigDecimal.ZERO,n(cash),BigDecimal.ZERO,n(book));}
    private static BigDecimal n(String value){return new BigDecimal(value);}
    private static void decimal(Map<String,Object> row,String field,String value){assertThat(row.get(field)).as(field).isNotNull();assertThat(new BigDecimal(row.get(field).toString())).as(field).isEqualByComparingTo(value);}
}
