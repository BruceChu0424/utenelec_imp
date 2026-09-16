package com.uten.imp.features.master.party;

import com.uten.imp.common.domain.BaseEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.util.UUID;

/** 客户/供应商多地址（V579）：SHIPPING 收货 / BILLING 开票注册 / OTHER 其它。 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "party_addresses")
public class PartyAddress extends BaseEntity {

    @Column(name = "party_type", nullable = false, length = 16)
    private String partyType;

    @Column(name = "party_id", nullable = false)
    private UUID partyId;

    @Column(name = "kind", nullable = false, length = 16)
    private String kind;

    @Column(name = "address", nullable = false)
    private String address;

    @Column(name = "is_default", nullable = false)
    private boolean defaultAddress;

    @Column(name = "remark")
    private String remark;
}
