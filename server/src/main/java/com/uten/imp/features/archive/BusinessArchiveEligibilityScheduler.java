package com.uten.imp.features.archive;

import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Profile;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import java.util.List;

/**
 * 每日低峰归档资格扫描与试点打包（B3）。
 *
 * <p>03:57（错开 03:41 库存核对、03:53 载荷分层）有界扫描已结案采购订单，
 * 重算资格登记；对已合格的少量对象组装完整快照包。只登记、只复制校验，
 * 不搬移、不删除任何业务数据；单对象失败不影响其余对象。
 */
@Slf4j
@Component
@Profile("!cloud")
public class BusinessArchiveEligibilityScheduler {

    private final BusinessArchiveEligibilityService eligibility;
    private final boolean enabled;
    private final int scanLimit;
    private final int packageLimit;

    public BusinessArchiveEligibilityScheduler(
            BusinessArchiveEligibilityService eligibility,
            @Value("${uten.archive.eligibility.enabled:true}") boolean enabled,
            @Value("${uten.archive.eligibility.scan-limit:200}") int scanLimit,
            @Value("${uten.archive.eligibility.package-limit:20}") int packageLimit) {
        this.eligibility = eligibility;
        this.enabled = enabled;
        this.scanLimit = Math.max(1, scanLimit);
        this.packageLimit = Math.max(0, Math.min(packageLimit, 100));
    }

    @Scheduled(cron = "0 57 3 * * *", zone = "Asia/Shanghai")
    public void scan() {
        if (!enabled) {
            return;
        }
        try {
            runOnce();
        } catch (Exception e) {
            log.warn("归档资格扫描失败(下一轮自动重试, 不影响业务): {}", e.toString());
        }
    }

    /** 一次有界扫描+打包；返回本次评估结果（测试/运维可直接调用）。 */
    public List<BusinessArchiveEligibilityService.Evaluation> runOnce() {
        List<BusinessArchiveEligibilityService.Evaluation> evaluations =
                eligibility.evaluatePurchaseOrders(scanLimit);
        long eligibleCount = evaluations.stream().filter(BusinessArchiveEligibilityService.Evaluation::eligible).count();
        if (eligibleCount > 0) {
            log.info("归档资格扫描：评估 {} 单，其中 {} 单具备完整打包资格", evaluations.size(), eligibleCount);
        }
        int packaged = 0;
        if (packageLimit > 0) {
            for (BusinessArchiveEligibilityService.Evaluation evaluation : evaluations) {
                if (packaged >= packageLimit) {
                    break;
                }
                if (!evaluation.eligible()) {
                    continue;
                }
                try {
                    BusinessArchiveEligibilityService.PackageOutcome outcome =
                            eligibility.packagePurchaseOrder(evaluation.objectId());
                    if ("PACKAGED".equals(outcome.outcome())) {
                        packaged++;
                    }
                } catch (Exception e) {
                    log.warn("归档包组装失败(对象 {}, 跳过本对象, 下一轮重试): {}",
                            evaluation.objectId(), e.toString());
                }
            }
        }
        if (packaged > 0) {
            log.info("归档试点打包完成：本次新增 {} 个完整快照包（只复制校验, 不搬移不删除）", packaged);
        }
        return evaluations;
    }
}
