package com.uten.imp.features.admin.serveroperations;

import com.fasterxml.jackson.databind.JsonNode;
import java.util.Map;
import java.util.Set;

/** Public guidance is selected by a fixed code; helper text is never forwarded. */
final class ServerOperationFailures {
    private ServerOperationFailures() {}

    record Definition(String title, String reason, String suggestion, String nextAction, boolean retrySafe) {}

    static final String HOST_PLATFORM_UNSUPPORTED = "HOST_PLATFORM_UNSUPPORTED";
    // Deliberately outside the helper catalog: only the local transport can establish this fact.
    private static final Definition PLATFORM_UNSUPPORTED = new Definition("当前平台不支持服务器运维助手",
            "服务器更新与存储清理助手仅支持 Linux，当前后端运行平台不支持此功能。",
            "本地开发环境可继续使用其他功能；正式部署请在 Linux 服务器安装并核验配套运维助手。",
            "CONTACT_ADMIN", false);

    private static final Map<String, Definition> CATALOG = Map.ofEntries(
            Map.entry("UNKNOWN", new Definition("原因尚未确认", "本次操作未完成，现有信息不足以确认具体原因。", "请保留任务标识联系管理员查看本机诊断；确认原因前不要重复更新。", "CONTACT_ADMIN", false)),
            Map.entry("HOST_IDENTITY_PERMISSION", new Definition("主机账号切换权限不足", "更新组件无法切换到数据库或应用系统账号，本阶段未通过。", "请管理员核对更新服务的受限身份切换能力；不要关闭安全沙箱或修改业务账号权限。", "CONTACT_ADMIN", false)),
            Map.entry("HOST_COMPONENT_MISSING", new Definition("主机更新组件不完整", "必需的本机更新程序未找到，操作无法继续。", "请管理员核对已安装的运维组件及程序版本，再重新检查。", "CONTACT_ADMIN", false)),
            Map.entry("HOST_COMPONENT_PERMISSION", new Definition("主机文件访问被拒绝", "更新组件无法访问必需的受保护文件或目录。", "请管理员核对程序、备份与发布目录的属主和权限，不要放宽为公开可写。", "CONTACT_ADMIN", false)),
            Map.entry("HOST_CONFIGURATION_INVALID", new Definition("主机配置未通过校验", "更新或迁移配置的格式、权限或可信边界不符合要求。", "请管理员核对本机受保护配置和安装步骤，不要通过关闭校验继续更新。", "CONTACT_ADMIN", false)),
            Map.entry("SOURCE_NOT_CONFIGURED", new Definition("发布来源尚未配置完成", "发布来源、只读访问凭据或可信签名公钥尚未准备好。", "请超级管理员完成发布来源配置后，显式重新检查版本。", "CHECK_SOURCE", false)),
            Map.entry("SOURCE_CHANGED", new Definition("运行信息已变化", "发布来源、可用版本或当前运行版本已与本次请求不一致。", "请刷新状态并重新检查版本，核对后再提交新的操作。", "REFRESH_STATUS", true)),
            Map.entry("BUSY", new Definition("已有运维任务正在执行", "另一个更新或清理任务仍持有执行权，本次没有开始。", "请查看当前任务并等待完成，不要并行或重复提交更新。", "WAIT_FOR_JOB", false)),
            Map.entry("FORBIDDEN", new Definition("当前操作未获授权", "当前账号或主机调用身份不允许执行此操作。", "请联系有对应权限的管理员；不要借用账号或绕过授权。", "CONTACT_ADMIN", false)),
            Map.entry("SOURCE_DNS_FAILED", new Definition("无法解析发布来源", "服务器未能解析发布来源的域名。", "请管理员核对发布区域配置和服务器 DNS，恢复后重新检查。", "CHECK_SOURCE", true)),
            Map.entry("SOURCE_NETWORK_FAILED", new Definition("无法连接发布来源", "服务器与发布来源之间的网络连接未能完成。", "请管理员核对出口网络、代理及区域配置，恢复后重新检查。", "CHECK_SOURCE", true)),
            Map.entry("SOURCE_TLS_FAILED", new Definition("发布来源安全连接失败", "发布来源的 TLS 连接或证书校验未通过。", "请管理员核对系统时间、可信 CA 与发布源证书；不要跳过证书校验。", "CHECK_SOURCE", false)),
            Map.entry("SOURCE_FORBIDDEN", new Definition("发布来源拒绝访问", "发布来源拒绝了只读请求，访问凭据、请求签名或读取权限可能不匹配。", "请超级管理员核对只读凭据、区域、对象前缀和读取权限，并由管理员核对服务器时间。", "CHECK_SOURCE", false)),
            Map.entry("SOURCE_NOT_FOUND", new Definition("发布文件未找到", "发布来源没有返回所需的版本通道或发布文件。", "请管理员核对发布是否完整及对象前缀；修正后重新检查，不要手工跳过缺失文件。", "CHECK_SOURCE", true)),
            Map.entry("SOURCE_METADATA_INVALID", new Definition("版本通道内容无效", "版本通道返回的内容不符合支持的版本格式或大小限制。", "请发布管理员核对通道文件与对应版本，修正后重新检查。", "CHECK_SOURCE", false)),
            Map.entry("RELEASE_SIGNATURE_INVALID", new Definition("发布签名验证失败", "发布包未通过已配置可信公钥的签名验证，未被接受。", "请发布管理员核对签名公钥与发布文件；不要跳过验签或临时信任未知密钥。", "CONTACT_ADMIN", false)),
            Map.entry("RELEASE_CHECKSUM_INVALID", new Definition("发布文件完整性校验失败", "发布文件与签名清单中的校验值不一致。", "请发布管理员核对完整上传与文件内容，确认后重新检查；不要使用未通过校验的暂存文件。", "CONTACT_ADMIN", false)),
            Map.entry("RELEASE_CONTENT_INVALID", new Definition("发布包内容不符合要求", "发布清单、文件路径或必要内容未通过安全检查。", "请发布管理员重新核对完整发布包，保留任务标识协助定位。", "CONTACT_ADMIN", false)),
            Map.entry("MIGRATIONS_NOT_FORWARD_ONLY", new Definition("发布迁移不满足向前升级要求", "发布包修改、删除或缺少已使用的数据库迁移。", "请发布管理员提供只追加且与当前库兼容的版本，禁止直接跳过迁移检查。", "CONTACT_ADMIN", false)),
            Map.entry("INVALID_RUNTIME_BINDING", new Definition("运行环境身份无法确认", "当前数据库与附件存储身份不完整，更新没有获得执行许可。", "请管理员核对当前运行环境及存储信息，再刷新状态重新检查。", "CONTACT_ADMIN", false)),
            Map.entry("BACKUP_BINDING_MISMATCH", new Definition("备份目标与运行环境不一致", "数据库、附件目录与可信备份或迁移配置未能对应。", "请管理员先核对备份覆盖的数据库、附件和历史目录；不要跳过配套备份。", "CONTACT_ADMIN", false)),
            Map.entry("HOST_DISK_SPACE", new Definition("主机可用空间不足", "当前操作所需的存储空间不足，无法继续。", "请管理员检查对应磁盘容量及挂载状态，通过受控清理释放空间后重新检查。", "CONTACT_ADMIN", false)),
            Map.entry("BACKUP_SPACE", new Definition("备份空间不足", "备份磁盘未满足可用空间安全要求。", "请管理员检查备份盘挂载与空间，按保留策略清理；不要删除当前恢复所需的备份。", "CONTACT_ADMIN", false)),
            Map.entry("BACKUP_REFERENCE_INVALID", new Definition("配套备份引用未通过校验", "备份的数据库与附件引用或发布位置未能形成可信对应。", "请管理员核对数据库和附件备份覆盖范围及本机诊断，修复前不要继续激活。", "CONTACT_ADMIN", false)),
            Map.entry("BACKUP_INTEGRITY_FAILED", new Definition("配套备份完整性校验失败", "备份内容、校验值或数据库备份目录未通过复核。", "请管理员检查备份完整性与数据库备份可读性；必须形成已验证备份后才能更新。", "CONTACT_ADMIN", false)),
            Map.entry("BACKUP_FAILED", new Definition("配套备份未能完成", "数据库和附件配套备份没有成功完成，具体原因需要本机诊断确认。", "请管理员保留失败记录并核对备份程序、磁盘及文件权限，不要绕过备份继续更新。", "CONTACT_ADMIN", false)),
            Map.entry("OPERATION_TIMEOUT", new Definition("操作超过等待时限", "本阶段未在限定时间内完成，执行结果需要按任务状态核对。", "请先刷新任务状态并联系管理员核对网络、资源与本机诊断，不要重复提交更新。", "REFRESH_STATUS", true)),
            Map.entry("MIGRATION_FAILED", new Definition("数据库迁移未能完成", "数据库迁移阶段未能通过，当前数据状态需要管理员核对。", "请管理员结合任务标识、迁移记录和已验证备份完成恢复检查；不要再次激活或回滚数据库。", "VERIFY_RECOVERY", false)),
            Map.entry("ACTIVATION_FAILED", new Definition("版本激活未能完成", "版本切换或启动阶段没有完成全部验证。", "请管理员核对当前代码、数据库、备份与进程状态，确认恢复路径后处理。", "VERIFY_RECOVERY", false)),
            Map.entry("HEALTH_CHECK_FAILED", new Definition("后端健康检查未通过", "更新后的后端未通过连续健康验证。", "请管理员核对启动日志、数据库连接和当前运行版本，完成恢复检查后再操作。", "VERIFY_RECOVERY", false)),
            Map.entry("DATABASE_CATALOG_MISMATCH", new Definition("数据库迁移记录不一致", "运行数据库的迁移记录与发布包要求不一致。", "请管理员核对完整迁移记录与已验证备份，不要补写成功记录或重复执行迁移。", "VERIFY_RECOVERY", false)),
            Map.entry("PROCESS_UNSTABLE", new Definition("后端进程未稳定运行", "后端在观察期内退出、重启或未保持同一健康进程。", "请管理员核对服务日志和重启原因，确认恢复状态后处理。", "VERIFY_RECOVERY", false)),
            Map.entry("WORKER_INTERRUPTED", new Definition("更新任务已中断", "负责本次操作的主机任务已退出或被中断，没有自动重放。", "请管理员结合当前版本、数据库与备份核对结果；不要直接重放旧更新请求。", "CONTACT_ADMIN", false)),
            Map.entry("WORKER_START_FAILED", new Definition("更新任务无法启动", "主机未能启动独立的更新服务，本次任务没有进入执行。", "请管理员核对运维服务安装、系统服务状态及本机执行权限。", "CONTACT_ADMIN", false)),
            Map.entry("CURRENT_VERSION_CHANGED", new Definition("当前版本已被其他操作改变", "执行前发现运行版本已变化，本次未停服或迁移。", "请刷新当前状态并重新检查版本，核对后再提交新的操作。", "REFRESH_STATUS", true)),
            Map.entry("UPDATE_NOTICE_REQUIRED", new Definition("更新预告尚未获得确认", "当前激活没有匹配正在执行的授权任务和完整十分钟预告，未停服或迁移。", "请从服务器运维页面重新检查并发起更新，不要直接重放激活命令。", "CONTACT_ADMIN", false)),
            Map.entry("CUTOVER_BACKUP_FAILED_RECOVERED", new Definition("最终备份失败，原服务已恢复", "切换前的最终数据库备份未成功；没有执行迁移，原服务已恢复健康。", "请管理员核对最终备份失败原因与备份磁盘，修复后重新检查，不要重放旧任务。", "CONTACT_ADMIN", false)),
            Map.entry("HOST_HELPER_UNAVAILABLE", new Definition("无法连接主机运维助手", "后端未能与本机运维服务建立可信连接。", "请管理员核对运维助手服务、受保护连接与组件安装状态。", "CONTACT_ADMIN", false)),
            Map.entry("HOST_RESPONSE_INVALID", new Definition("主机响应未通过安全校验", "主机运维响应不符合当前支持的协议，不能据此确认操作结果。", "请管理员核对后端与主机组件版本并查看本机诊断；不要再次提交尚未确认的更新。", "REFRESH_STATUS", false)),
            Map.entry("OUTCOME_UNCERTAIN", new Definition("操作结果尚未确认", "请求可能已经被主机接收，当前连接没有返回可确认的结果。", "请使用原任务标识刷新任务或配置状态，不要更换标识重复提交。", "REFRESH_STATUS", false)),
            Map.entry("RECOVERY_REQUIRED", new Definition("当前更新需要先完成恢复核对", "已有更新在迁移或切换后未完成验证，尚不能确认可安全开始新的操作。", "请管理员结合任务标识和已验证备份完成恢复核对；不要再次更新、激活或回滚数据库。", "VERIFY_RECOVERY", false)),
            Map.entry("INVALID_REQUEST", new Definition("操作参数未通过校验", "本次参数或预约时间不符合支持的操作要求。", "请核对页面提示和服务器时区，刷新状态后重新确认操作。", "REFRESH_STATUS", true)),
            Map.entry("AUTOMATIC_UPDATES_ENABLED", new Definition("自动更新尚未停用", "主机仍配置了自动更新任务，当前手动执行条件未满足。", "请管理员完成手动更新组件安装并核对自动任务已停用。", "CONTACT_ADMIN", false))
    );

