package com.uten.imp.features.master.client;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.client.dto.ClientShipAddressDto;
import com.uten.imp.features.master.client.dto.ClientShipAddressSaveRequest;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/**
 * 客户收货地址簿（V300 学习能力）。
 *
 * <p>学习口径：出货/其它出货保存时调用 {@link #learn}——同客户同地址（trim+小写，
 * 与唯一索引 {@code md5(lower(btrim(address)))} 同口径）已存在则 使用次数+1、刷新最近
 * 使用时间；用户改过的联系电话随保存写回该行（记住修改）；不存在则插入新行。
 * 插入走原生 {@code ON CONFLICT DO NOTHING}，并发重复保存不会产生唯一冲突；
 * 异常数据（空/超长地址）静默跳过，绝不影响单据落库。
 *
 * <p>删除是敏感操作：软删 + 独立权限点 {@code client_address:delete}。
 */
@Service
@RequiredArgsConstructor
public class ClientShipAddressService {

    private final ClientShipAddressRepository repo;
    private final ClientRepository clientRepo;
    private final ClientAccessPolicy accessPolicy;
    private final EntityManager em;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;

    /** 某客户地址簿（最近使用优先；出货开单默认带出第一行）。 */
    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ)
    @PreAuthorize("hasAuthority('client:view')")
    public List<ClientShipAddressDto> list(UUID clientId) {
        Client client = requireClient(clientId);
        ClientAccessPolicy.ClientScope scope = accessPolicy.evaluate();
        accessPolicy.requireReadable(client, scope);
        return repo.findByClientIdAndDeletedFalseOrderByLastUsedAtDesc(clientId)
                .stream().map(this::toDto).toList();
    }

    /**
     * 手工新增地址（地址弹窗「新增地址」）。开单人员与主档维护人员均可新增；
     * 与既有地址规范化重复时等价于"点选既有地址"，刷新使用时间并返回该行。
     */
    @Transactional
    @PreAuthorize("hasAuthority('client_address:create')")
    public ClientShipAddressDto add(UUID clientId, ClientShipAddressSaveRequest req) {
        tx.bind();
        Client client = requireClientForUpdate(clientId);
        ClientAccessPolicy.ClientScope scope = accessPolicy.evaluate();
        accessPolicy.requireWritable(client, scope);
        String address = normalize(req == null ? null : req.address());
        if (address == null || address.length() < 2 || address.length() > 500) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "收货地址须为 2–500 个字符");
        }
        String phone = normalizePhone(req.linkPhone());
        UUID id = upsert(clientId, address, phone);
        return repo.findById(id).map(this::toDto)
                .orElseThrow(() -> new ApiException(ErrorCode.BUSINESS, "地址保存失败，请重试"));
    }

    /** 删除地址（软删；独立权限点，删除事实保留在审计账）。 */
    @Transactional
    @PreAuthorize("hasAuthority('client_address:delete')")
    public void delete(UUID clientId, UUID addressId) {
        tx.bind();
        Client client = requireClientForUpdate(clientId);
        ClientAccessPolicy.ClientScope scope = accessPolicy.evaluate();
        accessPolicy.requireWritable(client, scope);
        ClientShipAddress row = repo.findByIdAndDeletedFalse(addressId)
                .filter(r -> r.getClientId().equals(clientId))
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "收货地址不存在或已删除"));
        row.setDeleted(true);
        row.setDeletedAt(OffsetDateTime.now());
        row.setUpdatedBy(currentUser.employeeId().orElse(null));
        repo.save(row);
    }

    /**
     * 学习钩子（出货/其它出货保存同事务调用）：记住本次收货地址+电话。
     * 无权限/校验语义——单据保存已被各自服务授权；异常数据静默跳过，绝不影响单据落库。
     */
    @Transactional
    public void learn(UUID clientId, String rawAddress, String rawPhone) {
        if (clientId == null) return;
        String address = normalize(rawAddress);
        if (address == null || address.length() < 2 || address.length() > 500) return;
        upsert(clientId, address, normalizePhone(rawPhone));
    }

    /**
     * 规范化 upsert（与 uq_client_ship_addresses_addr 同口径：client_id + md5(lower(btrim)）：
     * 不存在 → 插入（并发安全 ON CONFLICT DO NOTHING）；已存在 → 使用次数+1、
     * 刷新最近使用时间；本次带电话才覆盖电话（留空沿用已学值，不清空）。
     *
     * @return 命中行的 id（新增或既有）。
     */
    private UUID upsert(UUID clientId, String address, String phone) {
        UUID actor = currentUser.employeeId().orElse(null);
        UUID newId = UUID.randomUUID();
        em.createNativeQuery("""
                INSERT INTO client_ship_addresses
                    (id, client_id, address, link_phone, usage_count, last_used_at, created_by)
                VALUES (:id, :clientId, :address, :phone, 1, now(), :actor)
                ON CONFLICT (client_id, md5(lower(btrim(address))))
                WHERE is_deleted = FALSE
                DO NOTHING
                """)
                .setParameter("id", newId)
                .setParameter("clientId", clientId)
                .setParameter("address", address)
                .setParameter("phone", phone)
                .setParameter("actor", actor)
                .executeUpdate();
        em.createNativeQuery("""
                UPDATE client_ship_addresses
                SET usage_count = usage_count + 1,
                    last_used_at = now(),
                    link_phone = COALESCE(:phone, link_phone),
                    updated_by = :actor
                WHERE client_id = :clientId
                  AND is_deleted = FALSE
                  AND md5(lower(btrim(address))) = md5(lower(btrim(:address)))
                  AND id <> :skipId
                """)
                .setParameter("clientId", clientId)
                .setParameter("address", address)
                .setParameter("phone", phone)
                .setParameter("actor", actor)
                .setParameter("skipId", newId)
                .executeUpdate();
        Object found = em.createNativeQuery("""
                SELECT id FROM client_ship_addresses
                WHERE client_id = :clientId AND is_deleted = FALSE
                  AND md5(lower(btrim(address))) = md5(lower(btrim(:address)))
                """)
                .setParameter("clientId", clientId)
                .setParameter("address", address)
                .getSingleResult();
        return (UUID) found;
    }

    private Client requireClient(UUID clientId) {
        return clientRepo.findById(clientId).filter(c -> !c.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "客户不存在或已删除"));
    }

    private Client requireClientForUpdate(UUID clientId) {
        Client client = em.find(
                Client.class, clientId, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        if (client == null || client.isDeleted()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "客户不存在或已删除");
        }
        return client;
    }

    /** 规范化 = 仅 trim（与唯一索引 btrim 口径严格一致；不做内部空白折叠，避免索引口径漂移）。 */
    private static String normalize(String raw) {
        if (raw == null) return null;
        String t = raw.trim();
        return t.isEmpty() ? null : t;
    }

    private static String normalizePhone(String raw) {
        String t = normalize(raw);
        if (t == null || t.length() > 64) return null;
        return t;
    }

    private ClientShipAddressDto toDto(ClientShipAddress r) {
        return new ClientShipAddressDto(
                r.getId(), r.getClientId(), r.getAddress(), r.getLinkPhone(),
                r.getUsageCount(), r.getLastUsedAt());
    }
}
