package com.uten.imp.application.port;

/**
 * 导出行数上限端口 (ADR-110): 报表、基础资料与审计导出统一读取系统设置「导出行数上限」,
 * 实现方在系统设置模块。基础资料等未登记依赖系统设置模块的 feature 只经本端口读取。
 */
public interface ExportLimitPort {

    /** 单次导出允许的最大行数 (系统设置 export_max_rows)。 */
    int exportMaxRows();
}
