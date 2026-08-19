package com.uten.imp.features.master.client;

import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

/** 客户收货地址簿仓库。 */
public interface ClientShipAddressRepository extends JpaRepository<ClientShipAddress, UUID> {

    /** 某客户的有效地址簿，最近使用优先（默认带出顺序）。 */
    List<ClientShipAddress> findByClientIdAndDeletedFalseOrderByLastUsedAtDesc(UUID clientId);

    /** 规范化地址匹配（学习 upsert 用）：由服务层先取列表再在内存比较，避免散列口径漂移。 */
    Optional<ClientShipAddress> findByIdAndDeletedFalse(UUID id);

    long countByClientIdAndDeletedFalse(UUID clientId);
}
