package com.uten.imp.features.notice;

import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.notice.NoticeService.CelebrationSubject;
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
 * 庆典通知每日扫描：在职员工生日 / 入职纪念日，当天自动发布庆典广播（bless 互动）。
 *
 * <p>每天 08:00:07 跑一次（避开整点/半点拥堵，与 {@link DeliveryDueWarningScheduler} 同策略）。
 * 设置开关：{@code celebration.auto_enabled}（默认开）+ {@code celebration.auto_types}
 * （默认 birthday,anniversary）+ {@code celebration.publisher_name}（默认「公司」）。
 *
 * <p><b>聚合卡（V454）</b>：每天每类型只发一张卡——今天 5 位同事生日就发一张生日卡，
 * 卡内列出 5 位主角，不再是 5 张单人卡；入职周年各人年数不同，逐人事件标签由
 * {@link NoticeService#publishCelebrationGroupBroadcast} 快照落 notice_celebration_subjects。
 *
 * <p><b>隐私</b>：birth_date/hire_date 属敏感 PII，绝不出现在通知里——
 * 通知只写姓名快照与节日标签 event_label。
 *
 * <p><b>幂等</b>：按 (员工, 类型, 当年) 在 notice_celebration_subjects 去重——同员工本类型
 * 本年已出现在任何庆典卡则不进卡；调度器多跑一次/补跑也不会刷屏。当天已发过聚合卡后
 * 若又有新的未覆盖主角（如数据补录/当日入职），下一轮只为其另发一张补充卡。
 * 整体扫描失败只记 warn（与延期预警一致的旁路策略）。
 */
@Slf4j
@Component
@Profile("!cloud")
@RequiredArgsConstructor
public class CelebrationScheduler {

    /** 在职员工状态：active 正式在职 / probation 试用期；排除 resigned/rejected/disabled。 */
    private static final String ACTIVE_EMPLOYEE_PREDICATE =
            "e.is_deleted = false AND e.status IN ('active','probation')";

    /** (员工, 类型, 当年) 去重子查询：按主角表判定（聚合卡与单人卡同口径，V454）。 */
    private static final String ALREADY_CELEBRATED = """
            AND NOT EXISTS (
                SELECT 1
                FROM notice_celebration_subjects s
                JOIN notices n ON n.id = s.notice_id
                WHERE s.employee_id = e.id
                  AND n.type = ?
                  AND n.published_at >= make_date(?::int, 1, 1)
            )
            """;

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
                log.info("庆典扫描完成：今日聚合卡覆盖 {} 位主角(types={})", published, autoTypes);
            }
        } catch (Exception e) {
            log.warn("庆典通知扫描失败(不影响业务): {}", e.toString());
        }
    }

    /** 生日扫描：birth_month_day（MM-DD，低敏个人属性）== 今天；为空跳过。一张聚合卡。 */
    private int scanBirthday(int month, int day, int year, String publisherName) {
        String todayMonthDay = String.format("%02d-%02d", month, day);
        List<Map<String, Object>> rows = jdbc.queryForList("""
                SELECT e.id, e.full_name FROM employees e
                WHERE
                """ + ACTIVE_EMPLOYEE_PREDICATE + """
                  AND e.birth_month_day = ?
                """ + ALREADY_CELEBRATED,
                todayMonthDay, "birthday", year);
        if (rows.isEmpty()) {
            return 0;
        }
        List<CelebrationSubject> subjects = rows.stream()
                .map(r -> new CelebrationSubject(
                        (UUID) r.get("id"), (String) r.get("full_name"), "生日快乐"))
                .toList();
        noticeService.publishCelebrationGroupBroadcast("birthday", subjects, publisherName);
        return subjects.size();
    }

    /**
     * 入职纪念日扫描：hire_date 月日 == 今天 且已满至少 1 整年（未满 1 年不进卡）。
     * 年数 = EXTRACT(YEAR FROM age(hire_date))，与服务端 {@code Period.between} 等价；
     * 各人年数不同，逐人生成事件标签（张三 入职5周年、李四 入职10周年）。
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
                """ + ALREADY_CELEBRATED,
                month, day, "anniversary", year);
        if (rows.isEmpty()) {
            return 0;
        }
        List<CelebrationSubject> subjects = rows.stream()
                .map(r -> {
                    int years = ((Number) r.get("years")).intValue();
                    String eventLabel = years >= 1 ? "入职" + years + "周年" : "入职快乐";
                    return new CelebrationSubject(
                            (UUID) r.get("id"), (String) r.get("full_name"), eventLabel);
                })
                .toList();
        noticeService.publishCelebrationGroupBroadcast("anniversary", subjects, publisherName);
        return subjects.size();
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
