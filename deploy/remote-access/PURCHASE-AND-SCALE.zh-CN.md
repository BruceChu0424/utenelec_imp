# 阿里云采购、成本和扩容清单（5 人远程入口）

核查日期：2026-10-17。以下区分官方可核验单价、账户专属报价和预算假设；没有代购、创建资源或把促销承诺成长期续费价。实际选择以企业账号、地域库存、购买时长及订单为准。

## 1. 推荐的第一套配置

| 项目 | 具体选择 | 原因 |
|---|---|---|
| ECS | 1 台，`ecs.u1-c1m2.large`，2 vCPU / 4 GiB；企业官网正常购买规格 | 云只做 stream + TLS 封装 + WireGuard，5 人不需要云数据库或大型实例；规格由官方清单确认 |
| ECS购买周期 | 默认包年包月购买1年，比较同账号新购和续费价 | 不用按量ECS或只买1个月来直接申报大陆接入备案；官方备案表要求包年包月且累计购买时长大于3个月 |
| 系统 | Ubuntu 24.04 LTS x86_64 官方公共镜像 | 与本目录实际 Nginx 1.24/stream 测试环境一致，避免第三方预装面板 |
| 系统盘 | 40 GiB ESSD Entry，无额外数据盘 | 存系统、配置和轮转连接日志；不存业务数据；如促销绑定 80 GiB，保留套餐不要盲目变配 |
| VPC/交换机 | 专用小 VPC/单交换机，与公司 LAN/WG 网段不冲突 | 不连接公司整段局域网；云服务身份不持有业务权限 |
| EIP | 与 ECS 同地域，BGP 多线、单独 EIP | 方便以后换 ECS；不要同时买固定公网 IP 和 EIP 重复付费 |
| 带宽 | 性能优先预算可选固定 10 Mbps；费用敏感先按流量峰值 20 Mbps 做 1 周试点 | 固定 10 Mbps 的基准费用明显高于 5 Mbps，见下表；不是把峰值 20 Mbps 当作保证值 |
| 域名 | 公司实名普通 `.com`；使用 `erp.<域名>` | 若已有合适公司域名，可只新增子域名，省去再次注册 |
| 员工 TLS | 公司 DNS-01 签发 Let's Encrypt 正式证书，自动续期 | 证书费用 0，私钥/ACME 账号只在公司；需承担续期监测 |
| 可选 OSS | 首期不为这个入口新增业务/备份 Bucket | 继续现有发布包用途；公司业务数据库、附件、备份保持现有本地合同 |

