package com.uten.searchtest;

import com.uten.imp.common.util.NameRefKeyword;

import jakarta.persistence.*;
import org.hibernate.SessionFactory;
import org.hibernate.cfg.Configuration;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.data.domain.*;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.data.jpa.repository.support.SimpleJpaRepository;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/** Real JPA predicates, referenced names, count and relevance before pagination. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class NameRefKeywordPostgresTest {
    private static final PostgreSQLContainer DATABASE = new PostgreSQLContainer("postgres:16-alpine");
    private static SessionFactory factory;
    private EntityManager em;
    private UUID owner;
    private Party screws;
    private Party other;

    @BeforeAll static void start() {
        DATABASE.start();
        factory = new Configuration().addAnnotatedClass(Document.class).addAnnotatedClass(Party.class)
                .setProperty("hibernate.connection.url", DATABASE.getJdbcUrl())
                .setProperty("hibernate.connection.username", DATABASE.getUsername())
                .setProperty("hibernate.connection.password", DATABASE.getPassword())
                .setProperty("hibernate.hbm2ddl.auto", "create-drop")
                .buildSessionFactory();
    }

    @AfterAll static void stop() {
        if (factory != null) factory.close();
        DATABASE.stop();
    }

    @BeforeEach void fixture() {
        em = factory.createEntityManager();
        owner = UUID.randomUUID();
        em.getTransaction().begin();
        em.createQuery("delete from SearchDocumentFixture").executeUpdate();
        em.createQuery("delete from SearchPartyFixture").executeUpdate();
        screws = new Party("不锈钢螺丝", "SUP_100%");
        other = new Party("开关", "OTHER");
        em.persist(screws); em.persist(other);
        em.getTransaction().commit();
    }

    @AfterEach void close() { em.close(); }

    @Test void wordsMatchAcrossDocumentAndReferencedNameWithoutBroadeningOwnerScope() {
        add("AX_100", screws, 2020, owner);
        add("AX_100-OTHER", other, 2026, owner);
        add("AX_100", screws, 2026, UUID.randomUUID());
        var result = search("AX_100\u3000螺丝", 0, 20);
        assertThat(result.getTotalElements()).isEqualTo(1);
        assertThat(result.getContent()).extracting(row -> row.billNo).containsExactly("AX_100");
    }

    @Test void literalWildcardCharactersDoNotActAsSearchOperators() {
        add("AX_100%", screws, 2020, owner);
        add("AXA100X", screws, 2026, owner);
        add("M3\\A", screws, 2021, owner);
        assertThat(search("AX_100%", 0, 20).getContent()).extracting(row -> row.billNo).containsExactly("AX_100%");
        assertThat(search("SUP_100%", 0, 20).getTotalElements()).isEqualTo(3);
        assertThat(search("M3\\A", 0, 20).getContent()).extracting(row -> row.billNo).containsExactly("M3\\A");
    }

    @Test void exactAndPrefixResultsStayBeforeNewerSubstringResultsAcrossPages() {
        add("Z-AX-Z", other, 2026, owner);
        add("AX-EXT", other, 2025, owner);
        add("AX", other, 2000, owner);
        assertThat(search("AX", 0, 1).getContent()).extracting(row -> row.billNo).containsExactly("AX");
        assertThat(search("AX", 1, 1).getContent()).extracting(row -> row.billNo).containsExactly("AX-EXT");
        assertThat(search("AX", 2, 1).getContent()).extracting(row -> row.billNo).containsExactly("Z-AX-Z");
        assertThat(search("AX", 0, 1).getTotalElements()).isEqualTo(3);
    }

    @Test void exactReferencedNameAlsoRanksBeforeApproximateDocumentMatches() {
        add("X开关X", screws, 2026, owner);
        add("OLD", other, 2000, owner);
        assertThat(search("开关", 0, 1).getContent()).extracting(row -> row.billNo).containsExactly("OLD");
        assertThat(search("开关", 0, 1).getTotalElements()).isEqualTo(2);
    }

    @Test void missingOrDeletedReferencedNamesCannotCreateFalseMatches() {
        var deleted = new Party("不存在的螺丝", "DELETED");
        deleted.deleted = true;
        em.getTransaction().begin(); em.persist(deleted); em.getTransaction().commit();
        add("NO-NAME", deleted, 2020, owner);
        add("NO-REFERENCE", null, 2020, owner);
        assertThat(search("不存在", 0, 20).getTotalElements()).isZero();
        assertThat(search("NO-REFERENCE", 0, 20).getTotalElements()).isEqualTo(1);
    }

    private void add(String billNo, Party party, int year, UUID responsible) {
        em.getTransaction().begin();
        Document row = new Document();
        row.id = UUID.randomUUID(); row.billNo = billNo;
        row.partyId = party == null ? null : party.id;
        row.billDate = LocalDate.of(year, 1, 1); row.ownerId = responsible;
        em.persist(row); em.getTransaction().commit();
    }

    private Page<Document> search(String query, int page, int size) {
        Specification<Document> filter = (root, criteria, cb) -> {
            var matches = NameRefKeyword.match(root, criteria, cb, query, pattern -> {
                var fields = new ArrayList<jakarta.persistence.criteria.Predicate>();
                fields.add(NameRefKeyword.text(cb, root.get("billNo"), pattern));
                NameRefKeyword.byName(fields, criteria, cb, root.get("partyId"), Party.class, "name", pattern);
                NameRefKeyword.byName(fields, criteria, cb, root.get("partyId"), Party.class, "code", pattern);
                return NameRefKeyword.or(cb, fields);
            });
            return cb.and(cb.equal(root.get("ownerId"), owner), matches);
        };
        var plan = NameRefKeyword.page(filter, PageRequest.of(page, size,
                Sort.by(Sort.Direction.DESC, "billDate").and(Sort.by("id"))), query);
        return new SimpleJpaRepository<>(Document.class, em).findAll(plan.specification(), plan.pageable());
    }

    @Entity(name = "SearchPartyFixture") @Table(name = "search_party_fixture")
    public static class Party {
        @Id UUID id;
        String name;
        String code;
        boolean deleted;
        public Party() {}
        Party(String name, String code) { id = UUID.randomUUID(); this.name = name; this.code = code; }
    }

    @Entity(name = "SearchDocumentFixture") @Table(name = "search_document_fixture")
    public static class Document {
        @Id UUID id;
        String billNo;
        UUID partyId;
        UUID ownerId;
        LocalDate billDate;
        public Document() {}
    }
}
