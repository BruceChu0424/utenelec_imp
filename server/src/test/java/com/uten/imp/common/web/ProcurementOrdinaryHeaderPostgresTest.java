package com.uten.imp.common.web;

import com.uten.imp.features.purchase.request.*;
import com.uten.imp.features.purchase.order.*;
import com.uten.imp.features.purchase.receipt.*;
import com.uten.imp.features.purchase.ret.*;
import com.uten.imp.features.subcontract.application.*;
import com.uten.imp.features.subcontract.inquiry.*;
import com.uten.imp.features.subcontract.order.*;
import com.uten.imp.features.subcontract.receipt.*;
import com.uten.imp.features.subcontract.ret.*;
import com.uten.imp.features.subcontract.material_issue.*;
import com.uten.imp.features.subcontract.material_return.*;
import com.uten.imp.features.subcontract.waste.*;
import com.uten.imp.security.*;
import com.uten.imp.support.MigratedProjectionSchema;
import jakarta.persistence.EntityManager;
import jakarta.persistence.criteria.Root;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;
import java.util.stream.Stream;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.persistenceunit.PersistenceManagedTypes;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;
import org.testcontainers.postgresql.PostgreSQLContainer;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Owning service predicates run against real current column shapes, including NULL and hidden owners. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class ProcurementOrdinaryHeaderPostgresTest {
    private static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine");
    private static JdbcTemplate db;
    private static jakarta.persistence.EntityManagerFactory emf;
    private static final UUID OWNER=UUID.randomUUID(),OTHER=UUID.randomUUID();
    private EntityManager em;
    record Document(String table,Class<?> entity,Class<?> service,String specification,Class<?> filter,
            String amountKey,boolean weight,boolean ownerScoped) {
        @Override public String toString(){return table;}
    }
    static Stream<Document> documents() { return Stream.of(
        new Document("purchase_requests",PurchaseRequest.class,PurchaseRequestService.class,"requestSpec",com.uten.imp.features.purchase.request.dto.RequestQueryFilter.class,null,false,false),
        new Document("purchase_orders",PurchaseOrder.class,PurchaseOrderService.class,"orderSpec",com.uten.imp.features.purchase.order.dto.OrderQueryFilter.class,"total",false,true),
        new Document("purchase_receipts",PurchaseReceipt.class,PurchaseReceiptService.class,"receiptSpec",com.uten.imp.features.purchase.receipt.dto.ReceiptQueryFilter.class,"total",false,true),
        new Document("purchase_returns",PurchaseReturn.class,PurchaseReturnService.class,"returnSpec",com.uten.imp.features.purchase.ret.dto.ReturnQueryFilter.class,"total",false,true),
        new Document("subcontract_applications",SubcontractApplication.class,SubcontractApplicationService.class,"applicationSpec",com.uten.imp.features.subcontract.application.dto.ApplicationQueryFilter.class,null,false,false),
        new Document("subcontract_inquiries",SubcontractInquiry.class,SubcontractInquiryService.class,"inquirySpec",com.uten.imp.features.subcontract.inquiry.dto.InquiryQueryFilter.class,"amount",false,true),
        new Document("subcontract_orders",SubcontractOrder.class,SubcontractOrderService.class,"orderSpec",com.uten.imp.features.subcontract.order.dto.OrderQueryFilter.class,"amount",false,true),
        new Document("subcontract_receipts",SubcontractReceipt.class,SubcontractReceiptService.class,"receiptSpec",com.uten.imp.features.subcontract.receipt.dto.ReceiptQueryFilter.class,"amount",false,true),
        new Document("subcontract_returns",SubcontractReturn.class,SubcontractReturnService.class,"returnSpec",com.uten.imp.features.subcontract.ret.dto.ReturnQueryFilter.class,"amount",false,true),
        new Document("subcontract_material_issues",SubcontractMaterialIssue.class,SubcontractMaterialIssueService.class,"issueSpec",com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueQueryFilter.class,null,false,true),
        new Document("subcontract_material_returns",SubcontractMaterialReturn.class,SubcontractMaterialReturnService.class,"materialReturnSpec",com.uten.imp.features.subcontract.material_return.dto.MaterialReturnQueryFilter.class,null,false,true),
        new Document("subcontract_wastes",SubcontractWaste.class,SubcontractWasteService.class,"wasteSpec",com.uten.imp.features.subcontract.waste.dto.WasteQueryFilter.class,null,true,true)); }
    static Stream<Document> commercialDocuments(){return documents().filter(document->document.amountKey()!=null);}
    @BeforeAll static void start() {
        PG.start();var source=new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());db=new JdbcTemplate(source);
        MigratedProjectionSchema.createCurrentTables(db,documents().map(Document::table).toArray(String[]::new));
        var factory=new LocalContainerEntityManagerFactoryBean();factory.setDataSource(source);factory.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        factory.setManagedTypes(PersistenceManagedTypes.of(documents().map(document->document.entity().getName()).toArray(String[]::new)));
        factory.setJpaPropertyMap(Map.of("hibernate.hbm2ddl.auto","none","hibernate.jdbc.time_zone","UTC"));factory.afterPropertiesSet();emf=factory.getObject();
    }
    @AfterAll static void stop() {
        if (emf != null) {
            emf.close();
        }
        PG.stop();
    }
    @BeforeEach void prepare() {
        db.execute("TRUNCATE "+documents().map(Document::table).collect(java.util.stream.Collectors.joining(",")));
        em=emf.createEntityManager();
        // ALL is a real supported history mode. Test only the owning predicates and typed columns;
        // imported-document provenance/marker functions have their separate full-chain contracts.
        var request=new MockHttpServletRequest();request.addParameter("originScope","ALL");
        RequestContextHolder.setRequestAttributes(new ServletRequestAttributes(request));
    }
    @AfterEach void close(){RequestContextHolder.resetRequestAttributes();if(em!=null)em.close();}

    @ParameterizedTest(name="{0}: typed dates/numbers before count, paging and facets") @MethodSource("documents")
    void eachActualServiceUsesItsDeclaredHeaderFieldsBeforeCountAndPaging(Document document) throws Exception {
        UUID first=seed(document,"1",OWNER,"2026-10-28","90071992547409.1234","1.2345",false);
        UUID second=seed(document,"2",OWNER,"2026-10-31","90071992547409.1235","1.2354",false);
        seed(document,"3",OWNER,"2026-10-29",null,null,false);
        seed(document,"4",OWNER,"2026-09-30","90071992547409.1234","1.2345",false);
        seed(document,"5",OTHER,"2026-10-28","90071992547409.1234","1.2345",false);
        seed(document,"6",OWNER,"2026-10-28","90071992547409.1234","1.2345",true);
        Object service=service(document,true);
        Map<String,String> values=new LinkedHashMap<>();values.put("search.billDate","2026-10");
        if(document.amountKey()!=null)values.put("search."+document.amountKey(),"90071992547409.1234..90071992547409.1235");
        if(document.weight())values.put("search.weight","1.235");
        Object filter=filter(document,new HeaderColumnFilter(values));
        var predicate=specification(document,service,filter);
        long expected=document.amountKey()!=null||document.weight()?2:document.ownerScoped()?3:4;
        assertThat(count(document,predicate)).isEqualTo(expected);
        assertThat(page(document,predicate,0)).containsExactly(first);
        assertThat(page(document,predicate,1)).containsExactly(second);
        @SuppressWarnings("unchecked") var facets=(Map<String,List<Map<String,Object>>>)ReflectionTestUtils.invokeMethod(service,"facets",filter);
        assertThat(facets.get("billNo")).hasSize((int)expected);
        values.put("search.billDate","2026-10-28..2026-10-30");
        assertThat(count(document,specification(document,service,filter(document,new HeaderColumnFilter(values)))))
                .isEqualTo(document.amountKey()!=null||document.weight()?1:document.ownerScoped()?2:3);
        if(document.amountKey()!=null||document.weight()) {
            values.put("search.billDate","2026-10");
            values.put("search."+(document.weight()?"weight":document.amountKey()),document.weight()?"!=1.235":"!=90071992547409.1234");
            assertThat(count(document,specification(document,service,filter(document,new HeaderColumnFilter(values)))))
                    .isEqualTo(document.weight()?0:1); // Unknown NULL never acts as zero, including !=.
        }
    }
    @ParameterizedTest(name="{0}: masked amount rejects before parsing/dependencies") @MethodSource("commercialDocuments")
    void allCommercialEntryPointsRejectHiddenAmountQueriesAndSortsBeforeReadingValues(Document document) throws Exception {
        Object masked=mock(document.service(),CALLS_REAL_METHODS);
        Object filtered=filter(document,HeaderColumnFilter.from(Map.of("search."+document.amountKey(),"NaN")));
        assertForbidden(()->ReflectionTestUtils.invokeMethod(masked,"list",filtered,1,20,null,null));
        assertForbidden(()->ReflectionTestUtils.invokeMethod(masked,"facets",filtered));
        Object empty=filter(document,HeaderColumnFilter.EMPTY);
        assertForbidden(()->ReflectionTestUtils.invokeMethod(masked,"list",empty,1,20,"total","asc"));
    }
    private void assertForbidden(org.assertj.core.api.ThrowableAssert.ThrowingCallable call) {
        assertThatThrownBy(call).isInstanceOfSatisfying(ApiException.class,failure->assertThat(failure.getCode()).isEqualTo(ErrorCode.FORBIDDEN));
    }
    private Object service(Document document,boolean visible) {
        Object service=mock(document.service(),CALLS_REAL_METHODS);
        var current=mock(SecurityContextCurrentUser.class);when(current.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(),OWNER,"reader",Set.of(),false,true,false)));
        var owners=mock(OwnerVisibility.class);when(owners.evaluate(anyString(),anyString())).thenReturn(new OwnerVisibility.OwnerScope(false,Set.of(OWNER)));
        Object access=document.table().startsWith("purchase_")?new com.uten.imp.features.purchase.PurchaseDocumentAccessPolicy(owners,current)
                :new com.uten.imp.features.subcontract.SubcontractDocumentAccessPolicy(owners,current);
        inject(service,document.service(),"access",access);inject(service,document.service(),"em",em);
        var commercial=mock(CommercialPriceVisibility.class,invocation->invocation.getMethod().getReturnType()==boolean.class?visible:RETURNS_DEFAULTS.answer(invocation));
        inject(service,document.service(),"commercialPriceVisibility",commercial);
        var masker=mock(ReceiptPriceMasker.class);when(masker.canViewPurchaseReceipt()).thenReturn(visible);when(masker.canViewSubcontractReceipt()).thenReturn(visible);
        inject(service,document.service(),"priceMasker",masker);return service;
    }
    private void inject(Object target,Class<?> type,String field,Object value) {
        if(org.springframework.util.ReflectionUtils.findField(type,field)!=null)ReflectionTestUtils.setField(target,field,value);
    }
    private Object filter(Document document,HeaderColumnFilter headers) throws Exception {
        var components=document.filter().getRecordComponents();Object[] values=new Object[components.length];
        for(int index=0;index<components.length;index++) {
            var type=components[index].getType();values[index]=type==HeaderColumnFilter.class?headers:type.isPrimitive()?java.lang.reflect.Array.get(java.lang.reflect.Array.newInstance(type,1),0):null;
        }
        return document.filter().getDeclaredConstructor(Arrays.stream(components).map(java.lang.reflect.RecordComponent::getType).toArray(Class<?>[]::new)).newInstance(values);
    }
    @SuppressWarnings("unchecked") private Specification<Object> specification(Document document,Object service,Object filter) {
        return ReflectionTestUtils.invokeMethod(service,document.specification(),filter);
    }
    @SuppressWarnings("unchecked") private long count(Document document,Specification<Object> specification) {
        var builder=em.getCriteriaBuilder();var query=builder.createQuery(Long.class);Root<Object> root=(Root<Object>)query.from(document.entity());
        query.select(builder.count(root)).where(specification.toPredicate(root,query,builder));return em.createQuery(query).getSingleResult();
    }
    @SuppressWarnings("unchecked") private List<UUID> page(Document document,Specification<Object> specification,int offset) {
        var builder=em.getCriteriaBuilder();var query=builder.createQuery(UUID.class);Root<Object> root=(Root<Object>)query.from(document.entity());
        query.select(root.get("id")).where(specification.toPredicate(root,query,builder)).orderBy(builder.asc(root.get("billNo")));
        return em.createQuery(query).setFirstResult(offset).setMaxResults(1).getResultList();
    }
    private UUID seed(Document document,String suffix,UUID owner,String date,String amount,String weight,boolean deleted) {
        UUID id=UUID.randomUUID();var fields=new ArrayList<>(List.of("id","bill_no","bill_date","maker_id","is_deleted"));
        var parameters=new ArrayList<Object>(List.of(id,"H-"+suffix,LocalDate.parse(date),owner,deleted));
        if(document.amountKey()!=null){fields.add("total_local");parameters.add(amount==null?null:new BigDecimal(amount));}
        if(document.weight()){fields.add("total_weight");parameters.add(weight==null?null:new BigDecimal(weight));}
        db.update("INSERT INTO "+document.table()+"("+String.join(",",fields)+") VALUES("+String.join(",",Collections.nCopies(fields.size(),"?"))+")",parameters.toArray());return id;
    }
}
