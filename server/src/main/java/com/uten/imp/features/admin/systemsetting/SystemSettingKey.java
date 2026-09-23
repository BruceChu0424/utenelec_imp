package com.uten.imp.features.admin.systemsetting;

import java.util.Arrays;
import java.util.Map;
import java.util.Optional;
import java.util.function.Function;
import java.util.stream.Collectors;

/**
 * 系统设置的唯一登记处 (ADR-110)。
 *
 * <p>每个运行时可调的设置项在这里声明一次: 键、类型、默认值、取值范围、分组、是否下发给
 * 全体登录用户、界面名称/单位/排序与说明。数据库 {@code system_settings} 只保存「当前值」,
 * 行集合必须与本枚举完全一致 (由迁移种子保证, {@code SystemSettingRegistryContractTest} 守护)。
 * 代码只能按枚举读取, 不再有散落各处的字符串键和各自的默认值。</p>
 */
public enum SystemSettingKey {

    // ===== 安全策略 =====
    LOGIN_RATE_LIMIT_PER_MINUTE("login_rate_limit_per_minute", Type.INT, "5", 1L, 100_000L,
            Category.SECURITY, false, "登录主体限流", "次/分", 10,
            "每个登录账号或规范化手机号在每个鉴权入口每分钟允许的尝试次数"),
    LOGIN_IP_RATE_LIMIT_PER_MINUTE("login_ip_rate_limit_per_minute", Type.INT, "300", 1L, 1_000_000L,
            Category.SECURITY, false, "鉴权 IP 粗限流", "次/分", 11,
            "员工登录、访客发码和访客登录各自每 IP 每分钟上限 (平滑回填, 瞬间最多放行 20 次); 应显著高于单主体阈值"),
    LOCKOUT_THRESHOLD("lockout_threshold", Type.INT, "5", 1L, 1_000L,
            Category.SECURITY, false, "账号锁定阈值", "次", 20,
            "连续登录失败几次后临时锁定账号; 敏感操作前的密码确认连续输错同样按此次数暂停验证"),
    LOCKOUT_MINUTES("lockout_minutes", Type.INT, "15", 1L, 525_600L,
            Category.SECURITY, false, "锁定时长", "分钟", 30,
            "账号 (或敏感操作的密码确认) 锁定多少分钟后自动解除"),
    PASSWORD_MIN_LENGTH("password_min_length", Type.INT, "8", 8L, 64L,
            Category.SECURITY, true, "密码最短长度", "位", 35,
            "员工自己设置新密码时至少要多少位 (还须同时包含字母和数字)"),
    PASSWORD_HISTORY_SIZE("password_history_size", Type.INT, "5", 0L, 100L,
            Category.SECURITY, false, "密码历史回溯", "个", 40,
            "改密码时禁止复用最近 N 个历史密码; 0 仅关闭历史回溯, 仍禁止复用当前密码。"),
    TEMP_PASSWORD_TTL_HOURS("temp_password_ttl_hours", Type.INT, "72", 1L, 168L,
            Category.SECURITY, false, "临时密码有效期", "小时", 45,
            "开通账号或重置密码后发出的临时密码多少小时内有效; 过期需重新发放, 首次登录必须改成自己的密码"),
    EXPORT_RATE_LIMIT_PER_MINUTE("export_rate_limit_per_minute", Type.INT, "10", 1L, 10_000L,
            Category.SECURITY, false, "导出限流", "次/分", 50,
            "每用户每分钟最多导出次数 (防拖库)"),
    SESSION_IDLE_TIMEOUT_MINUTES("session_idle_timeout_minutes", Type.INT, "30", 1L, 525_600L,
            Category.SECURITY, true, "自动退出登录", "分钟", 60,
            "多少分钟没有任何操作就自动退出登录; 由服务器判定, 页面自动刷新的角标和计数不算操作"),
    IMPERSONATION_WINDOW_MINUTES("impersonation_window_minutes", Type.INT, "15", 1L, 120L,
            Category.SECURITY, false, "切换人窗口", "分钟", 70,
            "超级管理员确认密码后, 多少分钟内可以连续切换查看不同员工的视角; 到期需重新确认密码"),

    // ===== 登录令牌 =====
    JWT_ACCESS_TTL_MINUTES("jwt_access_ttl_minutes", Type.LONG, "15", 5L, 1_440L,
            Category.TOKEN, false, "登录令牌有效期", "分钟", 115,
            "单个访问令牌多久自动换一次新的 (用户无感); 退出登录、空闲超时、账号变动会立即让令牌失效, 与本值无关"),
    JWT_REFRESH_TTL_DAYS("jwt_refresh_ttl_days", Type.LONG, "7", 1L, 30L,
            Category.TOKEN, false, "登录保持时长", "天", 120,
            "从登录那一刻起算, 最多保持多少天免输密码; 到期必须重新登录, 中途有没有操作都不会延长"),

    // ===== 短信验证 (访客端) =====
    SMS_CODE_TTL_MINUTES("sms_code_ttl_minutes", Type.INT, "5", 1L, 1_440L,
            Category.SMS, false, "验证码有效期", "分钟", 210, "短信验证码有效时长"),
    SMS_SEND_INTERVAL_SECONDS("sms_send_interval_seconds", Type.INT, "60", 1L, 86_400L,
            Category.SMS, false, "短信发送间隔", "秒", 220, "同一手机号两次发送的最小间隔"),
    SMS_DAILY_LIMIT("sms_daily_limit", Type.INT, "10", 1L, 10_000L,
            Category.SMS, false, "每日短信上限", "条", 230, "同一手机号每日最多发送条数"),

