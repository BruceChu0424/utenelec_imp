package com.uten.imp.features.webinquiry;

import com.uten.imp.common.domain.BaseEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.time.Instant;
import java.util.UUID;

/**
 * 官网询盘（客户留言统一收件箱，综合营销）。
 *
 * <p>官网（Next.js 站点）询盘落库后推送到 {@code POST /api/website-inquiries/ingest}，
 * {@link #sourceId} 为官网 inquiries.id，重推幂等。官网后台保留只读副本，IMP 为处理主入口。
 *
 * <p>状态机：new → following → converted / closed；converted 必须已关联 {@link #clientId}。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "website_inquiries")
public class WebsiteInquiry extends BaseEntity {

    /** 官网 inquiries.id（重推幂等键，唯一约束兜底）。 */
    @Column(name = "source_id", nullable = false, unique = true)
    private String sourceId;

    @Column(nullable = false)
    private String name;
    private String phone;
    private String email;
    private String company;

    /** 目标市场/国家。 */
    private String market;

    /** distributor/project/oem/designer/other */
    @Column(name = "customer_type")
    private String customerType;

    /** 目标市场要求的标准（如安装体系/认证要求，自由文本）。 */
    @Column(name = "required_standard")
    private String requiredStandard;

    @Column(name = "product_interest")
    private String productInterest;

    /** quotation/sample/technical/partnership/other */
    @Column(name = "request_type")
    private String requestType;

    @Column(name = "estimated_quantity")
    private String estimatedQuantity;

    @Column(name = "target_schedule")
    private String targetSchedule;

    @Column(name = "preferred_contact")
    private String preferredContact;

    @Column(nullable = false)
    private String message;

    /** contact/join/partner/product/studio */
    @Column(nullable = false)
    private String source = "contact";

    @Column(nullable = false)
    private String locale = "zh";

    /** new/following/converted/closed */
    @Column(nullable = false)
    private String status = "new";

    /** 跟进人（employees.id）。 */
    @Column(name = "assignee_employee_id")
    private UUID assigneeEmployeeId;

    /** 转客户后关联的客户主档 ID；跨 feature 查询经应用 Port 完成。 */
    @Column(name = "client_id")
    private UUID clientId;

    /** 最近一次跟进备注。 */
    private String note;

    @Column(name = "received_at", nullable = false)
    private Instant receivedAt = Instant.now();
}
