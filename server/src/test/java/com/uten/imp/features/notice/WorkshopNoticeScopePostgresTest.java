package com.uten.imp.features.notice;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.FinanceReviewerEligibilityPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.admin.workflow.SalesOrderFinanceConfirmerEligibility;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.department.Department;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.position.Position;
import com.uten.imp.features.production.fulfillment.ProductionExecutionSegment;
import com.uten.imp.features.rbac.UserRoleRepository;
import com.uten.imp.features.rd_task.RdTaskService;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import org.hibernate.SessionFactory;
import org.hibernate.cfg.Configuration;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.mockito.ArgumentCaptor;
import org.springframework.data.domain.PageRequest;
import org.springframework.data.jpa.repository.support.JpaRepositoryFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Actual PostgreSQL/Hibernate repository queries and current organization scope.
 * The isolated entity schema tests notices, not the full production movement guards. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS", matches="(?i)true")
class WorkshopNoticeScopePostgresTest {
    private static final PostgreSQLContainer<?> DB = new PostgreSQLContainer<>("postgres:16-alpine");
    private static final String EVENT = ReviewNoticeAudience.WORKSHOP_EVENT;
    private static final UUID ROOT=id(1), A=id(2), CHILD=id(3), B=id(4), OFFICE=id(5);
    private static final UUID TASK_A=id(10), TASK_B=id(11);
    private static final Set<String> ACTION = Set.of("notice:read", "production_execution:view", "production_execution:start");
    private static final Set<String> REPORT = Set.of("notice:read", "production_execution:view", "production_daily_report:view", "production_daily_report:create");
    private static final Set<String> VIEW = Set.of("notice:read", "production_execution:view");
    private static final List<Actor> ACTORS=List.of(
            new Actor(101, CHILD, ACTION), new Actor(102, OFFICE, REPORT),
            new Actor(103, OFFICE, ACTION), new Actor(104, OFFICE, ACTION),
            new Actor(105, B, ACTION), new Actor(106, OFFICE, ACTION),
            new Actor(107, A, VIEW), new Actor(108, A, VIEW),
            new Actor(109, A, ACTION), new Actor(110, A, ACTION));
    private static SessionFactory factory;
    private static JdbcTemplate jdbc;
    private EntityManager em;
    private NoticeRepository notices;
    private ReviewNoticeAudience audience;

