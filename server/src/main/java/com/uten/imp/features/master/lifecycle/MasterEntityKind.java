package com.uten.imp.features.master.lifecycle;

/**
 * 参与统一「删除 / 批量启停 / 批量删除」命令的主档种类(ADR-111)。
 *
 * <p>表名、权限点都是硬编码白名单，永远不来自请求；{@link MasterLifecycleService} 只会把
 * 这里的常量拼进 SQL。{@code versioned} 表示该表有乐观锁 version 列(货品/客户/供应商)，
 * 命令会比对客户端带回的版本并在写入时 +1；其余主档沿用行锁串行。
 */
public enum MasterEntityKind {
    GOODS("goods", "货品", true, "goods:status", "goods:delete"),
    COLOR("colors", "颜色", false, "color:status", "color:delete"),
    UNIT("units", "单位", false, "unit:status", "unit:delete"),
    WAREHOUSE("warehouses", "仓库", false, "warehouse:status", "warehouse:delete"),
    CLIENT("clients", "客户", true, "client:status", "client:delete"),
    SUPPLIER("suppliers", "供应商", true, "supplier:status", "supplier:delete"),
    MOULD("moulds", "模具", false, "mould:status", "mould:delete");

    private final String table;
    private final String noun;
    private final boolean versioned;
    private final String statusPermission;
    private final String deletePermission;

    MasterEntityKind(String table, String noun, boolean versioned,
                     String statusPermission, String deletePermission) {
        this.table = table;
        this.noun = noun;
        this.versioned = versioned;
        this.statusPermission = statusPermission;
        this.deletePermission = deletePermission;
    }

    /** 物理表名(白名单常量)。 */
    public String table() { return table; }

    /** 面向人的中文名词(报错文案用)。 */
    public String noun() { return noun; }

    public boolean versioned() { return versioned; }

    public String statusPermission() { return statusPermission; }

    public String deletePermission() { return deletePermission; }
}
