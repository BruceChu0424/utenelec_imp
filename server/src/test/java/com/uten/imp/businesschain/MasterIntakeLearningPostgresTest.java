package com.uten.imp.businesschain;

import com.uten.imp.application.port.AiJobUsagePort;
import com.uten.imp.application.port.MasterIntakeLookupPort;
import com.uten.imp.application.port.MasterIntakeLookupPort.AliasRow;
import com.uten.imp.application.port.MasterIntakeLookupPort.AliasScope;
import com.uten.imp.application.port.MasterIntakeLookupPort.ClientCandidate;
import com.uten.imp.application.port.MasterIntakeLookupPort.ClientCandidateQuery;
import com.uten.imp.application.port.MasterIntakeLookupPort.ClientSignal;
import com.uten.imp.application.port.MasterIntakeLookupPort.GoodsRow;
import com.uten.imp.application.port.SalesMasterLearningPort;
import com.uten.imp.application.port.SalesMasterLearningPort.LearnedLine;
import com.uten.imp.application.port.SalesMasterLearningPort.SalesLearningRequest;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.text.IntakeTextNormalizer;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.client.ClientService;
import com.uten.imp.features.master.client.dto.ClientQueryFilter;
import com.uten.imp.features.master.goods.GoodsController;
import com.uten.imp.features.master.goods.GoodsService;
import com.uten.imp.features.master.goods.dto.GoodsNameEnRequest;
import com.uten.imp.features.master.goods.dto.GoodsQueryFilter;
import com.uten.imp.features.master.learning.ClientFromDocumentController;
import com.uten.imp.features.master.learning.ClientGoodsAliasController;
import com.uten.imp.features.master.learning.ClientGoodsAliasView;
import com.uten.imp.features.master.party.PartyDirectoryService;
import com.uten.imp.common.web.PageResponse;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Nested;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.TestPropertySource;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.math.BigDecimal;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.catchThrowable;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 客户文件识别的主档读取与保存后学习(ADR-134)在真实迁移库上的行为:
 * 读取按登录人范围、型号/编号/品名/英文名召回、对照学习规则、英文名称与客户资料的权限闸门、
 * 学习失败不回滚保存、用文件新建客户查重、货品对照接口的范围与越权校验。
 *
 * <p>AI 平台的识别结果读取口({@link AiJobUsagePort})用替身, 其余全部真实 Bean + 真实 PostgreSQL。
 * <b>CI 必须显式设置 {@code UTEN_RUN_DB_TESTS=true}</b>, 否则整类跳过。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class MasterIntakeLearningPostgresTest {

    private static final String[] SALES_PERMS = {
            "client:view", "client:edit", "client:create", "sales_quote:view", "sales_quote:create",
            "sales_order:view", "sales_order:create", "goods:view", "goods:name_en:edit"};

    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @MockitoBean
    AiJobUsagePort jobUsage;

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired PlatformTransactionManager transactionManager;
    @Autowired MasterIntakeLookupPort lookup;
    @Autowired SalesMasterLearningPort learning;
    @Autowired DocNumberService docNumbers;
    @Autowired ClientGoodsAliasController aliasController;
    @Autowired ClientFromDocumentController fromDocumentController;
    @Autowired GoodsController goodsController;
    @Autowired GoodsService goodsService;
    @Autowired ClientService clientService;
    @Autowired PartyDirectoryService partyDirectory;

    private FullChainEndToEndTest fixture;
    private FullChainEndToEndTest.World world;
    private String tag;

    @BeforeEach
    void prepare() {
        fixture = new FullChainEndToEndTest();
        beans.autowireBean(fixture);
        tag = "MIL" + UUID.randomUUID().toString().replace("-", "").substring(0, 8).toUpperCase(Locale.ROOT);
        world = fixture.seedWorld(tag);
    }

    @AfterEach
    void logout() {
        SecurityContextHolder.clearContext();
    }

    // ==================================================================
    // 读取: 客户范围
    // ==================================================================

    @Test
    void clientLookupIsScopedToTheCallersOwnActiveClients() {
        Seller a = seller("a", SALES_PERMS);
        Seller b = seller("b", SALES_PERMS);
        Seller nobody = seller("n", "client:view", "sales_quote:create");
        UUID sunas = client(a, "SUN", "尼日利亚SUNAS", "sunas.inv40@gmail.test", "+86 138 0013 8000", "尼日利亚",
                "SUNAS Electrical Resource Ltd");
        UUID disabled = client(a, "OFF", "停用客户", null, null, null, null);
        db.update("update clients set status = '禁用' where id = ?", disabled);
        UUID other = client(b, "OTH", "Shami", "buyer@aldar.test", "+962 6 739 5151", "约旦", "ALDAR FOR ELECTRICAL");

        fixture.loginAs(a.userId());
        List<ClientCandidate> byEmail = lookup.clientCandidates(query(Set.of("sunas.inv40@gmail.test", "buyer@aldar.test"),
                Set.of(), Set.of(), Set.of(), List.of(), Set.of(), Set.of()));
        assertThat(byEmail).extracting(ClientCandidate::clientId).containsExactly(sunas);
        assertThat(byEmail.getFirst().signals()).contains(ClientSignal.EMAIL);

        ClientCandidate combined = single(lookup.clientCandidates(query(Set.of(), Set.of("gmail.test"),
                Set.of("00138000"), Set.of(IntakeTextNormalizer.normalizeDescription("SUNAS ELECTRICAL RESOURCE LTD.")),
                List.of("SUNAS ELECTRICAL RESOURCE LTD."), Set.of("SUNAS"), Set.of("尼日利亚"))));
        assertThat(combined.clientId()).isEqualTo(sunas);
        assertThat(combined.signals()).contains(ClientSignal.EMAIL_DOMAIN, ClientSignal.PHONE,
                ClientSignal.NAME_EN_EXACT, ClientSignal.TOKEN, ClientSignal.NAME_SIMILARITY, ClientSignal.PLACE);
        assertThat(combined.matchedTokens()).containsExactly("SUNAS");
        assertThat(combined.nameSimilarity()).isGreaterThanOrEqualTo(0.5);

        assertThat(lookup.clientCandidates(query(Set.of(), Set.of("aldar.test"), Set.of("67395151"), Set.of(),
                List.of(), Set.of("ALDAR"), Set.of("约旦"))))
                .as("别人的客户(电话、名称、国家都命中)也不能出现").isEmpty();
        assertThat(lookup.visibleActiveClientCount()).as("停用客户不算").isEqualTo(1);
        assertThat(lookup.clientProfile(other)).isNull();
        MasterIntakeLookupPort.ClientProfile profile = lookup.clientProfile(sunas);
        assertThat(profile.editable()).isTrue();
        assertThat(profile.nameEn()).isEqualTo("SUNAS Electrical Resource Ltd");
        assertThat(profile.status()).as("识别侧按「使用」判断客户启用").isEqualTo("使用");
        assertThat(lookup.clientProfile(disabled)).as("停用客户仍可读资料, 状态如实返回")
                .extracting(MasterIntakeLookupPort.ClientProfile::status).isEqualTo("禁用");

        fixture.loginAs(b.userId());
        assertThat(lookup.clientCandidates(query(Set.of("sunas.inv40@gmail.test"), Set.of(), Set.of(), Set.of(),
                List.of(), Set.of(), Set.of()))).isEmpty();

        fixture.loginAs(nobody.userId());
        assertThat(lookup.visibleActiveClientCount()).as("名下没有客户的业务员看到 0 个").isZero();

        // 只读共享: 看得到, 但不可补全客户资料。
        share(sunas, nobody, a);
        fixture.loginAs(nobody.userId());
        assertThat(lookup.clientProfile(sunas)).isNotNull()
                .extracting(MasterIntakeLookupPort.ClientProfile::editable).isEqualTo(false);
    }

    @Test
    void clientHistoryBasketAndRecentDocumentsFollowTheSameScopeAndSkipVoidedOrders() {
        Seller a = seller("a", SALES_PERMS);
        Seller b = seller("b", SALES_PERMS);
        UUID sunas = client(a, "SUN", "尼日利亚SUNAS", null, null, null, null);
        UUID other = client(b, "OTH", "Shami", null, null, null, null);
        UUID white = color("白色");
        UUID g1 = goods("H1", "Z9两开插座" + tag, "GZ23/D" + tag, "Z9", white, "21", false, false, "使用");
        UUID g2 = goods("H2", "Z9一开" + tag, "GK12" + tag, "Z9", white, "9.45", false, false, "使用");
        UUID g3 = goods("H3", "作废单货品" + tag, "GK99" + tag, "Z9", white, "1", false, false, "使用");
        UUID first = order(sunas, a, (short) 1, g1, g2);
        order(sunas, a, (short) 1, g1);
        order(sunas, a, (short) -1, g3);
        order(other, b, (short) 1, g3);
        UUID quoteA = quote(sunas, a, (short) 0, g2, g3);
        quote(sunas, a, (short) -1, g1);
        Seller viewer = seller("v", SALES_PERMS);
        share(sunas, viewer, a);
        UUID quoteV = quote(sunas, viewer, (short) 0, g1);

        fixture.loginAs(a.userId());
        Map<UUID, MasterIntakeLookupPort.ClientGoodsHistory> history = lookup.clientHistory(sunas, 24);
        assertThat(history).containsOnlyKeys(g1, g2);
        assertThat(history.get(g1).orderCount()).isEqualTo(2);
        assertThat(history.get(g1).lastOrderDate()).isNotNull();

        Map<UUID, Set<UUID>> basket = lookup.historyContains(List.of(sunas, other), List.of(g1, g2, g3));
        assertThat(basket).containsOnlyKeys(sunas);
        assertThat(basket.get(sunas)).containsExactlyInAnyOrder(g1, g2);
        // 空客户集合 = 自己看得到的全部启用客户(文件上没有买方线索时的篮子比较): 别人的客户、作废订单都不算。
        Map<UUID, Set<UUID>> allVisible = lookup.historyContains(List.of(), List.of(g1, g2, g3));
        assertThat(allVisible).containsOnlyKeys(sunas);
        assertThat(allVisible.get(sunas)).containsExactlyInAnyOrder(g1, g2);
        assertThat(lookup.historyContains(List.of(), List.of())).isEmpty();

        List<MasterIntakeLookupPort.DuplicateDocRow> recent = lookup.recentDocs(sunas, 180);
        assertThat(recent).as("两张有效订货单 + 自己做的有效报价单; 作废的与别人做的报价单不算").hasSize(3);
        assertThat(recent).filteredOn(doc -> "order".equals(doc.docType())).hasSize(2);
        MasterIntakeLookupPort.DuplicateDocRow firstDoc = recent.stream()
                .filter(doc -> doc.docId().equals(first)).findFirst().orElseThrow();
        assertThat(firstDoc.lines()).extracting(MasterIntakeLookupPort.DuplicateDocLine::goodsId)
                .containsExactlyInAnyOrder(g1, g2);
        assertThat(firstDoc.contractNo()).isEqualTo("PO-" + tag);
        MasterIntakeLookupPort.DuplicateDocRow quoteDoc = recent.stream()
                .filter(doc -> "quote".equals(doc.docType())).findFirst().orElseThrow();
        assertThat(quoteDoc.docId()).isEqualTo(quoteA);
        assertThat(quoteDoc.contractNo()).isEqualTo("QC-" + tag);
        assertThat(quoteDoc.billNo()).isNotBlank();
        assertThat(quoteDoc.lines()).extracting(MasterIntakeLookupPort.DuplicateDocLine::goodsId)
                .containsExactlyInAnyOrder(g2, g3);
        assertThat(quoteDoc.lines()).allSatisfy(line -> assertThat(line.qty()).isEqualByComparingTo("10"));

        // 共享只读看得到客户, 单据仍按制单人/负责人范围: 只看到自己做的报价单。
        fixture.loginAs(viewer.userId());
        assertThat(lookup.recentDocs(sunas, 180)).extracting(MasterIntakeLookupPort.DuplicateDocRow::docId)
                .containsExactly(quoteV);

        fixture.loginAs(b.userId());
        assertThat(lookup.clientHistory(sunas, 24)).isEmpty();
        assertThat(lookup.recentDocs(sunas, 180)).isEmpty();
        assertThat(lookup.historyContains(List.of(), List.of(g1, g2, g3))).as("b 只比较自己的客户")
                .containsOnlyKeys(other);
    }

    // ==================================================================
    // 读取: 货品候选
    // ==================================================================

    @Test
    void goodsCandidatesReturnOnlyLiveGoodsAndKeepSameModelConfusers() {
        Seller a = seller("a", SALES_PERMS);
        UUID white = color("白色");
        UUID black = color("黑色");
        String model = "GZ23/D" + tag;
        UUID z9White = goods("A1", "Z9两开" + tag, model, "Z9", white, "21", false, false, "使用");
        UUID z9Black = goods("A2", "Z9两开黑" + tag, model, "Z9", black, "21", false, false, "使用");
        UUID m6White = goods("A3", "尼日利亚6M两开" + tag, model.toLowerCase(Locale.ROOT).replace("/", "／"),
                "6M", white, "14", false, false, "使用");
        goods("A4", "占位" + tag, model, "Z9", white, "21", true, false, "使用");
        goods("A5", "已删" + tag, model, "Z9", white, "21", false, true, "使用");
        goods("A6", "停用" + tag, model, "Z9", white, "21", false, false, "禁用");
        UUID q120 = goods("A7", "Q120开关" + tag, "Q120-K20AD" + tag, "Q120", white, "0", false, false, "使用");

        fixture.loginAs(a.userId());
        List<GoodsRow> byModel = lookup.goodsByModelNorm(List.of(IntakeTextNormalizer.normalizePart(model)));
        assertThat(byModel).extracting(GoodsRow::id).containsExactlyInAnyOrder(z9White, z9Black, m6White);
        GoodsRow blackRow = byModel.stream().filter(row -> row.id().equals(z9Black)).findFirst().orElseThrow();
        assertThat(blackRow.colorName()).isEqualTo("黑色");
        assertThat(blackRow.series()).isEqualTo("Z9");
        assertThat(blackRow.price()).isEqualByComparingTo("21");
        assertThat(blackRow.unitName()).isEqualTo("个");

        assertThat(lookup.goodsByModelNorm(List.of("K20AD" + tag))).as("数据库侧不剥前缀, 变体由调用方给").isEmpty();
        assertThat(lookup.goodsByModelNorm(List.of(IntakeTextNormalizer.normalizePart("q120-k20ad" + tag))))
                .extracting(GoodsRow::id).containsExactly(q120);
        assertThat(lookup.goodsByCode(List.of(("a1-" + tag).toLowerCase(Locale.ROOT))))
                .extracting(GoodsRow::id).containsExactly(z9White);
        assertThat(lookup.goodsByIds(List.of(q120, z9White, UUID.randomUUID())))
                .extracting(GoodsRow::id).containsExactly(q120, z9White);

        // 型号召回走 idx_goods_model_norm(表达式与索引一致才会走)。
        // 先收集统计信息: 否则小表上规划器可能拿别的部分索引(goods_code_uq)全扫代替。
        db.execute("ANALYZE goods");
        String plan = new TransactionTemplate(transactionManager).execute(status -> {
            db.execute("SET LOCAL enable_seqscan = off");
            return String.join("\n", db.queryForList("EXPLAIN SELECT g.id FROM goods g "
                    + "WHERE NOT g.is_deleted AND g.model IS NOT NULL AND btrim(g.model) <> '' AND "
                    + com.uten.imp.features.master.learning.MasterIntakeLookupAdapter.MODEL_NORM_EXPR
                    + " IN ('X')", String.class));
        });
        assertThat(plan).contains("idx_goods_model_norm");
    }

    @Test
    void chineseNameAndEnglishNameRecallFindPrefixedBracketedAndFuzzyNames() {
        Seller a = seller("a", SALES_PERMS);
        UUID white = color("白色");
        UUID nigeria = goods("N1", "尼日利亚6M " + tag + "一开13A带A+C双USB", null, "6M", white, "14", false, false, "使用");
        UUID bracket = goods("N2", "Z9" + tag + "一开13A带A+C双USB(新款)", null, "Z9", white, "15", false, false, "使用");
        UUID fuzzy = goods("N3", "Z9" + tag + "一开13A带双USB插座", null, "Z9", white, "15", false, false, "使用");
        goods("N4", "Z9" + tag + "一开13A带A+C双USB", null, "Z9", white, "15", true, false, "使用");
        UUID english = goods("E1", "Z9两开" + tag, null, "Z9", white, "21", false, false, "使用");
        db.update("update goods set name_en = ?, name_en_source = 'MANUAL' where id = ?",
                "DOUBLE 3 PIN UNIVERSAL SOCKET WITH SWITCH " + tag, english);

        fixture.loginAs(a.userId());
        List<GoodsRow> byName = lookup.goodsByNameCandidates(List.of(tag + "一开13A带A+C 双USB"), 50);
        assertThat(byName).extracting(GoodsRow::id).contains(nigeria, bracket, fuzzy);
        assertThat(byName.indexOf(byName.stream().filter(r -> r.id().equals(nigeria)).findFirst().orElseThrow()))
                .as("名称结尾一致的排在相似召回前面")
                .isLessThan(byName.indexOf(byName.stream().filter(r -> r.id().equals(fuzzy)).findFirst().orElseThrow()));
        assertThat(byName).extracting(GoodsRow::code).noneMatch(code -> code.startsWith("N4"));

        List<GoodsRow> byEnglish = lookup.goodsByNameEn(
                List.of("double 3 pin universal soccket with switch " + tag.toLowerCase(Locale.ROOT)), 20);
        assertThat(byEnglish).extracting(GoodsRow::id).contains(english);
        assertThat(byEnglish.getFirst().nameEnSource()).isEqualTo("MANUAL");
    }

    /** 货品归属隔离开关打开时(uten.features.goods-owner-scope-enabled): 货品候选与对照都只含看得到的货品。 */
    @Nested
    @TestPropertySource(properties = "uten.features.goods-owner-scope-enabled=true")
    class WithGoodsOwnerScope {

        @Autowired MasterIntakeLookupPort scopedLookup;

        @Test
        void goodsCandidatesAndAliasesHideGoodsOwnedBySomeoneElse() {
            Seller a = seller("a", SALES_PERMS);
            Seller b = seller("b", SALES_PERMS);
            UUID white = color("白色");
            String model = "OWN/" + tag;
            UUID shared = goods("O1", "公共" + tag, model, "Z9", white, "21", false, false, "使用");
            UUID mine = goods("O2", "我的" + tag, model, "Z9", white, "21", false, false, "使用");
            UUID theirs = goods("O3", "别人的" + tag, model, "Z9", white, "21", false, false, "使用");
            db.update("update goods set owner_employee_id = ? where id = ?", a.employeeId(), mine);
            db.update("update goods set owner_employee_id = ? where id = ?", b.employeeId(), theirs);
            String aliasText = "OWN-ALIAS-" + tag;
            String aliasNorm = IntakeTextNormalizer.normalizePart(aliasText);
            for (UUID goodsId : List.of(shared, mine, theirs)) {
                db.update("""
                        insert into client_goods_aliases(client_id, alias_kind, alias_text, alias_norm, context_norm,
                            goods_id, confirm_count, explicit_count, first_confirmed_at, last_confirmed_at)
                        values (null, 'PART_NO', ?, ?, '', ?, 2, 0, now(), now())
                        """, aliasText, aliasNorm, goodsId);
            }
            String modelNorm = IntakeTextNormalizer.normalizePart(model);

            fixture.loginAs(a.userId());
            assertThat(scopedLookup.goodsByModelNorm(List.of(modelNorm))).extracting(GoodsRow::id)
                    .containsExactlyInAnyOrder(shared, mine);
            assertThat(scopedLookup.goodsByIds(List.of(shared, mine, theirs))).extracting(GoodsRow::id)
                    .containsExactly(shared, mine);
            assertThat(scopedLookup.aliases(null, List.of(aliasNorm), List.of())).extracting(AliasRow::goodsId)
                    .containsExactlyInAnyOrder(shared, mine);

            fixture.loginAs(b.userId());
            assertThat(scopedLookup.goodsByModelNorm(List.of(modelNorm))).extracting(GoodsRow::id)
                    .containsExactlyInAnyOrder(shared, theirs);
            assertThat(scopedLookup.aliases(null, List.of(aliasNorm), List.of())).extracting(AliasRow::goodsId)
                    .containsExactlyInAnyOrder(shared, theirs);
        }
    }

    // ==================================================================
    // 学习: 对照规则
    // ==================================================================

    @Test
    void aliasLearningFollowsConfirmationScopeAndSameDocumentRules() {
        Seller a = seller("a", SALES_PERMS);
        UUID sunas = client(a, "SUN", "尼日利亚SUNAS", null, null, null, null);
        UUID white = color("白色");
        UUID ga = goods("L1", "Z9两开" + tag, "GZ23/D" + tag, "Z9", white, "21", false, false, "使用");
        UUID gb = goods("L2", "Z9两开新款" + tag, "GZ23/DN" + tag, "Z9", white, "21", false, false, "使用");
        String part = "GZ23/D-" + tag;
        String desc = "DOUBLE SOCKET " + tag;
        UUID job = UUID.randomUUID();
        jobResult(job, a, line("S1R9", part, desc, "Z9|白", "MATCHED", ga, desc),
                line("S1R10", "REV-" + tag, null, "Z9|白", "REVIEW", ga, null));

        // 第一次保存: 自动对应且没改 → 客户对照 + 全局对照, 确认 1 次, 未明确选择。
        UUID doc1 = UUID.randomUUID();
        save(a, "quote", doc1, sunas, job, Map.of(),
                new LearnedLine(ga, part, desc, "S1R9", false, false),
                new LearnedLine(ga, "REV-" + tag, null, "S1R10", false, false));
        verify(jobUsage).markUsed(eq(job), eq(a.userId()), eq("quote"), eq(doc1));
        assertThat(aliasRow(sunas, "PART_NO", part, ga)).containsEntry("confirm_count", 1).containsEntry("explicit_count", 0)
                .containsEntry("context_norm", "Z9|白");
        assertThat(aliasRow(null, "PART_NO", part, ga)).as("与识别原文一致, 另学全局对照").isNotNull();
        assertThat(aliasRow(sunas, "DESCRIPTION", desc, ga)).isNotNull();
        assertThat(countAliases(sunas, "REV-" + tag)).as("待核对且未确认的行不学").isZero();

        // 同一张单据再次保存: 不重复计数。
        save(a, "quote", doc1, sunas, job, Map.of(), new LearnedLine(ga, part, desc, "S1R9", false, false));
        assertThat(aliasRow(sunas, "PART_NO", part, ga)).containsEntry("confirm_count", 1);

        // 另一张单据明确确认: 确认 2 次, 明确 1 次。
        UUID doc2 = UUID.randomUUID();
        save(a, "order", doc2, sunas, job, Map.of(), new LearnedLine(ga, part, desc, "S1R9", true, false));
        assertThat(aliasRow(sunas, "PART_NO", part, ga)).containsEntry("confirm_count", 2).containsEntry("explicit_count", 1)
                .containsEntry("last_source_doc_type", "order");
        assertThat(aliasRow(null, "PART_NO", part, ga)).as("全局对照按不同客户计数: 仍只有这一个客户")
                .containsEntry("confirm_count", 1).containsEntry("explicit_count", 1);

        // 读取口按规范化叫法返回客户 + 全局对照。
        fixture.loginAs(a.userId());
        List<AliasRow> rows = lookup.aliases(sunas, List.of(IntakeTextNormalizer.normalizePart(part)),
                List.of(IntakeTextNormalizer.normalizeDescription(desc)));
        assertThat(rows).extracting(AliasRow::scope).contains(AliasScope.CLIENT, AliasScope.GLOBAL);
        assertThat(rows).allMatch(row -> row.goodsId().equals(ga));

        // 手打的型号(与识别原文不同): 只学客户对照。
        UUID doc3 = UUID.randomUUID();
        String typed = "MY-OWN-" + tag;
        save(a, "quote", doc3, sunas, job, Map.of(), new LearnedLine(ga, typed, null, "S1R9", true, false));
        assertThat(aliasRow(sunas, "PART_NO", typed, ga)).isNotNull();
        assertThat(aliasRow(null, "PART_NO", typed, ga)).isNull();

        // 同一单据改了货品: 撤回本单据上次学到的旧对应。
        UUID doc4 = UUID.randomUUID();
        String retract = "RETRACT-" + tag;
        save(a, "quote", doc4, sunas, null, Map.of(), new LearnedLine(ga, retract, null, null, true, false));
        assertThat(aliasRow(sunas, "PART_NO", retract, ga)).isNotNull();
        save(a, "quote", doc4, sunas, null, Map.of(), new LearnedLine(gb, retract, null, null, true, false));
        assertThat(aliasRow(sunas, "PART_NO", retract, ga)).isNull();
        assertThat(aliasRow(sunas, "PART_NO", retract, gb)).containsEntry("confirm_count", 1);

        // 另一张单据明确改成别的货品: 这是用户改正。系统以前自动学到(没人明确选过)的旧对应作废,
        // 下次识别直接用改正后的货品(ADR-134 §五)。
        UUID weakJob = UUID.randomUUID();
        String weak = "WEAK-" + tag;
        jobResult(weakJob, a, line("S1R9", weak, null, "Z9|白", "MATCHED", ga, null));
        save(a, "quote", UUID.randomUUID(), sunas, weakJob, Map.of(), new LearnedLine(ga, weak, null, "S1R9", false, false));
        assertThat(aliasRow(sunas, "PART_NO", weak, ga)).containsEntry("explicit_count", 0);
        jobResult(weakJob, a, line("S1R9", weak, null, "Z9|白", "REVIEW", ga, null));
        save(a, "quote", UUID.randomUUID(), sunas, weakJob, Map.of(), new LearnedLine(gb, weak, null, "S1R9", true, false));
        assertThat(aliasRow(sunas, "PART_NO", weak, ga)).as("自动学到的错误对应被用户改正后作废").isNull();
        assertThat(aliasRow(sunas, "PART_NO", weak, gb)).containsEntry("explicit_count", 1);

        // 反例: 被人明确选过的对应不会被另一次明确选择删掉(同一叫法确有两种货品, 识别时交给人核对)。
        String firm = "FIRM-" + tag;
        jobResult(weakJob, a, line("S1R9", firm, null, "Z9|白", "REVIEW", ga, null));
        save(a, "quote", UUID.randomUUID(), sunas, weakJob, Map.of(), new LearnedLine(ga, firm, null, "S1R9", true, false));
        save(a, "quote", UUID.randomUUID(), sunas, weakJob, Map.of(), new LearnedLine(gb, firm, null, "S1R9", true, false));
        assertThat(aliasRow(sunas, "PART_NO", firm, ga)).containsEntry("explicit_count", 1);
        assertThat(aliasRow(sunas, "PART_NO", firm, gb)).containsEntry("explicit_count", 1);
    }

    @Test
    void globalAliasConfidenceCountsDistinctClientsNotRepeatedSaves() {
        Seller a = seller("a", SALES_PERMS);
        Seller b = seller("b", SALES_PERMS);
        UUID first = client(a, "C1", "客户一", null, null, null, null);
        UUID third = client(b, "C3", "客户三", null, null, null, null);
        UUID white = color("白色");
        UUID ga = goods("GA", "Z9两开" + tag, "GZ23/D" + tag, "Z9", white, "21", false, false, "使用");
        UUID gb = goods("GB", "Z9两开新款" + tag, "GZ23/DN" + tag, "Z9", white, "21", false, false, "使用");
        String part = "GLOBAL-" + tag;
        UUID jobA = UUID.randomUUID();
        jobResult(jobA, a, line("R1", part, null, "Z9|白", "MATCHED", ga, null));
        UUID jobB = UUID.randomUUID();
        jobResult(jobB, b, line("R1", part, null, "Z9|白", "MATCHED", ga, null));

        // 同一个业务员把两张单据交替反复保存: 全局对照始终只算这一个客户。
        UUID doc1 = UUID.randomUUID();
        UUID doc2 = UUID.randomUUID();
        for (UUID doc : List.of(doc1, doc2, doc1, doc2)) {
            save(a, "quote", doc, first, jobA, Map.of(), new LearnedLine(ga, part, null, "R1", false, false));
        }
        assertThat(aliasRow(null, "PART_NO", part, ga)).containsEntry("confirm_count", 1).containsEntry("explicit_count", 0);

        // 另一个客户的单据(明确选择)确认同一对应: 两个客户, 达到使用门槛。
        UUID doc3 = UUID.randomUUID();
        save(b, "order", doc3, third, jobB, Map.of(), new LearnedLine(ga, part, null, "R1", true, false));
        assertThat(aliasRow(null, "PART_NO", part, ga)).containsEntry("confirm_count", 2).containsEntry("explicit_count", 1);
        fixture.loginAs(a.userId());
        assertThat(lookup.aliases(null, List.of(IntakeTextNormalizer.normalizePart(part)), List.of()))
                .singleElement().satisfies(row -> {
                    assertThat(row.scope()).isEqualTo(AliasScope.GLOBAL);
                    assertThat(row.confirmCount()).isEqualTo(2);
                });

        // 用户在客户资料里删掉自己客户的对照: 这个客户不再算证据, 全局对照随即降回 1。
        UUID firstAlias = db.queryForObject("select id from client_goods_aliases where client_id = ? and alias_text = ?",
                UUID.class, first, part);
        aliasController.delete(first, firstAlias);
        assertThat(aliasRow(null, "PART_NO", part, ga)).containsEntry("confirm_count", 1).containsEntry("explicit_count", 1);

        // 同一张单据改成别的货品: 旧的全局对照已没有任何客户证据, 随撤回删除; 新对应从 1 开始。
        save(b, "order", doc3, third, jobB, Map.of(), new LearnedLine(gb, part, null, "R1", true, false));
        assertThat(aliasRow(third, "PART_NO", part, ga)).isNull();
        assertThat(aliasRow(null, "PART_NO", part, ga)).isNull();
        assertThat(aliasRow(null, "PART_NO", part, gb)).containsEntry("confirm_count", 1).containsEntry("explicit_count", 1);
    }

    @Test
    void clientAliasNeedsWriteScopeWhileGlobalAliasComesOnlyFromJobText() {
        Seller owner = seller("o", SALES_PERMS);
        Seller viewer = seller("v", SALES_PERMS);
        UUID sunas = client(owner, "SUN", "尼日利亚SUNAS", null, null, null, null);
        share(sunas, viewer, owner);
        UUID white = color("白色");
        UUID ga = goods("S1", "Z9两开" + tag, "GZ23/D" + tag, "Z9", white, "21", false, false, "使用");
        String part = "SHARED-" + tag;
        UUID job = UUID.randomUUID();
        jobResult(job, viewer, line("S1R9", part, null, "Z9|白", "MATCHED", ga, null));

        save(viewer, "quote", UUID.randomUUID(), sunas, job, Map.of(), new LearnedLine(ga, part, null, "S1R9", false, false));

        assertThat(aliasRow(sunas, "PART_NO", part, ga)).as("只读共享不能改客户对照").isNull();
        assertThat(aliasRow(null, "PART_NO", part, ga)).isNotNull();
    }

    // ==================================================================
    // 学习: 英文名称
    // ==================================================================

    @Test
    void englishNameIsLearnedOnlyWithTheAuthorityAndOnlyWhenTicked() {
        Seller withCode = seller("w", SALES_PERMS);
        Seller withoutCode = seller("x", "client:view", "client:edit", "sales_quote:create", "goods:view");
        UUID c1 = client(withCode, "C1", "客户一", null, null, null, null);
        UUID c2 = client(withoutCode, "C2", "客户二", null, null, null, null);
        UUID white = color("白色");
        UUID ga = goods("E1", "Z9两开" + tag, "GZ23/D" + tag, "Z9", white, "21", false, false, "使用");
        UUID gb = goods("E2", "Z9一开" + tag, "GK12" + tag, "Z9", white, "9", false, false, "使用");
        UUID gc = goods("E3", "Z9一开旧" + tag, "GK12O" + tag, "Z9", white, "9", false, false, "使用");
        db.update("update goods set name_en = 'Manual Name', name_en_source = 'MANUAL' where id = ?", gb);
        String textA = "DOUBLE SOCKET WITH SWITCH " + tag;
        String textB = "ONE GANG SWITCH " + tag;
        db.update("update goods set name_en = ?, name_en_source = 'MANUAL' where id = ?", "One Gang Switch " + tag, gc);
        UUID job = UUID.randomUUID();
        jobResult(job, withoutCode, line("R1", "P1-" + tag, textA, "", "MATCHED", ga, textA));
        save(withoutCode, "quote", UUID.randomUUID(), c2, job, Map.of(), new LearnedLine(ga, "P1-" + tag, textA, "R1", false, true));
        assertThat(goodsNameEn(ga)).as("没有英文名称权限不写").isNull();

        UUID job2 = UUID.randomUUID();
        jobResult(job2, withCode, line("R1", "P1-" + tag, textA, "", "MATCHED", ga, textA),
                line("R2", "P2-" + tag, "MANUAL OVERRIDE " + tag, "", "MATCHED", gb, null),
                line("R3", "P3-" + tag, textB, "", "MATCHED", gb, null));
        save(withCode, "quote", UUID.randomUUID(), c1, job2, Map.of(),
                new LearnedLine(ga, "P1-" + tag, textA, "R1", false, false));
        assertThat(goodsNameEn(ga)).as("没勾选不写").isNull();

        save(withCode, "quote", UUID.randomUUID(), c1, job2, Map.of(),
                new LearnedLine(ga, "P1-" + tag, textA, "R1", false, true),
                new LearnedLine(gb, "P2-" + tag, "MANUAL OVERRIDE " + tag, "R2", false, true));
        assertThat(goodsNameEn(ga)).isEqualTo(textA);
        assertThat(db.queryForObject("select name_en_source from goods where id = ?", String.class, ga)).isEqualTo("LEARNED");
        assertThat(goodsNameEn(gb)).as("明确勾选时覆盖人工值").isEqualTo("MANUAL OVERRIDE " + tag);

        UUID job3 = UUID.randomUUID();
        jobResult(job3, withCode, line("R3", "P3-" + tag, textB, "", "MATCHED", gb, null));
        save(withCode, "quote", UUID.randomUUID(), c1, job3, Map.of(),
                new LearnedLine(gb, "P3-" + tag, textB, "R3", false, true));
        assertThat(goodsNameEn(gb)).as("与另一个货品的英文名重复时不学").isEqualTo("MANUAL OVERRIDE " + tag);
    }

    // ==================================================================
    // 学习: 客户资料
    // ==================================================================

    @Test
    void clientFieldsAreValidatedBeforeWritingAndAppliedOnlyWithEditAndWriteScope() {
        Seller a = seller("a", SALES_PERMS);
        Seller noEdit = seller("r", "client:view", "sales_quote:create", "goods:view");
        UUID mine = client(a, "M", "尼日利亚SUNAS", null, null, null, null);
        UUID theirs = client(noEdit, "T", "客户乙", null, null, null, null);

        Map<String, String> fields = new LinkedHashMap<>();
        fields.put("email", " buyer@sunas.example ");
        fields.put("address", "Plot 5 Alaba Market Lagos");
        fields.put("nameEn", "SUNAS ELECTRICAL RESOURCE LTD");
        save(a, "quote", UUID.randomUUID(), mine, null, fields);
        Map<String, Object> row = db.queryForMap("select email, address, name_en from clients where id = ?", mine);
        assertThat(row).containsEntry("email", "buyer@sunas.example").containsEntry("address", "Plot 5 Alaba Market Lagos")
                .containsEntry("name_en", "SUNAS ELECTRICAL RESOURCE LTD");
        Map<String, Object> audit = db.queryForMap("""
                select action, result from audit_log
                where action = 'client.learn_from_document' and target_id = ?
                order by created_at desc limit 1
                """, mine.toString());
        assertThat((String) audit.get("result")).contains("邮箱", "地址", "外文名称")
                .doesNotContain("buyer@sunas.example").doesNotContain("Alaba");
        assertThat(contacts(mine, "EMAIL")).as("邮箱记进多联系方式表, 且是主联系方式")
                .containsExactly(Map.entry("buyer@sunas.example", true));

        // 之后在客户资料里增删任意联系方式都会从联系方式表重算平铺列: 学到的邮箱不能被冲掉。
        partyDirectory.addContact(PartyDirectoryService.PartyType.CLIENT, mine, "PHONE", "+234 800 123 4567", true, null);
        assertThat(db.queryForObject("select email from clients where id = ?", String.class, mine))
                .isEqualTo("buyer@sunas.example");

        // 同一个邮箱再学一次: 不重复记。
        save(a, "quote", UUID.randomUUID(), mine, null, Map.of("email", "BUYER@sunas.example"));
        assertThat(contacts(mine, "EMAIL")).hasSize(1);

        // 平铺列里有老邮箱、联系方式表里却没有(老的手工表单只写平铺列): 老邮箱先补成主联系方式, 新邮箱记为次要。
        UUID legacy = client(a, "L", "老客户", "old@legacy.example", null, null, null);
        save(a, "quote", UUID.randomUUID(), legacy, null, Map.of("email", "new@legacy.example"));
        assertThat(contacts(legacy, "EMAIL")).containsExactlyInAnyOrder(
                Map.entry("old@legacy.example", true), Map.entry("new@legacy.example", false));
        assertThat(db.queryForObject("select email from clients where id = ?", String.class, legacy))
                .isEqualTo("old@legacy.example");

        save(noEdit, "quote", UUID.randomUUID(), theirs, null, Map.of("email", "other@buyer.example"));
        assertThat(db.queryForObject("select email from clients where id = ?", String.class, theirs))
                .as("没有 client:edit 不补全").isNull();

        Seller sharedViewer = seller("s", SALES_PERMS);
        share(mine, sharedViewer, a);
        save(sharedViewer, "quote", UUID.randomUUID(), mine, null, Map.of("linkman", "Sunday Adinnu"));
        assertThat(db.queryForObject("select linkman from clients where id = ?", String.class, mine))
                .as("只读共享的客户即使有 client:edit 也不补全").isNull();

        // 不合法: 在保存事务里直接 422, 同一事务里的业务写入一并回滚, 学习也没有登记。
        UUID orderId = UUID.randomUUID();
        fixture.loginAs(a.userId());
        Throwable thrown = catchThrowable(() -> new TransactionTemplate(transactionManager).executeWithoutResult(status -> {
            insertOrderHeader(orderId, mine, a);
            learning.learnAfterCommit(new SalesLearningRequest("order", orderId, mine, a.userId(), a.employeeId(),
                    List.of(), Map.of("email", "not-an-email"), null));
        }));
        assertThat(thrown).isInstanceOf(ApiException.class);
        assertThat(((ApiException) thrown).getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED);
        assertThat(db.queryForObject("select count(*) from sales_orders where id = ?", Integer.class, orderId)).isZero();
    }

    // ==================================================================
    // 学习失败不影响保存
    // ==================================================================

    @Test
    void learningFailureAfterCommitNeverRollsBackTheBusinessSave() {
        Seller a = seller("a", SALES_PERMS);
        UUID sunas = client(a, "SUN", "尼日利亚SUNAS", null, null, null, null);
        UUID white = color("白色");
        UUID ga = goods("F1", "Z9两开" + tag, "GZ23/D" + tag, "Z9", white, "21", false, false, "使用");
        UUID job = UUID.randomUUID();
        jobResult(job, a);
        String poison = "BOOM-" + tag;
        String function = "test_fail_alias_" + tag.toLowerCase(Locale.ROOT);
        db.execute("CREATE FUNCTION " + function + "() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN "
                + "IF NEW.alias_text LIKE 'BOOM-%' THEN RAISE EXCEPTION 'simulated learning failure'; END IF; "
                + "RETURN NEW; END $$");
        db.execute("CREATE TRIGGER " + function + " BEFORE INSERT ON client_goods_aliases "
                + "FOR EACH ROW EXECUTE FUNCTION " + function + "()");
        try {
            UUID orderId = UUID.randomUUID();
            fixture.loginAs(a.userId());
            new TransactionTemplate(transactionManager).executeWithoutResult(status -> {
                insertOrderHeader(orderId, sunas, a);
                learning.learnAfterCommit(new SalesLearningRequest("order", orderId, sunas, a.userId(), a.employeeId(),
                        List.of(new LearnedLine(ga, poison, null, null, true, false)),
                        Map.of("email", "kept@sunas.example"), job));
            });

            assertThat(db.queryForObject("select count(*) from sales_orders where id = ?", Integer.class, orderId))
                    .as("保存已提交").isEqualTo(1);
            assertThat(countAliases(sunas, poison)).isZero();
            assertThat(db.queryForObject("select email from clients where id = ?", String.class, sunas))
                    .as("同一学习事务里的客户资料补全一并回滚").isNull();
            assertThat(contacts(sunas, "EMAIL")).isEmpty();
            verify(jobUsage).markUsed(eq(job), eq(a.userId()), eq("order"), eq(orderId));
        } finally {
            db.execute("DROP TRIGGER " + function + " ON client_goods_aliases");
            db.execute("DROP FUNCTION " + function + "()");
        }
    }

    // ==================================================================
    // 用文件信息新建客户
    // ==================================================================

    @Test
    void createClientFromDocumentProbesDuplicatesAcrossAllClientsWithoutLeakingOthers() {
        Seller a = seller("a", SALES_PERMS);
        Seller b = seller("b", SALES_PERMS);
        Seller cannotCreate = seller("c", "client:view", "sales_quote:create");
        UUID mine = client(a, "M", "尼日利亚SUNAS", "sunas@buyer.example", null, null, "SUNAS ELECTRICAL RESOURCE LTD");
        client(b, "T", "Shami", null, "+962 6 739 5151", null, null);

        fixture.loginAs(a.userId());
        ApiException visible = catchApi(() -> fromDocumentController.create(request("SUNAS " + tag, null,
                null, "SUNAS@buyer.example", null)));
        assertThat(visible.getCode()).isEqualTo(ErrorCode.CONFLICT);
        assertThat(visible.getFieldErrors()).singleElement()
                .satisfies(error -> {
                    assertThat(error.field()).isEqualTo("existingClientId");
                    assertThat(error.message()).isEqualTo(mine.toString());
                });

        ApiException byName = catchApi(() -> fromDocumentController.create(request("New " + tag,
                "Sunas Electrical Resource Ltd.", null, null, null)));
        assertThat(byName.getFieldErrors()).singleElement()
                .extracting(com.uten.imp.common.web.ApiError.FieldError::message).isEqualTo(mine.toString());

        ApiException hidden = catchApi(() -> fromDocumentController.create(request("ALDAR " + tag, null,
                null, null, "00962-6-7395151")));
        assertThat(hidden.getCode()).isEqualTo(ErrorCode.CONFLICT);
        assertThat(hidden.getFieldErrors()).as("看不到的客户不回传 id").isNull();
        assertThat(hidden.getMessage()).doesNotContain("Shami");

        String longName = "ALDAR FOR ELECTRICAL INDUSTRIES AND TRADING COMPANY LIMITED " + tag + " EXTRA WORDS HERE";
        ClientFromDocumentController.CreatedClientResponse created = fromDocumentController.create(
                request(longName, longName, "ALDAR FOR ELECTRICAL " + tag, "ops@aldar-" + tag.toLowerCase(Locale.ROOT)
                        + ".example", null));
        Map<String, Object> row = db.queryForMap("""
                select c.name, c.full_name, c.name_en, c.email, c.owner_employee_id, c.code, c.status,
                       c.category_id = (select client_category_id from system_master_category_registry limit 1) as uncategorized
                from clients c where c.id = ?
                """, created.clientId());
        assertThat((String) row.get("name")).hasSizeLessThanOrEqualTo(64).startsWith("ALDAR FOR ELECTRICAL");
        assertThat(row).containsEntry("full_name", longName).containsEntry("owner_employee_id", a.employeeId())
                .containsEntry("status", "使用").containsEntry("uncategorized", true);
        assertThat((String) row.get("code")).isNotBlank().isEqualTo(created.code());
        String createdEmail = "ops@aldar-" + tag.toLowerCase(Locale.ROOT) + ".example";
        assertThat(row).containsEntry("email", createdEmail);
        assertThat(contacts(created.clientId(), "EMAIL")).as("新客户的邮箱同样记进多联系方式表")
                .containsExactly(Map.entry(createdEmail, true));

        fixture.loginAs(cannotCreate.userId());
        assertThat(catchThrowable(() -> fromDocumentController.create(request("X " + tag, null, null, null, null))))
                .isInstanceOf(AccessDeniedException.class);
    }

    // ==================================================================
    // 货品对照接口
    // ==================================================================

    @Test
    void aliasApiEnforcesClientScopeAndRejectsCrossClientIds() {
        Seller a = seller("a", SALES_PERMS);
        Seller b = seller("b", SALES_PERMS);
        Seller viewer = seller("v", SALES_PERMS);
        UUID sunas = client(a, "SUN", "尼日利亚SUNAS", null, null, null, null);
        UUID second = client(a, "SEC", "第二客户", null, null, null, null);
        share(sunas, viewer, a);
        UUID white = color("白色");
        UUID ga = goods("P1", "Z9两开" + tag, "GZ23/D" + tag, "Z9", white, "21", false, false, "使用");
        UUID job = UUID.randomUUID();
        String part = "API-" + tag;
        jobResult(job, a, line("S1R9", part, null, "Z9|白", "MATCHED", ga, null));
        save(a, "quote", UUID.randomUUID(), sunas, job, Map.of(), new LearnedLine(ga, part, null, "S1R9", false, false));
        UUID aliasId = db.queryForObject("select id from client_goods_aliases where client_id = ? and alias_text = ?",
                UUID.class, sunas, part);
        UUID globalId = db.queryForObject("select id from client_goods_aliases where client_id is null and alias_text = ?",
                UUID.class, part);

        fixture.loginAs(a.userId());
        PageResponse<ClientGoodsAliasView> page = aliasController.list(sunas, null, 1, 20);
        assertThat(page.getItems()).singleElement().satisfies(view -> {
            assertThat(view.aliasText()).isEqualTo(part);
            assertThat(view.scope()).isEqualTo("CLIENT");
            assertThat(view.contextText()).isEqualTo("Z9 · 白");
            assertThat(view.goods().id()).isEqualTo(ga);
            assertThat(view.goods().colorName()).isEqualTo("白色");
            assertThat(view.canDelete()).isTrue();
            assertThat(view.lastConfirmedByName()).contains("(EMP-");
        });
        assertThat(aliasController.list(sunas, "zzz-nothing", 1, 20).getItems()).isEmpty();
        assertThat(aliasController.list(sunas, "gz23/d" + tag.toLowerCase(Locale.ROOT), 1, 20).getItems()).hasSize(1);

        assertThat(catchApi(() -> aliasController.delete(second, aliasId)).getCode())
                .as("对照不属于路径上的客户").isEqualTo(ErrorCode.NOT_FOUND);
        assertThat(catchApi(() -> aliasController.delete(sunas, globalId)).getCode())
                .as("全局对照不能从客户资料删除").isEqualTo(ErrorCode.NOT_FOUND);

        fixture.loginAs(b.userId());
        assertThat(catchApi(() -> aliasController.list(sunas, null, 1, 20)).getCode()).isEqualTo(ErrorCode.NOT_FOUND);
        assertThat(catchApi(() -> aliasController.delete(sunas, aliasId)).getCode()).isEqualTo(ErrorCode.NOT_FOUND);

        fixture.loginAs(viewer.userId());
        assertThat(aliasController.list(sunas, null, 1, 20).getItems()).singleElement()
                .extracting(ClientGoodsAliasView::canDelete).isEqualTo(false);
        assertThat(catchApi(() -> aliasController.delete(sunas, aliasId)).getCode()).isEqualTo(ErrorCode.FORBIDDEN);

        fixture.loginAs(a.userId());
        aliasController.delete(sunas, aliasId);
        assertThat(db.queryForObject("select count(*) from client_goods_aliases where id = ?", Integer.class, aliasId))
                .isZero();
        assertThat(db.queryForObject("select count(*) from audit_log where action = 'client_goods_alias.delete' "
                + "and target_id = ?", Integer.class, aliasId.toString())).isEqualTo(1);
    }

    // ==================================================================
    // 基础资料: 英文名称接口与搜索
    // ==================================================================

    @Test
    void goodsNameEnEndpointAndKeywordSearchIncludeTheEnglishNames() {
        Seller editor = seller("e", "goods:view", "goods:name_en:edit", "client:view", "client:edit");
        Seller reader = seller("r", "goods:view");
        UUID white = color("白色");
        UUID ga = goods("G1", "Z9两开" + tag, "GZ23/D" + tag, "Z9", white, "21", false, false, "使用");
        UUID sunas = client(editor, "SUN", "尼日利亚SUNAS", "orders@sunas-" + tag.toLowerCase(Locale.ROOT) + ".example",
                null, null, "SUNAS RESOURCE " + tag);

        fixture.loginAs(reader.userId());
        assertThat(goodsService.detail(ga).isCanEditNameEn()).isFalse();
        assertThat(catchThrowable(() -> goodsController.updateNameEn(ga, new GoodsNameEnRequest("X Y", null))))
                .isInstanceOf(AccessDeniedException.class);

        fixture.loginAs(editor.userId());
        var detail = goodsService.detail(ga);
        assertThat(detail.isCanEditNameEn()).isTrue();
        var updated = goodsController.updateNameEn(ga, new GoodsNameEnRequest("  Double Socket " + tag + " ", detail.getVersion()));
        assertThat(updated.getNameEn()).isEqualTo("Double Socket " + tag);
        assertThat(updated.getNameEnSource()).isEqualTo("MANUAL");
        assertThat(updated.getVersion()).isGreaterThan(detail.getVersion());
        assertThat(catchApi(() -> goodsController.updateNameEn(ga, new GoodsNameEnRequest("Other", detail.getVersion())))
                .getCode()).isEqualTo(ErrorCode.CONFLICT);

        // 按 id 批量解析(销售单据手工选货品时预填「文件品名」)同样带英文名称。
        fixture.loginAs(reader.userId());
        assertThat(goodsController.lookup(Set.of(ga))).singleElement()
                .satisfies(item -> assertThat(item.getNameEn()).isEqualTo("Double Socket " + tag));
        fixture.loginAs(editor.userId());

        var goodsPage = goodsService.list(goodsFilter("double socket " + tag.toLowerCase(Locale.ROOT)), 1, 20, null, null);
        assertThat(goodsPage.getItems()).extracting(item -> item.getId()).containsExactly(ga);
        assertThat(goodsPage.getItems().getFirst().getNameEn()).isEqualTo("Double Socket " + tag);

        var byNameEn = clientService.list(clientFilter("sunas resource " + tag.toLowerCase(Locale.ROOT)), 1, 20, null, null);
        assertThat(byNameEn.getItems()).extracting(item -> item.getId()).containsExactly(sunas);
        assertThat(byNameEn.getItems().getFirst().getNameEn()).isEqualTo("SUNAS RESOURCE " + tag);
        var byEmail = clientService.list(clientFilter("orders@sunas-" + tag.toLowerCase(Locale.ROOT)), 1, 20, null, null);
        assertThat(byEmail.getItems()).extracting(item -> item.getId()).containsExactly(sunas);

        // 导出与表格一致: 英文名称紧跟货品名称, 外文名称紧跟客户全称。
        var goodsExport = goodsService.export(goodsFilter("double socket " + tag.toLowerCase(Locale.ROOT)), null, null, 100);
        List<String> goodsLabels = goodsExport.columns().stream().map(column -> column.label()).toList();
        assertThat(goodsLabels.indexOf("英文名称")).isEqualTo(goodsLabels.indexOf("货品名称") + 1);
        assertThat(goodsExport.rows()).singleElement().satisfies(row ->
                assertThat(row).containsEntry("nameEn", "Double Socket " + tag));
        var clientExport = clientService.export(clientFilter("sunas resource " + tag.toLowerCase(Locale.ROOT)), null, null, 100);
        List<String> clientLabels = clientExport.columns().stream().map(column -> column.label()).toList();
        assertThat(clientLabels.indexOf("外文名称")).isEqualTo(clientLabels.indexOf("客户全称") + 1);
        assertThat(clientExport.rows()).singleElement().satisfies(row ->
                assertThat(row).containsEntry("nameEn", "SUNAS RESOURCE " + tag));
    }

    // ==================================================================
    // 夹具
    // ==================================================================

    private record Seller(UUID userId, UUID employeeId) {
    }

    private Seller seller(String role, String... perms) {
        UUID user = fixture.createUserWithPerms(world, role + "-" + tag, perms);
        UUID employee = db.queryForObject("select employee_id from users where id = ?", UUID.class, user);
        return new Seller(user, employee);
    }

    private UUID client(Seller owner, String code, String name, String email, String phone, String place, String nameEn) {
        UUID id = UUID.randomUUID();
        db.update("""
                insert into clients(id, code, name, status, code_sequence, owner_employee_id, email, phone,
                                    place_id, name_en)
                values (?, ?, ?, '使用', (select coalesce(max(code_sequence), 0) + 1 from clients), ?, ?, ?, ?, ?)
                """, id, code + "-" + tag, name, owner.employeeId(), email, phone, place, nameEn);
        return id;
    }

    private void share(UUID clientId, Seller grantee, Seller grantedBy) {
        db.update("""
                insert into client_visibility_grants(client_id, grantee_employee_id, granted_by_user_id)
                values (?, ?, ?)
                """, clientId, grantee.employeeId(), grantedBy.userId());
    }

    private UUID color(String name) {
        UUID id = UUID.randomUUID();
        db.update("insert into colors(id, code, name, status) values (?, ?, ?, '使用')",
                id, "CLR-" + UUID.randomUUID().toString().substring(0, 8), name);
        return id;
    }

    private UUID goods(String code, String name, String model, String series, UUID colorId, String price,
                       boolean stub, boolean deleted, String status) {
        UUID id = UUID.randomUUID();
        db.update("""
                insert into goods(id, code, name, model, series, color_id, source_type, status, unit_id,
                                  unit_legacy_id, price, code_sequence, auto_created)
                values (?, ?, ?, ?, ?, ?, '自制', ?, ?, ?, ?,
                        (select coalesce(max(code_sequence), 0) + 1 from goods), ?)
                """, id, code + "-" + tag, name, model, series, colorId, status, world.unitId(), world.unitLegacy(),
                new BigDecimal(price), stub);
        if (deleted) {
            db.update("update goods set is_deleted = true, deleted_at = now() where id = ?", id);
        }
        return id;
    }

    private UUID order(UUID clientId, Seller owner, short status, UUID... goodsIds) {
        UUID id = UUID.randomUUID();
        String billNo = docNumbers.nextNumber(DocNumberPrefix.SALES_ORDER);
        db.update("""
                insert into sales_orders(id, bill_no, bill_date, client_id, owner_employee_id, maker_id, status,
                                         contract_no)
                values (?, ?, current_date, ?, ?, ?, ?, ?)
                """, id, billNo, clientId, owner.employeeId(), owner.employeeId(), status, "PO-" + tag);
        for (UUID goodsId : goodsIds) {
            db.update("""
                    insert into sales_order_items(id, order_id, bill_no, bill_date, goods_id, qty,
                        goods_code_snapshot, goods_name_snapshot, goods_snapshot_source, goods_snapshot_locked_at)
                    values (gen_random_uuid(), ?, ?, current_date, ?, 10, 'SNAP', 'snapshot', 'MASTER_AT_APPROVAL', now())
                    """, id, billNo, goodsId);
        }
        return id;
    }

    private UUID quote(UUID clientId, Seller maker, short status, UUID... goodsIds) {
        UUID id = UUID.randomUUID();
        String billNo = docNumbers.nextNumber(DocNumberPrefix.SALES_QUOTE);
        db.update("""
                insert into sales_quotes(id, bill_no, bill_date, client_id, maker_id, status, contract_no)
                values (?, ?, current_date, ?, ?, ?, ?)
                """, id, billNo, clientId, maker.employeeId(), status, "QC-" + tag);
        for (UUID goodsId : goodsIds) {
            db.update("""
                    insert into sales_quote_items(id, quote_id, bill_no, bill_date, goods_id, qty,
                        goods_code_snapshot, goods_name_snapshot, goods_snapshot_source)
                    values (gen_random_uuid(), ?, ?, current_date, ?, 10, 'SNAP', 'snapshot', 'MASTER_AT_SAVE')
                    """, id, billNo, goodsId);
        }
        return id;
    }

    /** 客户某类联系方式: 值 → 是否主联系方式。 */
    private List<Map.Entry<String, Boolean>> contacts(UUID clientId, String kind) {
        return db.query("""
                        select value, is_primary from party_contact_methods
                        where party_type = 'CLIENT' and party_id = ? and kind = ?
                        order by created_at, value
                        """,
                (rs, rowNum) -> Map.entry(rs.getString("value"), rs.getBoolean("is_primary")), clientId, kind);
    }

    private void insertOrderHeader(UUID id, UUID clientId, Seller owner) {
        db.update("""
                insert into sales_orders(id, bill_no, bill_date, client_id, owner_employee_id, maker_id, status)
                values (?, ?, current_date, ?, ?, ?, 0)
                """, id, docNumbers.nextNumber(DocNumberPrefix.SALES_ORDER), clientId, owner.employeeId(),
                owner.employeeId());
    }

    /** 模拟一次保存: 在事务里调用学习入口, 提交后学习在独立事务里执行。 */
    private void save(Seller actor, String docType, UUID docId, UUID clientId, UUID jobId,
                      Map<String, String> clientFields, LearnedLine... lines) {
        fixture.loginAs(actor.userId());
        new TransactionTemplate(transactionManager).executeWithoutResult(status ->
                learning.learnAfterCommit(new SalesLearningRequest(docType, docId, clientId, actor.userId(),
                        actor.employeeId(), List.of(lines), clientFields, jobId)));
    }

    @SafeVarargs
    private void jobResult(UUID jobId, Seller owner, Map<String, Object>... lines) {
        Map<String, Object> result = new HashMap<>();
        result.put("schemaVersion", 2);
        result.put("lines", List.of(lines));
        when(jobUsage.resultFor(jobId, owner.userId())).thenReturn(Optional.of(result));
    }

    private static Map<String, Object> line(String key, String partNo, String description, String context,
                                            String status, UUID selected, String nameEnText) {
        Map<String, Object> line = new HashMap<>();
        line.put("key", key);
        line.put("partNo", partNo);
        line.put("description", description);
        line.put("contextNorm", context);
        line.put("status", status);
        line.put("selectedGoodsId", selected == null ? null : selected.toString());
        line.put("nameEnText", nameEnText);
        return line;
    }

    private Map<String, Object> aliasRow(UUID clientId, String kind, String text, UUID goodsId) {
        String norm = "PART_NO".equals(kind)
                ? IntakeTextNormalizer.normalizePart(text) : IntakeTextNormalizer.normalizeDescription(text);
        List<Map<String, Object>> rows = db.queryForList("""
                select confirm_count, explicit_count, context_norm, last_source_doc_type, alias_text
                from client_goods_aliases
                where client_id is not distinct from ? and alias_kind = ? and alias_norm = ? and goods_id = ?
                """, clientId, kind, norm, goodsId);
        return rows.isEmpty() ? null : rows.getFirst();
    }

    private int countAliases(UUID clientId, String text) {
        Integer count = db.queryForObject(
                "select count(*) from client_goods_aliases where client_id = ? and alias_text = ?",
                Integer.class, clientId, text);
        return count == null ? 0 : count;
    }

    private String goodsNameEn(UUID goodsId) {
        return db.queryForObject("select name_en from goods where id = ?", String.class, goodsId);
    }

    private static ClientCandidateQuery query(Set<String> emails, Set<String> domains, Set<String> phones,
                                              Set<String> nameEnNorms, List<String> nameTexts, Set<String> tokens,
                                              Set<String> places) {
        return new ClientCandidateQuery(emails, domains, phones, nameEnNorms, nameTexts, tokens, places, 0.5, 10);
    }

    private static ClientCandidate single(List<ClientCandidate> candidates) {
        assertThat(candidates).hasSize(1);
        return candidates.getFirst();
    }

    private static ClientFromDocumentController.Request request(String name, String fullName, String nameEn,
                                                                String email, String phone) {
        return new ClientFromDocumentController.Request(name, fullName, nameEn, null, email, phone, null, null, null);
    }

    private static ApiException catchApi(org.assertj.core.api.ThrowableAssert.ThrowingCallable call) {
        Throwable thrown = catchThrowable(call);
        assertThat(thrown).isInstanceOf(ApiException.class);
        return (ApiException) thrown;
    }

    private static GoodsQueryFilter goodsFilter(String keyword) {
        return new GoodsQueryFilter(null, null, keyword, Set.of(), null, null, null, null, null, null, null, null,
                null, null, null, null, null, null, null, null, null, null, null, null);
    }

    private static ClientQueryFilter clientFilter(String keyword) {
        return new ClientQueryFilter(null, keyword, Set.of(), null, null, null, null, null, null, null,
                null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null,
                true, false);
    }
}