    private static final Set<String> PRE_ACTIVATION = Set.of("CHECKING", "DOWNLOADING", "BACKING_UP", "NOTIFYING");
    private static final Set<String> RECOVERY_PHASES = Set.of("MIGRATING", "ACTIVATING", "HEALTH_CHECK", "DONE");
    private static final Set<String> PRESERVED_PRECONDITIONS = Set.of(
            "CURRENT_VERSION_CHANGED", "CUTOVER_BACKUP_FAILED_RECOVERED", "UPDATE_NOTICE_REQUIRED");
    private static final String RECOVERY_TITLE = "更新需要恢复核对";
    private static final String RECOVERY_REASON = "本次更新未获得可确认的恢复结果，当前代码、数据库与服务状态需要管理员核对。";
    private static final String RECOVERY_SUGGESTION = "请管理员结合任务标识和已验证备份完成恢复核对；不要再次更新、激活或回滚数据库。";
    private static final String UNCONFIRMED_TITLE = "更新状态需要核对";
    private static final String UNCONFIRMED_REASON = "尚未获得可确认的原服务保持或恢复结果，当前代码、数据库与服务状态需要管理员核对。";

    static boolean known(String code) { return code != null && CATALOG.containsKey(code); }
    static Set<String> codes() { return CATALOG.keySet(); }
    static Definition definition(String code) { return CATALOG.getOrDefault(code, CATALOG.get("UNKNOWN")); }

