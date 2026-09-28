package com.uten.imp.features.master.learning;

import com.uten.imp.application.port.MasterIntakeLookupPort;
import com.uten.imp.application.port.SalesDocumentReadScopePort;
import com.uten.imp.common.text.IntakeTextNormalizer;
import com.uten.imp.common.util.NativeValueConverters;
import com.uten.imp.features.master.client.ClientAccessPolicy;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.DocumentAccessPolicy;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import lombok.RequiredArgsConstructor;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.Collection;
import java.util.EnumSet;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/**
 * 客户文件识别读取主档的实现(ADR-134, {@link MasterIntakeLookupPort})。
 *
 * <p>全部按<b>当前登录人</b>的数据范围: 客户只返回看得到(负责人范围、交接、数据范围授权、单客户共享)
 * 且启用中的; 货品只返回状态「使用」、未删除、非占位的, 货品归属隔离开关打开时再按归属人过滤。
 * 每个方法都是按索引批量召回的原生 SQL(型号走 idx_goods_model_norm 同一表达式, 英文名称走
 * idx_goods_name_en_trgm, 对照走唯一键前缀), 中文品名走 {@link GoodsNameCatalog} 内存索引。
 * 只召回与提供证据, 打分全在识别侧; 这里不做任何金额计算。
 */
@Service
@RequiredArgsConstructor
@Transactional(readOnly = true)
public class MasterIntakeLookupAdapter implements MasterIntakeLookupPort {

    /** 单条 IN 列表的上限(PG 绑定参数上限 32767, 留足余量), 超过分批。 */
    static final int IN_CHUNK = 1000;
    /** 近期单据最多返回多少张。 */
    static final int RECENT_DOCS_MAX = 200;
    /** 客户历史货品池上限(SPEC: 客户买过的货品 ≤ 500)。 */
    static final int HISTORY_POOL_MAX = 500;
    /** 每段英文召回的上限。 */
    static final int NAME_EN_PER_TEXT = 20;
    /** 型号召回整批上限(GK12 一类通用型号在几十个系列都有)。 */
    static final int MODEL_ROWS_MAX = 5000;
    /** 名称相似召回最多比较几段买方名称。 */
    static final int NAME_TEXTS_MAX = 5;
    /** 篮子重合度不限客户(空客户集合)时, 按买过的候选货品数最多返回几个客户。 */
    static final int BASKET_CLIENTS_MAX = 50;
    /** 篮子重合度不限客户时最多带几个候选货品(一个参数列表, 远低于 PG 绑定参数上限)。 */
    static final int BASKET_GOODS_MAX = 4000;

    /** 与 V742 idx_goods_model_norm 完全相同的表达式(改一处必须同时改索引)。 */
    public static final String MODEL_NORM_EXPR = "regexp_replace(upper(regexp_replace("
            + "translate(normalize(coalesce(g.model, ''), NFKC), '／－—–', '/---'), '\\s+', '', 'g')), '\\.$', '')";

    private static final String GOODS_COLUMNS = """
            SELECT g.id, g.code, g.name, g.model, g.series, g.spec, g.color_id, col.name AS color_name,
                   g.unit_id, u.name AS unit_name, g.name_en, g.name_en_source, g.price, g.status
            FROM goods g
            LEFT JOIN colors col ON col.id = g.color_id
            LEFT JOIN units u ON u.id = g.unit_id
            WHERE NOT g.is_deleted AND g.status = '使用' AND NOT g.auto_created
            """;

    /** 客户基础过滤: 未删除、启用、非旧库财务占位客户。 */
    private static final String CLIENT_ACTIVE = """
            NOT c.is_deleted AND c.status = '使用'
            AND (c.code IS NULL OR lower(c.code) NOT LIKE 'legacy-fin-cl-%')
            """;

    private final EntityManager em;
    private final ClientAccessPolicy clientAccess;
    private final OwnerVisibility ownerVisibility;
    private final SecurityContextCurrentUser currentUser;
    private final SalesDocumentReadScopePort salesScope;
    private final GoodsNameCatalog nameCatalog;
    private final ClientFromDocumentService fromDocument;

    /** 与 GoodsService 同一开关: 货品默认全员可见, 打开后按外贸归属人隔离。 */
    @Value("${uten.features.goods-owner-scope-enabled:false}")
    private boolean goodsOwnerScopeEnabled;

    // ------------------------------------------------------------------
    // 客户
    // ------------------------------------------------------------------

