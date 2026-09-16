package com.uten.imp.features.master.party;

import com.uten.imp.common.domain.BaseEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.util.UUID;

/**
 * 客户/供应商跟进与行为记录（V579）：FOLLOW_UP 跟进 / COMPLAINT 投诉 /
 * PENALTY 违约扣分 / REWARD 奖励 / OTHER 其它。带 score_delta 的客户记录会
 * 同步累计 clients.credit_score（首条按 100±delta 初始化）。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "party_activity_records")
public class PartyActivityRecord extends BaseEntity {

    @Column(name = "party_type", nullable = false, length = 16)
    private String partyType;

    @Column(name = "party_id", nullable = false)
    private UUID partyId;

    @Column(name = "kind", nullable = false, length = 16)
    private String kind;

    @Column(name = "content", nullable = false)
    private String content;

    @Column(name = "score_delta", nullable = false)
    private int scoreDelta;
}
