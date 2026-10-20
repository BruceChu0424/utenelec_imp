package com.uten.searchtest;

import com.uten.imp.features.notice.NoticeAudienceService;
import com.uten.imp.features.webinquiry.WebsiteInquiry;
import com.uten.imp.features.webinquiry.WebsiteInquiryRepository;
import com.uten.imp.support.MigratedProjectionSchema;
import jakarta.persistence.EntityManager;
import org.hibernate.SessionFactory;
import org.hibernate.cfg.Configuration;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.data.domain.PageRequest;
import org.springframework.data.domain.Sort;
import org.springframework.data.jpa.repository.support.JpaRepositoryFactory;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.time.OffsetDateTime;
import java.util.*;

import static org.assertj.core.api.Assertions.assertThat;

/** Real Spring Data default repository methods and real notice candidate JDBC; sends no notices. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class AuxiliaryDirectorySearchPostgresTest {
    static final PostgreSQLContainer<?> PG = new PostgreSQLContainer<>("postgres:16-alpine");
    static SessionFactory factory;
    static NamedParameterJdbcTemplate db;
    static NoticeAudienceService audience;
    EntityManager em;
    WebsiteInquiryRepository inquiries;

    @BeforeAll static void start() {
        PG.start();
        var source = new DriverManagerDataSource(PG.getJdbcUrl(), PG.getUsername(), PG.getPassword());
        db = new NamedParameterJdbcTemplate(source);
        factory = new Configuration().addAnnotatedClass(WebsiteInquiry.class)
                .setProperty("hibernate.connection.url", PG.getJdbcUrl())
                .setProperty("hibernate.connection.username", PG.getUsername())
                .setProperty("hibernate.connection.password", PG.getPassword())
                .setProperty("hibernate.hbm2ddl.auto", "create-drop").buildSessionFactory();
        // Query-only fixtures retain the complete current migration column shapes;
        // the projection intentionally omits unrelated business CHECK/FK/triggers.
        MigratedProjectionSchema.createCurrentTables(db.getJdbcTemplate(),
                "departments", "employees", "users");
        audience = new NoticeAudienceService(JdbcClient.create(source));
    }
    @AfterAll static void stop() { if(factory!=null){ factory.close(); } PG.stop(); }
    @BeforeEach void setup() {
        for(String table:List.of("website_inquiries","users","employees","departments"))db.getJdbcTemplate().update("DELETE FROM "+table);
        em=factory.createEntityManager(); inquiries=new JpaRepositoryFactory(em).getRepository(WebsiteInquiryRepository.class);
    }
    @AfterEach void close(){em.close();}

    @Test void inquiryWordsAndLiteralCharactersKeepStatusCountsAndNameRelevanceBeforePaging() {
        UUID exact=inquiry("Alice","ACME_100%\\A","new",2020);
        UUID prefix=inquiry("Alice Team","other","following",2022);
        UUID contains=inquiry("X Alice X","other","new",2025);
        UUID company=inquiry("Bob","Alice","new",2026);
        inquiry("Alice","history","closed",2026); inquiry("Alice","history","converted",2026);
        inquiry("Other","ACMEA100X\\A","new",2026);
        var expected=List.of(exact,prefix,contains,company);
        for(int index=0;index<expected.size();index++) {
            var result=inquiries.search("ACTIVE","Alice",page(index,1));
            assertThat(result.getTotalElements()).isEqualTo(4);
            assertThat(result.getContent()).extracting(WebsiteInquiry::getId).containsExactly(expected.get(index));
        }
        assertThat(inquiries.search("ACTIVE","Alice\u3000ACME_100%\\A",page(0,20)).getContent())
                .extracting(WebsiteInquiry::getId).containsExactly(exact);
        assertThat(inquiries.search("ACTIVE","ACME_100%\\A",page(0,20)).getTotalElements()).isEqualTo(1);
        assertThat(inquiries.search("ACTIVE","Alice missing",page(0,20)).getTotalElements()).isZero();
        assertThat(inquiries.search("HISTORY","Alice",page(0,20)).getTotalElements()).isEqualTo(2);
        assertThat(inquiries.search("following","Alice",page(0,20)).getContent())
                .extracting(WebsiteInquiry::getId).containsExactly(prefix);
        assertThat(inquiries.search("ACTIVE","",page(0,1)).getContent().getFirst().getReceivedAt())
                .isEqualTo(OffsetDateTime.parse("2026-01-01T00:00:00Z").toInstant());
    }

    @Test void noticeCandidatesUseNamePriorityAndLiteralAndWordsWithoutChangingRecipientEligibility() {
        UUID exact=employee("Z","Alice","active",false,"active",false);
        UUID prefix=employee("M","Alice Team","probation",false,"active",false);
        UUID contains=employee("A","X Alice X","onLeave",false,"active",false);
        UUID code=employee("Alice","Bob","active",false,"active",false);
        employee("RESIGNED","Alice","resigned",false,"active",false);
        employee("DELETED","Alice","active",true,"active",false);
        employee("LOCKED","Alice","active",false,"locked",false);
        employee("DELETED_ACCOUNT","Alice","active",false,"active",true);
        employee("NO_ACCOUNT","Alice","active",false,null,false);
        UUID literal=employee("UT_100%\\A","字面员工","active",false,"active",false);
        employee("UTA100X\\A","近似员工","active",false,"active",false);
        assertThat(audience.searchEmployees("Alice")).extracting(row->row.id())
                .containsExactlyElementsOf(List.of(exact,prefix,contains,code).stream().map(UUID::toString).toList());
        assertThat(audience.searchEmployees("Alice Z")).extracting(row->row.id()).containsExactly(exact.toString());
        assertThat(audience.searchEmployees("UT_100%\\A")).extracting(row->row.id()).containsExactly(literal.toString());
        assertThat(audience.searchEmployees("Alice missing")).isEmpty();
    }

    private static PageRequest page(int page,int size){return PageRequest.of(page,size,Sort.by(Sort.Order.desc("receivedAt"),Sort.Order.desc("id")));}
    private UUID inquiry(String name,String company,String status,int year) {
        UUID id=UUID.randomUUID();
        db.update("""
                INSERT INTO website_inquiries(id,source_id,name,company,email,phone,message,source,locale,status,received_at)
                VALUES(:id,:source,:name,:company,'contact@example.com','10086','Switch request','contact','en',:status,:at)
                """,Map.of("id",id,"source",UUID.randomUUID().toString(),"name",name,"company",company,"status",status,"at",OffsetDateTime.parse(year+"-01-01T00:00:00Z")));
        return id;
    }
    private UUID employee(String code,String name,String status,boolean deleted,String accountStatus,boolean accountDeleted) {
        UUID id=UUID.randomUUID();
        db.update("INSERT INTO employees(id,code,full_name,status,is_deleted) VALUES(:id,:code,:name,:status,:deleted)",
                Map.of("id",id,"code",code,"name",name,"status",status,"deleted",deleted));
        if(accountStatus!=null) db.update("INSERT INTO users(id,employee_id,status,is_deleted) VALUES(:id,:employee,:status,:deleted)",
                Map.of("id",UUID.randomUUID(),"employee",id,"status",accountStatus,"deleted",accountDeleted));
        return id;
    }
}