    static ServerOperationsDto.Failure project(JsonNode raw, String state, String phase) {
        if (raw == null || raw.isNull() || !("FAILED".equals(state) || "RECOVERY_REQUIRED".equals(state))) return null;
        String requested = raw.path("code").isTextual() ? raw.path("code").textValue() : null;
        String code = known(requested) ? requested : "UNKNOWN";
        Definition entry = definition(code);
        boolean preservedPrecondition = "FAILED".equals(state) && PRESERVED_PRECONDITIONS.contains(code);
        boolean recovery = "RECOVERY_REQUIRED".equals(state)
                || raw.path("recoveryRequired").isBoolean() && raw.path("recoveryRequired").booleanValue()
                || !preservedPrecondition && (RECOVERY_PHASES.contains(phase) || "VERIFY_RECOVERY".equals(entry.nextAction()));
        boolean preserved = !recovery && (PRE_ACTIVATION.contains(phase) || preservedPrecondition)
                && raw.path("originalServicePreserved").isBoolean() && raw.path("originalServicePreserved").booleanValue();
        JsonNode exit = raw.path("exitCode");
        Integer exitCode = !"UNKNOWN".equals(code) && exit.isIntegralNumber() && exit.canConvertToInt()
                && exit.intValue() != 0 && exit.intValue() >= -255 && exit.intValue() <= 255 ? exit.intValue() : null;
        boolean contradictoryPreservation = recovery && PRESERVED_PRECONDITIONS.contains(code);
        boolean unconfirmedPreservation = !recovery && !preserved && PRESERVED_PRECONDITIONS.contains(code);
        return new ServerOperationsDto.Failure(code, phase,
                contradictoryPreservation ? RECOVERY_TITLE : unconfirmedPreservation ? UNCONFIRMED_TITLE : entry.title(),
                contradictoryPreservation ? RECOVERY_REASON : unconfirmedPreservation ? UNCONFIRMED_REASON : entry.reason(),
                recovery ? RECOVERY_SUGGESTION : entry.suggestion(),
                recovery ? "VERIFY_RECOVERY" : entry.nextAction(), entry.retrySafe() && !recovery,
                recovery, preserved, exitCode);
    }

