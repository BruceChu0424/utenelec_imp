package com.uten.imp.features.master.learning;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.json.JsonMapper;
import com.uten.imp.application.port.MasterIntakeLookupPort.AliasScope;
import com.uten.imp.audit.AuditService;
import com.uten.imp.features.master.client.Client;
import com.uten.imp.features.master.client.ClientAccessPolicy;
import com.uten.imp.features.master.goods.GoodsService;
import com.uten.imp.features.master.party.PartyDirectoryService;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.Collection;
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
 * 在<b>独立事务</b>里执行一次保存的主档学习(ADR-134): 撤回同一单据被改掉的旧对照、写对照、
 * 刷新全局对照的可信度、写货品英文名称、补全客户资料。由 {@link SalesMasterLearningAdapter}
 * 在保存事务提交之后调用; 这里任何失败只回滚学习本身, 保存早已提交。
 *
 * <p>对照的撤回、写入、全局刷新各一条语句({@link ClientGoodsAliasLedger}), 英文名称撞名检查一条语句,
 * 语句数不随明细行数增长(学习在保存请求的线程里同步执行, 直接影响保存响应时间)。
 *
 * <p>权限在这里按当前登录人重新判定(提交后回调与保存在同一线程, 主体就是保存人):
 * 客户对照要求对该客户有写范围(只读共享不算); 英文名称要求 goods:name_en:edit 或 goods:edit
 * 且对货品有写范围; 客户资料要求 client:edit 且对客户有写范围。缺权限的部分静默跳过。
 */
@Service
@RequiredArgsConstructor
public class SalesMasterLearningApplier {

    static final String AUDIT_ACTION_CLIENT_FIELDS = "client.learn_from_document";
    /** party_contact_methods.value 的长度上限(表约束 1..200)。 */
    static final int CONTACT_VALUE_MAX = 200;

    /** 联系类字段 → 多联系方式表(V579, 联系方式的唯一权威存储)里的类型。 */
    private static final Map<String, String> CONTACT_KINDS = Map.of(
            ClientDocumentFields.EMAIL, "EMAIL",
            ClientDocumentFields.PHONE, "PHONE",
            ClientDocumentFields.MOBILE, "MOBILE",
            ClientDocumentFields.WEBSITE, "WEBSITE");

    private static final JsonMapper JSON = JsonMapper.builder().build();

    private final EntityManager em;
    private final TxSessionVars tx;
    private final ClientAccessPolicy clientAccess;
    private final GoodsService goodsService;
    private final PartyDirectoryService partyDirectory;
    private final ClientGoodsAliasLedger aliasLedger;
    private final AuditService audit;
    private final SecurityContextCurrentUser currentUser;

    /** 一次学习的结果(日志与测试用)。 */
    public record Outcome(int aliasesWritten, int aliasesRetracted, int globalAliasesRefreshed,
                          int nameEnUpdated, List<String> clientFieldsApplied) {
        static Outcome none() {
            return new Outcome(0, 0, 0, 0, List.of());
        }
    }

    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public Outcome apply(String docType, UUID docId, UUID clientId, UUID actorUserId,
                         SalesLearningPlanner.Plan plan, Map<String, String> clientFields) {
        tx.bind();
        List<SalesLearningPlanner.AliasUpsert> aliases = new ArrayList<>();
        Set<UUID> liveGoods = liveGoods(plan.aliases().stream()
                .map(SalesLearningPlanner.AliasUpsert::goodsId).toList());
        boolean clientWritable = clientId != null && clientWritable(clientId);
        for (SalesLearningPlanner.AliasUpsert alias : plan.aliases()) {
            if (!liveGoods.contains(alias.goodsId())) continue;
            // 客户对照要求对客户有写范围; 全局对照只从识别结果原文学习, 不挂在任何客户上。
            if (alias.scope() == AliasScope.CLIENT && !clientWritable) continue;
            aliases.add(alias);
        }

        ClientGoodsAliasLedger.Retraction retraction = aliasLedger.retractChangedMappings(docType, docId, aliases);
        int written = aliasLedger.upsert(docType, docId, actorUserId, aliases);
        // 全局对照的可信度 = 不同客户的证据数: 本次写到的叫法(客户对照也是证据)与撤回掉的旧对应都要重算。
        Set<ClientGoodsAliasLedger.EvidenceKey> evidence = new LinkedHashSet<>(retraction.touched());
        for (SalesLearningPlanner.AliasUpsert alias : aliases) {
            evidence.add(new ClientGoodsAliasLedger.EvidenceKey(alias.kind(), alias.norm(), alias.goodsId()));
        }
        int refreshed = aliasLedger.refreshGlobalConfidence(evidence, retraction.releasedGlobalIds());

        int nameEn = 0;
        Set<UUID> collisions = nameEnCollisions(plan.nameEn());
        for (SalesLearningPlanner.NameEnCandidate candidate : plan.nameEn()) {
            if (collisions.contains(candidate.goodsId())) continue;
            if (goodsService.learnNameEn(candidate.goodsId(), candidate.text())) nameEn++;
        }

        List<String> applied = clientId == null || clientFields.isEmpty()
                ? List.of()
                : applyClientFields(clientId, actorUserId, clientFields);
        return new Outcome(written, retraction.changed(), refreshed, nameEn, applied);
    }

