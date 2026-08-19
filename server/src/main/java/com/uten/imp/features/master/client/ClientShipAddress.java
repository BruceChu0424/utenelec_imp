package com.uten.imp.features.master.client;

import com.uten.imp.common.domain.SoftDeletableEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 客户收货地址簿（V300）。
 *
 * <p>出货开单的"学习能力"载体：出货/其它出货保存时按客户 upsert 收货地址+联系电话
 * （{@code usageCount}/{@code lastUsedAt} 递增），下次开单按最近使用优先带出；
 * 地址弹窗支持查看/选择/新增；删除走软删且需要 {@code client_address:delete} 权限。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "client_ship_addresses")
public class ClientShipAddress extends SoftDeletableEntity {

    /** 所属客户（clients.id）。 */
    @Column(name = "client_id", nullable = false)
    private UUID clientId;

    /** 收货地址（客户内规范化唯一，见 uq_client_ship_addresses_addr）。 */
    @Column(name = "address", nullable = false)
    private String address;

    /** 该地址对应的联系电话（可空）。 */
    @Column(name = "link_phone")
    private String linkPhone;

    /** 被出货单据引用次数（学习热度）。 */
    @Column(name = "usage_count", nullable = false)
    private int usageCount = 1;

    /** 最近一次被出货单保存引用的时间（默认带出排序主键）。 */
    @Column(name = "last_used_at", nullable = false)
    private OffsetDateTime lastUsedAt;

    @Column(name = "created_by")
    private UUID createdBy;

    @Column(name = "updated_by")
    private UUID updatedBy;
}
