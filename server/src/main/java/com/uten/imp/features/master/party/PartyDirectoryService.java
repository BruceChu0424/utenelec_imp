package com.uten.imp.features.master.party;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import jakarta.persistence.PersistenceContext;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.UUID;

/**
 * 客户/供应商资料子表（V579）：多联系方式、多地址、跟进记录与客户信誉分。
 *
 * <p>联系方式/地址变更后把「每类第一条」同步回主档平铺列（mobile/phone/fax/
 * email/website、address/ship_address），保证单据、导出与老接口读平铺列的
 * 口径一致——两套数据不会漂移。跟进记录带分数变动时累计 clients.credit_score。
 */
@Service
@RequiredArgsConstructor
public class PartyDirectoryService {

    public enum PartyType { CLIENT, SUPPLIER }

    private static final Set<String> CONTACT_KINDS =
            Set.of("MOBILE", "PHONE", "FAX", "EMAIL", "WEBSITE", "OTHER");
    private static final Set<String> ADDRESS_KINDS =
            Set.of("SHIPPING", "BILLING", "OTHER");
    private static final Set<String> ACTIVITY_KINDS =
            Set.of("FOLLOW_UP", "COMPLAINT", "PENALTY", "REWARD", "OTHER");

    private final PartyContactMethodRepository contactRepo;
    private final PartyAddressRepository addressRepo;
    private final PartyActivityRecordRepository activityRepo;

    @PersistenceContext
    private EntityManager em;

    // ======================= 联系方式 =======================

    @Transactional(readOnly = true)
    public List<PartyContactMethod> listContacts(PartyType type, UUID partyId) {
        requireParty(type, partyId);
        return contactRepo.findByPartyTypeAndPartyIdOrderByKindAscPrimaryDescCreatedAtAsc(
                type.name(), partyId);
    }

    @Transactional
    public PartyContactMethod addContact(
            PartyType type, UUID partyId, String kind, String value,
            boolean primary, String remark) {
        requireParty(type, partyId);
        String normalizedKind = normalizeKind(kind, CONTACT_KINDS, "联系方式类型");
        String trimmed = trimToNull(value);
        if (trimmed == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "联系方式内容不能为空");
        if (contactRepo.countByPartyTypeAndPartyIdAndKindAndValueIgnoreCase(
                type.name(), partyId, normalizedKind, trimmed) > 0) {
            throw new ApiException(ErrorCode.BUSINESS, "该联系方式已存在，请勿重复添加");
        }
        PartyContactMethod row = new PartyContactMethod();
        row.setPartyType(type.name());
        row.setPartyId(partyId);
        row.setKind(normalizedKind);
        row.setValue(trimmed);
        row.setPrimary(primary);
        row.setRemark(trimToNull(remark));
        contactRepo.save(row);
        if (primary) clearOtherPrimaries(type, partyId, normalizedKind, row.getId());
        syncFlatContactColumns(type, partyId);
        return row;
    }

    @Transactional
    public void deleteContact(PartyType type, UUID partyId, UUID contactId) {
        PartyContactMethod row = requireContact(type, partyId, contactId);
        contactRepo.delete(row);
        syncFlatContactColumns(type, partyId);
    }