    @BeforeAll
    static void start() {
        DB.start();
        jdbc=new JdbcTemplate(new DriverManagerDataSource(DB.getJdbcUrl(),DB.getUsername(),DB.getPassword()));
        factory=new Configuration().addAnnotatedClass(Notice.class).addAnnotatedClass(NoticeUserState.class)
                .addAnnotatedClass(ProductionExecutionSegment.class).addAnnotatedClass(Department.class)
                .addAnnotatedClass(Employee.class).addAnnotatedClass(Position.class)
                .setProperty("hibernate.connection.driver_class","org.postgresql.Driver")
                .setProperty("hibernate.connection.url",DB.getJdbcUrl())
                .setProperty("hibernate.connection.username",DB.getUsername())
                .setProperty("hibernate.connection.password",DB.getPassword())
                .setProperty("hibernate.hbm2ddl.auto","create").buildSessionFactory();
        jdbc.execute("CREATE TABLE users(id uuid PRIMARY KEY,employee_id uuid,status text,is_deleted boolean DEFAULT FALSE)");
        jdbc.execute("CREATE TABLE employee_secondary_departments(employee_id uuid,department_id uuid)");
        for (var entry : List.of(new Object[]{ROOT,null,"ROOT"},new Object[]{A,ROOT,"ACTUAL_WORKSHOP_A"},
                new Object[]{CHILD,A,"TEAM_A"},new Object[]{B,ROOT,"ACTUAL_WORKSHOP_B"},new Object[]{OFFICE,ROOT,"OFFICE"})) {
            jdbc.update("INSERT INTO departments(id,code,name,level,parent_id,path,headcount,is_deleted,permission_delegation_generation) VALUES (?,?,?,'department',?,'/',0,FALSE,0)",
                    entry[0],entry[2],entry[2],entry[1]);
        }
        for (Actor actor:ACTORS) {
            jdbc.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type,is_deleted,version,permission_delegation_generation) VALUES (?,?,?,'ID_CARD',?,CURRENT_DATE,'active','fullTime',FALSE,0,0)",
                    actor.employee(),"E"+actor.number(),"Actor "+actor.number(),actor.department());
            jdbc.update("INSERT INTO users VALUES (?,?,'active',FALSE)",actor.user(),actor.employee());
        }
        jdbc.update("INSERT INTO employee_secondary_departments VALUES (?,?)",ACTORS.get(1).employee(),CHILD);
        jdbc.update("UPDATE departments SET manager_id=? WHERE id=?",ACTORS.get(2).employee(),A);
        try (EntityManager seed=factory.createEntityManager()) {
            seed.getTransaction().begin();
            seed.persist(segment(TASK_A,A,ACTORS.get(3).employee()));
            seed.persist(segment(TASK_B,B,null));
            seed.getTransaction().commit();
        }
        jdbc.execute("CREATE TABLE warehouses(id uuid PRIMARY KEY,parent_id uuid,name text)");
        jdbc.execute("CREATE TABLE stock_documents(id uuid PRIMARY KEY,bill_no text,warehouse_id uuid,doc_type text,is_deleted boolean,status int,created_at timestamptz)");
        jdbc.execute("CREATE TABLE production_planning_package_documents(document_id uuid,execution_segment_id uuid,document_type text)");
        jdbc.execute("""
                CREATE VIEW v_production_execution_workbench_segments AS
                SELECT id AS segment_id,segment_code,'PLAN-01'::text AS plan_no,'P01'::text AS product_code,
                    '产品'::text AS product_name,NULL::text AS product_color_name,'件'::text AS product_unit_name,
                    planned_qty,status AS segment_status,'KIT_READY'::text AS material_status,
                    'PREPARED'::text AS preparation_status,TRUE AS issued,
                    workshop_department_id,'实际车间A'::text AS workshop_name,
                    responsible_employee_id,'指定负责'::text AS responsible_employee_name
                FROM production_execution_segments
                """);
        jdbc.update("INSERT INTO warehouses VALUES (?,NULL,'主仓甲'),(?,?,'子仓一'),(?,NULL,'主仓乙'),(?,?,'子仓二')",id(201),id(202),id(201),id(203),id(204),id(203));
        for (int i=0;i<3;i++) {
            jdbc.update("INSERT INTO stock_documents VALUES (?,?,?,'DRAW',FALSE,1,now()+?*interval '1 second')",id(301+i),"DRAW-"+(i+1),i==0?id(202):id(204),i);
            jdbc.update("INSERT INTO production_planning_package_documents VALUES (?,?,'DRAW')",id(301+i),i==2?TASK_B:TASK_A);
        }
        // The same DRAW mapping can appear more than once; the summary remains unique.
        jdbc.update("INSERT INTO production_planning_package_documents VALUES (?,?,'DRAW')",id(301),TASK_A);
    }

    @BeforeEach
    void open() {
        jdbc.execute("DELETE FROM notice_user_states");
        jdbc.execute("DELETE FROM notices");
        jdbc.update("UPDATE employees SET status='active' WHERE id=?",ACTORS.get(0).employee());
        jdbc.update("UPDATE employees SET department_id=? WHERE id=?",CHILD,ACTORS.get(0).employee());
        jdbc.update("UPDATE employees SET status='resigned' WHERE id=?",ACTORS.get(8).employee());
        jdbc.update("UPDATE users SET status='disabled' WHERE id=?",ACTORS.get(9).user());
        em=factory.createEntityManager();
        notices=new JpaRepositoryFactory(em).getRepository(NoticeRepository.class);
        audience=new ReviewNoticeAudience(jdbc);
    }
    @AfterEach void close() { if(em!=null)em.close(); }
    @AfterAll static void stop() { if(factory!=null)factory.close(); DB.stop(); }

    @Test
    void currentReceiversIncludeActualWorkshopSecondaryManagerAndResponsibleButNotViewOnlyOrPlanner() {
        UserAccountRepository users=mock(UserAccountRepository.class);
        PermissionResolver permissions=mock(PermissionResolver.class);
        for(Actor actor:ACTORS) {
            UserAccount account=mock(UserAccount.class);
            when(account.getStatus()).thenReturn("active");
            when(users.findById(actor.user())).thenReturn(Optional.of(account));
            when(permissions.permsOf(account)).thenReturn(actor.permissions());
        }
        var chain=chain(mock(NoticeService.class),users,permissions);
        assertThat(chain.workshopRecipientUserIds(A,ACTORS.get(3).employee()))
                .containsExactly(ACTORS.get(0).user(),ACTORS.get(1).user(),ACTORS.get(2).user(),ACTORS.get(3).user());
        for(int index:List.of(0,1,2,3)) {
            Actor actor=ACTORS.get(index);
            Notice notice=persist(actor.user(),TASK_A,"important");
            assertThat(audience.eligibleEvents(actor.auth())).contains(EVENT);
            assertThat(notices.findScopedVisibleNoticeIds(actor.user(),Set.of(notice.getId()),audience.workshopScope(actor.auth())))
                    .containsExactly(notice.getId());
        }
        for(int index:List.of(4,5,6,7,8,9)) {
            Actor actor=ACTORS.get(index);
            Notice notice=persist(actor.user(),TASK_A,"important");
            assertThat(notices.findScopedVisibleNoticeIds(actor.user(),Set.of(notice.getId()),audience.workshopScope(actor.auth())))
                    .as("other workshop/planner/view/revoked/resigned/disabled actor %s",actor.number()).isEmpty();
        }
    }

    @Test
    void listsCountsAndPopupUseObjectScopeBeforePaginationAndRejectHistoricalBroadcast() {
        Actor actor=ACTORS.get(0);
        Notice target=persist(actor.user(),TASK_A,"important");
        for(int i=0;i<24;i++)persist(actor.user(),TASK_B,"urgent");
        persist(null,TASK_A,"urgent"); // old all-staff broadcast must not become visible
        persist(actor.user(),null,"urgent"); // old unanchored reminder
        var scope=audience.workshopScope(actor.auth());
        assertThat(notices.findVisible(actor.user(),false,scope,PageRequest.of(0,1))).extracting(Notice::getId).containsExactly(target.getId());
        assertThat(notices.findVisibleArrivalsAfter(actor.user(),Instant.EPOCH,id(0),scope,PageRequest.of(0,1)))
                .extracting(Notice::getId).containsExactly(target.getId());
        assertThat(notices.countVisibleUnread(actor.user(),scope)).isEqualTo(1);
        assertThat(notices.countUnreadBySourceEvents(actor.user(),List.of(EVENT),scope)).isEqualTo(1);
        assertThat(notices.findPendingTodos(actor.user(),scope,PageRequest.of(0,1))).extracting(Notice::getId).containsExactly(target.getId());
        assertThat(notices.countPendingTodos(actor.user(),scope)).isEqualTo(1);
        assertThat(notices.findVisiblePendingReviews(actor.user(),List.of(EVENT),scope,PageRequest.of(0,1)))
                .extracting(Notice::getId).containsExactly(target.getId());
        assertThat(service(actor.auth()).pendingReviews()).singleElement().satisfies(dto -> {
            assertThat(dto.id()).isEqualTo(target.getId().toString());
            assertThat(dto.interactive()).isTrue();
        });
    }

    @Test
    void withdrawalHidesExistingMessageAndPopupWithoutDeletingHistory() {
        Actor actor=ACTORS.get(0);
        Notice target=persist(actor.user(),TASK_A,"important");
        NoticeService service=service(actor.auth());
        assertThat(service.getById(target.getId()).interactive()).isTrue();
        assertThat(service.pendingReviewStatus(List.of(target.getId()))).hasSize(1);
        jdbc.update("UPDATE employees SET department_id=? WHERE id=?",B,actor.employee());
        assertThat(service.unreadCount()).isZero();
        assertThat(service.list(false)).isEmpty();
        assertThat(service.pendingReviewStatus(List.of(target.getId()))).isEmpty();
        assertThatThrownBy(()->service.getById(target.getId())).isInstanceOf(ApiException.class);
        jdbc.update("UPDATE employees SET department_id=? WHERE id=?",CHILD,actor.employee());
        assertThat(service(new Actor(actor.number(),CHILD,VIEW).auth()).pendingReviews()).isEmpty();
        assertThat(service(new Actor(actor.number(),CHILD,VIEW).auth()).unreadCount()).isZero();
        jdbc.update("UPDATE employees SET status='resigned' WHERE id=?",actor.employee());
        assertThat(service.unreadCount()).isZero();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM notices WHERE id=?",Integer.class,target.getId())).isEqualTo(1);
    }

    @Test
    void statusHeartbeatChecksManyObjectsInOneBatch() {
        Actor actor=ACTORS.get(0);
        Notice target=persist(actor.user(),TASK_A,"important");
        for(int i=0;i<24;i++)persist(actor.user(),TASK_B,"important");
        List<UUID> ids=notices.findAll().stream().map(Notice::getId).toList();
        NoticeService service=service(actor.auth());
        factory.getStatistics().setStatisticsEnabled(true);
        factory.getStatistics().clear();
        assertThat(service.pendingReviewStatus(ids)).singleElement()
                .satisfies(status -> assertThat(status.noticeId()).isEqualTo(target.getId().toString()));
        // Notice rows, per-user states, and one exact-object filter; never a
        // segment query per notice. Organization eligibility is also batched JDBC.
        assertThat(factory.getStatistics().getPrepareStatementCount()).isEqualTo(3);
        factory.getStatistics().setStatisticsEnabled(false);
    }

    @Test
    void waitingProgressHasAnExactVisibleObjectButDoesNotBecomeAnActionPopup() {
        Actor actor=ACTORS.get(0);
        Notice progress=persist(actor.user(),TASK_A,"normal");
        NoticeService service=service(actor.auth());
        assertThat(service.list(false)).singleElement().satisfies(dto -> assertThat(dto.interactive()).isFalse());
        assertThat(service.pendingReviews()).isEmpty();
        assertThat(service.pendingReviewStatus(List.of(progress.getId()))).isEmpty();
    }

    @Test
    void issuedTaskMessageSummarizesEveryActualDrawOnceAndOnlyOffersStart() {
        UserAccountRepository users=mock(UserAccountRepository.class);
        PermissionResolver permissions=mock(PermissionResolver.class);
        for(Actor actor:ACTORS) {
            UserAccount account=mock(UserAccount.class);
            when(account.getStatus()).thenReturn("active");
            when(users.findById(actor.user())).thenReturn(Optional.of(account));
            when(permissions.permsOf(account)).thenReturn(actor.permissions());
        }
        NoticeService notice=mock(NoticeService.class);
        chain(notice,users,permissions).deliverOutboxEvent(ChainNoticeService.EVENT_SEGMENT_WORKSHOP_ASSIGNED,TASK_A,new ObjectMapper().createObjectNode());
        ArgumentCaptor<String> content=ArgumentCaptor.forClass(String.class);
        verify(notice,times(4)).publishForUser(any(),startsWith("物料已领齐·可以开工"),content.capture(),
                eq("task"),anyString(),eq("/production/workshop-tasks"),eq(EVENT),eq("important"),eq(TASK_A));
        assertThat(content.getAllValues()).allSatisfy(message -> assertThat(message)
                .contains("物料已领齐，可以开工","DRAW-1（主仓甲 - 子仓一）","DRAW-2（主仓乙 - 子仓二）")
                .doesNotContain("DRAW-3","可直接报工","DRAW-1（主仓甲 - 子仓一）；DRAW-1"));
    }

    private Notice persist(UUID user,UUID segment,String priority) {
        Notice notice=new Notice();notice.setTitle("任务");notice.setContent("当前工作");notice.setType("task");
        notice.setPublisher("系统");notice.setAudienceUserId(user);notice.setAudienceScope(user==null?"all":"selected");
        notice.setPriority(priority);notice.setSourceEvent(EVENT);notice.setAggregateKind("PRODUCTION_EXECUTION_SEGMENT");
        notice.setAggregateId(segment);notice.setKind("TODO");
        em.getTransaction().begin();em.persist(notice);em.getTransaction().commit();
        return notice;
    }
    private NoticeService service(AuthUser auth) {
        SecurityContextCurrentUser current=mock(SecurityContextCurrentUser.class);
        when(current.get()).thenReturn(Optional.of(auth));
        return new NoticeService(notices,new JpaRepositoryFactory(em).getRepository(NoticeUserStateRepository.class),
                mock(NoticeAcknowledgmentRepository.class),mock(NoticeBlessingRepository.class),mock(NoticeCelebrationSubjectRepository.class),
                mock(com.uten.imp.features.org.employee.EmployeeRepository.class),current,new ObjectMapper(),mock(NoticeAudienceService.class),
                mock(com.uten.imp.security.TxSessionVars.class),mock(com.uten.imp.features.admin.systemsetting.SystemSettingsService.class),
                mock(com.uten.imp.audit.AuditService.class),mock(com.uten.imp.features.common.taskclaim.TaskClaimRepository.class),
                mock(com.uten.imp.application.port.EmployeeNameLookupPort.class),audience);
    }
    private static ChainNoticeService chain(NoticeService notices,UserAccountRepository users,PermissionResolver permissions) {
        return new ChainNoticeService(notices,users,permissions,mock(UserRoleRepository.class),jdbc,mock(BusinessEventPublisher.class),
                mock(RdTaskService.class),mock(FinanceReviewerEligibilityPort.class),mock(SalesOrderFinanceConfirmerEligibility.class));
    }
    private static ProductionExecutionSegment segment(UUID id,UUID workshop,UUID responsible) {
        var segment=new ProductionExecutionSegment();segment.setId(id);segment.setPackageId(UUID.randomUUID());segment.setPlanId(UUID.randomUUID());
        segment.setSourcePlanItemId(UUID.randomUUID());segment.setSegmentNo(1);segment.setSegmentCode("SEG-"+id.getLeastSignificantBits());
        segment.setClientSegmentKey(id.toString());segment.setProductGoodsId(UUID.randomUUID());segment.setProductUnitId(UUID.randomUUID());
        segment.setProductUnitRate(BigDecimal.ONE);segment.setPlannedQty(BigDecimal.TEN);segment.setStatus("READY");
        segment.setWorkshopDepartmentId(workshop);segment.setResponsibleEmployeeId(responsible);segment.setBomFingerprint("fixture");segment.setIdempotencyKey(id.toString());
        return segment;
    }
    private record Actor(int number,UUID department,Set<String> permissions) {
        UUID employee(){return id(number);} UUID user(){return id(number+1000);}
        AuthUser auth(){return new AuthUser(user(),employee(),"actor"+number,Set.of(),permissions,false,true,false);}
    }
    private static UUID id(int number){return new UUID(0,number);}
}