    @Override
    @SuppressWarnings("unchecked")
    public List<ClientCandidate> clientCandidates(ClientCandidateQuery q) {
        if (q == null) return List.of();
        Set<String> emails = lowerAll(q.emails());
        Set<String> domains = lowerAll(q.emailDomains());
        Set<String> phones = digitsOnly(q.phoneLast8());
        Set<String> tokens = upperAll(q.distinctiveTokens());
        Set<String> places = trimAll(q.placeIds());
        // 外文名称比较一律按 normalizeDescription(幂等)重新规范化, 调用方少去了哪些标点都不影响精确命中。
        Set<String> nameEnNorms = new LinkedHashSet<>();
        for (String norm : trimAll(q.nameEnNorms())) {
            String key = IntakeTextNormalizer.normalizeDescription(norm);
            if (!key.isEmpty()) nameEnNorms.add(key);
        }
        Set<String> nameEnLower = new HashSet<>();
        Set<String> nameEnCompact = new HashSet<>();
        for (String norm : trimAll(q.nameEnNorms())) {
            nameEnLower.add(norm.toLowerCase(Locale.ROOT));
            String compact = compactAscii(norm);
            if (compact.length() >= 3) nameEnCompact.add(compact);
        }
        List<String> nameTexts = new ArrayList<>();
        for (String text : q.nameTexts()) {
            String cleaned = ClientDocumentFields.clean(text);
            if (cleaned != null && nameTexts.size() < NAME_TEXTS_MAX) {
                nameTexts.add(cleaned.length() > 300 ? cleaned.substring(0, 300) : cleaned);
            }
        }
        double minSimilarity = q.minNameSimilarity() <= 0 ? 0.5 : Math.min(1.0, q.minNameSimilarity());
        int limit = q.limit() <= 0 ? 10 : Math.min(q.limit(), 50);
        if (emails.isEmpty() && domains.isEmpty() && phones.isEmpty() && tokens.isEmpty()
                && places.isEmpty() && nameEnLower.isEmpty() && nameTexts.isEmpty()) {
            return List.of();
        }

        String emailHit = emails.isEmpty() ? "FALSE" : """
                (EXISTS (SELECT 1 FROM regexp_split_to_table(lower(coalesce(c.email, '')), '[\\s,;/]+') AS e(v)
                         WHERE e.v IN (:emails))
                 OR EXISTS (SELECT 1 FROM party_contact_methods m
                            WHERE m.party_type = 'CLIENT' AND m.party_id = c.id AND m.kind = 'EMAIL'
                              AND lower(btrim(m.value)) IN (:emails)))
                """;
        String domainHit = domains.isEmpty() ? "FALSE" : """
                (EXISTS (SELECT 1 FROM regexp_split_to_table(lower(coalesce(c.email, '')), '[\\s,;/]+') AS e(v)
                         WHERE split_part(e.v, '@', 2) IN (:domains))
                 OR EXISTS (SELECT 1 FROM party_contact_methods m
                            WHERE m.party_type = 'CLIENT' AND m.party_id = c.id AND m.kind = 'EMAIL'
                              AND split_part(lower(btrim(m.value)), '@', 2) IN (:domains)))
                """;
        String phoneHit = phones.isEmpty() ? "FALSE" : """
                (EXISTS (SELECT 1
                         FROM unnest(ARRAY[c.phone, c.phone2, c.mobile, c.fax]) AS p(v),
                              regexp_split_to_table(coalesce(p.v, ''), '[,;/]+') AS part(v)
                         WHERE length(regexp_replace(part.v, '\\D', '', 'g')) >= 8
                           AND right(regexp_replace(part.v, '\\D', '', 'g'), 8) IN (:phones))
                 OR EXISTS (SELECT 1 FROM party_contact_methods m
                            WHERE m.party_type = 'CLIENT' AND m.party_id = c.id
                              AND m.kind IN ('PHONE', 'MOBILE', 'FAX')
                              AND length(regexp_replace(m.value, '\\D', '', 'g')) >= 8
                              AND right(regexp_replace(m.value, '\\D', '', 'g'), 8) IN (:phones)))
                """;
        String tokenHit = tokens.isEmpty() ? "CAST(NULL AS text)" : """
                (SELECT string_agg(DISTINCT t.v, ' ')
                 FROM regexp_split_to_table(upper(normalize(coalesce(c.name, '') || ' ' || coalesce(c.full_name, '')
                                                  || ' ' || coalesce(c.name_en, ''), NFKC)), '[^A-Z0-9]+') AS t(v)
                 WHERE t.v IN (:tokens))
                """;
        List<String> nameEnParts = new ArrayList<>();
        if (!nameEnLower.isEmpty()) nameEnParts.add("lower(btrim(c.name_en)) IN (:nameEnLower)");
        if (!nameEnCompact.isEmpty()) {
            nameEnParts.add("regexp_replace(lower(normalize(c.name_en, NFKC)), '[^a-z0-9]+', '', 'g') IN (:nameEnCompact)");
        }
        String nameEnHit = nameEnParts.isEmpty() ? "FALSE"
                : "(c.name_en IS NOT NULL AND (" + String.join(" OR ", nameEnParts) + "))";
        String placeHit = places.isEmpty() ? "FALSE" : "(btrim(c.place_id) IN (:places))";
        StringBuilder similarity = new StringBuilder("CAST(0 AS double precision)");
        if (!nameTexts.isEmpty()) {
            List<String> parts = new ArrayList<>();
            for (int i = 0; i < nameTexts.size(); i++) {
                for (String column : List.of("c.name", "c.full_name", "c.name_en")) {
                    parts.add("word_similarity(" + spaced(column) + ", CAST(:nameText" + i + " AS text))");
                }
            }
            similarity = new StringBuilder("coalesce(GREATEST(" + String.join(", ", parts) + "), 0)");
        }

        ClientAccessPolicy.NativeReadScope scope = clientAccess.nativeReadScope("c", clientAccess.evaluate());
        String sql = """
                SELECT x.id, x.code, x.name, x.full_name, x.name_en, x.place_id,
                       x.email_hit, x.domain_hit, x.phone_hit, x.tokens, x.name_en_hit, x.place_hit, x.sim
                FROM (
                    SELECT c.id, c.code, c.name, c.full_name, c.name_en, c.place_id,
                           {EMAIL} AS email_hit, {DOMAIN} AS domain_hit, {PHONE} AS phone_hit,
                           {TOKENS} AS tokens, {NAME_EN} AS name_en_hit, {PLACE} AS place_hit,
                           {SIM} AS sim
                    FROM clients c
                    WHERE {ACTIVE} AND {SCOPE}
                ) x
                WHERE x.email_hit OR x.domain_hit OR x.phone_hit OR x.tokens IS NOT NULL
                   OR x.name_en_hit OR x.place_hit OR x.sim >= :minSim
                ORDER BY x.email_hit DESC, x.name_en_hit DESC, x.phone_hit DESC, x.sim DESC, x.code, x.id
                LIMIT 500
                """
                .replace("{EMAIL}", emailHit)
                .replace("{DOMAIN}", domainHit)
                .replace("{PHONE}", phoneHit)
                .replace("{TOKENS}", tokenHit)
                .replace("{NAME_EN}", nameEnHit)
                .replace("{PLACE}", placeHit)
                .replace("{SIM}", similarity)
                .replace("{ACTIVE}", CLIENT_ACTIVE)
                .replace("{SCOPE}", scope.predicate());
        Query query = em.createNativeQuery(sql);
        scope.bind(query);
        if (!emails.isEmpty()) query.setParameter("emails", emails);
        if (!domains.isEmpty()) query.setParameter("domains", domains);
        if (!phones.isEmpty()) query.setParameter("phones", phones);
        if (!tokens.isEmpty()) query.setParameter("tokens", tokens);
        if (!nameEnLower.isEmpty()) query.setParameter("nameEnLower", nameEnLower);
        if (!nameEnCompact.isEmpty()) query.setParameter("nameEnCompact", nameEnCompact);
        if (!places.isEmpty()) query.setParameter("places", places);
        for (int i = 0; i < nameTexts.size(); i++) query.setParameter("nameText" + i, nameTexts.get(i));
        query.setParameter("minSim", minSimilarity);

        List<ClientCandidate> candidates = new ArrayList<>();
        for (Object[] row : (List<Object[]>) query.getResultList()) {
            EnumSet<ClientSignal> signals = EnumSet.noneOf(ClientSignal.class);
            if (Boolean.TRUE.equals(row[6])) signals.add(ClientSignal.EMAIL);
            if (Boolean.TRUE.equals(row[7])) signals.add(ClientSignal.EMAIL_DOMAIN);
            if (Boolean.TRUE.equals(row[8])) signals.add(ClientSignal.PHONE);
            Set<String> matchedTokens = new LinkedHashSet<>();
            if (row[9] != null) {
                for (String token : row[9].toString().split(" ")) {
                    if (!token.isBlank()) matchedTokens.add(token);
                }
                if (!matchedTokens.isEmpty()) signals.add(ClientSignal.TOKEN);
            }
            String nameEn = (String) row[4];
            if (Boolean.TRUE.equals(row[10]) && nameEn != null
                    && nameEnNorms.contains(IntakeTextNormalizer.normalizeDescription(nameEn))) {
                signals.add(ClientSignal.NAME_EN_EXACT);
            }
            if (Boolean.TRUE.equals(row[11])) signals.add(ClientSignal.PLACE);
            double sim = row[12] == null ? 0 : ((Number) row[12]).doubleValue();
            if (sim >= minSimilarity) signals.add(ClientSignal.NAME_SIMILARITY);
            if (signals.isEmpty()) continue;
            candidates.add(new ClientCandidate((UUID) row[0], (String) row[1], (String) row[2], (String) row[3],
                    nameEn, (String) row[5], signals, matchedTokens, sim));
        }
        candidates.sort((a, b) -> {
            int byStrength = Integer.compare(strength(b), strength(a));
            if (byStrength != 0) return byStrength;
            int bySim = Double.compare(b.nameSimilarity(), a.nameSimilarity());
            if (bySim != 0) return bySim;
            return Objects.toString(a.code(), "").compareTo(Objects.toString(b.code(), ""));
        });
        return candidates.size() > limit ? List.copyOf(candidates.subList(0, limit)) : List.copyOf(candidates);
    }