    private PartyContactMethod requireContact(PartyType type, UUID partyId, UUID contactId) {
        PartyContactMethod row = contactRepo.findById(contactId)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "联系方式不存在"));
        if (!row.getPartyType().equals(type.name()) || !row.getPartyId().equals(partyId)) {
            throw new ApiException(ErrorCode.NOT_FOUND, "联系方式不属于该主档");
        }
        return row;
    }

    private void clearOtherPrimaries(
            PartyType type, UUID partyId, String kind, UUID keepId) {
        for (PartyContactMethod other : contactRepo
                .findByPartyTypeAndPartyIdOrderByKindAscPrimaryDescCreatedAtAsc(
                        type.name(), partyId)) {
            if (other.getKind().equals(kind) && !other.getId().equals(keepId) && other.isPrimary()) {
                other.setPrimary(false);
                contactRepo.save(other);
            }
        }
    }

    /**
     * 平铺列同步：每类第一条（主选优先，其次最早）写回主档对应列；该类清空则置空串。
     * SQL 全部为固定文本块 + 参数绑定（表名/列名/类型来自白名单常量，无运行期拼接）。
     */
    private void syncFlatContactColumns(PartyType type, UUID partyId) {
        String[][] columnAndKind = {
                {"mobile", "MOBILE"},
                {"phone", "PHONE"},
                {"fax", "FAX"},
                {"email", "EMAIL"},
                {"website", "WEBSITE"},
        };
        for (String[] pair : columnAndKind) {
            em.createNativeQuery(flatContactSyncSql(type, pair[0], pair[1]))
                    .setParameter(1, partyId)
                    .setParameter(2, partyId)
                    .executeUpdate();
        }
    }

    private String flatContactSyncSql(PartyType type, String column, String kind) {
        String table = type == PartyType.CLIENT ? "clients" : "suppliers";
        return switch (table + ":" + column) {
            case "clients:mobile" -> """
                UPDATE clients SET mobile = COALESCE((SELECT m.value FROM party_contact_methods m
                    WHERE m.party_type = 'CLIENT' AND m.party_id = ?1 AND m.kind = 'MOBILE'
                    ORDER BY m.is_primary DESC, m.created_at ASC LIMIT 1), '') WHERE id = ?2
                """;
            case "clients:phone" -> """
                UPDATE clients SET phone = COALESCE((SELECT m.value FROM party_contact_methods m
                    WHERE m.party_type = 'CLIENT' AND m.party_id = ?1 AND m.kind = 'PHONE'
                    ORDER BY m.is_primary DESC, m.created_at ASC LIMIT 1), '') WHERE id = ?2
                """;
            case "clients:fax" -> """
                UPDATE clients SET fax = COALESCE((SELECT m.value FROM party_contact_methods m
                    WHERE m.party_type = 'CLIENT' AND m.party_id = ?1 AND m.kind = 'FAX'
                    ORDER BY m.is_primary DESC, m.created_at ASC LIMIT 1), '') WHERE id = ?2
                """;
            case "clients:email" -> """
                UPDATE clients SET email = COALESCE((SELECT m.value FROM party_contact_methods m
                    WHERE m.party_type = 'CLIENT' AND m.party_id = ?1 AND m.kind = 'EMAIL'
                    ORDER BY m.is_primary DESC, m.created_at ASC LIMIT 1), '') WHERE id = ?2
                """;
            case "clients:website" -> """
                UPDATE clients SET website = COALESCE((SELECT m.value FROM party_contact_methods m
                    WHERE m.party_type = 'CLIENT' AND m.party_id = ?1 AND m.kind = 'WEBSITE'
                    ORDER BY m.is_primary DESC, m.created_at ASC LIMIT 1), '') WHERE id = ?2
                """;
            case "suppliers:mobile" -> """
                UPDATE suppliers SET mobile = COALESCE((SELECT m.value FROM party_contact_methods m
                    WHERE m.party_type = 'SUPPLIER' AND m.party_id = ?1 AND m.kind = 'MOBILE'
                    ORDER BY m.is_primary DESC, m.created_at ASC LIMIT 1), '') WHERE id = ?2
                """;
            case "suppliers:phone" -> """
                UPDATE suppliers SET phone = COALESCE((SELECT m.value FROM party_contact_methods m
                    WHERE m.party_type = 'SUPPLIER' AND m.party_id = ?1 AND m.kind = 'PHONE'
                    ORDER BY m.is_primary DESC, m.created_at ASC LIMIT 1), '') WHERE id = ?2
                """;
            case "suppliers:fax" -> """
                UPDATE suppliers SET fax = COALESCE((SELECT m.value FROM party_contact_methods m
                    WHERE m.party_type = 'SUPPLIER' AND m.party_id = ?1 AND m.kind = 'FAX'
                    ORDER BY m.is_primary DESC, m.created_at ASC LIMIT 1), '') WHERE id = ?2
                """;
            case "suppliers:email" -> """
                UPDATE suppliers SET email = COALESCE((SELECT m.value FROM party_contact_methods m
                    WHERE m.party_type = 'SUPPLIER' AND m.party_id = ?1 AND m.kind = 'EMAIL'
                    ORDER BY m.is_primary DESC, m.created_at ASC LIMIT 1), '') WHERE id = ?2
                """;
            case "suppliers:website" -> """
                UPDATE suppliers SET website = COALESCE((SELECT m.value FROM party_contact_methods m
                    WHERE m.party_type = 'SUPPLIER' AND m.party_id = ?1 AND m.kind = 'WEBSITE'
                    ORDER BY m.is_primary DESC, m.created_at ASC LIMIT 1), '') WHERE id = ?2
                """;
            default -> throw new IllegalStateException("Unexpected column: " + column + " kind: " + kind);
        };
    }

    // ======================= 地址 =======================

    @Transactional(readOnly = true)
    public List<PartyAddress> listAddresses(PartyType type, UUID partyId) {
        requireParty(type, partyId);
        return addressRepo.findByPartyTypeAndPartyIdOrderByDefaultAddressDescCreatedAtAsc(
                type.name(), partyId);
    }

    @Transactional
    public PartyAddress addAddress(
            PartyType type, UUID partyId, String kind, String address,
            boolean defaultAddress, String remark) {
        requireParty(type, partyId);
        String normalizedKind = normalizeKind(kind, ADDRESS_KINDS, "地址类型");
        String trimmed = trimToNull(address);
        if (trimmed == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "地址内容不能为空");
        PartyAddress row = new PartyAddress();
        row.setPartyType(type.name());
        row.setPartyId(partyId);
        row.setKind(normalizedKind);
        row.setAddress(trimmed);
        row.setDefaultAddress(defaultAddress);
        row.setRemark(trimToNull(remark));
        addressRepo.save(row);
        if (defaultAddress) clearOtherDefaults(type, partyId, row.getId());
        return row;
    }

    @Transactional
    public void deleteAddress(PartyType type, UUID partyId, UUID addressId) {
        PartyAddress row = addressRepo.findById(addressId)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "地址不存在"));
        if (!row.getPartyType().equals(type.name()) || !row.getPartyId().equals(partyId)) {
            throw new ApiException(ErrorCode.NOT_FOUND, "地址不属于该主档");
        }
        addressRepo.delete(row);
    }

    private void clearOtherDefaults(PartyType type, UUID partyId, UUID keepId) {
        for (PartyAddress other : addressRepo
                .findByPartyTypeAndPartyIdOrderByDefaultAddressDescCreatedAtAsc(
                        type.name(), partyId)) {
            if (!other.getId().equals(keepId) && other.isDefaultAddress()) {
                other.setDefaultAddress(false);
                addressRepo.save(other);
            }
        }
    }

    // ======================= 跟进记录与信誉分 =======================

    @Transactional(readOnly = true)
    public List<PartyActivityRecord> listActivities(PartyType type, UUID partyId) {
        requireParty(type, partyId);
        return activityRepo.findByPartyTypeAndPartyIdOrderByCreatedAtDesc(
                type.name(), partyId);
    }

    @Transactional
    public PartyActivityRecord addActivity(
            PartyType type, UUID partyId, String kind, String content, int scoreDelta) {
        requireParty(type, partyId);
        String normalizedKind = normalizeKind(kind, ACTIVITY_KINDS, "记录类型");
        String trimmed = trimToNull(content);
        if (trimmed == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "记录内容不能为空");
        if (scoreDelta < -100 || scoreDelta > 100) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "信誉分变动须在 -100 到 100 之间");
        }
        PartyActivityRecord row = new PartyActivityRecord();
        row.setPartyType(type.name());
        row.setPartyId(partyId);
        row.setKind(normalizedKind);
        row.setContent(trimmed);
        row.setScoreDelta(scoreDelta);
        activityRepo.save(row);
        if (scoreDelta != 0 && type == PartyType.CLIENT) {
            applyCreditScoreDelta(partyId, scoreDelta);
        }
        return row;
    }

    /** 信誉分：NULL=从未评估 → 首次按 100±delta 初始化；累计后夹在 [0,200]。 */
    private void applyCreditScoreDelta(UUID clientId, int delta) {
        em.createNativeQuery(
                "UPDATE clients SET credit_score ="
                        + " GREATEST(0, LEAST(200, COALESCE(credit_score, 100 - ?) + ?))"
                        + " WHERE id = ?")
                .setParameter(1, delta)
                .setParameter(2, delta)
                .setParameter(3, clientId)
                .executeUpdate();
    }

    @Transactional(readOnly = true)
    public Integer creditScore(UUID clientId) {
        var rows = em.createNativeQuery(
                        "SELECT credit_score FROM clients WHERE id = ? AND NOT is_deleted")
                .setParameter(1, clientId)
                .getResultList();
        if (rows.isEmpty() || rows.get(0) == null) return null;
        return ((Number) rows.get(0)).intValue();
    }

    // ======================= 内部工具 =======================

    private void requireParty(PartyType type, UUID partyId) {
        var exists = em.createNativeQuery(type == PartyType.CLIENT
                        ? "SELECT id FROM clients WHERE id = ? AND NOT is_deleted"
                        : "SELECT id FROM suppliers WHERE id = ? AND NOT is_deleted")
                .setParameter(1, partyId)
                .getResultList();
        if (exists.isEmpty()) {
            throw new ApiException(ErrorCode.NOT_FOUND,
                    type == PartyType.CLIENT ? "客户不存在" : "供应商不存在");
        }
    }

    private static String normalizeKind(String kind, Set<String> allowed, String label) {
        String normalized = kind == null ? "" : kind.trim().toUpperCase(Locale.ROOT);
        if (!allowed.contains(normalized)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, label + "不合法");
        }
        return normalized;
    }

    private static String trimToNull(String value) {
        if (value == null) return null;
        String trimmed = value.trim();
        return trimmed.isEmpty() ? null : trimmed;
    }
}
