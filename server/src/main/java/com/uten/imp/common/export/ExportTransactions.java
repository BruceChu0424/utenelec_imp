package com.uten.imp.common.export;

/** One time budget for synchronous exports across all masters, reports and audits. */
public final class ExportTransactions {
    /**
     * 同步导出(整份文件在请求内读完整库并写完)的事务时限, 单一维护入口。
     *
     * <p>2026-11-08 定为 2 分钟, 与四道既有边界对齐: 客户端导出下载接收超时
     * (apiDownloadReceiveTimeout 120s)、nginx 导出路径 proxy_read_timeout(120s)、
     * {@link LegacyExportBudget} 同步导出检查点(2 分钟)以及数据库
     * idle_in_transaction_session_timeout(120s)。各导出服务的 @Transactional
     * 必须引用本常量, 不写裸数字; 单条语句仍受 statement_timeout(60s)约束,
     * 导出按批读取, 单语句远短于该限。</p>
     *
     * <p>注: FulfillmentHttpDeadlineFilter 已豁免导出/下载端点, 40 秒履约命令
     * 截止不再压住本值; 后台导出任务走 worker 自己的 600s 读事务与本值无关。</p>
     */
    public static final int TIMEOUT_SECONDS = 120;

    private ExportTransactions() { }
}
