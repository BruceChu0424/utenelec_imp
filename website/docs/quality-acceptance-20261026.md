# 官网质量阶段验证记录

日期：2026-10-26（America/Denver）。工作树为 `C:/Users/bruce/.codex/worktrees/website-completion/uten_imp`，本阶段基于 `f9192c79dbaaf7507ede1659ea3a79550a97e4f6` 的本地候选增量。该记录证明下述源码检查和构建，不代替跨应用浏览器验收，也不代表已部署阿里云。

## 唯一公共入口及调用清单

正式质量入口仍是 `website/scripts/quality-gate.mjs`。现有 `.github/workflows/quality.yml` 官网任务与 `.github/workflows/website-release.yml` 的网站候选任务均调用该入口；官网 README 和 `deploy/README.md` 的源验收说明也统一指向它，不维护第二套公开检查脚本。

本轮把 Next 官方 `typegen` 放在 lint 和 `tsc --noEmit` 之前。首次从无 `.next` 的工作树完成该阶段，验证了当前 Next 16 的路由类型和 `next-env.d.ts` 能在干净目录生成，不再依赖某位开发者之前启动过 `next dev`。

PostgreSQL 测试继续复用 `tests/helpers/isolated-postgresql.ts` 的唯一 `createIsolatedPostgresqlDatabase`：`cms-revisions.test.ts` 与 `series-media-postgresql.test.ts` 全部调用它。本轮只增加可选绝对 `UTEN_TEST_POSTGRESQL_CONFIG`，默认旧配置路径保持兼容；固定 loopback/55439、随机库名、库主校验及定向删除保护未放宽。没有向运行中的联调库写测试夹具。

## 本轮变更范围与保留差异

| 范围 | 处理及调用方 |
|---|---|
| `scripts/quality-gate.mjs` | 统一增加 Next route typegen；两个既有 CI 调用方共用，不复制新流程 |
| `tests/helpers/isolated-postgresql.ts` | 可选本机私密配置入口；CMS 与非空图库迁移均接入同一隔离库合同 |
| `tests/legacy-series-content-repair.test.ts` | 完整离线档案审查预算从 30 秒调至 120 秒，保留全部 2157 份原始 HTML、148 个本地化分类及 32 个有界并发读；未截断、跳过或改变断言 |
| `README.md`、`.env.example` | 同步 Next 16/React 19、双 Prisma、私有 PDF、IMP PKCE/租约和持久拉取/ACK；不再把已移除的即时推送描述成当前流程 |
| `deploy/README.md` | 源验收统一到正式 gate；明确旧 SQLite 执行链不能直接承接 PostgreSQL 或私有 documents 的生产恢复 |

Next/React/Prisma/ESLint 版本和锁文件沿用当前基准，本轮未做依赖升级或兼容性回退。UI 与设计说明继续使用 `frontend-design`，官网保留公司及产品展示、联系销售语义，不引入购物车、支付或下单。

已移除的重复维护点是部署 README 内独立列出的 install/lint/裸 tsc/test/migration 命令组合，由同一个 gate 取代。SQLite 生产包合同与 PostgreSQL 运行支持保留为明确差异，未为了“统一”绕开生产路径、权限、备份或签名要求。

## 当前已通过结果

