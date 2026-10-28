package com.uten.imp.features.suggestion;

import com.uten.imp.application.port.HrNoticePort;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import com.uten.imp.support.MigratedProjectionSchema;
import com.uten.imp.support.MigratedSchemaBaseline;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.SharedEntityManagerCreator;
import org.springframework.orm.jpa.persistenceunit.PersistenceManagedTypes;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.data.jpa.repository.support.JpaRepositoryFactory;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.*;

/** Real Hibernate predicates/counts against current migrated shapes; no mock Criteria expressions. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class SuggestionHeaderQueryPostgresTest {
    private static MigratedSchemaBaseline.ScopedDatabase database;
    private static jakarta.persistence.EntityManagerFactory emf;
    private static JdbcTemplate db;
    private SuggestionService service;
    private SecurityContextCurrentUser currentUser;
    private final UUID viewer=UUID.randomUUID();

    @BeforeAll static void baseline() throws Exception {
        database=MigratedSchemaBaseline.openDatabase("suggestion_headers");
        try(var connection=database.openConnection();var sql=connection.createStatement()) {
            sql.execute("CREATE SCHEMA suggestion_header_oracle");
            sql.execute("SET search_path=suggestion_header_oracle,public");
            MigratedProjectionSchema.copyEmptyTablesFromMigratedCatalog(connection,"suggestions","suggestion_replies","suggestion_likes");
        }
        var dataSource=new DriverManagerDataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword());
        var properties=new java.util.Properties();
        properties.setProperty("currentSchema","suggestion_header_oracle,public");
        dataSource.setConnectionProperties(properties);
        db=new JdbcTemplate(dataSource);
        var factory=new LocalContainerEntityManagerFactoryBean();
        factory.setDataSource(dataSource);
        factory.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        factory.setManagedTypes(PersistenceManagedTypes.of(Suggestion.class.getName(),SuggestionReply.class.getName(),SuggestionLike.class.getName()));
        factory.setJpaPropertyMap(Map.of("hibernate.hbm2ddl.auto","none","hibernate.jdbc.time_zone","UTC"));
        factory.afterPropertiesSet();
        emf=factory.getObject();
    }
    @AfterAll static void close() throws Exception {
        if(emf!=null) emf.close();
        if(database!=null) database.close();
    }
    @BeforeEach void repositories() {
        db.execute("TRUNCATE suggestions,suggestion_replies,suggestion_likes");
        var em=SharedEntityManagerCreator.createSharedEntityManager(emf);
        var repositories=new JpaRepositoryFactory(em);
        currentUser=mock(SecurityContextCurrentUser.class);
        actor(viewer,Set.of());
        service=new SuggestionService(repositories.getRepository(SuggestionRepository.class),
                repositories.getRepository(SuggestionReplyRepository.class),repositories.getRepository(SuggestionLikeRepository.class),
                mock(EmployeeRepository.class),currentUser,mock(TxSessionVars.class),mock(HrNoticePort.class));
    }

    @Test void displayedAnonymousIdentityCountsAndChineseDatesAreFilteredBeforePagination() {
        UUID author=UUID.randomUUID();
        UUID first=suggestion(author,"张优腾",true,"HEADER%_ 一号","2026-10-27T16:00:00Z");
        UUID second=suggestion(author,"张优腾",true,"HEADER%_ 二号","2026-10-28T15:59:59Z");
        UUID tomorrow=suggestion(author,"张优腾",true,"HEADER%_ 明日","2026-10-28T16:00:00Z");
        suggestion(author,"李实名",false,"HEADER-APPROX","2026-10-28T04:00:00Z");
        for(UUID id:java.util.List.of(first,second,tomorrow)) {
            for(int i=0;i<2;i++) {
                db.update("INSERT INTO suggestion_replies(id,suggestion_id,replier_id,replier_name,replier_role,content,replied_at) VALUES(?,?,?,'回复人','','内容',now())",
                        UUID.randomUUID(),id,viewer);
                db.update("INSERT INTO suggestion_likes(suggestion_id,user_id) VALUES(?,?)",id,UUID.randomUUID());
            }
        }
        var columns=Map.of("title","HEADER%_", "submitter","张**", "submittedAt","2026-10-28", "replyCount",">=1.5", "likes","2..2");
        var page1=service.list("square","process","reviewing",1,1,columns,"submittedAt","asc");
        var page2=service.list("square","process","reviewing",2,1,columns,"submittedAt","asc");
        assertThat(page1.getTotal()).isEqualTo(2);
        assertThat(page1.getTotalPages()).isEqualTo(2);
        assertThat(page1.getItems().getFirst().id()).isEqualTo(first.toString());
        assertThat(page2.getItems().getFirst().id()).isEqualTo(second.toString());
        assertThat(page1.getItems().getFirst().submitterId()).isEmpty();
        assertThat(page1.getItems().getFirst().submitterName()).isEqualTo("张**");
        assertThat(page1.getItems().getFirst().replyCount()).isEqualTo(2);
        assertThat(service.list("square",null,null,1,20,Map.of("submitter","优腾"),null,null).getTotal()).isZero();
        assertThat(service.list("square",null,null,1,20,Map.of("replyCount",">2"),null,null).getTotal()).isZero();
        assertThat(service.list("mine",null,null,1,20,Map.of("submitter","张**"),null,null).getTotal()).isZero();
        assertThat(service.list("square",null,null,1,20,Map.of("submittedAt","2026-10-29"),null,null).getItems())
                .extracting(com.uten.imp.features.suggestion.dto.SuggestionDto::id).containsExactly(tomorrow.toString());
        actor(author,Set.of());
        assertThat(service.list("mine",null,null,1,20,Map.of("submitter","优腾"),null,null).getTotal()).isEqualTo(3);
        actor(viewer,Set.of("suggestion:reply"));
        assertThat(service.list("square",null,null,1,20,Map.of("submitter","优腾"),null,null).getTotal()).isEqualTo(3);
    }
    private void actor(UUID id,Set<String> permissions) {
        when(currentUser.get()).thenReturn(Optional.of(new AuthUser(id,UUID.randomUUID(),"viewer",permissions,false,true,false)));
    }
    private UUID suggestion(UUID author,String name,boolean anonymous,String title,String submittedAt) {
        UUID id=UUID.randomUUID();
        db.update("INSERT INTO suggestions(id,submitter_id,submitter_name,category,title,content,status,is_anonymous,submitted_at) VALUES(?,?,?,'process',?,'建议内容','reviewing',?,?::timestamptz)",
                id,author,name,title,anonymous,submittedAt);
        return id;
    }
}