    /** 排序用的强度: 强线索优先, 只靠国家/地区召回的排最后。 */
    private static int strength(ClientCandidate candidate) {
        int score = 0;
        for (ClientSignal signal : candidate.signals()) {
            score += switch (signal) {
                case EMAIL -> 1000;
                case NAME_EN_EXACT -> 900;
                case PHONE -> 800;
                case TOKEN -> 700;
                case EMAIL_DOMAIN -> 600;
                case NAME_SIMILARITY -> 300;
                case PLACE -> 10;
            };
        }
        return score;
    }

    /** 名称里中文与英文/数字挨着时插入空格, 让 pg_trgm 把它们当成两个词(「尼日利亚SUNAS」→「尼日利亚 SUNAS」)。 */
    private static String spaced(String column) {
        return "regexp_replace(regexp_replace(coalesce(" + column + ", ''), "
                + "'([一-鿿])([A-Za-z0-9])', '\\1 \\2', 'g'), '([A-Za-z0-9])([一-鿿])', '\\1 \\2', 'g')";
    }

    @Override
    public int visibleActiveClientCount() {
        ClientAccessPolicy.NativeReadScope scope = clientAccess.nativeReadScope("c", clientAccess.evaluate());
        Query query = em.createNativeQuery(
                "SELECT count(*) FROM clients c WHERE " + CLIENT_ACTIVE + " AND " + scope.predicate());
        scope.bind(query);
        return ((Number) query.getSingleResult()).intValue();
    }