    static ServerOperationsDto.Failure unavailable(String transportCode) {
        String code = "INVALID_RESPONSE".equals(transportCode) || "HOST_RESPONSE_INVALID".equals(transportCode)
                ? "HOST_RESPONSE_INVALID" : "HOST_HELPER_UNAVAILABLE";
        Definition entry = definition(code);
        return new ServerOperationsDto.Failure(code, "CHECKING", entry.title(), entry.reason(), entry.suggestion(),
                entry.nextAction(), false, false, false, null);
    }

    static ServerOperationsDto.Failure platformUnsupported() {
        return new ServerOperationsDto.Failure(HOST_PLATFORM_UNSUPPORTED, "CHECKING", PLATFORM_UNSUPPORTED.title(),
                PLATFORM_UNSUPPORTED.reason(), PLATFORM_UNSUPPORTED.suggestion(), PLATFORM_UNSUPPORTED.nextAction(),
                false, false, false, null);
    }

    static String message(ServerOperationsDto.Failure failure) {
        return failure.title() + "：" + failure.reason() + " " + failure.suggestion();
    }

    static String guidance(String code) {
        Definition entry = definition(code);
        return entry.title() + "：" + entry.reason() + " " + entry.suggestion();
    }

    static String rpcCode(String code) {
        if (known(code)) return code;
        return switch (code) {
            case "UNAVAILABLE", "TIMEOUT" -> "HOST_HELPER_UNAVAILABLE";
            case "INVALID_RESPONSE" -> "HOST_RESPONSE_INVALID";
            case "STALE_CONFIG", "STALE_RELEASE", "RUNTIME_MISMATCH", "REQUEST_CONFLICT", "CONFLICT", "REVISION_CONFLICT", "INVALID_JOB_STATE" -> "SOURCE_CHANGED";
            case "INVALID_HOST_CONFIG", "UNSAFE_HOST_CONFIG" -> "HOST_CONFIGURATION_INVALID";
            case "INVALID_ENDPOINT", "INVALID_BUCKET", "INVALID_PREFIX", "INVALID_CREDENTIALS", "INVALID_PUBLIC_KEY" -> "SOURCE_NOT_CONFIGURED";
            case "INVALID_SCHEDULE", "AMBIGUOUS_SCHEDULE", "VALIDATION_FAILED", "NOT_DUE" -> "INVALID_REQUEST";
            case "RECOVERY_REQUIRED" -> "ACTIVATION_FAILED";
            default -> "UNKNOWN";
        };
    }
}
