package com.uten.imp.features.master.party;

import com.uten.imp.common.domain.BaseEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.util.UUID;

/** 客户/供应商多联系方式（V579）；party_type 区分主档。 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "party_contact_methods")
public class PartyContactMethod extends BaseEntity {

    @Column(name = "party_type", nullable = false, length = 16)
    private String partyType;

    @Column(name = "party_id", nullable = false)
    private UUID partyId;

    /** MOBILE / PHONE / FAX / EMAIL / WEBSITE / OTHER。 */
    @Column(name = "kind", nullable = false, length = 16)
    private String kind;

    @Column(name = "value", nullable = false)
    private String value;

    @Column(name = "is_primary", nullable = false)
    private boolean primary;

    @Column(name = "remark")
    private String remark;
}
