package com.uten.imp.features.notice;

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
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.List;
import java.util.UUID;
import java.util.function.Consumer;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 审核待办登录弹窗查询（{@link NoticeRepository#findVisiblePendingReviews}，
 * V459/ADR-063）在真实 PostgreSQL 上的口径证明（2026-10-09 用户确认规则：
 * **没读过的任务一登录就弹居中弹窗；读过的不再重复弹**）：
 * <ul>
 *   <li>未办结 + 未读（含从未弹过、或弹窗仅点 X 关闭——UI 不写 popup_acknowledged）
 *       → 每次登录检查都弹；</li>
 *   <li>已读（markRead / 去工作台处理 / 办结置读，均同时置 popup_acknowledged）→ 不弹；</li>
 *   <li>「稍后再看」到期后未办结恒弹（用户明确要求再提醒，已读不吞掉）；未到期不弹；</li>
 *   <li>已办结（resolved_at）不弹；删除态不弹；他人的定向卡不可见。</li>
 * </ul>
 * 事件选直通型 SALES_ORDER_PENDING_FINANCE_CONFIRM（SCOPED_VISIBILITY 不加业务谓词），
 * 与人工通知口径证明（ManualNoticePopupPostgresTest）互为对照。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ReviewPendingLoginPopupPostgresTest {
    private static final PostgreSQLContainer<?> DB = new PostgreSQLContainer<>("postgres:16-alpine");
    private static final UUID ME = new UUID(0, 2001);
    private static final UUID OTHER = new UUID(0, 2002);
    private static final String EVENT = "SALES_ORDER_PENDING_FINANCE_CONFIRM";
    private static SessionFactory factory;
    private EntityManager em;
    private NoticeRepository notices;

    @BeforeAll
    static void start() {
        DB.start();
        JdbcTemplate jdbc = new JdbcTemplate(
                new DriverManagerDataSource(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword()));
        // 仓库创建时整体校验所有 @Query：SCOPED_VISIBILITY 引用 SalesOrder（V825 计划
        // 提醒补投的 EXISTS 子句）与 fn_notice_production_over_limit_visible。
        factory = new Configuration()
                .addAnnotatedClass(Notice.class)
                .addAnnotatedClass(NoticeUserState.class)
                .addAnnotatedClass(NoticeAcknowledgment.class)
                .addAnnotatedClass(com.uten.imp.features.org.department.Department.class)
                .addAnnotatedClass(com.uten.imp.features.org.employee.Employee.class)
                .addAnnotatedClass(com.uten.imp.features.org.position.Position.class)
                .addAnnotatedClass(com.uten.imp.features.sales.order.SalesOrder.class)
                .addAnnotatedClass(com.uten.imp.features.production.fulfillment.ProductionExecutionSegment.class)
                .setProperty("hibernate.connection.driver_class", "org.postgresql.Driver")
                .setProperty("hibernate.connection.url", DB.getJdbcUrl())
                .setProperty("hibernate.connection.username", DB.getUsername())
                .setProperty("hibernate.connection.password", DB.getPassword())
                .setProperty("hibernate.hbm2ddl.auto", "create")
                .buildSessionFactory();
        // 只装载真函数本体；非超限事件在触碰生产表之前提前返回（与
        // WorkshopNoticeScopePostgresTest 同一抽取方式）。
        String migration = java.nio.file.Path.of(
                "src/main/resources/db/migration/V823__production_over_limit_disposition.sql").toString();
        String text;
        try {
            text = java.nio.file.Files.readString(java.nio.file.Path.of(migration));
        } catch (java.io.IOException e) {
            throw new IllegalStateException(e);
        }
        int start = text.indexOf("CREATE FUNCTION fn_notice_production_over_limit_visible(");
        int end = text.indexOf("\n$$;", start) + 4;
        assertThat(start).isGreaterThanOrEqualTo(0);
        assertThat(end).isGreaterThan(start);
        jdbc.execute(text.substring(start, end));
        // fn_production_draw_requested 是 LANGUAGE sql 函数，创建时即校验表存在——
        // 照 WorkshopNoticeScopePostgresTest 建 5 张最小表后装载真函数本体
        //（本夹具事件不触达这些表）。
        jdbc.execute("CREATE TABLE stock_documents(id uuid PRIMARY KEY,bill_no text,warehouse_id uuid,doc_type text,is_deleted boolean,status int,created_at timestamptz,transfer_kind text NOT NULL DEFAULT 'NORMAL',defect_reason text,channel_request_key text)");
        jdbc.execute("CREATE TABLE production_planning_package_documents(document_id uuid,execution_segment_id uuid,document_type text)");
        jdbc.execute("CREATE TABLE production_execution_segment_events(action text,draw_document_ids uuid[],draw_item_quantities jsonb, counter_event_id uuid, receiving_confirmation_id uuid, receiving_direction smallint)");
        jdbc.execute("CREATE TABLE stock_document_items(id uuid,doc_id uuid,qty numeric DEFAULT 1,issued_qty numeric DEFAULT 0,is_deleted boolean DEFAULT false)");
        jdbc.execute("CREATE TABLE production_material_stock_postings(stock_document_item_id uuid,posting_type text, recorded_tx_id xid8)");
        String draw = java.nio.file.Path.of(
                "src/main/resources/db/migration/V559__production_workshop_draw_request.sql").toString();
        String drawText;
        try {
            drawText = java.nio.file.Files.readString(java.nio.file.Path.of(draw));
        } catch (java.io.IOException e) {
            throw new IllegalStateException(e);
        }
        int drawStart = drawText.indexOf("CREATE OR REPLACE FUNCTION fn_production_draw_requested(");
        int drawEnd = drawText.indexOf("\n$$;", drawStart) + 4;
        assertThat(drawStart).isGreaterThanOrEqualTo(0);
        assertThat(drawEnd).isGreaterThan(drawStart);
        jdbc.execute(drawText.substring(drawStart, drawEnd));
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
    void unresolvedUnreadCardPopsAtEveryLoginCheckEvenAfterPlainClose() {
        Notice card = reviewCard(ME, null, null);

        // 无任何状态行 = 从未读、弹窗只是被 X 关闭过（前端不写 popup_ack）。
        assertThat(pending(ME)).as("没读过、未办结：一登录就弹").containsExactly(card.getId());
    }

    @Test
    void readCardNeverPopsAgain() {
        Notice card = reviewCard(ME, null, null);
        // markRead / 去工作台处理落点置读：read_at 与 popup_acknowledged_at 同事务落库。
        state(card.getId(), ME, s -> {
            s.setReadAt(Instant.now());
            s.setPopupAcknowledgedAt(Instant.now());
        });

        assertThat(pending(ME)).as("读过的不再重复弹").isEmpty();
    }

    @Test
    void snoozedCardHidesUntilExpiryThenPopsEvenIfRead() {
        Notice card = reviewCard(ME, null, null);
        state(card.getId(), ME, s -> {
            // snoozeNotice 同时置已读（R6：稍后再看也算已处理提醒）。
            s.setReadAt(Instant.now());
            s.setPopupAcknowledgedAt(Instant.now());
            s.setSnoozedUntil(Instant.now().plus(15, ChronoUnit.MINUTES));
        });
        assertThat(pending(ME)).as("稍后未到期不弹").isEmpty();

        state(card.getId(), ME, s -> s.setSnoozedUntil(Instant.now().minus(1, ChronoUnit.MINUTES)));
        assertThat(pending(ME)).as("稍后到期：未办结恒弹（已读也不吞掉用户要求的再提醒）")
                .containsExactly(card.getId());
    }

    @Test
    void resolvedAndDeletedAndOtherUsersCardsStaySilent() {
        Notice resolved = reviewCard(ME, Instant.now(), null);
        Notice deleted = reviewCard(ME, null, null);
        state(deleted.getId(), ME, s -> s.setDeletedAt(Instant.now()));
        reviewCard(OTHER, null, null);

        assertThat(pending(ME)).as("办结不弹、删除不弹、他人的定向卡不可见").isEmpty();
    }

    @Test
    void urgentCardsAreListedBeforeNormalOnes() {
        Notice normal = reviewCard(ME, null, "normal");
        Notice urgent = reviewCard(ME, null, "urgent");

        assertThat(pending(ME)).as("重要度排序：urgent 在 normal 前")
                .containsExactly(urgent.getId(), normal.getId());
    }

    private List<UUID> pending(UUID user) {
        em.clear();
        return notices.findVisiblePendingReviews(
                        user, List.of(EVENT), ReviewNoticeAudience.ReadScope.NONE, PageRequest.of(0, 20))
                .stream().map(Notice::getId).toList();
    }

    private Notice reviewCard(UUID audienceUser, Instant resolvedAt, String priority) {
        Notice n = new Notice();
        n.setTitle("待财务确认");
        n.setContent("订单待确认");
        n.setType("approval");
        n.setKind("NORMAL");
        n.setPublisher("系统链路");
        n.setPublishedAt(Instant.now());
        n.setPriority(priority == null ? "normal" : priority);
        n.setAudienceScope("selected");
        n.setAudienceUserId(audienceUser);
        n.setSourceEvent(EVENT);
        n.setAggregateKind("SALES_ORDER");
        n.setAggregateId(UUID.randomUUID());
        n.setResolvedAt(resolvedAt);
        tx(() -> em.persist(n));
        state(n.getId(), audienceUser, s -> { });
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