    @Override
    @SuppressWarnings("unchecked")
    public ClientProfile clientProfile(UUID clientId) {
        if (clientId == null) return null;
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT c.id, c.code, c.name, c.full_name, c.name_en, c.linkman, c.email, c.phone,
                               c.mobile, c.address, c.tax_id, c.website, c.place_id, c.default_currency_id,
                               c.default_settlement_method_id, c.owner_employee_id, c.status, c.is_deleted
                        FROM clients c
                        WHERE c.id = :id
                        """)
                .setParameter("id", clientId)
                .getResultList();
        if (rows.size() != 1) return null;
        Object[] row = rows.getFirst();
        if (Boolean.TRUE.equals(row[17])) return null;
        UUID ownerEmployeeId = (UUID) row[15];
        ClientAccessPolicy.ClientScope scope = clientAccess.evaluate();
        if (!clientAccess.canRead(clientId, ownerEmployeeId, scope)) return null;
        List<String> contactEmails = new ArrayList<>();
        List<String> contactPhones = new ArrayList<>();
        List<Object[]> contacts = em.createNativeQuery("""
                        SELECT m.kind, m.value
                        FROM party_contact_methods m
                        WHERE m.party_type = 'CLIENT' AND m.party_id = :id
                          AND m.kind IN ('EMAIL', 'PHONE', 'MOBILE')
                        ORDER BY m.is_primary DESC, m.created_at, m.id
                        """)
                .setParameter("id", clientId)
                .getResultList();
        for (Object[] contact : contacts) {
            String value = ClientDocumentFields.clean((String) contact[1]);
            if (value == null) continue;
            if ("EMAIL".equals(contact[0])) contactEmails.add(value);
            else contactPhones.add(value);
        }
        boolean editable = hasAuthority("client:edit") && clientAccess.canWriteOwner(ownerEmployeeId, scope);
        return new ClientProfile(clientId, (String) row[1], (String) row[2], (String) row[3], (String) row[4],
                (String) row[5], (String) row[6], (String) row[7], (String) row[8], (String) row[9],
                (String) row[10], (String) row[11], (String) row[12], (UUID) row[13], (UUID) row[14],
                ownerEmployeeId, (String) row[16], contactEmails, contactPhones, editable);
    }

    @Override
    @SuppressWarnings("unchecked")
    public Map<UUID, ClientGoodsHistory> clientHistory(UUID clientId, int months) {
        if (clientId == null || !clientReadable(clientId)) return Map.of();
        int window = Math.max(1, Math.min(months <= 0 ? 24 : months, 120));
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT i.goods_id, count(DISTINCT o.id) AS orders, max(o.bill_date) AS last_date
                        FROM sales_orders o
                        JOIN sales_order_items i ON i.order_id = o.id AND NOT i.is_deleted
                        JOIN goods g ON g.id = i.goods_id
                         AND NOT g.is_deleted AND g.status = '使用' AND NOT g.auto_created
                        WHERE o.client_id = :clientId AND NOT o.is_deleted AND o.status <> -1
                          AND o.bill_date >= current_date - make_interval(months => :months)
                        GROUP BY i.goods_id
                        ORDER BY count(DISTINCT o.id) DESC, max(o.bill_date) DESC, i.goods_id
                        LIMIT :limit
                        """)
                .setParameter("clientId", clientId)
                .setParameter("months", window)
                .setParameter("limit", HISTORY_POOL_MAX)
                .getResultList();
        Map<UUID, ClientGoodsHistory> out = new LinkedHashMap<>();
        for (Object[] row : rows) {
            UUID goodsId = (UUID) row[0];
            out.put(goodsId, new ClientGoodsHistory(goodsId, ((Number) row[1]).intValue(),
                    NativeValueConverters.toLocalDate(row[2])));
        }
        return out;
    }

    @Override
    @SuppressWarnings("unchecked")
    public Map<UUID, Set<UUID>> historyContains(Collection<UUID> clientIds, Collection<UUID> goodsIds) {
        Set<UUID> goods = nonNull(goodsIds);
        if (goods.isEmpty()) return Map.of();
        Set<UUID> requested = nonNull(clientIds);
        if (requested.isEmpty()) return historyAcrossVisibleClients(goods);
        Set<UUID> clients = visibleClients(requested);
        if (clients.isEmpty()) return Map.of();
        Map<UUID, Set<UUID>> out = new LinkedHashMap<>();
        for (List<UUID> chunk : chunks(goods)) {
            List<Object[]> rows = em.createNativeQuery("""
                            SELECT DISTINCT o.client_id, i.goods_id
                            FROM sales_orders o
                            JOIN sales_order_items i ON i.order_id = o.id AND NOT i.is_deleted
                            WHERE o.client_id IN (:clients) AND i.goods_id IN (:goods)
                              AND NOT o.is_deleted AND o.status <> -1
                            """)
                    .setParameter("clients", clients)
                    .setParameter("goods", chunk)
                    .getResultList();
            for (Object[] row : rows) {
                out.computeIfAbsent((UUID) row[0], ignored -> new HashSet<>()).add((UUID) row[1]);
            }
        }
        return out;
    }

    /**
     * 空客户集合: 调用人可见的全部启用客户(与候选召回同一过滤), 按买过的候选货品数取前
     * {@link #BASKET_CLIENTS_MAX} 个(同数按 id), 一条语句在库里排好, 不把全部客户 × 货品搬到内存。
     * 用于文件上没有任何买方线索时的「篮子重合度」(只预选待核对, 从不自动选定)。
     */
    @SuppressWarnings("unchecked")
    private Map<UUID, Set<UUID>> historyAcrossVisibleClients(Set<UUID> goods) {
        List<UUID> bounded = new ArrayList<>(goods);
        if (bounded.size() > BASKET_GOODS_MAX) bounded = bounded.subList(0, BASKET_GOODS_MAX);
        ClientAccessPolicy.NativeReadScope scope = clientAccess.nativeReadScope("c", clientAccess.evaluate());
        Query query = em.createNativeQuery("""
                WITH hits AS (
                    SELECT DISTINCT o.client_id, i.goods_id
                    FROM sales_orders o
                    JOIN sales_order_items i ON i.order_id = o.id AND NOT i.is_deleted
                    JOIN clients c ON c.id = o.client_id
                    WHERE i.goods_id IN (:goods) AND NOT o.is_deleted AND o.status <> -1
                      AND ({ACTIVE}) AND {SCOPE}
                ), ranked AS (
                    SELECT client_id FROM hits
                    GROUP BY client_id
                    ORDER BY count(*) DESC, client_id
                    LIMIT :clients
                )
                SELECT hits.client_id, hits.goods_id
                FROM hits JOIN ranked ON ranked.client_id = hits.client_id
                ORDER BY hits.client_id, hits.goods_id
                """.replace("{ACTIVE}", CLIENT_ACTIVE.strip()).replace("{SCOPE}", scope.predicate()));
        query.setParameter("goods", bounded);
        query.setParameter("clients", BASKET_CLIENTS_MAX);
        scope.bind(query);
        Map<UUID, Set<UUID>> out = new LinkedHashMap<>();
        for (Object[] row : (List<Object[]>) query.getResultList()) {
            out.computeIfAbsent((UUID) row[0], ignored -> new LinkedHashSet<>()).add((UUID) row[1]);
        }
        return out;
    }

    @Override
    @SuppressWarnings("unchecked")
    public List<DuplicateDocRow> recentDocs(UUID clientId, int days) {
        if (clientId == null || !clientReadable(clientId)) return List.of();
        int window = Math.max(1, Math.min(days <= 0 ? 180 : days, 3650));
        List<DuplicateDocRow> out = new ArrayList<>();
        if (hasAuthority("sales_order:view")) {
            out.addAll(recentDocs("order", "sales_orders", "sales_order_items", "order_id",
                    "o.owner_employee_id", "o.contract_no", clientId, window));
        }
        if (hasAuthority("sales_quote:view")) {
            out.addAll(recentDocs("quote", "sales_quotes", "sales_quote_items", "quote_id",
                    "o.maker_id", "o.contract_no", clientId, window));
        }
        out.sort((a, b) -> {
            int byDate = Objects.compare(b.billDate(), a.billDate(),
                    java.util.Comparator.nullsFirst(java.util.Comparator.naturalOrder()));
            return byDate != 0 ? byDate : Objects.toString(a.billNo(), "").compareTo(Objects.toString(b.billNo(), ""));
        });
        return out.size() > RECENT_DOCS_MAX ? List.copyOf(out.subList(0, RECENT_DOCS_MAX)) : List.copyOf(out);
    }

    @SuppressWarnings("unchecked")
    private List<DuplicateDocRow> recentDocs(String docType, String headerTable, String itemTable, String itemFk,
                                             String ownerColumn, String contractColumn, UUID clientId, int days) {
        DocumentAccessPolicy.NativeReadScope scope = salesScope.nativeReadScope(ownerColumn, "__salesOwners");
        Query headerQuery = em.createNativeQuery("""
                SELECT o.id, o.bill_no, o.bill_date, {CONTRACT}
                FROM {HEADER} o
                WHERE o.client_id = :clientId AND NOT o.is_deleted AND o.status <> -1
                  AND o.bill_date >= current_date - :days
                  AND {SCOPE}
                ORDER BY o.bill_date DESC, o.bill_no DESC
                LIMIT :limit
                """
                .replace("{CONTRACT}", contractColumn)
                .replace("{HEADER}", headerTable)
                .replace("{SCOPE}", scope.predicate()));
        headerQuery.setParameter("clientId", clientId);
        headerQuery.setParameter("days", days);
        headerQuery.setParameter("limit", RECENT_DOCS_MAX);
        scope.bind(headerQuery);
        List<Object[]> headers = headerQuery.getResultList();
        if (headers.isEmpty()) return List.of();
        Map<UUID, List<DuplicateDocLine>> lines = new HashMap<>();
        List<UUID> ids = headers.stream().map(row -> (UUID) row[0]).toList();
        List<Object[]> itemRows = em.createNativeQuery("""
                        SELECT i.{FK}, i.goods_id, i.color_id, i.qty
                        FROM {ITEMS} i
                        WHERE i.{FK} IN (:ids) AND NOT i.is_deleted
                        ORDER BY i.{FK}, i.id
                        """
                        .replace("{FK}", itemFk)
                        .replace("{ITEMS}", itemTable))
                .setParameter("ids", ids)
                .getResultList();
        for (Object[] row : itemRows) {
            lines.computeIfAbsent((UUID) row[0], ignored -> new ArrayList<>())
                    .add(new DuplicateDocLine((UUID) row[1], (UUID) row[2],
                            row[3] == null ? null : NativeValueConverters.toBigDecimal(row[3])));
        }
        List<DuplicateDocRow> out = new ArrayList<>(headers.size());
        for (Object[] row : headers) {
            UUID id = (UUID) row[0];
            out.add(new DuplicateDocRow(docType, id, (String) row[1], NativeValueConverters.toLocalDate(row[2]),
                    (String) row[3], lines.getOrDefault(id, List.of())));
        }
        return out;
    }

    @Override
    @Transactional
    public CreatedClient createClientFromDocument(NewClientRequest req) {
        return fromDocument.create(req);
    }

    // ------------------------------------------------------------------
    // 货品
    // ------------------------------------------------------------------

    @Override
    public List<GoodsRow> goodsByModelNorm(Collection<String> modelNorms) {
        Set<String> norms = new LinkedHashSet<>();
        for (String norm : nonNull(modelNorms)) {
            if (!norm.isBlank() && norm.length() <= 255) norms.add(norm);
        }
        if (norms.isEmpty()) return List.of();
        List<GoodsRow> out = new ArrayList<>();
        for (List<String> chunk : chunks(norms)) {
            out.addAll(goodsQuery(" AND g.model IS NOT NULL AND btrim(g.model) <> '' AND "
                            + MODEL_NORM_EXPR + " IN (:norms) ORDER BY g.id LIMIT " + MODEL_ROWS_MAX,
                    query -> query.setParameter("norms", chunk)));
            if (out.size() >= MODEL_ROWS_MAX) break;
        }
        return out.size() > MODEL_ROWS_MAX ? List.copyOf(out.subList(0, MODEL_ROWS_MAX)) : List.copyOf(out);
    }

    @Override
    public List<GoodsRow> goodsByCode(Collection<String> codes) {
        Set<String> variants = new LinkedHashSet<>();
        for (String code : nonNull(codes)) {
            String trimmed = code.strip();
            if (trimmed.isEmpty() || trimmed.length() > 100) continue;
            variants.add(trimmed);
            variants.add(trimmed.toUpperCase(Locale.ROOT));
            variants.add(trimmed.toLowerCase(Locale.ROOT));
        }
        if (variants.isEmpty()) return List.of();
        List<GoodsRow> out = new ArrayList<>();
        for (List<String> chunk : chunks(variants)) {
            out.addAll(goodsQuery(" AND g.code IN (:codes) ORDER BY g.id",
                    query -> query.setParameter("codes", chunk)));
        }
        return List.copyOf(out);
    }

    @Override
    public List<GoodsRow> goodsByNameCandidates(Collection<String> cnTexts, int limit) {
        if (cnTexts == null || cnTexts.isEmpty() || limit <= 0) return List.of();
        List<UUID> ids = nameCatalog.search(cnTexts, Math.min(limit, 5000));
        return goodsInOrder(ids);
    }

    @Override
    @SuppressWarnings("unchecked")
    public List<GoodsRow> goodsByNameEn(Collection<String> texts, int limit) {
        List<String> queries = new ArrayList<>();
        for (String text : nonNull(texts)) {
            String cleaned = ClientDocumentFields.clean(text);
            if (cleaned == null) continue;
            String lower = cleaned.toLowerCase(Locale.ROOT);
            if (lower.length() > 300) lower = lower.substring(0, 300);
            if (!queries.contains(lower)) queries.add(lower);
            if (queries.size() >= 200) break;
        }
        if (queries.isEmpty() || limit <= 0) return List.of();
        StringBuilder values = new StringBuilder();
        for (int i = 0; i < queries.size(); i++) {
            if (i > 0) values.append(", ");
            values.append("(").append(i).append(", CAST(:t").append(i).append(" AS text))");
        }
        Query query = em.createNativeQuery("""
                SELECT hit.id, max(hit.sim) AS best
                FROM (VALUES {VALUES}) AS q(idx, t)
                CROSS JOIN LATERAL (
                    SELECT g.id, similarity(lower(g.name_en), q.t) AS sim
                    FROM goods g
                    WHERE NOT g.is_deleted AND g.name_en IS NOT NULL
                      AND lower(g.name_en) % q.t
                    ORDER BY similarity(lower(g.name_en), q.t) DESC, g.id
                    LIMIT :perText
                ) hit
                GROUP BY hit.id
                ORDER BY best DESC, hit.id
                """.replace("{VALUES}", values));
        for (int i = 0; i < queries.size(); i++) query.setParameter("t" + i, queries.get(i));
        query.setParameter("perText", NAME_EN_PER_TEXT);
        List<UUID> ids = new ArrayList<>();
        for (Object[] row : (List<Object[]>) query.getResultList()) {
            ids.add((UUID) row[0]);
            if (ids.size() >= Math.min(limit, 5000)) break;
        }
        return goodsInOrder(ids);
    }

    @Override
    public List<GoodsRow> goodsByIds(Collection<UUID> ids) {
        return goodsInOrder(new ArrayList<>(nonNull(ids)));
    }

    @Override
    @SuppressWarnings("unchecked")
    public List<AliasRow> aliases(UUID clientIdOrNull, Collection<String> partNorms, Collection<String> descNorms) {
        Set<String> parts = boundedNorms(partNorms);
        Set<String> descs = boundedNorms(descNorms);
        if (parts.isEmpty() && descs.isEmpty()) return List.of();
        boolean withClient = clientIdOrNull != null && clientReadable(clientIdOrNull);
        String clientScope = withClient ? "(a.client_id = :clientId OR a.client_id IS NULL)" : "a.client_id IS NULL";
        GoodsOwnerClause owner = goodsOwnerClause();
        List<AliasRow> out = new ArrayList<>();
        for (Map.Entry<String, Set<String>> kind : Map.of("PART_NO", parts, "DESCRIPTION", descs).entrySet()) {
            if (kind.getValue().isEmpty()) continue;
            for (List<String> chunk : chunks(kind.getValue())) {
                Query query = em.createNativeQuery("""
                        SELECT a.id, a.client_id, a.alias_kind, a.alias_text, a.alias_norm, a.context_norm,
                               a.goods_id, a.confirm_count, a.explicit_count, a.last_confirmed_at
                        FROM client_goods_aliases a
                        JOIN goods g ON g.id = a.goods_id
                         AND NOT g.is_deleted AND g.status = '使用' AND NOT g.auto_created {OWNER}
                        WHERE {CLIENT} AND a.alias_kind = :kind AND a.alias_norm IN (:norms)
                        ORDER BY a.alias_norm, a.client_id NULLS LAST, a.context_norm, a.goods_id
                        """.replace("{OWNER}", owner.sql()).replace("{CLIENT}", clientScope));
                if (withClient) query.setParameter("clientId", clientIdOrNull);
                query.setParameter("kind", kind.getKey());
                query.setParameter("norms", chunk);
                owner.bind(query);
                for (Object[] row : (List<Object[]>) query.getResultList()) {
                    UUID aliasClient = (UUID) row[1];
                    out.add(new AliasRow((UUID) row[0], aliasClient == null ? AliasScope.GLOBAL : AliasScope.CLIENT,
                            aliasClient, AliasKind.valueOf((String) row[2]), (String) row[3], (String) row[4],
                            (String) row[5], (UUID) row[6], ((Number) row[7]).intValue(),
                            ((Number) row[8]).intValue(), NativeValueConverters.toOffsetDateTime(row[9])));
                }
            }
        }
        return List.copyOf(out);
    }

    // ------------------------------------------------------------------
    // 公共
    // ------------------------------------------------------------------

    /** 按给定顺序取货品行(过滤后可能变少), 顺序保持调用方的优先级。 */
    private List<GoodsRow> goodsInOrder(List<UUID> ids) {
        Set<UUID> distinct = new LinkedHashSet<>(ids);
        distinct.remove(null);
        if (distinct.isEmpty()) return List.of();
        Map<UUID, GoodsRow> byId = new HashMap<>();
        for (List<UUID> chunk : chunks(distinct)) {
            for (GoodsRow row : goodsQuery(" AND g.id IN (:ids)", query -> query.setParameter("ids", chunk))) {
                byId.put(row.id(), row);
            }
        }
        List<GoodsRow> out = new ArrayList<>(byId.size());
        for (UUID id : distinct) {
            GoodsRow row = byId.get(id);
            if (row != null) out.add(row);
        }
        return List.copyOf(out);
    }

    @SuppressWarnings("unchecked")
    private List<GoodsRow> goodsQuery(String condition, java.util.function.Consumer<Query> binder) {
        GoodsOwnerClause owner = goodsOwnerClause();
        Query query = em.createNativeQuery(GOODS_COLUMNS + owner.sql() + condition);
        binder.accept(query);
        owner.bind(query);
        List<GoodsRow> out = new ArrayList<>();
        for (Object[] row : (List<Object[]>) query.getResultList()) {
            out.add(new GoodsRow((UUID) row[0], (String) row[1], (String) row[2], (String) row[3], (String) row[4],
                    (String) row[5], (UUID) row[6], (String) row[7], (UUID) row[8], (String) row[9],
                    (String) row[10], (String) row[11],
                    row[12] == null ? null : NativeValueConverters.toBigDecimal(row[12]),
                    (String) row[13]));
        }
        return out;
    }

    /** 货品归属隔离子句(开关关闭或可看全部时为空)。 */
    private record GoodsOwnerClause(String sql, Set<UUID> owners) {
        void bind(Query query) {
            if (owners != null) query.setParameter("__goodsOwners", owners);
        }
    }

    private GoodsOwnerClause goodsOwnerClause() {
        if (!goodsOwnerScopeEnabled) return new GoodsOwnerClause("", null);
        OwnerVisibility.OwnerScope scope = ownerVisibility.evaluate("goods", "goods:view:all");
        if (scope.seeAll()) return new GoodsOwnerClause("", null);
        if (scope.visibleOwners().isEmpty()) return new GoodsOwnerClause(" AND g.owner_employee_id IS NULL ", null);
        return new GoodsOwnerClause(
                " AND (g.owner_employee_id IS NULL OR g.owner_employee_id IN (:__goodsOwners)) ",
                scope.visibleOwners());
    }

    private boolean clientReadable(UUID clientId) {
        return !visibleClients(Set.of(clientId)).isEmpty();
    }

    /** 调用人看得到的未删除客户(不要求启用: 停用客户的历史与对照仍可用于核对)。 */
    @SuppressWarnings("unchecked")
    private Set<UUID> visibleClients(Set<UUID> clientIds) {
        if (clientIds.isEmpty()) return Set.of();
        ClientAccessPolicy.NativeReadScope scope = clientAccess.nativeReadScope("c", clientAccess.evaluate());
        Set<UUID> out = new LinkedHashSet<>();
        for (List<UUID> chunk : chunks(clientIds)) {
            Query query = em.createNativeQuery(
                    "SELECT c.id FROM clients c WHERE c.id IN (:ids) AND NOT c.is_deleted AND " + scope.predicate());
            query.setParameter("ids", chunk);
            scope.bind(query);
            for (Object id : (List<Object>) query.getResultList()) out.add((UUID) id);
        }
        return out;
    }

    private boolean hasAuthority(String authority) {
        AuthUser user = currentUser.get().orElse(null);
        if (user == null || user.isVisitor()) return false;
        return user.isSuperAdmin() || (user.getPermissions() != null && user.getPermissions().contains(authority));
    }

    private static Set<String> boundedNorms(Collection<String> norms) {
        Set<String> out = new LinkedHashSet<>();
        for (String norm : nonNull(norms)) {
            if (!norm.isEmpty() && norm.length() <= SalesLearningPlanner.MAX_ALIAS_LENGTH) out.add(norm);
        }
        return out;
    }

    private static <T> List<List<T>> chunks(Collection<T> values) {
        List<T> list = new ArrayList<>(values);
        List<List<T>> out = new ArrayList<>();
        for (int from = 0; from < list.size(); from += IN_CHUNK) {
            out.add(list.subList(from, Math.min(list.size(), from + IN_CHUNK)));
        }
        return out;
    }

    private static <T> Set<T> nonNull(Collection<T> values) {
        Set<T> out = new LinkedHashSet<>();
        if (values != null) {
            for (T value : values) if (value != null) out.add(value);
        }
        return out;
    }

    private static Set<String> lowerAll(Collection<String> values) {
        Set<String> out = new LinkedHashSet<>();
        for (String value : nonNull(values)) {
            String trimmed = value.strip().toLowerCase(Locale.ROOT);
            if (!trimmed.isEmpty() && trimmed.length() <= 200) out.add(trimmed);
        }
        return out;
    }

    private static Set<String> upperAll(Collection<String> values) {
        Set<String> out = new LinkedHashSet<>();
        for (String value : nonNull(values)) {
            String trimmed = IntakeTextNormalizer.nfkc(value).strip().toUpperCase(Locale.ROOT);
            if (!trimmed.isEmpty() && trimmed.length() <= 100) out.add(trimmed);
        }
        return out;
    }

    private static Set<String> trimAll(Collection<String> values) {
        Set<String> out = new LinkedHashSet<>();
        for (String value : nonNull(values)) {
            String trimmed = value.strip();
            if (!trimmed.isEmpty() && trimmed.length() <= 255) out.add(trimmed);
        }
        return out;
    }

    private static Set<String> digitsOnly(Collection<String> values) {
        Set<String> out = new LinkedHashSet<>();
        for (String value : nonNull(values)) {
            String last8 = last8(value);
            if (last8 != null) out.add(last8);
        }
        return out;
    }

    /** 电话号码只留数字后的末 8 位; 不足 8 位返回 null(太短会误配)。 */
    static String last8(String phone) {
        if (phone == null) return null;
        StringBuilder digits = new StringBuilder();
        for (int i = 0; i < phone.length(); i++) {
            char ch = phone.charAt(i);
            if (ch >= '0' && ch <= '9') digits.append(ch);
        }
        return digits.length() < 8 ? null : digits.substring(digits.length() - 8);
    }

    /** 只留小写 ASCII 字母与数字(外文名称的宽松预筛键)。 */
    static String compactAscii(String text) {
        String lower = IntakeTextNormalizer.nfkc(text).toLowerCase(Locale.ROOT);
        StringBuilder out = new StringBuilder(lower.length());
        for (int i = 0; i < lower.length(); i++) {
            char ch = lower.charAt(i);
            if ((ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9')) out.append(ch);
        }
        return out.toString();
    }
}
