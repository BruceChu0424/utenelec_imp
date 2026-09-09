-- A separately assignable read-only monitor; does not grant authorization management or host commands.
INSERT INTO permissions(code,name,module,category,sort_order,action_type,description,
                        active,assignable,bulk_assignable,sensitivity)
VALUES ('server_status:view','查看服务器状态','系统管理','服务器状态',246,'VIEW',
        '只读查看CPU、内存、磁盘、数据库及备份状态；不允许执行服务器维护命令',
        TRUE,TRUE,TRUE,'NORMAL')
ON CONFLICT (code) DO UPDATE SET name=EXCLUDED.name,module=EXCLUDED.module,
    category=EXCLUDED.category,sort_order=EXCLUDED.sort_order,action_type=EXCLUDED.action_type,
    description=EXCLUDED.description,active=EXCLUDED.active,assignable=EXCLUDED.assignable,
    bulk_assignable=EXCLUDED.bulk_assignable,sensitivity=EXCLUDED.sensitivity;
