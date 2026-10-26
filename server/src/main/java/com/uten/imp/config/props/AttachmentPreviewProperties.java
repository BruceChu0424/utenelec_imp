package com.uten.imp.config.props;

import lombok.Getter;
import lombok.Setter;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.boot.convert.DurationUnit;
import org.springframework.stereotype.Component;

import java.time.Duration;
import java.time.temporal.ChronoUnit;

/**
 * Office 附件在线预览（服务端 LibreOffice 转 PDF）配置。
 *
 * <p>默认关闭：只有显式打开且 {@code soffice-path} 在服务器上可执行时才提供转换；
 * 否则预览接口返回业务错误，客户端回落为下载原件。转换结果缓存在附件存储根目录下的
 * {@code preview/} 私有目录（与原件同一持久卷，不经 Nginx 静态映射）。
 */
@Getter
@Setter
@Component
@ConfigurationProperties(prefix = "uten.attachment.preview")
public class AttachmentPreviewProperties {

    /** 是否启用 Office → PDF 转换预览。 */
    private boolean enabled = false;

    /** 默认连接隔离 worker；直接 soffice 路径仅供显式配置的隔离开发测试。 */
    private String sofficePath = "/usr/local/libexec/uten-preview-soffice-isolated";

    /** 单次转换超时；超时进程被强制结束并按失败处理。 */
    @DurationUnit(ChronoUnit.SECONDS)
    private Duration timeout = Duration.ofSeconds(60);

    /** 同时运行的转换进程上限（每个槽位独立 LibreOffice 用户配置目录）。 */
    private int maxConcurrent = 2;

    /** 预览缓存目录总量上限；超出后按最久未使用删除。 */
    private long cacheMaxBytes = 1073741824L;

    /** PDF 单文件上限；转换器本身的内存/磁盘/网络隔离仍由独立 worker 提供。 */
    private long maxOutputBytes = 67108864L;

    /** Office ZIP 容器在进入转换器之前的累计展开字节上限。 */
    private long maxExpandedBytes = 268435456L;

    /** Office ZIP 容器的条目数上限，避免海量小文件耗尽转换资源。 */
    private int maxArchiveEntries = 10000;
}
