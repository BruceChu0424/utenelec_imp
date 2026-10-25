# 临时逻辑换库启动护栏

适用单次已授权维护：旧应用 v2.5.29 与旧 OID、新应用 v2.5.30 与新 OID，保持同 cluster、5432/uten_imp。这是 root 显式安装的可撤除护栏，不在普通 installer 自动启用，不改变 Operations/updater/job、签名、备份、迁移、current 或 active-version 状态机。未安装前不能称现场已受保护。

## 校验和执行身份

`host/cutover-start-guard.py` 只读固定 `/etc/uten-imp/cutover-start-guard.json`。配置 root:root0600、单链接、真实文件；所有祖先 root 拥有且无 group/other 写权限。允许两个准确物理发行路径与 OID 配对，拒绝旧app+新DB、新app+旧DB和未知发行。签名 inventory、签名本身、trusted allowed_signers 都绑定受审 SHA；每次以固定 principal/namespace 实际 OpenSSH 验签，并核 inventory 中的 app/migrator JAR 与 `web/version.json` 字节。版本和 commit 取该已签 web 元数据，不凭可编辑的版本字符串认定真实代码。

代码不依赖 active-version.txt 判定本次启动：官方 updater 是先切 current、启动并健康后才写 active-version。把旧 active-version 当启动条件会阻断合法新版本；最终一致性仍由正式worker验收。current只允许root拥有的symlink，目标须为配置准确物理release。helper直接读取自身真实 `Path.cwd().resolve()`，必须与该物理current相同；不是调用者可提供的cwd证明。遗留WorkingDirectory指旧发行、current已新发行时明确拒绝。校验后复核同一symlink身份和实际cwd，发现并发替换拒绝。

ExecCondition 的 `+` 必须视为一次 root 边界：它绕过本unit的 User、capability 和文件系统 namespace限制。其后立即执行系统 `/usr/bin/setpriv`，只保留 SETUID/SETGID，清 inheritable/ambient 并开启NoNewPrivileges。helper以root读受保护配置/发行/签名，再以固定 `runuser postgres` 经 Unix `/run/postgresql:5432` 连接管理库 `postgres`；清理子进程环境，不传app密码或PGHOST/PGSERVICE/PGOPTIONS。不让 uten 读 pg_control_system，不给它新增系统权限。

只读SQL显式事务/statement与lock timeout/search_path=pg_catalog，查询实际 cluster system_identifier、PGDATA、port、uten_imp 名称映射的 OID、datallowconn、uten rolcanlogin、有效 CONNECT 与密码有效期。postgres是有系统权限的观察者，不能将其连接成功称为runtime连接成功；runtime授权字段各自核验。此门禁不证明HBA/实际密码认证、连接池容量或完整业务授权正确，那些仍须部署时实际runtime只读连接与发布oracle验收。

应用主进程仍保留原 User=uten-imp、EnvironmentFile、NNP、空cap和沙箱。v2配置新增必填 `runtimeProfile`，仅允许单一prod或internal-test，并与实际UTEN_PROFILE exact一致；cloud、复合、缺省/空值不接受。公司运行PID95015于2026-10-25 16:17:29Z只读实证为prod，已知Spring配置/数据源/profile及JVM自动注入键未出现；这只是该时点，不是未来窗口授权。v1配置不会被v2静默接纳。

护栏拒绝Spring datasource/config/profiles/main族与application JSON，以及JAVA_TOOL_OPTIONS、_JAVA_OPTIONS、JDK_JAVA_OPTIONS，连空值也拒绝；归一化覆盖常见大小写、点与下划线的relaxed binding别名。正常heap flags在受审ExecStart中保留，当前start-server.py不读取JAVA_OPTS，不把这个无效变量误当自动注入。仅在这些前置下，检查UTEN URL固定127.0.0.1:5432/uten_imp、uten角色；query仅允许空或currentSchema=public。helper所有子进程无继承app secret，错误只输出固定拒绝语句，不打印异常/口令/连接串。

**强外部门槛仍须落实：** helper不独立读取/认证systemd完整ExecStart、全部Spring外部来源或classpath。root必须机械核受信unit/launcher（下面完整readback）、没有旁置 `.env`/`application*`/`config/`，且整个独占窗口内它们不可变；同一受审已签JAR中的内置配置与profile也是前提。不能泛称只验UTEN两个键就证明JVM真实DataSource。只补cwd仍不能阻止一个错误的绝对旧JAR ExecStart，故canonical argv检查必不可少。

## systemd 拒绝与重试语义