    // ------------------------------------------------------------------
    // 对照的前置判断
    // ------------------------------------------------------------------

    /** 未删除、非占位的货品(已停用的货品保存时已被拦截, 这里不再区分)。 */
    @SuppressWarnings("unchecked")
    private Set<UUID> liveGoods(Collection<UUID> goodsIds) {
        Set<UUID> ids = new HashSet<>(goodsIds);
        ids.remove(null);
        if (ids.isEmpty()) return Set.of();
        List<Object> rows = em.createNativeQuery("""
                        SELECT id FROM goods
                        WHERE id IN (:ids) AND NOT is_deleted AND NOT auto_created
                        """)
                .setParameter("ids", ids)
                .getResultList();
        Set<UUID> out = new HashSet<>();
        for (Object row : rows) out.add((UUID) row);
        return out;
    }

    /** 客户对照要求对客户有写范围(负责人是自己或交接给自己的; 只读共享不算)。 */
    @SuppressWarnings("unchecked")
    private boolean clientWritable(UUID clientId) {
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT owner_employee_id, is_deleted
                        FROM clients
                        WHERE id = :id
                        """)
                .setParameter("id", clientId)
                .getResultList();
        if (rows.size() != 1 || Boolean.TRUE.equals(rows.getFirst()[1])) return false;
        return clientAccess.canWriteOwner((UUID) rows.getFirst()[0], clientAccess.evaluate());
    }

    // ------------------------------------------------------------------
    // 货品英文名称
    // ------------------------------------------------------------------

    /**
     * 另一个未删除货品已经用了同一英文名称(不分大小写; 写入时都已规范化空白)的候选: 不学, 避免英文名撞车。
     * 全部候选一条语句查完, 走英文名称的 trigram 索引。
     */
    @SuppressWarnings("unchecked")
    private Set<UUID> nameEnCollisions(List<SalesLearningPlanner.NameEnCandidate> candidates) {
        if (candidates.isEmpty()) return Set.of();
        List<Map<String, Object>> rows = new ArrayList<>(candidates.size());
        for (SalesLearningPlanner.NameEnCandidate candidate : candidates) {
            Map<String, Object> row = new LinkedHashMap<>();
            row.put("goods_id", candidate.goodsId());
            row.put("text", candidate.text());
            rows.add(row);
        }
        String json;
        try {
            json = JSON.writeValueAsString(rows);
        } catch (JsonProcessingException exception) {
            throw new IllegalStateException("Unable to encode name candidates", exception);
        }
        List<Object> hits = em.createNativeQuery("""
                        SELECT c.goods_id
                        FROM jsonb_to_recordset(CAST(:rows AS jsonb)) AS c(goods_id uuid, text text)
                        WHERE EXISTS (
                            SELECT 1
                            FROM goods g
                            WHERE NOT g.is_deleted
                              AND g.name_en IS NOT NULL
                              AND lower(g.name_en) = lower(c.text)
                              AND g.id <> c.goods_id)
                        """)
                .setParameter("rows", json)
                .getResultList();
        Set<UUID> out = new HashSet<>();
        for (Object hit : hits) out.add((UUID) hit);
        return out;
    }

    // ------------------------------------------------------------------
    // 客户资料
    // ------------------------------------------------------------------

    /**
     * 把用户勾选的文件信息写进客户资料: 需要 client:edit 且对客户有写范围; 值相同的不写;
     * 实际改了的字段写一条审计事件(只列字段名, 不含值; 新旧值由客户表与联系方式表的行级审计保留)。
     *
     * <p>邮箱、电话、手机、网址写进多联系方式表(见 {@link #learnContact}), 由它同步回客户表的平铺列;
     * 其余字段直接写客户表。
     */
    private List<String> applyClientFields(UUID clientId, UUID actorUserId, Map<String, String> fields) {
        AuthUser user = currentUser.get().orElse(null);
        if (!hasClientEdit(user)) return List.of();
        Client client = em.find(Client.class, clientId, LockModeType.PESSIMISTIC_WRITE);
        if (client == null || client.isDeleted()) return List.of();
        if (!clientAccess.canWrite(client, clientAccess.evaluate())) return List.of();
        Set<String> changed = new HashSet<>();
        Map<String, String> contacts = new LinkedHashMap<>();
        for (Map.Entry<String, String> entry : fields.entrySet()) {
            String key = entry.getKey();
            String value = entry.getValue();
            if (CONTACT_KINDS.containsKey(key)) {
                contacts.put(key, value);
                continue;
            }
            switch (key) {
                case ClientDocumentFields.NAME_EN -> {
                    if (differs(client.getNameEn(), value)) { client.setNameEn(value); changed.add(key); }
                }
                case ClientDocumentFields.FULL_NAME -> {
                    if (differs(client.getFullName(), value)) { client.setFullName(value); changed.add(key); }
                }
                case ClientDocumentFields.LINKMAN -> {
                    if (differs(client.getLinkman(), value)) { client.setLinkman(value); changed.add(key); }
                }
                case ClientDocumentFields.ADDRESS -> {
                    if (differs(client.getAddress(), value)) { client.setAddress(value); changed.add(key); }
                }
                case ClientDocumentFields.TAX_ID -> {
                    if (differs(client.getTaxId(), value)) { client.setTaxId(value); changed.add(key); }
                }
                default -> {
                    // 字段白名单已在保存事务里校验过, 这里不会出现。
                }
            }
        }
        // 先把客户表字段写下去。之后联系方式表会用语句把平铺列同步回客户表, 这个实体不能再改,
        // 否则提交时的整行更新会把同步好的联系方式列写回旧值。
        em.flush();
        if (!contacts.isEmpty()) {
            Map<String, String> flat = new HashMap<>();
            flat.put(ClientDocumentFields.EMAIL, client.getEmail());
            flat.put(ClientDocumentFields.PHONE, client.getPhone());
            flat.put(ClientDocumentFields.MOBILE, client.getMobile());
            flat.put(ClientDocumentFields.WEBSITE, client.getWebsite());
            Map<String, List<String>> existing = existingContacts(clientId);
            for (Map.Entry<String, String> entry : contacts.entrySet()) {
                String kind = CONTACT_KINDS.get(entry.getKey());
                if (learnContact(clientId, kind, entry.getValue(), flat.get(entry.getKey()),
                        existing.getOrDefault(kind, List.of()))) {
                    changed.add(entry.getKey());
                }
            }
        }
        if (changed.isEmpty()) return List.of();
        List<String> ordered = fields.keySet().stream().filter(changed::contains).toList();
        // TODO(coordinator): 换成不「说明请求」的旁路事件写法(见主档包报告), 否则保存请求自己的语义审计行会被跳过。
        audit.logCommitted(actorUserId, user.getLoginAccount(), AUDIT_ACTION_CLIENT_FIELDS,
                "clients", clientId.toString(),
                "从客户文件补全: " + ClientDocumentFields.labels(ordered));
        return ordered;
    }

    /** 该客户已有的联系方式(类型 → 值), 一条语句。 */
    @SuppressWarnings("unchecked")
    private Map<String, List<String>> existingContacts(UUID clientId) {
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT kind, value
                        FROM party_contact_methods
                        WHERE party_type = 'CLIENT' AND party_id = :id
                          AND kind IN ('EMAIL', 'PHONE', 'MOBILE', 'WEBSITE')
                        """)
                .setParameter("id", clientId)
                .getResultList();
        Map<String, List<String>> out = new HashMap<>();
        for (Object[] row : rows) {
            out.computeIfAbsent((String) row[0], ignored -> new ArrayList<>()).add((String) row[1]);
        }
        return out;
    }

    /**
     * 把一个联系方式记进多联系方式表: 同类里已有同样的值(不分大小写)就不记; 该类还没有任何一条时记为主联系方式。
     * 客户表平铺列里有旧值、联系方式表里却没有(老的手工表单只写平铺列)时, 先把旧值补成主联系方式,
     * 新值记为次要, 不让同步把旧值冲掉。
     *
     * @return 是否记了新值
     */
    private boolean learnContact(UUID clientId, String kind, String value, String flatValue, List<String> sameKind) {
        if (value.length() > CONTACT_VALUE_MAX) return false;
        String upper = value.toUpperCase(Locale.ROOT);
        for (String existing : sameKind) {
            if (existing != null && existing.strip().toUpperCase(Locale.ROOT).equals(upper)) return false;
        }
        boolean primary = sameKind.isEmpty();
        String flat = flatValue == null ? null : flatValue.strip();
        if (primary && flat != null && !flat.isEmpty() && !flat.toUpperCase(Locale.ROOT).equals(upper)) {
            if (flat.length() > CONTACT_VALUE_MAX) return false;
            partyDirectory.addContact(PartyDirectoryService.PartyType.CLIENT, clientId, kind, flat, true, null);
            primary = false;
        }
        partyDirectory.addContact(PartyDirectoryService.PartyType.CLIENT, clientId, kind, value, primary, null);
        return true;
    }

    private static boolean hasClientEdit(AuthUser user) {
        if (user == null || user.isVisitor()) return false;
        if (user.isSuperAdmin()) return true;
        return user.getPermissions() != null && user.getPermissions().contains("client:edit");
    }

    private static boolean differs(String current, String proposed) {
        String normalizedCurrent = ClientDocumentFields.clean(current);
        return !Objects.equals(normalizedCurrent, proposed);
    }
}
