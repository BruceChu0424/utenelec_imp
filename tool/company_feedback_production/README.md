# 公司反馈生产整改：可复跑验证

涉及界面的整改默认使用 `frontend-design`，复用 Uten 现有组件、主题与权限/数量/来源约束。

所有数据库、Maven 输出、TMP、端口和证据目录必须独立。原审查目录只读保留；每轮使用新的 `--output`。这些脚本仅面向明确指定的本地回环 PostgreSQL，不连接公司库，不合并、推送、部署或打包。

- `run_final_a.py --root <最终独立工作树> --candidate <完整SHA> --output <新目录>` 默认只输出计划；Root 冻结后追加 `--execute` 才新编译并顺序运行原15类209项、owning26子集、DirectLot两例、旧程序编译、proof、双起点12副本和真实SQL投影变异。只接受同一干净HEAD、新隔离输出和自己创建的PG，不读取Root运行配置。详见 `docs/99-项目治理/公司网页反馈整改-20261110/A-最终后端整组执行入口-20261111.md`。
- `attest_candidate.py --root <工作树> --candidate <SHA> --output <新JSON>` 逐文件列出候选与7b的main/test/migration/contracts/pom/tools Git blob；不把源码比对当运行class证明，不更名旧通过来源。
- `compile_legacy.py --root <候选工作树> --output <全新目录>` 从 Git `86dffb9db` 干净编译 V1128 原业务程序，输出 `legacy-build`。
- `proof_probe.py --root <候选工作树> --output <全新目录>` 重演原 V1129 缩量反例，然后应用 V1130/V1131，并测量 513/1025/2049 个检查点及原始 EXPLAIN。使用一次性隔离容器，不修改旧证据。
- `upgrade_probe.py --root <候选工作树> --output <全新目录> --build-dir <候选隔离Maven输出> --legacy-build <V1128的legacy-build> --deps <依赖jar清单>` 公开造原单和两个修前草稿，保全原库及 dump，分别从 V1128 与已真实迁至 V1129 两个起点独立复制创建、编辑、审核数据库，V1129 起点迁候选前保留 dump；另用原 V1128 公开保存三材料各发 5000/计划 10000/产量 6000 草稿，再用独立副本验证两个起点的候选、新建、编辑和审核拒绝（12个候选副本；6次1129 staging；加旧库准备共19次单项launcher，分栏记数）。候选必须包含 V1130/V1131，输出目录需要同时包含 `classes`、`test-classes`；依赖清单是 Maven test scope 的分号分隔 jar 路径，不得混入旧产物目录。
- `projection_mutation.py --root <候选工作树> --output <全新目录> --build-dir <隔离Maven输出> --deps <jar清单> --runtime-config <本地私有JSON>` 在真实查询中验证两种相反岗位，另编译一个仅交换布尔表达式的类路径覆盖，要求业务断言失败，再恢复正确查询通过。产品源文件不被修改。
- `seed_browser.py` 使用同样的 `--root/--output/--build-dir/--deps/--runtime-config` 参数。先完成最终源码迁移，再运行它；`--compile-only` 仅编译、不连接数据库。输出普通报工编辑岗、独立审批岗、三材料各领 5000/计划 10000 的工单、草稿 300/配套 500 的工单和合法齐套工单，以及可打开的页面 ID。密码只取私有配置的 `syntheticAccountPassword`，不写证据 JSON 或命令参数。

私有配置包含 `jdbcUrl`（只支持 `jdbc:postgresql://127.0.0.1:...`）、`username`、`password`；浏览器造数另需与运行程序一致的 `bootstrapLogin`、`bootstrapPassword` 以及 `syntheticAccountPassword`、`jwtSecret`、`hmacKey` 和 `pgpMasterKey`，与最终运行后端保持一致；动态属性在 Spring 初始化前覆盖夹具常量，验证时不回显秘密。私有配置不进 Git。源码 Java 夹具复用正式业务服务造单，不关闭触发器、不补造历史序号或检查点。

`legacy_approved_read_only.sql` 仅作历史不确定记录的只读核查入口。缺乏证据不等于旧产量虚假；不得按查询结果自动红冲或改写旧账。核实原计划、需求与物料身份、发退料、实耗、品质/入库和成本/财务下游后，再由具备相应权限的现场岗位按原业务逆向流程决定处置。

Java 服务/SQL、Flutter VM、合成 API 浏览器、真实 Web→隔离服务→PG、桌面实际交互、Win7 真机分栏记录；不能将不同组拼成一个闭环或相加为新的用例总数。

`prepare_projection_database.py --upgrade-output <该轮upgrade输出> --output <新private/projection-runtime.json>` 只允许该轮专用容器及实际回环端口，另建全新空库，供投影变异使用。不得指向总验收或公司库。最终完整命令及source inventory保护提案见 `docs/99-项目治理/公司网页反馈整改-20261110/A-最终统一候选复跑计划.md`。