[`ecs.u1-c1m2.large` 官方规格](https://help.aliyun.com/en/ecs/user-guide/overview-of-instance-families)为 2 vCPU / 4 GiB。若目标地域已无库存，比较同为 2/4 的 `ecs.u2a-c1m2.large` 等当前可售通用算力规格，重新核价并验证，不用经济型/突发型的宣传峰值推导持续 TLS 性能。实例清单里的 Gbit/s 是实例网络能力，不是已购买公网 Mbps。

地域不能仅凭“杭州便宜”确定。以公司位置附近的杭州/上海/深圳等为候选，先测公司实际出口到候选地域的工作时段 RTT、丢包、抖动及上行，再锁定一个地域购买；偶尔海外用户另从其真实所在地测试。默认不把公司业务链绕到香港，也不为“偶尔海外”先上全球加速或跨境专线。

对固定5名员工，优先安装正式原生客户端：应用资源随签名安装包分发，远程时主要传API与用户实际打开的附件，服务器端点仍由批准的构建配置决定。浏览器保留为补充；必须单独实测首次启动、版本升级资源下载、5人同时冷启动和热缓存，不能把普通API的P95目标套到首次加载。10Mbps约1.25MB/s是整个入口共享的理论上限，5人同时下载Flutter Web资源可能明显变慢；双层TLS下云无法对明文内容做L7缓存，不能为提速把员工域名证书私钥搬到云端。

## 2. 已核验的费用与未核定项

| 项目 | 当前可核验价格/算法 | 新购和续费口径 |
|---|---|---|
| 固定带宽 EIP，5 Mbps | 杭州/上海/北京/深圳等基准 **125 元/月** | 普通公有云目录价；包年优惠/地域差异以订单为准 |
| 固定带宽 EIP，10 Mbps | **125 + (10−5)×80 = 525 元/月** | 不把 5 Mbps 后每 Mbps 的价格当成前 5 Mbps 的平均价 |
| 固定带宽 EIP，20 Mbps | **125 + (20−5)×80 = 1325 元/月** | 10→20Mbps增加 **800元/月**；升配当期差价按剩余周期计算 |
| 按流量 EIP/CDT | 内地账号共享前 **20 GB/月** 免费；超出后首 10 TB **0.80 元/GB** | 新开通按流量 EIP 已纳入 CDT；账户其他产品会共享免费额度 |
| EIP 保有费 | BGP EIP 直接绑定 VPC ECS，账号 EIP 配额≤2000 时通常免该项；其他适用场景内地 **0.02 元/小时/个** | 不把未绑定/绑定网卡等情形都写成免费；按实际关联方式核验 |
| 普通 `.com` 域名 | 万网当前普通词查询示例 **85 元首年、95 元/年续费** | 特殊词、活动资格和选定名称不同；提交订单前核对 |
| Let's Encrypt 正式证书 | **0 元证书费** | DNS-01 自动化和运维人工不等于 0 成本；不能把阿里云测试证书替代它 |
| 阿里云付费正式 DV（比较项） | Rapid 单域名目录价 **485 元/1 年订阅**，242.50 元/6 个月 | 2026-05-06 调价公告；换 CA 须另行审查签发控制/CAA，不直接套当前 LE 模板 |
| 可选 OSS 标准本地冗余 | 以 **0.12 元/GB/月**示例核算，100 GB≈12 元/月，仅存储 | 旧版本、请求、取回/外网流量另计；不是 12 元包全部备份服务 |
| ECS 2/4 + 40 GiB | **需企业账号购买页/只读询价 API 核价** | 不用社区文章代替官方实时订单；新购、续费、变配差价分别保存 |

来源：[EIP 包年包月](https://help.aliyun.com/zh/eip/subscription)、[EIP 按量付费/保有费](https://help.aliyun.com/zh/eip/pay-as-you-go/)、[CDT 公网流量](https://help.aliyun.com/zh/cdt/internet-data-transfers/)、[万网普通词查询价格示例](https://wanwang.aliyun.com/domain/searchresult/?keyword=sozolabz&suffix=.com)、[域名定价说明](https://wanwang.aliyun.com/help/price.html)、[Let's Encrypt 免费正式证书](https://letsencrypt.org/about/)、[阿里云正式证书调价](https://help.aliyun.com/zh/ssl-certificate/product-overview/announcement-price-adjustment-of-some-brand-certificates)、[OSS 存储费用](https://help.aliyun.com/zh/oss/storage-fees)。

阿里云官方证书选型文档当前写明个人测试证书（免费/pro）不能用于生产环境，不能把“每年 20 张免费测试证书”算作本 ERP 的生产保障。[官方证书选型](https://help.aliyun.com/zh/ssl-certificate/functions-and-features)。正式证书的**订阅期**也不等于单张证书的有效期，仍需自动补签/轮换。[证书订阅变化](https://help.aliyun.com/zh/ssl-certificate/product-overview/notice-ssl-certificate-is-upgraded-to-subscription-service-mode)。

检索到的官方旧 `99program` 规则出现过 2/4、5 Mbps、80 GiB 的 199 元/年套餐，但该可见规则写的截止时间是 2026-03-31；当前活动页动态报价在本次环境未能核验。因此 **199 元不列入已确认预算**。即使企业账户现在显示新活动，也要截存新购资格、绑定配置、续费条件和活动截止日期，不能承诺“以后永远 199”。官方入口：[ECS 活动](https://www.aliyun.com/daily-act/ecs/activity_selection)、[ECS 选型](https://www.aliyun.com/product/ecs)。若套餐已经含公网带宽，不再直接叠加上表 EIP 费用；先核对是否允许换 EIP以及变配后是否失去套餐权益。

开通流程是先企业/域名实名，购买符合条件的大陆ECS并绑定EIP，再到“可备案实例管理”确认实例可选、完成域名接入备案后才正式开放；非80/443端口也不是备案豁免。官方备案表要求包年包月、累计购买时长大于3个月和公网带宽，本方案默认买1年。不要把下面的月度只读询价当成“只买1个月即可备案”。[备案服务器检查](https://help.aliyun.com/zh/icp-filing/basic-icp-service/user-guide/icp-filing-server-access-information-check)。官方也列出了为ECS节点绑定EIP以满足公网接入条件的方式，绑定后仍要核对实际账号里的备案资格，不另买重复公网IP。[备案前期准备](https://help.aliyun.com/zh/icp-filing/basic-icp-service/user-guide/overview/)。

## 3. 总成本如何算

记 `C` 为**当前账号已确认的 ECS + 系统盘月均价**，`D` 为本账户内地可用免费额度后实际出网总量；以普通 `.com` 新购 85、LE 证书 0 为例：

| 方案 | 第一年总价，不含人工/可选项 | 对应特点 |
|---|---|---|
| 固定 5 Mbps | `12C + 1500 + 85` 元 | 成本可预测，5 人同时冷加载/传附件可能明显排队 |
| 固定 10 Mbps | `12C + 6300 + 85` 元 | 更充裕的固定带宽；公司上行不足仍不会变快 |
| 按流量，月总量 100 GB且完整20GB免费额度可用 | `12C + 768 + 85` 元 | 峰值设 20 Mbps；费用约64元/月，峰值不属于承诺指标 |
| 按流量，月总量 300 GB且完整20GB免费额度可用 | `12C + 2688 + 85` 元 | 费用约224元/月；达到此量应重新比较固定5/10Mbps |

为准备采购额度，**假设而非官方报价** `C=100～200 元/月`，上述首年预算分别约 **2785～3985、7585～8785、2053～3253、3973～5173 元**。拿到 `C` 后立刻替换；如果账户有真实套餐优惠，按完整套餐重算。次年域名按示例95计，ECS续费必须重新核价。公司备线、UPS、云第二节点和监控付费产品另列，不混入此处。

同一假设折算月均（含域名首年摊销，不含可选项）：固定5Mbps约 **232～332元/月**，固定10Mbps约 **632～732元/月**，按流量100GB约 **171～271元/月**，按流量300GB约 **331～431元/月**。明确推荐：若接受约六七百元月预算，选固定10Mbps；只偶尔轻量单据操作、愿意先测量时，选按流量20Mbps峰值试点；固定5Mbps适合附件很少且首次加载体验已验收的场景。

固定10Mbps是5人原生端/API的期初采购起点，不承诺任何文件或浏览器首次启动都能秒开。实测冷启动/附件目标不达标且瓶颈确在带宽时，固定20Mbps在同一计算盘预算假设下约 **1432～1532元/月、17185～18385元/首年**；也可评估按流量更高峰值，仍以实际用量、账单与峰值保障差异决定。

固定 5 Mbps 与 0.8 元/GB的单纯网络费交点约 `20+125/0.8=176.25 GB/月`，固定 10 Mbps约676.25 GB/月；免费额度已被其他服务使用时交点相应下降。这只是成本比较，不代表两种计费模式带宽保障相同。按流量 EIP 峰值官方不作业务承诺，性能优先并希望固定额度时选固定带宽。[EIP 计费保障区别](https://help.aliyun.com/zh/eip/pay-as-you-go/)。

本架构云出向流量既包括云→员工的响应，也包括云→公司的请求/上传与协议开销；不能只统计员工下载。公司的上行决定多数响应速度。带宽估算可用 `并发数×单次响应字节×每秒请求数×8×安全余量`，再加上传/附件峰值；不要用“最多5个人”直接推定1Mbps足够。5Mbps约0.625MB/s、10Mbps约1.25MB/s是理想换算，实际还要扣除协议与争用。

## 4. 不购买也能完成的精确核价

在公司受控运维终端使用阿里云官方 CLI，采用已授权只读账户/临时角色，凭据走官方配置链，不写到 ECS 或本目录。先选择地域和官方 Ubuntu24.04 镜像ID，再用 [DescribePrice](https://help.aliyun.com/zh/ecs/developer-reference/api-ecs-2014-05-26-describeprice) 查询，不调用 Create/RunInstances。示例参数（镜像ID以 DescribeImages 返回的真实ID替换）：

```bash
aliyun ecs DescribePrice --RegionId cn-hangzhou --ResourceType instance --InstanceType ecs.u1-c1m2.large --ImageId APPROVED_UBUNTU_2404_IMAGE_ID --PriceUnit Month --Period 1 --SystemDisk.Category cloud_essd_entry --SystemDisk.Size 40 --InternetMaxBandwidthOut 0 --Amount 1
aliyun ecs DescribePrice --RegionId cn-hangzhou --ResourceType instance --InstanceType ecs.u1-c1m2.large --ImageId APPROVED_UBUNTU_2404_IMAGE_ID --PriceUnit Year --Period 1 --SystemDisk.Category cloud_essd_entry --SystemDisk.Size 40 --InternetMaxBandwidthOut 0 --Amount 1
```

另外保存包年购买页的实际新购价与 [DescribeRenewalPrice](https://help.aliyun.com/zh/ecs/developer-reference/api-ecs-2014-05-26-describerenewalprice) 的现有实例续费报价；后者需要真实实例ID，购买前不得虚构。活动最终优惠未必全部反映在 API 价中，付款前订单才是最终核定。报价记录包含日期、地域、SKU、盘、网络是否已含、周期、优惠资格、税费口径及续费价，不保存令牌和付款信息。

## 5. 随业务扩展的顺序

1. **0→5人试点**：一台2/4入口，实际三网/海外地点测一周。选择固定10Mbps作为性能优先配置；若先用按流量20Mbps，设用量/余额告警，报告真实高峰后再转换，告警不会自动封顶费用。
2. **先看公司网络**：公网入口带宽未满但API慢，先看公司上行/RTT、接口次数、数据库锁/池等待。增加公司第二运营商或移动备线；它解决公司单线路故障，第二台云ECS不能替代它。
3. **再升带宽**：当实际出口持续接近购买上限，或5人冷加载/上传产生明显排队，再从5升10/20Mbps。EIP固定带宽>5Mbps每增加1Mbps的目录费用较高，升级前保存差价。固定带宽升配可实时生效，降配/计费转换有不同时间规则，以官方变配规则执行。[EIP 变配](https://help.aliyun.com/zh/eip/subscription)。
4. **再升计算**：只有云CPU持续高、TLS握手/吞吐是瓶颈时再到4vCPU8GiB；云升CPU不修复公司慢SQL。先保留EIP，准备可回滚的新实例/维护窗口，验证同一受控配置、证书和负向网络边界后替换。
5. **提高可用性**：另一个可用区第二入口、独立机器证书、不同WG peer和公司备线，规划L4负载均衡/DNS健康切换与单写策略。当前模板严格只允许单peer，不能简单添加LAN网段/多个宽泛AllowedIPs。DNS切换受TTL与客户端缓存影响，不能承诺无缝切换正在提交的请求。
6. **更多远程并发**：先测远程8请求预算的429、LAN P95和数据库资源，再调整remote connector容量；不是按用户数线性扩大Hikari。请求预算至少比池上限少4只是名义容量校验，单请求嵌套事务可能占多个连接，不构成物理连接预留，也不代表CPU/磁盘/锁已隔离。
7. **海外成为经常性需求**：从具体国家/运营商测量后再评估专门加速。不得为加速而把员工TLS私钥、JWT/数据库密钥放到云端；任何L7 CDN/WAF产品改变TLS终结位置都须重新评审威胁模型。

OSS若以后用于异地加密备份，必须另立备份项目：公司本地加密、独立密钥、独立写入身份、恢复/删除身份分离、明确WORM保留期和恢复演练。版本控制会保留旧版本并继续计费，不等于防删除；不要给ECS转发入口任何Bucket权限。本入口采购不要求新增OSS备份或改变当前数据位置。
