package com.uten.imp.features.notice;

import com.uten.imp.features.org.department.Department;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.position.Position;
import com.uten.imp.features.production.fulfillment.ProductionExecutionSegment;
import jakarta.persistence.EntityManager;
import org.hibernate.SessionFactory;
import org.hibernate.cfg.Configuration;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.data.domain.PageRequest;
import org.springframework.data.jpa.repository.support.JpaRepositoryFactory;
import org.testcontainers.containers.PostgreSQLContainer;

import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.List;
import java.util.UUID;
import java.util.function.Consumer;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 人工通知登录弹窗查询（{@link NoticeRepository#findVisiblePendingManualNotices}，
 * 2026-09-10 / ADR-063 §8）在真实 PostgreSQL 上的口径证明：
 * 全员/指定范围可见性、打卡后退出、稍后到期重弹、庆典与系统链路排除、
 * 只提醒类型的已读与 14 天窗口、打卡优先排序。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ManualNoticePopupPostgresTest {
    private static final PostgreSQLContainer<?> DB = new PostgreSQLContainer<>("postgres:16-alpine");
    private static final UUID ME = new UUID(0, 1001);
    private static final UUID OTHER = new UUID(0, 1002);
    private static final Instant NONE_SINCE = Instant.now().minus(14, ChronoUnit.DAYS);
    private static SessionFactory factory;
    private EntityManager em;
    private NoticeRepository notices;

    @BeforeAll
    static void start() {
        DB.start();
        // NoticeRepository 的全部 @Query 在仓库创建时整体校验：车间对象范围子句引用
        // ProductionExecutionSegment/Department，故与 WorkshopNoticeScopePostgresTest 同样注册。
        factory = new Configuration()
                .addAnnotatedClass(Notice.class)
                .addAnnotatedClass(NoticeUserState.class)
                .addAnnotatedClass(NoticeAcknowledgment.class)
                .addAnnotatedClass(ProductionExecutionSegment.class)
                .addAnnotatedClass(Department.class)
                .addAnnotatedClass(Employee.class)
                .addAnnotatedClass(Position.class)
                .setProperty("hibernate.connection.driver_class", "org.postgresql.Driver")
                .setProperty("hibernate.connection.url", DB.getJdbcUrl())
                .setProperty("hibernate.connection.username", DB.getUsername())
                .setProperty("hibernate.connection.password", DB.getPassword())
                .setProperty("hibernate.hbm2ddl.auto", "create")
                .buildSessionFactory();
    }

    @BeforeEach
    void open() {
        em = factory.createEntityManager();
        tx(() -> {
            em.createQuery("DELETE FROM NoticeAcknowledgment").executeUpdate();
            em.createQuery("DELETE FROM NoticeUserState").executeUpdate();
            em.createQuery("DELETE FROM Notice").executeUpdate();
        });
        notices = new JpaRepositoryFactory(em).getRepository(NoticeRepository.class);
    }

    @AfterEach
    void close() {
        if (em != null) em.close();
    }

    @AfterAll
    static void stop() {
        if (factory != null) factory.close();
        DB.stop();
    }

    @Test
    void allScopeAcknowledgeNoticePopsForEveryoneUntilTheyAcknowledge() {
        Notice notice = manual("announcement", "all", null, "normal", Instant.now(), null);

        assertThat(pending(ME)).containsExactly(notice.getId());
        assertThat(pending(OTHER)).containsExactly(notice.getId());

        acknowledge(notice.getId(), ME);

        assertThat(pending(ME)).as("已打卡即退出").isEmpty();
        assertThat(pending(OTHER)).as("他人打卡不影响我").containsExactly(notice.getId());
    }

    @Test
    void selectedScopePopsOnlyForSnapshotRecipients() {
        Notice notice = manual("policy", "selected", null, "normal", Instant.now(), null);
        state(notice.getId(), ME, s -> { });

        assertThat(pending(ME)).containsExactly(notice.getId());
        assertThat(pending(OTHER)).as("非接收人不可见").isEmpty();
    }

    @Test
    void snoozeHidesAcknowledgeNoticeUntilExpiryThenPopsAgainEvenIfRead() {
        Notice notice = manual("urgent", "all", null, "urgent", Instant.now(), null);
        state(notice.getId(), ME, s -> {
            s.setReadAt(Instant.now());
            s.setSnoozedUntil(Instant.now().plus(15, ChronoUnit.MINUTES));
        });
        assertThat(pending(ME)).as("稍后未到期不弹").isEmpty();

        state(notice.getId(), ME, s -> s.setSnoozedUntil(Instant.now().minus(1, ChronoUnit.MINUTES)));
        assertThat(pending(ME)).as("稍后到期重弹（已读也弹，打卡是强制动作）").containsExactly(notice.getId());

        state(notice.getId(), ME, s -> s.setPopupAcknowledgedAt(Instant.now()));
        assertThat(pending(ME)).as("打卡类型不看 popup_acknowledged，只看回执").containsExactly(notice.getId());

        acknowledge(notice.getId(), ME);
        assertThat(pending(ME)).isEmpty();
    }

    @Test
    void acknowledgeNoticeHasNoAgeCutoff() {
        Notice old = manual("benefit", "all", null, "normal", Instant.now().minus(90, ChronoUnit.DAYS), null);
        assertThat(pending(ME)).containsExactly(old.getId());
    }

    @Test
    void noneModeRespectsReadPopupAcknowledgedSnoozeAndFourteenDayWindow() {
        Notice fresh = manual("task", "all", null, "normal", Instant.now(), null);
        Notice read = manual("approval", "all", null, "normal", Instant.now(), null);
        state(read.getId(), ME, s -> s.setReadAt(Instant.now()));
        Notice stale = manual("workflow", "all", null, "normal", Instant.now().minus(15, ChronoUnit.DAYS), null);
        assertThat(pending(ME)).as("只提醒：未读且 14 天内").containsExactly(fresh.getId());

        // 稍后到期重弹（snooze 顺带置了 read_at，但用户明确要求再提醒）
        state(fresh.getId(), ME, s -> {
            s.setReadAt(Instant.now());
            s.setSnoozedUntil(Instant.now().minus(1, ChronoUnit.MINUTES));
        });
        assertThat(pending(ME)).containsExactly(fresh.getId());

        // 「知道了」= markRead 置 popup_acknowledged_at → 即使 snooze 已到期也不再弹
        state(fresh.getId(), ME, s -> s.setPopupAcknowledgedAt(Instant.now()));
        assertThat(pending(ME)).isEmpty();
        assertThat(stale.getPublishedAt()).isBefore(NONE_SINCE);
    }

    @Test
    void celebrationSystemChainDeletedAndTargetedOthersAreExcluded() {
        manual("birthday", "all", null, "normal", Instant.now(), null);
        manual("system", "selected", ME, "normal", Instant.now(), "SALES_ORDER_FINANCE_REJECTED");
        Notice deleted = manual("announcement", "all", null, "normal", Instant.now(), null);
        state(deleted.getId(), ME, s -> s.setDeletedAt(Instant.now()));
        manual("announcement", "selected", OTHER, "normal", Instant.now(), null);
        Notice mine = manual("announcement", "selected", ME, "normal", Instant.now(), null);

        assertThat(pending(ME)).containsExactly(mine.getId());
    }

    @Test
    void orderingPutsAcknowledgeThenUrgentThenTopThenNewestFirst() {
        Notice remindNewest = manual("task", "all", null, "normal", Instant.now(), null);
        Notice ackNormalOld = manual("announcement", "all", null, "normal", Instant.now().minus(2, ChronoUnit.DAYS), null);
        Notice ackNormalTop = manual("announcement", "all", null, "normal", Instant.now().minus(3, ChronoUnit.DAYS), null);
        tx(() -> em.createQuery("UPDATE Notice n SET n.topPriority = true WHERE n.id = :id")
                .setParameter("id", ackNormalTop.getId()).executeUpdate());
        Notice ackUrgent = manual("urgent", "all", null, "urgent", Instant.now().minus(5, ChronoUnit.DAYS), null);

        assertThat(pending(ME)).containsExactly(
                ackUrgent.getId(), ackNormalTop.getId(), ackNormalOld.getId(), remindNewest.getId());
        assertThat(notices.findVisiblePendingManualNotices(ME, NONE_SINCE, PageRequest.of(0, 2)))
                .extracting(Notice::getId).containsExactly(ackUrgent.getId(), ackNormalTop.getId());
    }

    private List<UUID> pending(UUID user) {
        em.clear();
        return notices.findVisiblePendingManualNotices(user, NONE_SINCE, PageRequest.of(0, 20))
                .stream().map(Notice::getId).toList();
    }

    private Notice manual(String type, String scope, UUID audienceUser, String priority,
                          Instant publishedAt, String sourceEvent) {
        Notice n = new Notice();
        n.setTitle(type + " 通知");
        n.setContent("正文");
        n.setType(type);
        n.setInteractionMode(NoticeService.interactionModeFor(type));
        n.setPublisher("人事部");
        n.setPublishedAt(publishedAt);
        n.setPriority(priority);
        n.setAudienceScope(scope);
        n.setAudienceUserId(audienceUser);
        n.setSourceEvent(sourceEvent);
        tx(() -> em.persist(n));
        if (audienceUser != null) {
            state(n.getId(), audienceUser, s -> { });
        }
        return n;
    }

    private void state(UUID noticeId, UUID user, Consumer<NoticeUserState> mutate) {
        tx(() -> {
            NoticeUserState st = em.find(NoticeUserState.class, new NoticeUserStateId(noticeId, user));
            if (st == null) {
                st = new NoticeUserState();
                st.setId(new NoticeUserStateId(noticeId, user));
                mutate.accept(st);
                em.persist(st);
            } else {
                mutate.accept(st);
                em.merge(st);
            }
        });
    }

    private void acknowledge(UUID noticeId, UUID user) {
        tx(() -> {
            NoticeAcknowledgment ack = new NoticeAcknowledgment();
            ack.setId(new NoticeAcknowledgmentId(noticeId, user));
            ack.setAckedAt(Instant.now());
            em.persist(ack);
        });
    }

    private void tx(Runnable body) {
        em.getTransaction().begin();
        try {
            body.run();
            em.getTransaction().commit();
        } catch (RuntimeException e) {
            em.getTransaction().rollback();
            throw e;
        }
        em.clear();
    }
}
