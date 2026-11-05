package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.finance.payment.FinancePaymentService;
import com.uten.imp.features.finance.payment.dto.FinancePaymentSaveRequest;
import com.uten.imp.features.finance.payment.dto.FinancePaymentLineInput;
import com.uten.imp.features.finance.receipt.FinanceReceiptService;
import com.uten.imp.features.finance.receipt.dto.FinanceReceiptSaveRequest;
import com.uten.imp.features.master.lifecycle.MasterEntityKind;
import com.uten.imp.features.master.lifecycle.MasterLifecycleService;
import com.uten.imp.features.master.lifecycle.dto.MasterBatchRequests;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

import java.math.BigDecimal;
import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.time.ZoneOffset;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

/** Real HTTP/security and owning AR/AP sources. Finance labels do not grant master-data or document scope. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.RANDOM_PORT,properties={
        "server.address=127.0.0.1","spring.profiles.active=dev","uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false","uten.production.readiness-reconcile.enabled=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only","uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class FinanceDocumentPartyReferenceHttpPostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired ObjectMapper json;
    @Autowired PasswordEncoder passwords;
    @Autowired FinanceReceiptService receipts;
    @Autowired FinancePaymentService payments;
    @Autowired MasterLifecycleService masterLifecycle;
    @LocalServerPort int port;
    private final HttpClient http=HttpClient.newBuilder().followRedirects(HttpClient.Redirect.NEVER).build();
    private static final Set<String> FINANCE_PERMISSIONS=Set.of("finance_receipt:view","finance_receipt:approve",
            "finance_receipt:reverse","finance_payment:view","finance_payment:approve","finance_payment:reverse");
    private static final Set<String> MASTER_PRIVATE_FIELDS=Set.of("phone","phone2","mobile","fax","bankAccount",
            "bankAccountNo","taxId","address","shipAddress","postcode","linkman");
    @AfterEach void logout(){SecurityContextHolder.clearContext();}

    @Test void authorizedFinanceNamesRemainVisibleWithoutMasterAccessWhileOtherDocumentsStayScoped()throws Exception{
        String tag="party-http-"+UUID.randomUUID().toString().substring(0,8);
        var batch=ShipmentReceivableBatchFixture.prepare(beans,db,tag);
        var fixture=batch.fixture();var world=batch.world();fixture.loginAs(world.superAdminUserId());
        // Explicit other ownership keeps master lookup scope distinct from financial scope.
        db.update("UPDATE clients SET owner_employee_id=? WHERE id=?",world.employeeId(),world.clientId());
        db.update("UPDATE suppliers SET owner_employee_id=? WHERE id=?",world.employeeId(),world.supplierId());
        String clientName=db.queryForObject("SELECT name FROM clients WHERE id=?",String.class,world.clientId());
        String supplierName=db.queryForObject("SELECT name FROM suppliers WHERE id=?",String.class,world.supplierId());
        var purchase=new SupplierPrepaymentPostgresTest();beans.autowireBean(purchase);
        // Real purchase order, independent finance approval, receipt, IQC and warehouse stock-in produce this AP.
        UUID payable=purchase.receipt(fixture,world,world.currencyId());
        fixture.loginAs(world.superAdminUserId());
        var receiptRequest=receipt(batch,"30");var receipt=receipts.create(receiptRequest);
        var paymentRequest=payment(batch,payable,"10");var payment=payments.create(paymentRequest);

        Set<String> full=new HashSet<>(FINANCE_PERMISSIONS);full.add("finance:view:all");
        Actor fullReviewer=actor(fixture,world,tag+"-all",full);
        Actor scopedReviewer=actor(fixture,world,tag+"-scoped",FINANCE_PERMISSIONS);
        fixture.grantDataScope(scopedReviewer.id(),"finance",world.employeeId());
        // Another real creator owns these drafts. Their AR/AP remain the same
        // actual sources; only document ownership differs, through the service authority.
        var otherWorld=fixture.seedWorld(tag+"-other");fixture.loginAs(otherWorld.superAdminUserId());
        var otherReceipt=receipts.create(receipt(batch,"20"));
        var otherPayment=payments.create(payment(batch,payable,"5"));
        String allToken=login(fullReviewer);
        assertMasterUnavailable(allToken,world);
        assertFinanceReferences(allToken,receipt.getId(),receipt.getBillNo(),payment.getId(),payment.getBillNo(),clientName,supplierName);
        String scopedToken=login(scopedReviewer);
        assertMasterUnavailable(scopedToken,world);
        assertFinanceReferences(scopedToken,receipt.getId(),receipt.getBillNo(),payment.getId(),payment.getBillNo(),clientName,supplierName);
        get("/api/finance/receipts/"+otherReceipt.getId(),scopedToken,404);
        get("/api/finance/payments/"+otherPayment.getId(),scopedToken,404);
        assertThat(get("/api/finance/receipts?billNo="+encode(otherReceipt.getBillNo())+"&page=1&size=1",scopedToken,200).path("total").asLong()).isZero();
        assertThat(get("/api/finance/payments?billNo="+encode(otherPayment.getBillNo())+"&page=1&size=1",scopedToken,200).path("total").asLong()).isZero();

        // An old financial reference remains readable after the master is hidden.
        // No new party selection or master permission is granted by these labels.
        fixture.loginAs(world.superAdminUserId());
        assertThat(masterLifecycle.batchDelete(MasterEntityKind.CLIENT,
                List.of(new MasterBatchRequests.Item(world.clientId(),null)),true).succeeded()).isEqualTo(1);
        assertThat(masterLifecycle.batchDelete(MasterEntityKind.SUPPLIER,
                List.of(new MasterBatchRequests.Item(world.supplierId(),null)),true).succeeded()).isEqualTo(1);
        assertThat(db.queryForObject("SELECT is_hidden FROM clients WHERE id=?",Boolean.class,world.clientId())).isTrue();
        assertThat(db.queryForObject("SELECT is_hidden FROM suppliers WHERE id=?",Boolean.class,world.supplierId())).isTrue();
        assertFinanceReferences(allToken,receipt.getId(),receipt.getBillNo(),payment.getId(),payment.getBillNo(),clientName,supplierName);
        assertFinanceReferences(scopedToken,receipt.getId(),receipt.getBillNo(),payment.getId(),payment.getBillNo(),clientName,supplierName);
        assertMasterUnavailable(allToken,world);assertMasterUnavailable(scopedToken,world);
    }

    private record Actor(UUID id,String login,String password) { }
    private Actor actor(FullChainEndToEndTest fixture,FullChainEndToEndTest.World world,String tag,Set<String> allowed){
        fixture.loginAs(world.superAdminUserId());
        UUID id=fixture.createUserWithPerms(world,tag,allowed.toArray(String[]::new));fixture.loginAs(id);
        var inherited=new HashSet<>(((AuthUser)SecurityContextHolder.getContext().getAuthentication().getPrincipal()).getPermissions());
        inherited.removeAll(allowed);
        for(String code:inherited)db.update("INSERT INTO user_permission_overrides(user_id,permission_id,effect) SELECT ?,id,'revoke' FROM permissions WHERE code=? "
                +"ON CONFLICT(user_id,permission_id) DO UPDATE SET effect='revoke',active=TRUE",id,code);
        String password="Finite-Names-"+UUID.randomUUID(); // Synthetic, isolated test password; never a company credential.
        db.update("UPDATE users SET password_hash=?,must_change_password=FALSE WHERE id=?",passwords.encode(password),id);
        fixture.loginAs(id);var principal=(AuthUser)SecurityContextHolder.getContext().getAuthentication().getPrincipal();
        assertThat(principal.isSuperAdmin()).isFalse();assertThat(principal.getPermissions()).containsExactlyInAnyOrderElementsOf(allowed);
        return new Actor(id,db.queryForObject("SELECT login_account FROM users WHERE id=?",String.class,id),password);
    }

    private FinanceReceiptSaveRequest receipt(ShipmentReceivableBatchFixture.Prepared batch,String amount){
        var request=batch.fixture().receiptRequest(batch.world(),batch.ledger(),batch.bank(),null,amount,amount,"0","0",new BigDecimal("7.2"),BusinessTime.today());
        var occurred=BusinessTime.today().atStartOfDay().atOffset(ZoneOffset.ofHours(8));
        request.setBankBookedAt(occurred);request.setExchangeRateEffectiveAt(occurred);return request;
    }
    private FinancePaymentSaveRequest payment(ShipmentReceivableBatchFixture.Prepared batch,UUID payable,String amount){
        var world=batch.world();var request=new FinancePaymentSaveRequest();request.setBillDate(BusinessTime.today());
        request.setCreateIdempotencyKey("party-http-payment-"+UUID.randomUUID());request.setSupplierId(world.supplierId());
        request.setAccountId(batch.bank());request.setCurrencyId(world.currencyId());request.setExchangeRate(new BigDecimal("7.2"));
        request.setAmountOriginal(new BigDecimal(amount));request.setAccountCurrencyId(world.currencyId());request.setAccountAmount(new BigDecimal(amount));
        request.setBankFeeAccountAmount(BigDecimal.ZERO);request.setBankReference("FINITE-NATIVE-"+UUID.randomUUID());
        request.setBankBookedAt(BusinessTime.startOfDay(BusinessTime.today()));
        var line=new FinancePaymentLineInput();line.setAppliedLedgerId(payable);line.setSupplierId(world.supplierId());
        line.setAmountOriginal(new BigDecimal(amount));
        request.setItems(List.of(line));return request;
    }

    private void assertMasterUnavailable(String token,FullChainEndToEndTest.World world)throws Exception{
        get("/api/master/clients/"+world.clientId(),token,403);
        get("/api/master/suppliers/"+world.supplierId(),token,403);
        JsonNode clients=get("/api/master/clients/lookup?ids="+world.clientId(),token,200);
        JsonNode suppliers=get("/api/master/suppliers/lookup?ids="+world.supplierId(),token,200);
        assertThat(clients.isArray()).isTrue();assertThat(clients.isEmpty()).isTrue();
        // Supplier dictionaries already follow the narrow business-reference
        // capability. They do not confer the supplier master-detail permission.
        assertThat(suppliers.isArray()).isTrue();assertThat(suppliers.size()).isEqualTo(1);
        assertThat(suppliers.get(0).path("id").asText()).isEqualTo(world.supplierId().toString());
        Set<String> supplierFields=Set.of("id","code","name","status","defaultSettlementMethodId","selectable");
        suppliers.get(0).fieldNames().forEachRemaining(field->assertThat(field).isIn(supplierFields));
        noMasterPii(suppliers);
    }
    private void assertFinanceReferences(String token,UUID receipt,String receiptNo,UUID payment,String paymentNo,String client,String supplier)throws Exception{
        JsonNode received=get("/api/finance/receipts/"+receipt,token,200);
        JsonNode paid=get("/api/finance/payments/"+payment,token,200);
        assertThat(received.path("clientName").asText()).isEqualTo(client);
        assertThat(paid.path("supplierName").asText()).isEqualTo(supplier);
        JsonNode receiptsPage=get("/api/finance/receipts?billNo="+encode(receiptNo)+"&page=1&size=1",token,200);
        JsonNode paymentsPage=get("/api/finance/payments?billNo="+encode(paymentNo)+"&page=1&size=1",token,200);
        assertThat(receiptsPage.path("total").asLong()).isEqualTo(1);assertThat(paymentsPage.path("total").asLong()).isEqualTo(1);
        assertThat(receiptsPage.path("items").get(0).path("clientName").asText()).isEqualTo(client);
        assertThat(paymentsPage.path("items").get(0).path("supplierName").asText()).isEqualTo(supplier);
        for(JsonNode value:List.of(received,paid,receiptsPage,paymentsPage))noMasterPii(value);
        assertThat(received.has("client")).isFalse();assertThat(paid.has("supplier")).isFalse();
    }
    private void noMasterPii(JsonNode value){
        if(value.isObject())value.properties().forEach(field->{assertThat(field.getKey()).isNotIn(MASTER_PRIVATE_FIELDS);noMasterPii(field.getValue());});
        else if(value.isArray())value.forEach(this::noMasterPii);
    }
    private String login(Actor actor)throws Exception{
        JsonNode response=exchange("POST","/api/auth/login",json.writeValueAsBytes(Map.of("loginAccount",actor.login(),"password",actor.password())),null,200);
        String token=response.path("accessToken").asText();assertThat(token).isNotBlank();return token;
    }
    private JsonNode get(String path,String token,int status)throws Exception{return exchange("GET",path,null,token,status);}
    private JsonNode exchange(String method,String path,byte[] body,String token,int status)throws Exception{
        var request=HttpRequest.newBuilder(URI.create("http://127.0.0.1:"+port+path)).timeout(Duration.ofSeconds(30))
                .header("Accept","application/json").method(method,body==null?HttpRequest.BodyPublishers.noBody():HttpRequest.BodyPublishers.ofByteArray(body));
        if(body!=null)request.header("Content-Type","application/json");if(token!=null)request.header("Authorization","Bearer "+token);
        var response=http.send(request.build(),HttpResponse.BodyHandlers.ofByteArray());
        assertThat(response.statusCode()).as(method+" "+path).isEqualTo(status);
        return response.body().length==0?json.nullNode():json.readTree(response.body());
    }
    private static String encode(String value){return URLEncoder.encode(value,StandardCharsets.UTF_8);}
}
