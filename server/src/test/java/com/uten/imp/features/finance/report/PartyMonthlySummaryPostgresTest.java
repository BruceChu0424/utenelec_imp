package com.uten.imp.features.finance.report;

import com.uten.imp.testsupport.TestFlyway;
import org.hibernate.Session;
import org.hibernate.SessionFactory;
import org.hibernate.cfg.Configuration;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * B2 往来月度汇总在真实 PostgreSQL（完整迁移链，含 V950 脏期间触发器）上的证据：
 *
 * <ul>
 *   <li><b>迟到/乱序/红冲/核销/抵销反转</b>各自把（side, party, 业务月）登记进脏表，
 *       不依赖任何水位；读路径自愈后汇总=事件权威逐格相等；</li>
 *   <li><b>影子等价</b>：三段式 running/年度 SQL 与旧「全历史窗口」SQL 在多个窗口、
 *       双币、待核验原币、红冲、抵销场景下输出逐行相等；</li>
 *   <li><b>重放幂等</b>：重复自愈/后台排水不改变结果，晚到事件重新弄脏对应月。</li>
 * </ul>
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class PartyMonthlySummaryPostgresTest {

    private static final PostgreSQLContainer PG = new PostgreSQLContainer("postgres:16-alpine")
            .withDatabaseName("b2_party_monthly")
            .withUsername("fixture_admin")
            .withPassword("uten")
            .withCreateContainerCmdModifier(cmd -> cmd.getHostConfig()
                    .withMemory(768L * 1024 * 1024).withNanoCPUs(1_000_000_000L));

    private static JdbcTemplate jdbc;
    private static SessionFactory sessions;
    private static org.springframework.transaction.support.TransactionTemplate tx;
    private UUID party, supplier, currency, currency2, ledger, sourceLedger;

    @BeforeAll
    static void start() {
        PG.start();
        jdbc = new JdbcTemplate(new DriverManagerDataSource(PG.getJdbcUrl(), PG.getUsername(), PG.getPassword()));
        TestFlyway.configure()
                .dataSource(PG.getJdbcUrl(), PG.getUsername(), PG.getPassword())
                .locations("classpath:db/migration")
                .load()
                .migrate();
        var configuration = new Configuration().setProperty("hibernate.hbm2ddl.auto", "none");
        configuration.getProperties().put("hibernate.connection.datasource",
                new DriverManagerDataSource(PG.getJdbcUrl(), PG.getUsername(), PG.getPassword()));
        sessions = configuration.buildSessionFactory();
        tx = new org.springframework.transaction.support.TransactionTemplate(
                new org.springframework.jdbc.datasource.DataSourceTransactionManager(
                        jdbc.getDataSource()));
    }

    @AfterAll
    static void stop() {
        if (sessions != null) sessions.close();
        PG.stop();
    }

    @BeforeEach
    void clear() {
        // 完整迁移链带 FK 与 append-only 守卫，不能 TRUNCATE 清库；
        // 每个测试使用全新 party/currency/ledger UUID，事件流按 :pid 过滤互不干扰。
        party = UUID.randomUUID();
        supplier = UUID.randomUUID();
        currency = UUID.randomUUID();
        currency2 = UUID.randomUUID();
        ledger = UUID.randomUUID();
        sourceLedger = UUID.randomUUID();
        jdbc.update("INSERT INTO clients(id,code,name,code_sequence) VALUES(?,'B2-CL-'||?::text,'B2客户',('x'||substr(?::text,1,7))::bit(28)::int)", party, party, party);
        jdbc.update("INSERT INTO suppliers(id,code,name,code_sequence) VALUES(?,'B2-SU-'||?::text,'B2供应商',('x'||substr(?::text,1,7))::bit(28)::int)", supplier, supplier, supplier);
        jdbc.update("INSERT INTO currencies(id,code,name,exchange_rate) VALUES(?,'B2C-'||?::text,'B2币种',1)", currency, currency);
        jdbc.update("INSERT INTO currencies(id,code,name,exchange_rate) VALUES(?,'B2D-'||?::text,'B2币种二',7)", currency2, currency2);
    }

    // ==================== 场景矩阵 + 影子等价 ====================

    @Test void annualHasOneMonthRowWhenTwoCurrenciesPostInTheSameMonth() {
        nativeLedger("AR", UUID.randomUUID(), party, currency, "10", "2026-02-02");
        nativeLedger("AR", UUID.randomUUID(), party, currency2, "5", "2026-02-03");
        heal("AR",party);
        shadowAnnual("AR",party,2026);
        try (Session session=sessions.openSession()) {
            var transaction=session.beginTransaction();
            var rows=annualRows(session,"AR",party,2026);
            assertThat(rows).hasSize(12);
            assertThat(rows.stream().filter(row->row.get("ym").equals("2026-02"))).singleElement().satisfies(row->{
                assertThat((BigDecimal)row.get("posted")).isEqualByComparingTo("15");
                assertThat((BigDecimal)row.get("balance")).isEqualByComparingTo("15");
            });
            transaction.rollback();
        }
    }

    @Test
    void lateReversalOffsetAndMultiCurrencyStayExactThroughSelfHealing() {
        seedArHistory();

        // 触发器把每个事件落进自己的业务月（含红冲月、抵销反转月、第二币种月）。
        assertThat(dirtyMonths("AR", party)).containsExactlyInAnyOrder(
                LocalDate.of(2025, 1, 1), LocalDate.of(2025, 12, 1), LocalDate.of(2026, 2, 1),
                LocalDate.of(2026, 3, 1), LocalDate.of(2026, 6, 1));

        heal("AR", party);
        assertThat(dirtyMonths("AR", party)).isEmpty();
        assertSummariesMatchEventAuthority("AR", party);
        shadowRunningAcrossWindows("AR", party);
        shadowAnnual("AR", party, 2026);

        // 迟到：往 2025-01 旧月补一张立账 → 只弄脏该月，自愈后仍精确。
        nativeLedger("AR", UUID.randomUUID(), party, currency, "9", "2025-01-20");
        assertThat(dirtyMonths("AR", party)).containsExactly(LocalDate.of(2025, 1, 1));
        heal("AR", party);
        assertSummariesMatchEventAuthority("AR", party);
        shadowRunningAcrossWindows("AR", party);

        // 重放幂等：再次自愈 + 全量哨兵重建，结果不变。
        heal("AR", party);
        jdbc.update("INSERT INTO party_month_dirty(side,party_id,month_start) VALUES('AR',?,DATE '1900-01-01')", party);
        heal("AR", party);
        assertSummariesMatchEventAuthority("AR", party);
        shadowRunningAcrossWindows("AR", party);
        shadowAnnual("AR", party, 2026);
    }

    @Test
    void apSidePaymentAndSupplierOffsetFollowTheSameContract() {
        nativeLedger("AP", ledger, supplier, currency, "25", "2025-01-02");
        pay(supplier, currency, "2025-12-15", 8);
        pay(supplier, currency, "2026-02-10", 3);
        // 贷项（负余额）来源 + 应付抵销 + 反转（V332 快照恒等式见助手）。
        nativeLedger("AP", sourceLedger, supplier, currency, "-4", "2025-01-05");
        supplierOffset(sourceLedger, ledger);

        assertThat(dirtyMonths("AP", supplier)).containsExactlyInAnyOrder(
                LocalDate.of(2025, 1, 1), LocalDate.of(2025, 12, 1),
                LocalDate.of(2026, 2, 1), LocalDate.of(2026, 3, 1));
        heal("AP", supplier);
        assertThat(dirtyMonths("AP", supplier)).isEmpty();
        assertSummariesMatchEventAuthority("AP", supplier);
        shadowRunningAcrossWindows("AP", supplier);
        shadowAnnual("AP", supplier, 2026);
    }

    @Test
    void unverifiedLegacyOriginalKeepsPendingStatusThroughTheThreeSegmentPath() {
        // 待核验原币：前史存在 posted_original/currency 为 NULL 的事件 → running_original 恒 NULL，
        // 三段式 base_nulls 必须把前史 NULL 计数带上（本地金额仍可报）。
        jdbc.update("INSERT INTO ar_ap_ledger(id,client_id,direction,status,bill_no,bill_date,source_doc_type,"
                        + "amount_original_local,amount_balance,exchange_rate) "
                        + "VALUES(?,?,'AR',1,'B2-UNK','2025-01-31','SALES_SHIPMENT',-7,-7,1)",
                UUID.randomUUID(), party);
        cash(party, currency, "2026-02-10", 3);

        heal("AR", party);
        assertSummariesMatchEventAuthority("AR", party);
        shadowRunningAcrossWindows("AR", party);
        shadowAnnual("AR", party, 2026);

        try (Session session = sessions.openSession()) {
            var tx = session.beginTransaction();
            var rows = runningRows(session, "AR", party, LocalDate.of(2026, 2, 1), LocalDate.of(2026, 12, 31));
            assertThat(rows).hasSize(1);
            // 旧语义（=新语义）：待核验 NULL 只在事件所属币种分区内传播；现金行分区无
            // NULL 事件 → 已核验，原币余额=分区基数0+本行(0-3)=-3；本币余额跨币滚动=-7+3=-4。
            assertThat(rows.getFirst().get("originalStatus")).isEqualTo("已核验");
            assertThat((BigDecimal) rows.getFirst().get("balanceOriginal")).isEqualByComparingTo("-3");
            assertThat((BigDecimal) rows.getFirst().get("balanceLocal")).isEqualByComparingTo("-10");
            tx.rollback();
        }
    }

    @Test
    void backgroundDrainRecomputesCellsAndIsReplaySafe() {
        seedArHistory();
        try (Session session = sessions.openSession()) {
            var service = new PartyMonthlySummaryService(session);
            var tx = session.beginTransaction();
            int processed = service.drain(50);
            assertThat(processed).isGreaterThan(0);
            // 再跑一轮：无脏键时 0，不产生重复单元格。
            assertThat(service.drain(50)).isZero();
            tx.commit();
        }
        assertThat(dirtyMonths("AR", party)).isEmpty();
        assertSummariesMatchEventAuthority("AR", party);
        shadowRunningAcrossWindows("AR", party);
    }

    // ==================== 事件播种 ====================

    private void seedArHistory() {
        // 2025-01：三张本币立账（遗留期初的快照日语义由 FinanceLegacyOpeningStatementPostgresTest
        // 在其专用夹具上继续覆盖；本测试聚焦触发器/脏期间/自愈/影子机制）。
        nativeLedger("AR", ledger, party, currency, "25", "2025-01-02");
        nativeLedger("AR", UUID.randomUUID(), party, currency, "17", "2025-01-31");
        // 2025-12：预收款 8（现金事件；预收转销语义由 Legacy 投影测试覆盖，此处不重建其全链夹具）。
        cash(party, currency, "2025-12-15", 8);
        // 2026-02：预收款 3。
        cash(party, currency, "2026-02-10", 3);
        // 2026-03：立账红冲（跨月负事件落在红冲月；收款反审需 GL 双向凭证，由投影夹具测试覆盖）。
        jdbc.update("UPDATE ar_ap_ledger SET status=-1,is_deleted=true,deleted_at='2026-03-15T02:00:00Z' "
                + "WHERE id=?", ledger);
        // 2026-06：第二币种立账（外币）。
        nativeLedger("AR", UUID.randomUUID(), party, currency2, "5", "2026-06-08");
    }

    private void nativeLedger(String side, UUID id, UUID partyId, UUID currencyId, String amount, String date) {
        String partyColumn = side.equals("AR") ? "client_id" : "supplier_id";
        jdbc.update("INSERT INTO ar_ap_ledger(id," + partyColumn + ",currency_id,direction,status,bill_no,"
                        + "bill_date,source_doc_type,amount_original,amount_original_local,amount_balance_original,"
                        + "amount_received_original,amount_write_off_original,amount_offset_original,"
                        + "amount_balance,exchange_rate) "
                        + "VALUES(?,?,?,?,1,?,?::date,?,?::numeric,?::numeric,?::numeric,0,0,0,?::numeric,1)",
                id, partyId, currencyId, side, "B2-" + id, date,
                side.equals("AR") ? "SALES_SHIPMENT" : "PURCHASE_RECEIPT", amount, amount, amount, amount);
    }

    private static final java.util.concurrent.atomic.AtomicInteger DOC_SEQ =
            new java.util.concurrent.atomic.AtomicInteger(1);

    /** 注册发号格式：文档族=固定前缀+YYYYMMDD+6位序号（V279）。 */
    private static String docNo(String prefix, String date) {
        return prefix + date.replace("-", "") + String.format("%06d", DOC_SEQ.getAndIncrement() % 999999 + 1);
    }

    /** 无核销行的预收款头：cash_facts 走头金额回退路径产生现金事件，
     * 避免在测试里重建 V407 结算权威/来源引用全链。 */
    private UUID cash(UUID partyId, UUID currencyId, String date, int amount) {
        UUID id = UUID.randomUUID();
        jdbc.update("INSERT INTO finance_receipts(id,client_id,currency_id,bill_no,bill_date,status,"
                        + "amount_original,amount_local,exchange_rate,receipt_kind) "
                        + "VALUES(?,?,?,?,?::date,1,?,?,1,'CUSTOMER_PREPAYMENT')",
                id, partyId, currencyId, docNo("XS", date), date, amount, amount);
        return id;
    }
    /** 无核销行的付款头：paymentBookLocal 头金额回退路径产生付款事件。 */
    private UUID pay(UUID supplierId, UUID currencyId, String date, int amount) {
        UUID id = UUID.randomUUID();
        jdbc.update("INSERT INTO finance_payments(id,supplier_id,currency_id,bill_no,bill_date,status,"
                        + "amount_original,amount_local,exchange_rate) VALUES(?,?,?,?,?::date,1,?,?,1)",
                id, supplierId, currencyId, docNo("CF", date), date, amount, amount);
        return id;
    }

    private void supplierOffset(UUID source, UUID target) {
        // V332 快照恒等式：来源 -4→0，目标 25→21；REVERSED 需 reversed_by/at + 理由。
        jdbc.update("INSERT INTO supplier_open_item_offsets(id,offset_batch_id,line_sequence,source_ledger_id,"
                        + "target_ledger_id,supplier_id,currency_id,effective_date,amount_original,"
                        + "source_amount_local,target_amount_local,source_rate,target_rate,"
                        + "source_balance_before_original,source_balance_after_original,"
                        + "target_balance_before_original,target_balance_after_original,reason,status) "
                        + "VALUES(gen_random_uuid(),gen_random_uuid(),1,?,?,?,?,'2026-02-20',4,4,4,1,1,-4,0,25,21,'B2应付抵销','APPLIED')",
                source, target, supplier, currency);
        jdbc.update("UPDATE supplier_open_item_offsets SET status='REVERSED',reversed_at='2026-03-10T00:00:00Z',"
                        + "reverse_reason='B2抵销反转' WHERE supplier_id=? AND status='APPLIED'", supplier);
    }
    // ==================== 校验与影子 ====================

    private void heal(String side, UUID partyId) {
        try (Session session = sessions.openSession()) {
            var tx = session.beginTransaction();
            new PartyMonthlySummaryService(session).reconcileNow(side, partyId);
            tx.commit();
        }
    }

    private List<LocalDate> dirtyMonths(String side, UUID partyId) {
        return jdbc.queryForList("SELECT month_start FROM party_month_dirty WHERE side=? AND party_id=? "
                + "AND month_start<>DATE '1900-01-01' ORDER BY month_start", LocalDate.class, side, partyId);
    }

    /** 汇总单元格与事件权威直接聚合（独立重算）逐格相等；调用前该单位脏键应为空。 */
    private void assertSummariesMatchEventAuthority(String side, UUID partyId) {
        String events = eventsOf(side);
        try (Session session = sessions.openSession()) {
            var tx = session.beginTransaction();
            List<Object[]> authority = session.createNativeQuery("""
                    %s
                    , authority AS (
                        SELECT event.currency_id,
                               date_trunc('month',event.event_date)::DATE AS month_start,
                               SUM(event.posted_original-event.settled_original),
                               SUM(event.posted_local),SUM(event.settled_local),
                               SUM(event.posted_local-event.settled_local),COUNT(*),
                               COUNT(*) FILTER(WHERE event.posted_original IS NULL
                                   OR event.settled_original IS NULL OR event.currency_id IS NULL)
                        FROM party_events event
                        GROUP BY event.currency_id,date_trunc('month',event.event_date)::DATE
                    )
                    SELECT * FROM authority ORDER BY 2,1 NULLS LAST
                    """.formatted(events), Object[].class)
                    .setParameter("pid", partyId)
                    .getResultList();
            tx.rollback();
            List<Map<String, Object>> cells = jdbc.queryForList(
                    "SELECT currency_id,month_start,net_original,posted_local_sum,settled_local_sum,net_local,"
                            + "event_count,null_original_count FROM party_monthly_summaries "
                            + "WHERE side=? AND party_id=? ORDER BY month_start,currency_id NULLS LAST",
                    side, partyId);
            assertThat(cells).hasSameSizeAs(authority);
            for (int i = 0; i < authority.size(); i++) {
                Object[] expected = authority.get(i);
                Map<String, Object> actual = cells.get(i);
                assertThat(java.sql.Date.valueOf(expected[1].toString()).toLocalDate())
                        .isEqualTo(((java.sql.Date) actual.get("month_start")).toLocalDate());
                assertThat(UUIDcompare(expected[0], actual.get("currency_id")))
                        .as("currency of %s", actual.get("month_start")).isTrue();
                assertNum(expected[2], actual.get("net_original"));
                assertNum(expected[3], actual.get("posted_local_sum"));
                assertNum(expected[4], actual.get("settled_local_sum"));
                assertNum(expected[5], actual.get("net_local"));
                assertThat(((Number) expected[6]).longValue())
                        .isEqualTo(((Number) actual.get("event_count")).longValue());
                assertThat(((Number) expected[7]).longValue())
                        .isEqualTo(((Number) actual.get("null_original_count")).longValue());
            }
        }
    }

    /** 新三段式 running 与旧全历史窗口 running 的输出在多窗口下逐行相等（影子等价）。 */
    private void shadowRunningAcrossWindows(String side, UUID partyId) {
        List<LocalDate[]> windows = List.of(
                new LocalDate[]{LocalDate.of(2026, 2, 1), LocalDate.of(2026, 12, 31)},
                new LocalDate[]{LocalDate.of(2026, 2, 15), null},
                new LocalDate[]{null, LocalDate.of(2026, 12, 31)},
                new LocalDate[]{LocalDate.of(2025, 6, 1), LocalDate.of(2025, 12, 31)});
        for (LocalDate[] window : windows) {
            try (Session session = sessions.openSession()) {
                var tx = session.beginTransaction();
                List<Map<String, Object>> legacy = legacyRunningRows(session, side, partyId, window[0], window[1]);
                List<Map<String, Object>> current = runningRows(session, side, partyId, window[0], window[1]);
                assertThat(current).as("three-segment rows %s..%s", window[0], window[1])
                        .containsExactlyElementsOf(legacy);
                tx.rollback();
            }
        }
    }

    /** 新汇总化年度与旧逐月相关子查询年度输出相等（影子等价）。 */
    private void shadowAnnual(String side, UUID partyId, int year) {
        try (Session session = sessions.openSession()) {
            var tx = session.beginTransaction();
            List<Map<String, Object>> legacy = legacyAnnualRows(session, side, partyId, year);
            List<Map<String, Object>> current = annualRows(session, side, partyId, year);
            assertThat(current).containsExactlyElementsOf(legacy);
            tx.rollback();
        }
    }

    private List<Map<String, Object>> runningRows(Session session, String side, UUID partyId,
                                                  LocalDate from, LocalDate to) {
        return queryRows(session, FinancePartyStatementSql.running(eventsOf(side), side),
                partyId, from, to, from == null ? null : from.withDayOfMonth(1));
    }

    private List<Map<String, Object>> legacyRunningRows(Session session, String side, UUID partyId,
                                                        LocalDate from, LocalDate to) {
        return queryRows(session, LEGACY_RUNNING.formatted(eventsOf(side)), partyId, from, to, null);
    }

    private List<Map<String, Object>> annualRows(Session session, String side, UUID partyId, int year) {
        String sql = FinancePartyStatementSql.annual(side);
        List<Object[]> rows = session.createNativeQuery(sql, Object[].class)
                .setParameter("pid", partyId)
                .setParameter("ys", LocalDate.of(year, 1, 1))
                .setParameter("ye", LocalDate.of(year, 12, 31))
                .getResultList();
        return toMaps(rows, List.of("ym", "prevBalance", "posted", "settled", "returned", "balance"));
    }

    private List<Map<String, Object>> legacyAnnualRows(Session session, String side, UUID partyId, int year) {
        List<Object[]> rows = session.createNativeQuery(LEGACY_ANNUAL.formatted(eventsOf(side)), Object[].class)
                .setParameter("pid", partyId)
                .setParameter("ys", LocalDate.of(year, 1, 1))
                .setParameter("ye", LocalDate.of(year, 12, 31))
                .getResultList();
        return toMaps(rows, List.of("ym", "prevBalance", "posted", "settled", "returned", "balance"));
    }

    private List<Map<String, Object>> queryRows(Session session, String sql, UUID partyId,
                                                LocalDate from, LocalDate to, LocalDate fromMonth) {
        var query = session.createNativeQuery(sql, Object[].class)
                .setParameter("pid", partyId).setParameter("from", from).setParameter("to", to);
        if (sql.contains(":fromMonth")) {
            query.setParameter("fromMonth", fromMonth);
        }
        List<Object[]> rows = query.getResultList();
        return toMaps(rows, List.of("billDate", "refNo", "currencyCode", "salesOriginal", "salesRate",
                "salesLocal", "receiptOriginal", "receiptRate", "receiptLocal", "balanceOriginal",
                "balanceRate", "balanceLocal", "type", "remark", "eventOrder", "eventId",
                "originalStatus", "__currencyId"));
    }

    private static List<Map<String, Object>> toMaps(List<Object[]> rows, List<String> keys) {
        List<Map<String, Object>> out = new ArrayList<>();
        for (Object[] row : rows) {
            Map<String, Object> map = new LinkedHashMap<>();
            for (int i = 0; i < keys.size(); i++) {
                Object value = row[i];
                if (value instanceof java.sql.Date date) value = date.toLocalDate();
                // 三段式与旧窗口的 numeric 标度不同（COALESCE 字面量带小数位），
                // 影子比对按数值规范化，不放宽业务断言本身。
                if (value instanceof BigDecimal decimal) value = decimal.stripTrailingZeros();
                map.put(keys.get(i), value);
            }
            out.add(map);
        }
        return out;
    }

    private static boolean UUIDcompare(Object left, Object right) {
        UUID a = left == null ? null : UUID.fromString(left.toString());
        UUID b = right == null ? null : UUID.fromString(right.toString());
        return java.util.Objects.equals(a, b);
    }

    private static void assertNum(Object expected, Object actual) {
        if (expected == null) {
            assertThat(actual).isNull();
            return;
        }
        assertThat(actual).isNotNull();
        assertThat(new BigDecimal(expected.toString())).isEqualByComparingTo(new BigDecimal(actual.toString()));
    }

    private static String eventsOf(String side) {
        return FinancePartyStatementSql.events(!side.equals("AP"), "1=1");
    }

    // ==================== 旧实现（全历史窗口）——冻结为影子基准 ====================

    private static final String LEGACY_RUNNING = """
            %s
            , windowed AS (
                SELECT event.*,
                       CASE WHEN COUNT(*) FILTER(WHERE posted_original IS NULL OR settled_original IS NULL
                                  OR currency_id IS NULL) OVER currency_history>0 THEN NULL
                            ELSE SUM(posted_original-settled_original) OVER currency_history END AS running_original,
                       SUM(posted_local-settled_local) OVER all_history AS running_local
                FROM party_events event
                WHERE CAST(:to AS date) IS NULL OR event_date<=:to
                WINDOW currency_history AS (PARTITION BY currency_id ORDER BY event_date,event_order,ref_no,event_id ROWS UNBOUNDED PRECEDING),
                       all_history AS (ORDER BY event_date,event_order,ref_no,event_id ROWS UNBOUNDED PRECEDING)
            )
            SELECT event_date AS "billDate",ref_no AS "refNo",currency_code AS "currencyCode",
                   posted_original AS "salesOriginal",posted_rate AS "salesRate",posted_local AS "salesLocal",
                   settled_original AS "receiptOriginal",settled_rate AS "receiptRate",settled_local AS "receiptLocal",
                   running_original AS "balanceOriginal",posted_rate AS "balanceRate",running_local AS "balanceLocal",
                   event_type AS "type",remark AS "remark",event_order AS "eventOrder",event_id AS "eventId",
                   CASE WHEN running_original IS NULL THEN '待核验' ELSE '已核验' END AS "originalStatus",
                   currency_id AS "__currencyId"
            FROM windowed WHERE CAST(:from AS date) IS NULL OR event_date>=:from
            """;

    private static final String LEGACY_ANNUAL = """
            %s
            , monthly AS (
                SELECT month AS ms,to_char(month,'YYYY-MM') AS ym,
                       COALESCE(SUM(event.posted_local),0) AS posted,
                       COALESCE(SUM(event.settled_local),0) AS settled
                FROM generate_series(CAST(:ys AS date),CAST(:ye AS date),INTERVAL '1 month') month
                LEFT JOIN party_events event ON event.event_date>=month
                    AND event.event_date<month+INTERVAL '1 month'
                WHERE EXISTS(SELECT 1 FROM party_events known WHERE known.event_date<=:ye)
                GROUP BY month
            )
            SELECT month.ym,
                   COALESCE((SELECT SUM(prior.posted_local-prior.settled_local)
                       FROM party_events prior WHERE prior.event_date<month.ms),0),
                   month.posted,month.settled,0,
                   COALESCE((SELECT SUM(closing.posted_local-closing.settled_local)
                       FROM party_events closing WHERE closing.event_date<month.ms+INTERVAL '1 month'),0)
            FROM monthly month ORDER BY month.ym
            """;
}