    // ===== 业务限制 =====
    EXPORT_MAX_ROWS("export_max_rows", Type.INT, "100000", 1L, 100_000L,
            Category.BUSINESS, false, "导出行数上限", "行", 310,
            "单次导出最大行数 (报表、基础资料、审计导出统一; 超限拒绝, 防内存耗尽和拖库)"),
    CELEBRATION_AUTO_ENABLED("celebration.auto_enabled", Type.BOOL, "false", null, null,
            Category.BUSINESS, false, "庆典通知自动发布", null, 320,
            "开启后每日 08:00 (北京时间) 自动扫描在职员工生日/入职纪念日并发布庆典通知; 默认关闭, "
                    + "由人事在 HR 任务中心手动送祝福, 也可在该页打开「自动发送」"),
    CELEBRATION_AUTO_TYPES("celebration.auto_types", Type.STRING, "birthday,anniversary", null, null,
            Category.BUSINESS, false, "自动发布的庆典类型", null, 321,
            "逗号分隔, 仅支持 birthday(生日)、anniversary(入职纪念日)。每日北京时间 08:00:07 扫描; 停发请关闭自动发布。"),
    CELEBRATION_PUBLISHER_NAME("celebration.publisher_name", Type.STRING, "公司", null, null,
            Category.BUSINESS, false, "自动庆典通知署名", null, 322,
            "自动发布的庆典通知署名 (如「公司」/「人力资源部」)"),
    DELIVERY_DUE_WARNING_DAYS("delivery_due_warning_days", Type.INT, "3", 1L, 30L,
            Category.BUSINESS, false, "交货期预警提前天数", "天", 330,
            "销售订单交货日期前多少天开始提醒跟单与生产"),
    RESERVATION_HOLD_GRACE_DAYS("reservation_hold_grace_days", Type.INT, "7", 1L, 90L,
            Category.BUSINESS, false, "预留超期提醒天数", "天", 331,
            "库存预留超过交货日期多少天仍未出货时提醒释放"),
    SUBCONTRACT_RETURN_DUE_DAYS("subcontract_return_due_days", Type.INT, "3", 1L, 30L,
            Category.BUSINESS, false, "委外回厂预警提前天数", "天", 332,
            "委外订单约定回厂日期前多少天开始提醒跟单"),
    BADGE_POLL_SECONDS("badge_poll_seconds", Type.INT, "60", 15L, 600L,
            Category.BUSINESS, true, "待办角标刷新间隔", "秒", 340,
            "页面上待办数量角标每隔多少秒自动刷新一次; 调小会增加服务器压力"),

    // ===== 审计留存 =====
    AUDIT_HOT_RETENTION_MONTHS("audit_hot_retention_months", Type.INT, "6", 1L, 120L,
            Category.AUDIT, true, "在线审计保留期", "个月", 410,
            "日志在审计中心可查询、可导出的月数; 到期后自动转入冷归档"),
    AUDIT_ARCHIVE_RETENTION_MONTHS("audit_archive_retention_months", Type.INT, "30", 0L, 240L,
            Category.AUDIT, true, "归档追加保留期", "个月", 420,
            "转入冷归档后继续保留的月数; 到期将在每日清理任务中永久删除且不可恢复");

    /** 值类型: 决定解析与校验方式。 */
    public enum Type {
        INT("int"), LONG("long"), BOOL("bool"), STRING("string");

        private final String wire;

        Type(String wire) {
            this.wire = wire;
        }

        public String wire() {
            return wire;
        }
    }

    /** 系统设置页的分组。 */
    public enum Category {
        SECURITY("security"), TOKEN("token"), SMS("sms"), BUSINESS("business"), AUDIT("audit");

        private final String wire;

        Category(String wire) {
            this.wire = wire;
        }

        public String wire() {
            return wire;
        }
    }

    private static final Map<String, SystemSettingKey> BY_KEY = Arrays.stream(values())
            .collect(Collectors.toUnmodifiableMap(SystemSettingKey::key, Function.identity()));

    private final String key;
    private final Type type;
    private final String defaultValue;
    private final Long min;
    private final Long max;
    private final Category category;
    private final boolean publicValue;
    private final String label;
    private final String unit;
    private final int sortOrder;
    private final String description;

    SystemSettingKey(String key, Type type, String defaultValue, Long min, Long max,
                     Category category, boolean publicValue, String label, String unit,
                     int sortOrder, String description) {
        this.key = key;
        this.type = type;
        this.defaultValue = defaultValue;
        this.min = min;
        this.max = max;
        this.category = category;
        this.publicValue = publicValue;
        this.label = label;
        this.unit = unit;
        this.sortOrder = sortOrder;
        this.description = description;
    }

    public static Optional<SystemSettingKey> of(String key) {
        return Optional.ofNullable(key == null ? null : BY_KEY.get(key));
    }

    public String key() {
        return key;
    }

    public Type type() {
        return type;
    }

    public String defaultValue() {
        return defaultValue;
    }

    /** 数值项的最小值; 非数值项为 null。 */
    public Long min() {
        return min;
    }

    /** 数值项的最大值; 非数值项为 null。 */
    public Long max() {
        return max;
    }

    public Category category() {
        return category;
    }

    /** true 表示通过 /api/settings/public 下发给全体登录用户 (只能是非敏感项)。 */
    public boolean isPublic() {
        return publicValue;
    }

    public String label() {
        return label;
    }

    public String unit() {
        return unit;
    }

    public int sortOrder() {
        return sortOrder;
    }

    public String description() {
        return description;
    }

    public boolean numeric() {
        return type == Type.INT || type == Type.LONG;
    }
}
