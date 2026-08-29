package com.uten.imp.features.notice;

import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.context.annotation.Profile;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import java.time.LocalDate;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 庆典通知每日扫描：在职员工生日 / 入职纪念日，当天自动发布一条庆典广播（bless 互动）。
 *
 * <p>每天 08:00:07 跑一次（避开整点/半点拥堵，与 {@link DeliveryDueWarningScheduler} 同策略）。
 * 设置开关：{@code celebration.auto_enabled}（默认开）+ {@code celebration.auto_types}
 * （默认 birthday,anniversary）+ {@code celebration.publisher_name}（默认「公司」）。
 *
 * <p><b>隐私</b>：birth_date/hire_date 属敏感 PII，绝不出现在通知里——
 * 通知只写姓名快照 subject_name 与节日标签 event_label。
 *
 * <p><b>幂等</b>：按 (subject_employee_id, type, 当年) 去重——同员工本类型本年已发过则跳过，
 * 调度器多跑一次/补跑也不会刷屏。整体扫描失败只记 warn（与延期预警一致的旁路策略）。
 */
@Slf4j
@Component
@Profile("!cloud")
@RequiredArgsConstructor
public class CelebrationScheduler {

    /** 在职员工状态：active 正式在职 / probation 试用期；排除 resigned/rejected/disabled。 */
    private static final String ACTIVE_EMPLOYEE_PREDICATE =
            "e.is_deleted = false AND e.status IN ('active','probation')";

    private final JdbcTemplate jdbc;
    private final NoticeService noticeService;
    private final SystemSettingsService settings;

    @Scheduled(cron = "7 0 8 * * *", zone = "Asia/Shanghai")
    public void scan() {
        try {
            boolean autoEnabled = settings.readBool("celebration.auto_enabled", true);
            if (!autoEnabled) {
                return;
            }
            List<String> autoTypes = parseAutoTypes(
                    settings.readString("celebration.auto_types", "birthday,anniversary"));
            if (autoTypes.isEmpty()) {
                return;
            }
            String publisherName = settings.readString("celebration.publisher_name", "公司");
            LocalDate today = LocalDate.now(java.time.ZoneId.of("Asia/Shanghai"));
            int month = today.getMonthValue();
            int day = today.getDayOfMonth();
            int year = today.getYear();

            int published = 0;
            if (autoTypes.contains("birthday")) {
                published += scanBirthday(month, day, year, publisherName);
            }
            if (autoTypes.contains("anniversary")) {
                published += scanAnniversary(month, day, year, publisherName);
            }
            if (published > 0) {
                log.info("庆典扫描完成：今日发布 {} 条通知(types={})", published, autoTypes);
            }
        } catch (Exception e) {
            log.warn("庆典通知扫描失败(不影响业务): {}", e.toString());
        }
    }

    /** 生日扫描：birth_month_day（MM-DD，低敏个人属性）== 今天；为空跳过。 */
    private int scanBirthday(int month, int day, int year, String publisherName) {
        String todayMonthDay = String.format("%02d-%02d", month, day);
        List<Map<String, Object>> rows = jdbc.queryForList("""
                SELECT e.id, e.full_name FROM employees e
                WHERE
                """ + ACTIVE_EMPLOYEE_PREDICATE + """
                  AND e.birth_month_day = ?
                  AND NOT EXISTS (
                      SELECT 1 FROM notices n
                      WHERE n.subject_employee_id = e.id
                        AND n.type = 'birthday'
                        AND n.published_at >= make_date(?::int, 1, 1)
                  )
                """, todayMonthDay, year);
        for (Map<String, Object> r : rows) {
            UUID id = (UUID) r.get("id");
            String fullName = (String) r.get("full_name");
            noticeService.publishCelebrationBroadcast(
                    "birthday", id, fullName, "生日快乐", publisherName);
        }
        return rows.size();
    }

    /**
     * 入职纪念日扫描：hire_date 月日 == 今天 且已满至少 1 整年（未满 1 年不发）。
     * 年数 = EXTRACT(YEAR FROM age(hire_date))，与服务端 {@code Period.between} 等价。
     */
    private int scanAnniversary(int month, int day, int year, String publisherName) {
        List<Map<String, Object>> rows = jdbc.queryForList("""
                SELECT e.id, e.full_name,
                       EXTRACT(YEAR FROM age(e.hire_date))::int AS years
                FROM employees e
                WHERE
                """ + ACTIVE_EMPLOYEE_PREDICATE + """
                  AND e.hire_date IS NOT NULL
                  AND EXTRACT(MONTH FROM e.hire_date) = ?
                  AND EXTRACT(DAY FROM e.hire_date) = ?
                  AND EXTRACT(YEAR FROM age(e.hire_date)) >= 1
                  AND NOT EXISTS (
                      SELECT 1 FROM notices n
                      WHERE n.subject_employee_id = e.id
                        AND n.type = 'anniversary'
                        AND n.published_at >= make_date(?::int, 1, 1)
                  )
                """, month, day, year);
        for (Map<String, Object> r : rows) {
            UUID id = (UUID) r.get("id");
            String fullName = (String) r.get("full_name");
            int years = ((Number) r.get("years")).intValue();
            String eventLabel = years >= 1 ? "入职" + years + "周年" : "入职快乐";
            noticeService.publishCelebrationBroadcast(
                    "anniversary", id, fullName, eventLabel, publisherName);
        }
        return rows.size();
    }

    private static List<String> parseAutoTypes(String raw) {
        if (raw == null || raw.isBlank()) return List.of();
        return Arrays.stream(raw.split(","))
                .map(String::trim)
                .filter(s -> !s.isEmpty())
                .filter(NoticeService.AUTO_CELEBRATION_TYPES::contains)
                .distinct()
                .toList();
    }
}
