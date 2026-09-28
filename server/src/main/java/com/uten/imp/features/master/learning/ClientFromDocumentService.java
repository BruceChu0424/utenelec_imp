package com.uten.imp.features.master.learning;

import com.uten.imp.application.port.MasterIntakeLookupPort.CreatedClient;
import com.uten.imp.application.port.MasterIntakeLookupPort.NewClientRequest;
import com.uten.imp.common.mastercode.CategoryCodeAllocation;
import com.uten.imp.common.mastercode.CategoryDrivenCodeService;
import com.uten.imp.common.text.IntakeTextNormalizer;
import com.uten.imp.common.web.ApiError;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.SystemMasterCategoryRegistry;
import com.uten.imp.features.master.client.Client;
import com.uten.imp.features.master.client.ClientAccessPolicy;
import com.uten.imp.features.master.client.ClientRepository;
import com.uten.imp.features.master.clientcategory.ClientCategory;
import com.uten.imp.features.master.clientcategory.ClientCategoryRepository;
import com.uten.imp.features.master.party.PartyDirectoryService;
import com.uten.imp.security.CurrentAuthorityGuard;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * 用客户文件上的买方信息新建客户(ADR-134, {@code POST /api/master/clients/from-document})。
 *
 * <p>先在<b>全部</b>未删除客户里查重(精确邮箱、电话后 8 位、规范化后的外文名称/全称/简称), 不受调用人
 * 可见范围限制, 防止业务员把别人负责的客户重复建一份:
 * <ul>
 *   <li>命中调用人看得到的客户: 409「这个客户已经存在」, 并在 fieldErrors 里带
 *       {@code existingClientId}(页面据此直接选中那个客户);</li>
 *   <li>命中调用人看不到的客户: 409「这个客户可能已由其他业务员负责, 请联系主管分配」,
 *       不带任何名称或 id。</li>
 * </ul>
 * 没有重复才新建: 建在系统「未分类」客户分类下, 负责人为当前员工, 自动取号(与官网询盘转客户同一做法)。
 * 邮箱与电话记进多联系方式表(联系方式的唯一权威存储, 由它同步回客户表的平铺列)。
 * 并发新建用事务级咨询锁串行, 避免两个人同时建出同一个客户。
 */
@Service
@RequiredArgsConstructor
public class ClientFromDocumentService {

    /** 返回给页面的已存在客户 id 放在 fieldErrors 的这个字段名下。 */
    public static final String EXISTING_CLIENT_FIELD = "existingClientId";
    /** clients.name 在页面与选择器里显示为简称, 文件上的买方全名可能很长, 截到 64 个字符。 */
    static final int SHORT_NAME_MAX = 64;

    private static final String LOCK_KEY = "uten:master:client-from-document";

    private final EntityManager em;
    private final ClientRepository clients;
    private final ClientCategoryRepository categories;
    private final CategoryDrivenCodeService categoryCodes;
    private final SystemMasterCategoryRegistry systemCategories;
    private final ClientAccessPolicy clientAccess;
    private final PartyDirectoryService partyDirectory;
    private final TxSessionVars tx;

