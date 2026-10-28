package com.uten.imp.common.util;

import com.uten.imp.common.integrity.ProductionSupplySourceGuard;
import com.uten.imp.common.util.EmployeeNameResolver.HistoricalWorkerRole;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.purchase.request.PurchaseRequest;
import com.uten.imp.features.purchase.request.PurchaseRequestService;
import com.uten.imp.features.purchase.order.PurchaseOrder;
import com.uten.imp.features.purchase.order.PurchaseOrderService;
import com.uten.imp.features.purchase.receipt.PurchaseReceipt;
import com.uten.imp.features.purchase.receipt.PurchaseReceiptService;
import com.uten.imp.features.subcontract.receipt.SubcontractReceipt;
import com.uten.imp.features.subcontract.receipt.SubcontractReceiptService;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssue;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueService;
import com.uten.imp.features.subcontract.material_return.SubcontractMaterialReturn;
import com.uten.imp.features.subcontract.material_return.SubcontractMaterialReturnService;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import java.util.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.test.util.ReflectionTestUtils;
import org.testcontainers.postgresql.PostgreSQLContainer;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Real SQL reads and real detail projections; test data has distinct same-name legacy identities. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class HistoricalWorkerNameProjectionPostgresTest {
    private static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine");
    private static final UUID CURRENT=UUID.fromString("00000000-0000-0000-0000-000000000409");
    private static final UUID HISTORY=UUID.fromString("00000000-0000-0000-0000-000000000546");
    private static final UUID DOCUMENT=UUID.fromString("00000000-0000-0000-0000-000000000042");
    private static JdbcTemplate db;
    private static NamedParameterJdbcTemplate named;
    private EmployeeNameResolver names;
    private List<String> statements;
    private record Role(String table,String actor,String legacy) {}
    private static Role role(HistoricalWorkerRole role) {
        return switch(role) {
            case PURCHASE_REQUEST_APPLICANT -> new Role("purchase_requests","applicant_id","applicant_legacy_id");
            case PURCHASE_ORDER_PURCHASER -> new Role("purchase_orders","purchaser_id","purchaser_legacy_id");
            case PURCHASE_RECEIPT_SENDER -> new Role("purchase_receipts","sender_id","sender_legacy_id");
            case PURCHASE_RECEIPT_RECEIVER -> new Role("purchase_receipts","receiver_id","receiver_legacy_id");
            case PURCHASE_RECEIPT_PURCHASER -> new Role("purchase_receipts","purchaser_id","purchaser_legacy_id");
            case SUBCONTRACT_RECEIPT_RECEIVER -> new Role("subcontract_receipts","sender_id","receiver_legacy_id");
            case SUBCONTRACT_MATERIAL_ISSUE_OPERATOR -> new Role("subcontract_material_issues","worker_id","operator_legacy_id");
            case SUBCONTRACT_MATERIAL_RETURN_OPERATOR -> new Role("subcontract_material_returns","worker_id","operator_legacy_id");
            case SALES_ORDER_SELLER -> new Role("sales_orders","seller_id","seller_legacy_id");
            case SALES_SHIPMENT_SELLER -> new Role("sales_shipments","seller_id","seller_legacy_id");
            case SALES_SHIPMENT_SENDER -> new Role("sales_shipments","sender_id","sender_legacy_id");
            case SALES_OTHER_SHIPMENT_SELLER -> new Role("sales_other_shipments","seller_id","seller_legacy_id");
            case SALES_OTHER_SHIPMENT_SENDER -> new Role("sales_other_shipments","sender_id","sender_legacy_id");
            case SALES_RETURN_SELLER -> new Role("sales_returns","seller_id","seller_legacy_id");
        };
    }
    @BeforeAll static void start() {
        PG.start();var source=new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());
        db=new JdbcTemplate(source);named=new NamedParameterJdbcTemplate(source);
        com.uten.imp.support.MigratedProjectionSchema.createCurrentColumns(db,"employees","users");
        com.uten.imp.support.MigratedProjectionSchema.createCurrentLegacyWorkerIdentityReaders(db);
        db.execute("ALTER TABLE employees ADD PRIMARY KEY(id); ALTER TABLE users ADD PRIMARY KEY(id)");
        Set<String> tables=new LinkedHashSet<>();
        for(var key:HistoricalWorkerRole.values()) {
            tables.add(role(key).table());
        }
        com.uten.imp.support.MigratedProjectionSchema.createCurrentColumns(db,tables.toArray(String[]::new));
        tables.forEach(table->db.execute("ALTER TABLE "+table+" ADD PRIMARY KEY(id)"));
    }
    @AfterAll static void stop(){PG.stop();}
    @BeforeEach void reset() {
        var tables=new LinkedHashSet<String>();for(var key:HistoricalWorkerRole.values())tables.add(role(key).table());
        db.execute("TRUNCATE employee_identity_aliases,employee_identity_user_tombstones,employee_legacy_identity_aliases,employees,users,"+String.join(",",tables));
        db.update("INSERT INTO employees(id,legacy_id,full_name,code,status,is_deleted) VALUES (?,409,'Same name','UT0004','active',false),(?,546,'Same name','UT0192','resigned',false)",CURRENT,HISTORY);
        statements=new ArrayList<>();EntityManager em=mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(call->{
            String sql=call.getArgument(0);statements.add(sql);Map<String,Object> parameters=new HashMap<>();
            Query query=mock(Query.class);
            when(query.setParameter(anyString(),any())).thenAnswer(binding->{parameters.put(binding.getArgument(0),binding.getArgument(1));return query;});
            when(query.setMaxResults(anyInt())).thenReturn(query);
            when(query.getResultList()).thenAnswer(ignored->named.query(sql,parameters,(rs,index)->rs.getObject(1)));
            return query;
        });
        names=new EmployeeNameResolver(em);
    }
    private void document(HistoricalWorkerRole key,Integer employeeLegacy,UUID employeeId) {
        Role r=role(key);
        Set<String> realColumns=new HashSet<>(db.queryForList(
                "SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name=?",
                String.class,r.table()));
        Map<String,Object> row=new LinkedHashMap<>();
        row.put("id",DOCUMENT);row.put("legacy_id",42);
        // Conflicting current owner/operator facts use only genuine source
        // columns; a query oracle must not invent the same owner field on every document.
        for(String column:List.of("maker_legacy_id","approver_legacy_id"))
            if(realColumns.contains(column))row.put(column,409);
        for(String column:List.of("maker_id","approver_id","owner_employee_id"))
            if(realColumns.contains(column))row.put(column,CURRENT);
        row.put(r.actor(),employeeId);row.put(r.legacy(),employeeLegacy);
        db.update("INSERT INTO "+r.table()+"("+String.join(",",row.keySet())+") VALUES ("
                +String.join(",",Collections.nCopies(row.size(),"?"))+")",row.values().toArray());
    }
    @ParameterizedTest @EnumSource(HistoricalWorkerRole.class)
    void exactLegacyIdentityWinsOverSameNameCanonicalAliasAndCurrentOwner(HistoricalWorkerRole key) {
        document(key,546,null);
        assertThat(names.historicalWorkerNameWithCodeOf(null,DOCUMENT,42,key)).isEqualTo("Same name(UT0192)");
        Role r=role(key);
        assertThat(db.queryForObject("SELECT "+r.legacy()+" FROM "+r.table()+" WHERE id=?",Integer.class,DOCUMENT)).isEqualTo(546);
        assertThat(db.queryForObject("SELECT "+r.actor()+" FROM "+r.table()+" WHERE id=?",UUID.class,DOCUMENT)).isNull();
    }
    @Test void currentUuidIsAuthoritativeAndUnknownNonnullUuidNeverFallsBack() {
        document(HistoricalWorkerRole.PURCHASE_ORDER_PURCHASER,546,null);
        assertThat(names.historicalWorkerNameWithCodeOf(CURRENT,DOCUMENT,42,HistoricalWorkerRole.PURCHASE_ORDER_PURCHASER)).isEqualTo("Same name(UT0004)");
        assertThat(names.historicalWorkerNameWithCodeOf(UUID.randomUUID(),DOCUMENT,42,HistoricalWorkerRole.PURCHASE_ORDER_PURCHASER)).isNull();
        assertThat(statements).noneMatch(sql->sql.contains("FROM purchase_orders"));
    }
    @Test void fallbackRequiresTheSameHistoricalDocumentAndStoredNullRoleUuid() {
        document(HistoricalWorkerRole.PURCHASE_ORDER_PURCHASER,546,null);
        for(Integer legacy:Arrays.asList(null,0,-1))
            assertThat(names.historicalWorkerNameWithCodeOf(null,DOCUMENT,legacy,HistoricalWorkerRole.PURCHASE_ORDER_PURCHASER)).isNull();
        assertThat(names.historicalWorkerNameWithCodeOf(null,null,42,HistoricalWorkerRole.PURCHASE_ORDER_PURCHASER)).isNull();
        assertThat(names.historicalWorkerNameWithCodeOf(null,DOCUMENT,42,null)).isNull();
        assertThat(statements).isEmpty();
        assertThat(names.historicalWorkerNameWithCodeOf(null,DOCUMENT,43,HistoricalWorkerRole.PURCHASE_ORDER_PURCHASER)).isNull();
        assertThat(names.historicalWorkerNameWithCodeOf(null,UUID.randomUUID(),42,HistoricalWorkerRole.PURCHASE_ORDER_PURCHASER)).isNull();
        db.update("UPDATE purchase_orders SET purchaser_id=?",CURRENT);
        assertThat(names.historicalWorkerNameWithCodeOf(null,DOCUMENT,42,HistoricalWorkerRole.PURCHASE_ORDER_PURCHASER)).isNull();
    }
    @ParameterizedTest @ValueSource(ints={124,125,129,392,462,503,504,508,528,541,542,5068,5209,5326})
    void missingSourceWorkerIsUnknownAndLegacyIdIsPreserved(int missing) {
        document(HistoricalWorkerRole.SALES_ORDER_SELLER,missing,null);
        assertThat(names.historicalWorkerNameWithCodeOf(null,DOCUMENT,42,HistoricalWorkerRole.SALES_ORDER_SELLER)).isNull();
        assertThat(db.queryForObject("SELECT seller_legacy_id FROM sales_orders",Integer.class)).isEqualTo(missing);
        assertThat(db.queryForObject("SELECT count(*) FROM employees",Integer.class)).isEqualTo(2);
    }
    @Test void codeReallocationDoesNotChangeLegacyIdentityOrCacheAStaleName() {
        document(HistoricalWorkerRole.PURCHASE_ORDER_PURCHASER,546,null);
        assertThat(names.historicalWorkerNameWithCodeOf(null,DOCUMENT,42,HistoricalWorkerRole.PURCHASE_ORDER_PURCHASER)).isEqualTo("Same name(UT0192)");
        db.update("UPDATE employees SET code='UT0999' WHERE id=?",HISTORY);
        assertThat(names.historicalWorkerNameWithCodeOf(null,DOCUMENT,42,HistoricalWorkerRole.PURCHASE_ORDER_PURCHASER)).isEqualTo("Same name(UT0999)");
    }
    @Test void accountActorsCannotBeRequestedAndOnlineWritesRemainUuidOnly() {
        assertThat(Arrays.stream(HistoricalWorkerRole.values()).map(Enum::name)).noneMatch(value->value.contains("MAKER")||value.contains("APPROVER")||value.contains("OWNER"));
        assertThat(names.nameWithCodeOf(null)).isNull();
        assertThatThrownBy(()->names.resolveForWrite(null,546,"Same name","Worker")).isInstanceOf(ApiException.class);
        assertThat(statements).isEmpty();
    }
    @Test void ambiguousLegacyIdentityDoesNotChooseAnArbitraryEmployee() {
        document(HistoricalWorkerRole.PURCHASE_ORDER_PURCHASER,546,null);
        db.update("INSERT INTO employees(id,legacy_id,full_name,code,status,is_deleted) VALUES (?,546,'Other','UT1234','resigned',false)",UUID.randomUUID());
        assertThat(names.historicalWorkerNameWithCodeOf(null,DOCUMENT,42,HistoricalWorkerRole.PURCHASE_ORDER_PURCHASER)).isNull();
    }
    @Test void verifiedLegacyAliasKeepsTheDeletedHistoricalNameWithoutAnExactCurrentLegacyRow() {
        document(HistoricalWorkerRole.PURCHASE_ORDER_PURCHASER,777777,null);
        db.update("UPDATE employees SET is_deleted=true WHERE id=?",HISTORY);
        db.update("""
                INSERT INTO employee_legacy_identity_aliases(namespace_key,legacy_id,canonical_employee_id,source_employee_id,evidence_reference)
                VALUES ('B_WORKER',777777,?,?,'verified-projection-fixture')
                """,HISTORY,UUID.randomUUID());
        assertThat(names.historicalWorkerNameWithCodeOf(null,DOCUMENT,42,HistoricalWorkerRole.PURCHASE_ORDER_PURCHASER))
                .isEqualTo("Same name(UT0192)");
        assertThat(db.queryForObject("SELECT purchaser_legacy_id FROM purchase_orders",Integer.class)).isEqualTo(777777);
        assertThat(db.queryForObject("SELECT count(*) FROM employees",Integer.class)).isEqualTo(2);
    }
    @ParameterizedTest @ValueSource(strings={"request","order","purchaseReceipt","subcontractReceipt","issue","materialReturn"})
    void actualDetailProjectionReadsHistoryWithoutInventingRoleUuid(String kind) {
        Object entity,service;HistoricalWorkerRole key;String getter;
        switch(kind) {
            case "request" -> { var e=new PurchaseRequest();e.setId(DOCUMENT);e.setLegacyId(42);e.setApplicantLegacyId(546);entity=e;service=mock(PurchaseRequestService.class,CALLS_REAL_METHODS);key=HistoricalWorkerRole.PURCHASE_REQUEST_APPLICANT;getter="getApplicantName"; }
            case "order" -> { var e=new PurchaseOrder();e.setId(DOCUMENT);e.setLegacyId(42);e.setPurchaserLegacyId(546);e.setStatus((short)1);entity=e;service=mock(PurchaseOrderService.class,CALLS_REAL_METHODS);key=HistoricalWorkerRole.PURCHASE_ORDER_PURCHASER;getter="getPurchaserName"; }
            case "purchaseReceipt" -> { var e=new PurchaseReceipt();e.setId(DOCUMENT);e.setLegacyId(42);e.setReceiverLegacyId(546);entity=e;service=mock(PurchaseReceiptService.class,CALLS_REAL_METHODS);key=HistoricalWorkerRole.PURCHASE_RECEIPT_RECEIVER;getter="getReceiverName"; }
            case "subcontractReceipt" -> { var e=new SubcontractReceipt();e.setId(DOCUMENT);e.setLegacyId(42);e.setReceiverLegacyId(546);e.setReceiverName("Frozen worker");entity=e;service=mock(SubcontractReceiptService.class,CALLS_REAL_METHODS);key=HistoricalWorkerRole.SUBCONTRACT_RECEIPT_RECEIVER;getter="getSenderName"; }
            case "issue" -> { var e=new SubcontractMaterialIssue();e.setId(DOCUMENT);e.setLegacyId(42);e.setOperatorLegacyId(546);e.setOperatorName("Frozen worker");entity=e;service=mock(SubcontractMaterialIssueService.class,CALLS_REAL_METHODS);key=HistoricalWorkerRole.SUBCONTRACT_MATERIAL_ISSUE_OPERATOR;getter="getWorkerName"; }
            default -> { var e=new SubcontractMaterialReturn();e.setId(DOCUMENT);e.setLegacyId(42);e.setOperatorLegacyId(546);e.setOperatorName("Frozen worker");entity=e;service=mock(SubcontractMaterialReturnService.class,CALLS_REAL_METHODS);key=HistoricalWorkerRole.SUBCONTRACT_MATERIAL_RETURN_OPERATOR;getter="getWorkerName"; }
        }
        document(key,546,null);ReflectionTestUtils.setField(service,"nameResolver",names);
        if(kind.equals("request")||kind.equals("order"))ReflectionTestUtils.setField(service,"productionSourceGuard",mock(ProductionSupplySourceGuard.class));
        if(kind.equals("purchaseReceipt")||kind.equals("subcontractReceipt"))ReflectionTestUtils.setField(service,"priceMasker",mock(com.uten.imp.features.purchase.receipt.ReceiptPriceMasker.class));
        Object detail=kind.equals("order")?ReflectionTestUtils.invokeMethod(service,"toDetail",entity,List.of(),null):ReflectionTestUtils.invokeMethod(service,"toDetail",entity,List.of());
        assertThat(ReflectionTestUtils.invokeGetterMethod(detail,getter)).isEqualTo("Same name(UT0192)");
        assertThat(ReflectionTestUtils.invokeGetterMethod(entity,role(key).actor().equals("sender_id")?"getSenderId":role(key).actor().equals("worker_id")?"getWorkerId":role(key).actor().equals("receiver_id")?"getReceiverId":kind.equals("request")?"getApplicantId":"getPurchaserId")).isNull();
    }
}