正常不匹配、配置损坏、PG/签名子命令失败均返回1。`ExecCondition` 的1–254会跳过后续启动；这不同于反复失败的 ExecStartPre。临时drop-in额外 `Restart=no`，所以即使解释器崩溃、signal或unit timeout也不会自动重启风暴。完整验收撤掉准确drop-in后，正常base的 Restart=always 恢复。

开发WSL systemd259实测：在User普通用户/NNP1/空cap/ProtectSystem=strict/ProtectHome/PrivateDevices下，exact条件命令实际UID0、NNP1、Eff/Bnd=0xc0（仅SETGID/SETUID）、Inh/Amb0；委派nobody成功，子cap0；放行后的ExecStart仍普通用户、NNP1、cap0。`+`后的文件系统namespace仍被绕过，setpriv不重建它；固定root-owned只读代码是必要信任边界。此开发身份测试用既有nobody，未在公司新增OS或PG角色。

拒绝时实际inactive/dead、Result=exec-condition、MainPID0、NRestarts0，且Main没有运行；条件纠正后可显式再start。**外部重复start仍计StartLimit**：到限时CLI甚至可能返回0而无MainPID。不得依赖CLI0或Result残留。不要循环重试；保留journal和guard拒绝原因，确认真实配对纠正后等待窗口或在明确批准下对这个appunit一次reset-failed，再单次start并核PID/health。不能清Operations历史计数或把任务改绿。