| 校验 | 结果 |
|---|---|
| 锁定安装 | `npm ci --ignore-scripts=false` 通过；双 Prisma 客户端生成通过 |
| Next 路由类型 | `next typegen` 通过 |
| ESLint | exit 0，0 error、0 warning（仍保留 `--max-warnings 0`） |
| TypeScript | `tsc --noEmit` exit 0 |
| 最终网站全测试 | **133/133 通过，0 失败、0 取消、0 跳过** |
| 旧站原始证据 | 全部 **2157** 份详情、**148** 个本地化分类通过；50 类中文名称无冲突，实际约 41.2 秒 |
| PostgreSQL CMS 与非空图库 | 已启用 opt-in 并纳入上述全集；另有独立 CMS 14/14 与图库迁移 1/1 通过，所有随机测试库均回读 `dropped=true` |
| 正式 SQLite 迁移 | 5 个版本从空库应用并校验通过 |
| 全部依赖 audit | 0 vulnerabilities |
| 生产依赖 audit | 0 vulnerabilities |
| 空构建库 schema contract | Python 生成成功；114 个对象，SHA256 `cea6b2ae4f856667a0f1a587e50d1c4d22f9db2d02b9d3d5a13b78ff4b0ecf34` |
| 生产构建 | Next.js 16.4.2、Webpack，`npm run build` exit 0；优化编译约 31.8 秒，类型、路由及构建收尾均完成 |

生产构建环境为 Windows、Node `v24.19.0`，使用另一座新迁移空 SQLite 库，未把测试数据编入构建输出。该结果不是 Linux ECS 安装产物或云端运行证明。Python 使用本机可用的 LibreOffice Python 3.13.15；旧 bundled Python 的标准库初始化故障未通过修改用户运行时来掩盖。

锁文件 SHA256：`09b39e1ae02c50b04af573008b18a9fd017ab4e6fbd3a6c79d238098464cfb7f`，续作检查前后相同。

## 失败处理与证据完整性

首轮补齐原始档案后，旧站审查撞到原 30 秒预算。该用例检查档案完整性而非网页速度，已保留完整数据及有界读并发，只调整合理的离线审查时间；最终不再跳过原始证据。

随后新增 health 测试的环境恢复逻辑触发 Next 类型声明中的只读 `NODE_ENV`，正式 gate 的 `tsc` 如实失败。对应测试已改为保留 `finally`、未定义值删除和 `Object.assign` 恢复，没有放宽类型或跳过检查。

锁定安装已经成功，按主任务协调要求未重复安装；在同一锁定依赖环境中重新执行 fresh migration、typegen、lint、tsc、全部测试、正式迁移、两次 audit、另一空库 schema contract 和生产 build，全部成功。修前失败日志保留，不能把它描述为“正式 gate 脚本从头一次通过”。续作编排仅为忽略目录中的本次验证材料，正式 CI 入口仍只有原 gate。

证据位于工作树根 `.local-artifacts/website-completion/quality/`：

- `quality-gate.first-attempt.log`：原始档案 30 秒超时记录。
- `quality-gate.log`：成功安装/生成、修前 TypeScript 诊断。
- `quality-continuation.log`：最终全部后续检查及 `WEBSITE_QUALITY_CONTINUATION_OK`。
- `verification-summary.json`：各阶段 exit code、耗时、Node/锁文件信息。
- `sqlite-schema-contract.json`：空构建库合同。
- `postgresql-cms-tests.log`：独立 CMS PostgreSQL 补验；图库与随机库清理回执保留在 `.local-artifacts/website-imp/postgresql-tests/`。

## 阶段边界与后续绑定

本阶段覆盖共享目录/资料查询、图库与 Studio 入口、多语言导航、PDF 就绪检查、22 MiB 管理上传封套等本轮已冻结实现及其测试。本记录尚不包含随后补充的案例详情 `/cases/[slug]`、十语言事实文案和主任务 UI 验收中的后续源码修复，须在最终冻结后补增量 lint、类型/相关测试和直接 `next build --webpack`，将最终源码与构建结果重新绑定；不得重装或删除正在进行 UI 验收的开发环境。

销售收件、认领、跟进、IMP 到 CMS 进入、草稿/预览/发布/恢复、真实资料上传下载等跨应用 UI 证据由主任务独立收集，不能用本表代替。阿里云 ECS 与公司本地 ERP 的操作说明见 [联动手册](aliyun-local-erp-integration.md)。云端 PostgreSQL、图片和私有 documents 的一致备份/恢复及签名发布准备仍需部署阶段另行验证，当前未执行云端部署。