    @Transactional
    public CreatedClient create(NewClientRequest request) {
        CurrentAuthorityGuard.requireAll("client:create");
        tx.bind();
        NormalizedRequest normalized = normalize(request);
        UUID ownerEmployeeId = clientAccess.requireCurrentEmployeeId();
        em.createNativeQuery("SELECT pg_advisory_xact_lock(hashtextextended(CAST(:key AS text), 0))")
                .setParameter("key", LOCK_KEY)
                .getSingleResult();
        rejectDuplicates(normalized);

        UUID categoryId = systemCategories.clientCategoryId();
        ClientCategory category = categories.findById(categoryId)
                .filter(candidate -> !candidate.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.INTERNAL, "系统未分类客户分类缺失"));
        CategoryCodeAllocation code = categoryCodes.allocate(
                CategoryDrivenCodeService.MasterType.CLIENT, category.getId(), null);
        Client client = new Client();
        client.setCategory(category);
        client.setCode(code.code());
        client.setCodeSequence(code.sequence());
        client.setCodePrefixCategoryId(code.prefixCategoryId());
        client.setCodeManaged(code.managed());
        client.setName(normalized.name());
        client.setFullName(normalized.fields().get(ClientDocumentFields.FULL_NAME));
        client.setNameEn(normalized.fields().get(ClientDocumentFields.NAME_EN));
        client.setLinkman(normalized.fields().get(ClientDocumentFields.LINKMAN));
        client.setAddress(normalized.fields().get(ClientDocumentFields.ADDRESS));
        client.setTaxId(normalized.fields().get(ClientDocumentFields.TAX_ID));
        client.setPlaceId(normalized.placeId());
        client.setOwnerEmployeeId(ownerEmployeeId);
        client.setStatus("使用");
        client.setRemark("来源: 客户文件识别");
        Client saved = clients.save(client);
        // 先让客户行落库, 联系方式表才能挂上它; 之后不再改这个实体(同步回来的平铺列不能被整行更新盖掉)。
        em.flush();
        addPrimaryContact(saved.getId(), "EMAIL", normalized.fields().get(ClientDocumentFields.EMAIL));
        addPrimaryContact(saved.getId(), "PHONE", normalized.fields().get(ClientDocumentFields.PHONE));
        return new CreatedClient(saved.getId(), saved.getCode(), saved.getName());
    }

    private void addPrimaryContact(UUID clientId, String kind, String value) {
        if (value == null || value.length() > SalesMasterLearningApplier.CONTACT_VALUE_MAX) return;
        partyDirectory.addContact(PartyDirectoryService.PartyType.CLIENT, clientId, kind, value, true, null);
    }

    /** 规范化后的请求。fields 只含非空白且已校验的联系字段。 */
    record NormalizedRequest(String name, Map<String, String> fields, String placeId) {
    }

    static NormalizedRequest normalize(NewClientRequest request) {
        String name = ClientDocumentFields.clean(request.name());
        if (name == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请填写客户名称");
        }
        if (name.codePointCount(0, name.length()) > SHORT_NAME_MAX) {
            name = name.substring(0, name.offsetByCodePoints(0, SHORT_NAME_MAX)).strip();
        }
        Map<String, String> raw = new LinkedHashMap<>();
        raw.put(ClientDocumentFields.FULL_NAME, request.fullName());
        raw.put(ClientDocumentFields.NAME_EN, request.nameEn());
        raw.put(ClientDocumentFields.LINKMAN, request.linkman());
        raw.put(ClientDocumentFields.EMAIL, request.email());
        raw.put(ClientDocumentFields.PHONE, request.phone());
        raw.put(ClientDocumentFields.ADDRESS, request.address());
        raw.put(ClientDocumentFields.TAX_ID, request.taxId());
        Map<String, String> fields = ClientDocumentFields.normalizeAndValidate(raw);
        String placeId = ClientDocumentFields.clean(request.placeId());
        if (placeId != null && placeId.codePointCount(0, placeId.length()) > 64) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "客户所属地区太长(最多 64 个字符)");
        }
        return new NormalizedRequest(name, fields, placeId);
    }

    // ------------------------------------------------------------------
    // 查重
    // ------------------------------------------------------------------

    private void rejectDuplicates(NormalizedRequest request) {
        List<Hit> hits = new ArrayList<>();
        String email = request.fields().get(ClientDocumentFields.EMAIL);
        if (email != null) hits.addAll(emailHits(email.toLowerCase(java.util.Locale.ROOT)));
        String phoneLast8 = MasterIntakeLookupAdapter.last8(request.fields().get(ClientDocumentFields.PHONE));
        if (phoneLast8 != null) hits.addAll(phoneHits(phoneLast8));
        hits.addAll(nameHits(request));
        if (hits.isEmpty()) return;
        ClientAccessPolicy.ClientScope scope = clientAccess.evaluate();
        hits.sort(java.util.Comparator.comparing((Hit hit) -> hit.code() == null ? "" : hit.code())
                .thenComparing(hit -> hit.id().toString()));
        for (Hit hit : hits) {
            if (clientAccess.canRead(hit.id(), hit.ownerEmployeeId(), scope)) {
                throw new ApiException(ErrorCode.CONFLICT, "这个客户已经存在",
                        List.of(new ApiError.FieldError(EXISTING_CLIENT_FIELD, hit.id().toString())));
            }
        }
        throw new ApiException(ErrorCode.CONFLICT, "这个客户可能已由其他业务员负责, 请联系主管分配");
    }

    private record Hit(UUID id, UUID ownerEmployeeId, String code) {
    }

    @SuppressWarnings("unchecked")
    private List<Hit> emailHits(String email) {
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT c.id, c.owner_employee_id, c.code
                        FROM clients c
                        WHERE NOT c.is_deleted
                          AND (EXISTS (SELECT 1
                                       FROM regexp_split_to_table(lower(coalesce(c.email, '')), '[\\s,;/]+') AS e(v)
                                       WHERE e.v = :email)
                               OR EXISTS (SELECT 1 FROM party_contact_methods m
                                          WHERE m.party_type = 'CLIENT' AND m.party_id = c.id
                                            AND m.kind = 'EMAIL' AND lower(btrim(m.value)) = :email))
                        """)
                .setParameter("email", email)
                .getResultList();
        return toHits(rows);
    }

    @SuppressWarnings("unchecked")
    private List<Hit> phoneHits(String last8) {
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT c.id, c.owner_employee_id, c.code
                        FROM clients c
                        WHERE NOT c.is_deleted
                          AND (EXISTS (SELECT 1
                                       FROM unnest(ARRAY[c.phone, c.phone2, c.mobile, c.fax]) AS p(v),
                                            regexp_split_to_table(coalesce(p.v, ''), '[,;/]+') AS part(v)
                                       WHERE length(regexp_replace(part.v, '\\D', '', 'g')) >= 8
                                         AND right(regexp_replace(part.v, '\\D', '', 'g'), 8) = :phone)
                               OR EXISTS (SELECT 1 FROM party_contact_methods m
                                          WHERE m.party_type = 'CLIENT' AND m.party_id = c.id
                                            AND m.kind IN ('PHONE', 'MOBILE', 'FAX')
                                            AND length(regexp_replace(m.value, '\\D', '', 'g')) >= 8
                                            AND right(regexp_replace(m.value, '\\D', '', 'g'), 8) = :phone))
                        """)
                .setParameter("phone", last8)
                .getResultList();
        return toHits(rows);
    }

    /**
     * 名称查重: 新客户的外文名称/全称/简称与已有客户的外文名称/全称/简称, 按识别侧同一口径
     * (NFKC、小写、去标点、合并空白)比较。客户表规模小(千级), 在 Java 里比较保证口径一致。
     */
    @SuppressWarnings("unchecked")
    private List<Hit> nameHits(NormalizedRequest request) {
        Set<String> keys = new HashSet<>();
        addNameKey(keys, request.name());
        addNameKey(keys, request.fields().get(ClientDocumentFields.NAME_EN));
        addNameKey(keys, request.fields().get(ClientDocumentFields.FULL_NAME));
        if (keys.isEmpty()) return List.of();
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT c.id, c.owner_employee_id, c.code, c.name, c.full_name, c.name_en
                        FROM clients c
                        WHERE NOT c.is_deleted
                        """)
                .getResultList();
        List<Hit> hits = new ArrayList<>();
        for (Object[] row : rows) {
            for (int column = 3; column <= 5; column++) {
                String key = nameKey((String) row[column]);
                if (key != null && keys.contains(key)) {
                    hits.add(new Hit((UUID) row[0], (UUID) row[1], (String) row[2]));
                    break;
                }
            }
        }
        return hits;
    }

    private static void addNameKey(Set<String> keys, String text) {
        String key = nameKey(text);
        if (key != null) keys.add(key);
    }

    /** 名称比较键; 少于 2 个字符的不参与查重(太短会误伤)。 */
    static String nameKey(String text) {
        if (text == null) return null;
        String key = IntakeTextNormalizer.normalizeDescription(text);
        return key.codePointCount(0, key.length()) < 2 ? null : key;
    }

    private static List<Hit> toHits(List<Object[]> rows) {
        List<Hit> hits = new ArrayList<>(rows.size());
        for (Object[] row : rows) hits.add(new Hit((UUID) row[0], (UUID) row[1], (String) row[2]));
        return hits;
    }
}
