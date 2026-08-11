package com.uten.imp.config.props;

import lombok.Getter;
import lombok.Setter;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;

import java.util.List;

/**
 * 附件对象存储配置。复用 SMS 网关的多实现范式：
 * <ul>
 *   <li>{@code local}（默认）—— 本地磁盘，开发与本地测试用，不依赖云。</li>
 *   <li>{@code oss} —— 阿里云 OSS，预签名 URL 直传直下；云端 ECS 用 RAM 角色免密钥。</li>
 *   <li>{@code disabled} —— 未启用，上传接口报 503。</li>
 * </ul>
 * 切换后端只改 {@code UTEN_STORAGE_PROVIDER}，业务代码只依赖 {@code StorageService} 接口。
 */
@Getter
@Setter
@Component
@ConfigurationProperties(prefix = "uten.storage")
public class StorageProperties {

    /** 存储后端：local / oss / disabled。 */
    private String provider = "local";

    /** 单文件大小上限（字节），默认 25MB。 */
    private long maxBytes = 26214400L;

    /** 允许的 Content-Type 白名单（大小写不敏感匹配）。 */
    private List<String> allowedContentTypes = List.of(
            "image/jpeg", "image/png", "image/webp", "image/gif", "image/bmp",
            "application/pdf",
            "application/msword",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "application/vnd.ms-excel",
            "application/zip",
            "text/plain");

    /** 预签名 URL 有效期（秒）。 */
    private int presignedExpirySeconds = 300;

    /** 本地后端磁盘根目录。 */
    private String localDir = "./data/attachments";

    private Oss oss = new Oss();

    @Getter
    @Setter
    public static class Oss {
        /** OSS 公网 endpoint，如 https://oss-cn-hangzhou.aliyuncs.com。 */
        private String endpoint = "";
        /** 同 region 内网 endpoint（云端 ECS 走内网省流量），为空则用 endpoint。 */
        private String internalEndpoint = "";
        private String bucket = "";
        private String region = "";
        /** AK/SK（本地服务器用）；云端用 RAM 角色时留空。 */
        private String accessKeyId = "";
        private String accessKeySecret = "";
        /** true=用 ECS 实例 RAM 角色取临时凭证（免密钥）。 */
        private boolean useInstanceRole = false;
        /** RAM 角色名（useInstanceRole=true 时必填）。 */
        private String roleName = "";
        /** OSS key 前缀，如 attachments/。 */
        private String keyPrefix = "attachments/";
        /** 生产门禁：启动时确认 Bucket 已启用版本控制。 */
        private boolean requireVersioning = false;
    }
}