依据：[systemd255 service ExecCondition与命令前缀](https://www.freedesktop.org/software/systemd/man/255/systemd.service.html)、[systemd255执行权限](https://www.freedesktop.org/software/systemd/man/255/systemd.exec.html)、[PG16控制与权限查询](https://www.postgresql.org/docs/16/functions-info.html)。255官方语义和259开发实测分开；安装前在现场实际systemd/util-linux版本复核，不把开发结果称现场演练。

## 配置：由受审真实证据生成

以下 schema 给出公司当刻已知非secret身份，SHA/新commit均必须从最终受信发行核真；REPLACE必定拒绝，不可直接当可用配置。若数据正式candidate OID重新创建，先取得新的接受证据，不沿用1801072。

```json
{
  "format": "uten-imp-cutover-guard-v2",
  "maintenanceId": "00000000-0000-0000-0000-000000000001",
  "runtimeProfile": "prod",
  "systemIdentifier": "7672666251697880435",
  "dataDirectory": "/data/postgresql/16/main",
  "allowedSigners": "/etc/uten-imp-updater/REPLACE_WITH_CURRENT_TRUSTED_SIGNERS",
  "allowedSignersSha256": "REPLACE_WITH_ACTUAL_SHA256",
  "signerIdentity": "uten-imp-release",
  "namespace": "uten-imp-release",
  "pairs": {
    "old": {
      "databaseOid": 1685044,
      "version": "v2.5.29",
      "commitSha": "3de31ae904b0a38cc74e455e5fda8e4de36439c4",
      "releaseDirectory": "/opt/uten-imp/releases/v2.5.29",
      "sumsSha256": "REPLACE_WITH_ACTUAL_SIGNED_INVENTORY_SHA256",
      "signatureSha256": "REPLACE_WITH_ACTUAL_SIGNATURE_SHA256"
    },
    "new": {
      "databaseOid": 1801072,
      "version": "v2.5.30",
      "commitSha": "REPLACE_WITH_FINAL_SIGNED_COMMIT",
      "releaseDirectory": "/opt/uten-imp/releases/v2.5.30",
      "sumsSha256": "REPLACE_WITH_ACTUAL_SIGNED_INVENTORY_SHA256",
      "signatureSha256": "REPLACE_WITH_ACTUAL_SIGNATURE_SHA256"
    }
  }
}
```

maintenanceId使用本次新UUID；runtimeProfile由实际运行profile与本次受审目标明确选择，不能自动推测；签名参数/公钥路径从真实root发布配置核对，不盲沿用示例。两个release不必同时已暂存才允许旧配对；只校验即将启动的准确发行，因而可以在下载新版本前保护旧版本启动。配置不存API钥/数据库密码。不要把手工布尔“签名已验”代替真实签名和字节校验。

## 安装片段：根复核后、正式窗口内执行

前置：全部真实writer已经停/隔离，协调者独占维护窗口，数据执行者是唯一换名者。guard只检查启动瞬间，不能阻止已运行旧JVM，也不能防止检查后另一管理员立刻rename；不能替代这个外部唯一写入者协议。根独立复核当刻old/new OID、cluster、signed artifacts、真实EnvironmentFile与权限。先保存root私有原像/SHA/inode；任一准确目标已存在但不属于本维护事务就停止，禁止覆盖未知旧护栏。

只安装这三项：

| 受审来源 | 目标 | 权限 |
| --- | --- | --- |
| host/cutover-start-guard.py | /usr/local/lib/uten-imp/cutover-start-guard.py | root:root0755 |
| 本次受审配置 | /etc/uten-imp/cutover-start-guard.json | root:root0600 |
| units/99-database-cutover-guard.conf.example | /etc/systemd/system/uten-imp.service.d/99-database-cutover-guard.conf | root:root0644 |

原子安装形状（绝不source server.env；每个source及目标父目录先做root/no-symlink/权限与预期SHA核对；temporary在目标同目录）：

```sh
# 受审配置与源码已准备，oldapp尚未进行任何跨OID启动。
atomic_install() {
  local source=$1 target=$2 mode=$3 temporary
  [ ! -e "$target" ] && [ ! -L "$target" ] || return 1
  temporary=$(mktemp "${target}.install.XXXXXXXX") || return 1
  install -o root -g root -m "$mode" "$source" "$temporary" || return 1
  /usr/bin/python3 -I -c 'import os,sys; f=os.open(sys.argv[1],os.O_RDONLY|os.O_NOFOLLOW); os.fsync(f); os.close(f)' "$temporary" || return 1
  mv -T -- "$temporary" "$target" || return 1
  /usr/bin/python3 -I -c 'import os,sys; f=os.open(sys.argv[1],os.O_RDONLY|os.O_DIRECTORY); os.fsync(f); os.close(f)' "$(dirname "$target")"
}
atomic_install "$reviewed/deploy/simple/host/cutover-start-guard.py" /usr/local/lib/uten-imp/cutover-start-guard.py 0755
atomic_install "$approved_policy" /etc/uten-imp/cutover-start-guard.json 0600
atomic_install "$reviewed/deploy/simple/units/99-database-cutover-guard.conf.example" /etc/systemd/system/uten-imp.service.d/99-database-cutover-guard.conf 0644
systemd-analyze verify /etc/systemd/system/uten-imp.service
systemctl daemon-reload
systemctl show uten-imp.service -p WorkingDirectory -p ExecStart -p EnvironmentFiles -p ExecCondition -p Restart -p User -p Group -p DropInPaths
```

上述函数必须在 `set -euo pipefail; umask 077`、目标目录已安全创建的root维护脚本内使用；失败清理由本次事务精确记录的temporary处理，不做glob删除。外层唯一维护者排除目标被root并发创建；若无法保证则不用此片段，补CAS事务后再执行。安装失败不得继续换库。

读回effective条件必须是exact setpriv命令、Restart=no，WorkingDirectory必须是字面 `/opt/uten-imp/current`，ExecStart/EnvironmentFiles/User/Group必须机械等于受审canonical入口。2026-10-25 16:21:16Z只读实机确为此cwd、唯一EnvironmentFile=/etc/uten-imp/server.env、canonical argv匹配，但维护安装后仍需重核。其他前置门禁保留，不以“原值没变”替代内容匹配。以下代码在root私有reviewed树和目标均已完成属主/路径/无symlink预检后运行，拒绝时不打印未知argv或环境：

```python
import hashlib, pathlib, re, shlex, subprocess, sys
reviewed = pathlib.Path(sys.argv[1])  # root私有且已核SHA的同一reviewed源码根
enabled = sys.argv[2] == 'enabled'    # 撤除后用disabled并核无其他condition
def show(key):
    return subprocess.run(['/usr/bin/systemctl','show','uten-imp.service','--property='+key,'--value'],
                          check=True,capture_output=True,text=True).stdout.strip()
def argv(key):
    return [shlex.split(value.strip()) for value in re.findall(r'argv\[\]=(.*?);',show(key))]
expected = ['/usr/bin/python3','-I','/usr/local/lib/uten-imp/start-server.py','-Xms512m','-Xmx4g',
            '-Dserver.address=127.0.0.1','-Dserver.port=8080','-Dspring.flyway.enabled=false',
            '-XX:+ExitOnOutOfMemoryError','-jar','server/uten-imp-server.jar']
condition = ['/usr/bin/setpriv','--bounding-set=-all,+setuid,+setgid','--inh-caps=-all',
             '--ambient-caps=-all','--no-new-privs','/usr/bin/python3','-I',
             '/usr/local/lib/uten-imp/cutover-start-guard.py']
assert show('WorkingDirectory') == '/opt/uten-imp/current'
assert argv('ExecStart') == [expected]
assert show('EnvironmentFiles') == '/etc/uten-imp/server.env (ignore_errors=no)'
assert show('User') == show('Group') == 'uten-imp'
assert argv('ExecCondition') == ([condition] if enabled else [])
assert show('Restart') == ('no' if enabled else 'always')
actual = pathlib.Path('/usr/local/lib/uten-imp/start-server.py')
assert hashlib.sha256(actual.read_bytes()).digest() == hashlib.sha256((reviewed/'deploy/simple/host/start-server.py').read_bytes()).digest()
physical = pathlib.Path('/opt/uten-imp/current').resolve(strict=True)
blocked = [physical/'.env', physical/'config']
for suffix in ('.properties','.yml','.yaml'):
    for profile in ('','-prod','-internal-test'):
        blocked.append(physical/('application'+profile+suffix))
assert not any(path.exists() or path.is_symlink() for path in blocked)
print('Canonical startup invocation and external-config absence: PASS')
```

新发行暂存后、实际切current前也要对新物理release做同一旁置文件/目录检查；检查目录缺失不等同认证已签JAR内部所有配置。root需把完整effective unit/drop-in与launcher SHA、EnvironmentFile私有摘要及配置来源清单记录在事务，禁止全窗口并发修改。若现场多了已知合法EnvironmentFile或参数，必须先审其内容/优先级并更新准确canonical清单，不能忽略差异继续切库或放宽通用匹配。

再用复用真实User/EnvironmentFile/WorkingDirectory的合成oneshot临时unit核root条件执行上下文；仅运行固定guard和`/usr/bin/true`，不启动Java、不改数据库。保存condition执行码、ExecMainStartTimestamp和Main是否实际执行；跳过时的systemctl exit0不算PASS。不要为测试两交叉而交换公司正式库；交叉由本地真实PG16隔离夹具证明。

再由数据执行者正式CAS换名/权限交接，官方root维护API创建真实新job。失败回启旧current时guard观察新OID并跳过，旧JVM无法从这条unit启动；Operations真实失败/恢复状态保留，禁止伪造成功。新current+新OID通过后由官方worker执行原健康与目录验收。

## 撤销与回退

成功边界：新OID/cluster、真实signed版本commit、实际新JVM、官方job与稳定健康、业务/附件验收全部确认。或完整回退边界：数据执行者已证明旧OID恢复到uten_imp、旧code/current与权限成套恢复且没有丢新写，旧配对实际通过。二者之一明确成立后，根才撤销；中间交叉状态不得撤掉护栏“救启动”。

撤销前把准确三文件与effectiveunit/journal保存在本次root私有事务；核准确当前文件SHA/inode仍等于本次安装像。仅将确名drop-in移到本次私有归档（与既有文件跨卷时先私有copy+fsync再核源CAS后unlink），daemon-reload，重跑上面的disabled机械核验：WorkingDirectory、完整ExecStart、EnvironmentFiles、ExecCondition为空、Restart恢复base always、app身份及launcher SHA/旁置配置检查；另核开机enable状态未变。helper/config随后可同样精确归档，不递归清目录，不触其他drop-in，不改current/active-version/job。重新核已运行新进程与NRestarts，无需仅为撤drop-in再次重启健康app；未来开机/正常更新不再受这两个固定OID限制。

临时Restart=no意味着本窗口新进程异常不会自动复活；根应保持监控，查实故障后单次受控启动。撤销完成才恢复正常自动重启。若护栏在重启时仍存在，它会继续按真实配对保护，不因reboot静默失效；过期维护的撤销必须有人完成，不能靠修改配置让任意组合通过。

## 聚焦验证

CI已有root `unittest discover -s deploy/simple -p test*.py`覆盖本测试，无新增跳过或降低门槛。独立调用：

```sh
sudo /usr/bin/python3 -B -m unittest discover -s deploy/simple -p test_cutover_start_guard.py -v
```

18项Linux-root测试保留原14项，新增已知Spring/自动JVM覆盖族的真实纯函数拒绝、local profile精确绑定、main在真实chdir下旧/新正例及双向stale cwd负例。测试采用真实OpenSSH签名，继续覆盖两合法配对、两交叉、签名/清单/JAR/commit、错误集群/OID/端口/PGDATA/observer、datallowconn/LOGIN/CONNECT/期限、配置权限/symlink/重复键、runtime目标漂移、current并发替换、secret不外传与原setpriv/Restart契约。另用独立postgres:16.15容器（无network、无ports、无host数据挂载、仅内存PGDATA）执行真实metadata SQL和换名、NOLOGIN/REVOKE/datallowconn/过期操作：8条配对/拒绝均通过，容器精确销毁。只有合成库角色发生变化，没有公司角色/业务库写入；这不替代现场root复核与真实激活。
