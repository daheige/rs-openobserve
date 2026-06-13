# OpenObserve 架构设计与部署指南

> 版本：v0.91.0  
> 场景：1000GB/30天单机部署  
> 部署方式：Docker Compose / Kubernetes StatefulSet  
> 语言：Rust Edition 2024  
> 协议：AGPL-3.0  
> 更新日期：2026-06-10

---

## 目录

1. [项目概述](#一项目概述)
2. [整体架构分层](#二整体架构分层)
3. [核心组件详解](#三核心组件详解)
4. [源码 Crate 模块组织](#四源码-crate-模块组织)
5. [核心数据结构设计](#五核心数据结构设计)
6. [关键算法与机制](#六关键算法与机制)
7. [Rust 并发与异步模型](#七rust-并发与异步模型)
8. [技术栈精确版本](#八技术栈精确版本)
9. [本地单机部署方案](#九本地单机部署方案)
10. [参考文档](#十参考文档)

---

## 一、项目概述

OpenObserve 是一个基于 Rust 构建的云原生可观测性平台，支持日志、指标、追踪（Logs/Metrics/Traces）的统一采集、存储、查询和分析。采用现代数据栈实现了 **140 倍于 Elasticsearch 的存储成本降低** 和单二进制部署能力。

### 核心特性

- **单二进制部署**：一个 Rust 二进制文件包含所有组件，2 分钟启动
- **完全无状态（Stateless）**：计算节点不保存数据，故障时快速重启
- **S3-native 存储**：直接以对象存储为数据湖，无需维护本地热/温/冷分层
- **多租户原生**：Organization 和 Stream 作为一级概念，数据完全隔离
- **OpenTelemetry 原生**：直接接收 OTLP 协议，避免供应商锁定
- **SQL + PromQL 双查询语言**：兼容多种查询习惯
- **VRL 实时数据转换**：无需外部流处理工具即可完成数据转换

### 项目元信息

| 字段 | 值 |
|------|-----|
| 名称 | openobserve |
| 版本 | 0.91.0 |
| Rust Edition | 2024 |
| 开源协议 | AGPL-3.0 |
| 发布状态 | publish = false（不发布到 crates.io）|

### Features 特性开关

| Feature | 说明 |
|---------|------|
| `default = []` | 默认无特性 |
| `enterprise` | 企业版功能 |
| `vectorscan` | 向量扫描加速 |
| `cloud` | 云部署模式 |
| `vortex` | Vortex 压缩格式（`config/vortex`） |
| `mimalloc` | 使用 mimalloc 内存分配器 |
| `jemalloc` | 使用 tikv-jemallocator |
| `profiling` | 性能分析（含 jemalloc + pprof） |
| `pyroscope` | 持续性能分析（Pyroscope 集成） |
| `tokio-console` | Tokio 调试控制台 |

### Build Profile 配置

| Profile | 配置 | 用途 |
|---------|------|------|
| `[profile.release]` | `debug=false`, `strip=true` | 标准生产发布 |
| `[profile.release-ci]` | `opt-level=1`, `codegen-units=16`, `lto=false`, `debug-assertions=true` | CI 快速构建 |
| `[profile.release-prod]` | `codegen-units=1`, `lto=thin` | 极致优化发布 |
| `[profile.release-profiling]` | `debug=true`, `split-debuginfo=packed`, `codegen-units=4` | 性能分析构建 |

---

## 二、整体架构分层

OpenObserve 采用 **完全无状态（Stateless）** 的节点架构，所有组件均可水平扩展，数据持久化交由外部对象存储（S3/MinIO/GCS）和元数据库（PostgreSQL/SQLite）负责。

### 部署模式

| 模式 | 适用场景 | 协调器 | 元数据存储 | 数据存储 |
|------|---------|--------|-----------|---------|
| **单节点模式** | 测试、轻量生产、<< 2TB/天 | 内置 | SQLite | 本地磁盘或对象存储 |
| **HA 高可用模式** | 生产环境、PB 级规模 | NATS（推荐）或 etcd | PostgreSQL | 对象存储（S3 等） |

在 HA 模式下，Router、Querier、Ingester、Compactor、AlertManager 均可独立水平扩缩容，通过 NATS 进行节点发现与集群事件协调。

### 架构全景图

```
┌─────────────────────────────────────────────────────────────────────┐
│                        数据摄入层 (Ingestion)                        │
│  Fluentd/Fluent Bit → Prometheus Remote Write → OTel Collector       │
│         ↓                    ↓                    ↓                │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                        Router (5080/5081)                    │   │
│  │              HTTP/gRPC 请求路由 / 负载均衡                    │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                              ↓                                      │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                      Ingester (摄入引擎)                     │   │
│  │  HTTP接收 → 解析&VRL → Schema检查 → 实时告警 → WAL → Memtable │   │
│  │  → Immutable → 本地Parquet → 合并 → S3上传                    │   │
│  └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
                                    ↓
┌─────────────────────────────────────────────────────────────────────┐
│                        存储层 (Storage)                              │
│  ┌────────────────────────┐    ┌──────────────────────────────┐    │
│  │  S3 / MinIO / GCS      │    │  本地磁盘缓存 (WAL + Parquet) │    │
│  │  对象存储              │    │                              │    │
│  └────────────────────────┘    └──────────────────────────────┘    │
│  Apache Parquet 列式存储                                            │
│  • 压缩率 ~40x (vs Elasticsearch)                                    │
│  • Arrow 内存格式零拷贝                                              │
│  • 按时间分区 + 列裁剪                                                │
└─────────────────────────────────────────────────────────────────────┘
                                    ↓
┌─────────────────────────────────────────────────────────────────────┐
│                        查询层 (Query)                                │
│  ┌──────────┐ → ┌────────────┐ → ┌──────────────┐ → ┌──────────┐  │
│  │ Query    │ → │ File List  │ → │ Partition &  │ → │ Query    │  │
│  │ Leader   │ → │ Index      │ → │ Dispatch     │ → │ Worker   │  │
│  │ SQL解析  │ → │ PostgreSQL │ → │ gRPC分发     │ → │ 本地执行 │  │
│  └──────────┘   └────────────┘   └──────────────┘   └──────────┘  │
│       ↓              ↓                    ↓              ↓          │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  Apache DataFusion + Arrow RecordBatch + Tantivy Index    │   │
│  │  + Parquet Reader + Memory Cache (50% 内存)                 │   │
│  └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
                                    ↓
┌─────────────────────────────────────────────────────────────────────┐
│                      集群协调层 (Coordination)                       │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐              │
│  │ NATS         │  │ etcd (备选)  │  │ PostgreSQL   │              │
│  │ JetStream    │  │ 分布式协调   │  │ 元数据存储   │              │
│  │ 节点发现/心跳│  │ 服务注册/选举│  │ Schema/用户  │              │
│  └──────────────┘  └──────────────┘  └──────────────┘              │
└─────────────────────────────────────────────────────────────────────┘
                                    ↓
┌─────────────────────────────────────────────────────────────────────┐
│                      后台组件 (Background)                           │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐              │
│  │ Compactor    │  │ AlertManager │  │ Index Builder│              │
│  │ 文件合并     │  │ 告警管理     │  │ 倒排索引构建 │              │
│  │ 数据保留策略 │  │ 标准/定时告警│  │ Tantivy索引  │              │
│  └──────────────┘  └──────────────┘  └──────────────┘              │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 三、核心组件详解

### 1. Router（路由层）

作为统一入口代理，负责将外部请求分发到 Ingester（写入）或 Querier（查询），同时提供 Web UI 静态资源服务。所有组件通过 HTTP(5080) 和 gRPC(5081) 暴露接口。

### 2. Ingester（摄入层）

这是架构中最复杂的组件，负责数据接收、转换、缓冲和持久化。其内部采用 **多级缓冲流水线**：

```
HTTP/gRPC 请求 → 解析 & VRL 转换 → Schema 检查 → 实时告警评估 
    → WAL 写入 → Memtable(Arrow) → Immutable → 本地 Parquet 
    → 合并 → S3 上传
```

**关键机制**：

- **WAL（Write-Ahead Log）**：数据先写磁盘保证持久性，位于 `data/wal/logs`
- **Memtable**：基于 Apache Arrow RecordBatch 的内存缓冲，按 `organization/stream_type` 隔离
- **Immutable**：当 Memtable 达到 256MB 或 WAL 达到 128MB 时转为只读，每 5 秒刷盘为 Parquet
- **Parquet 合并**：每 10 秒检查本地文件，将小文件合并为最大 2GB 的标准文件后上传 S3

Ingester 查询时需要同时扫描 **Memtable + Immutable + 未上传的本地 Parquet** 三部分数据。

### 3. Querier（查询层）

完全无状态的查询引擎，基于 **Apache DataFusion** 构建：

1. **Query Leader** 接收 SQL/PromQL 请求，解析并验证
2. 从 File List Index 获取时间范围内的 Parquet 文件列表
3. 将文件列表分片给多个 **Query Worker**（通过 gRPC 分发）
4. 各 Worker 从 S3 拉取 Parquet 文件，利用 DataFusion 并行执行
5. Leader 聚合结果返回

**性能优化**：

- 默认使用 **50% 可用内存** 缓存 Parquet 文件
- 支持 Ingester 通知式缓存（新文件上传时主动通知 Querier 预热）
- 列裁剪、分区剪枝、谓词下推减少 I/O

### 4. Compactor（压缩层）

后台运行，负责：

- 合并小文件（<< 128MB）为大文件（最大 2GB），提升查询效率
- 执行数据保留策略（Retention）
- 全流删除（Stream deletion）
- 更新 File List Index

### 5. AlertManager（告警层）

支持两种告警模式：

- **Standard**：基于实时数据流的告警
- **Scheduled**：基于历史数据的定时查询告警

### 6. 集群协调与元数据

| 组件 | 技术选型 | 职责 |
|------|---------|------|
| **集群协调** | NATS（推荐）/ etcd | 节点发现、集群事件、节点信息 |
| **元数据存储** | PostgreSQL / SQLite | 组织、用户、Stream Schema、告警规则、文件列表索引 |

---

## 四、源码 Crate 模块组织

OpenObserve 采用 Rust Workspace 多 Crate 架构，按功能域垂直拆分。

### 顶层项目结构

| 目录/文件 | 职责 |
|-----------|------|
| `Cargo.toml` | Workspace 定义，管理所有 Crate 依赖 |
| `src/` | 主源码目录，包含所有 Rust Crate |
| `proto/` | gRPC Protobuf 定义（`cluster.proto`、`search.proto` 等） |
| `web/` | 前端 UI（基于 Vue.js 构建后嵌入二进制） |
| `tests/` | 集成测试套件 |
| `deploy/` | Kubernetes/Helm 部署模板 |

### Workspace Members（8 个 Crate）

| Crate | 路径 | 职责 |
|-------|------|------|
| `config` | `src/config` | 配置管理（`ZO_*` 环境变量） |
| `infra` | `src/infra` | 基础设施（cache/cluster/errors） |
| `ingester` | `src/ingester` | 摄入引擎（WAL/Memtable） |
| `wal` | `src/wal` | **独立的 WAL 预写日志 Crate** |
| `proto` | `src/proto` | gRPC Protobuf 协议定义 |
| `report_server` | `src/report_server` | 报表服务 |
| `flight` | `src/flight` | **Arrow Flight SQL 协议实现** |
| `tantivy_utils` | `src/tantivy_utils` | Tantivy 全文索引工具 |

> **关键发现**：WAL 是独立 Crate，不是 ingester 的子模块；新增了 `flight` Crate 用于 Arrow Flight SQL 协议。

### src/ 目录下的核心 Crate 详细

| Crate | 职责 | 关键子模块 |
|-------|------|-----------|
| **`infra`** | 基础设施层 | `cache`（内存缓存）、`cluster`（集群协调）、`config`（配置解析）、`errors`（错误定义）、`ider`（ID 生成）、`schema`（Schema 管理） |
| **`common`** | 公共工具 | `utils`（通用工具）、`json`（JSON 处理）、`time`（时间工具）、`hash`（哈希函数）、`flatten`（日志扁平化） |
| **`config`** | 配置管理 | 所有 `ZO_*` 前缀的环境变量定义与解析 |
| **`service`** | 业务服务层 | `alerts`（告警规则）、`dashboards`（仪表盘）、`functions`（VRL 函数）、`users`（用户管理）、`organization`（多租户） |
| **`ingester`** | 摄入引擎 | `WAL`（预写日志）、`Memtable`（内存表）、`ParquetWriter`（列式写入）、`SchemaEvolution`（Schema 演化） |
| **`querier`** | 查询引擎 | `DataFusion`（查询执行）、`FileList`（文件索引）、`Cache`（查询缓存）、`Federated`（联邦查询） |
| **`compactor`** | 压缩合并 | `Merge`（文件合并）、`Retention`（保留策略）、`Delete`（数据删除）、`IndexBuild`（索引构建） |
| **`job`** | 后台任务 | `Scheduler`（任务调度）、`Async Jobs`（异步任务队列） |
| **`router`** | 请求路由 | HTTP/gRPC 路由分发、负载均衡 |
| **`report_server`** | 报表服务 | 定时报表生成与分发 |
| **`proto`** | Protobuf 定义 | `cluster.proto`（集群通信）、`search.proto`（查询协议） |
| **`handler`** | HTTP Handler | API 路由、中间件、认证 |
| **`main`** | 程序入口 | `main.rs`、启动流程、组件初始化 |

---

## 五、核心数据结构设计

### 1. Memtable（内存表）

```rust
// 伪代码示意
HashMap<(Org, StreamType), Vec<ArrowRecordBatch>>
```

- **隔离维度**：按 `organization + stream_type` 组合键隔离，确保多租户数据不混存
- **内存上限**：`ZO_MAX_FILE_SIZE_IN_MEMORY = 256MB`，达到后转为 Immutable
- **WAL 配对**：每个 Memtable 对应一个 WAL 文件，位于 `data/wal/logs/<hour>/`
- **Arrow 格式**：直接使用 `arrow-rs` 的 `RecordBatch`，避免序列化开销

### 2. WAL（Write-Ahead Log）

- **按小时分桶**：`data/wal/logs/<hour>/`，便于崩溃恢复时按时间范围重建
- **写入顺序**：先写 WAL → 再写 Memtable，保证数据持久性
- **清理策略**：对应 Parquet 文件上传 S3 成功后，删除本地 WAL

### 3. Parquet 文件组织

```
S3://bucket/<org>/<stream_type>/<stream>/<date>/<file>.parquet
```

- **分区策略**：按时间 + Stream 双维度分区，查询时可快速裁剪无关文件
- **压缩编码**：Snappy/ZSTD 列式压缩，压缩率可达 40x
- **合并策略**：Compactor 将小文件（<<128MB）合并为最大 2GB 的标准文件，减少查询时的文件句柄开销

### 4. File List Index（元数据索引）

- **存储位置**：PostgreSQL（HA 模式）或 SQLite（单节点）的 `file_list` 表
- **索引内容**：每个 Parquet 文件的元信息（路径、时间范围、Stream、大小、行数）
- **查询路径**：Querier 查询时先查 File List Index 获取文件列表，再定位具体 Parquet 文件

---

## 六、关键算法与机制

### 1. 写入流水线（Ingester 内部）

```
T+0ms   HTTP/gRPC 接收请求
T+1ms   VRL 转换 + Schema 检查（Schema 演化需加锁）
T+2ms   写入 WAL（磁盘顺序写）
T+3ms   写入 Memtable（内存 Arrow RecordBatch）
T+5s    Memtable 达到 256MB 或 WAL 达到 128MB → 转为 Immutable
T+5s    Immutable 每 5 秒刷盘为本地 Parquet
T+10s   检查文件大小/保留时间，合并小文件
T+10s   上传 S3 + 更新 File List Index
T+10s   通知 Querier 缓存新文件（可选）
```

**Schema 演化机制**：

- 当新字段出现或字段类型变更时，Ingester 获取分布式锁更新 PostgreSQL 中的 Stream Schema
- 旧数据保持原有 Schema，新数据按新 Schema 写入，查询时由 DataFusion 自动处理 Schema 合并

### 2. 查询执行流水线（Querier 内部）

```
1. Query Leader 接收 SQL/PromQL 请求
2. 解析 SQL，提取时间范围与 Stream 条件
3. 查询 File List Index 获取文件列表
4. 按文件数量均分给所有 Querier Worker（含 Leader 自身）
5. 通过 gRPC 分发查询任务到各 Worker
6. 各 Worker 从 S3 读取 Parquet 文件（或命中本地缓存）
7. DataFusion 执行向量化查询（Arrow 内存计算 + Tantivy 索引）
8. Leader 聚合结果返回
```

**缓存策略**：

- **内存缓存**：默认使用 50% 可用内存缓存 Parquet 文件
- **通知式缓存**：Ingester 上传新文件后主动通知 Querier 预热缓存
- **分布式缓存**：每个 Querier 节点只缓存部分数据，通过一致性哈希减少重复缓存

### 3. Compactor 合并算法

- **触发条件**：每 10 秒检查，或文件保留超过 600 秒
- **合并目标**：将同一分区内的多个小文件合并为单个最大 2GB 的大文件
- **数据保留**：执行保留期删除（Retention），清理过期数据
- **索引构建**：合并过程中触发 Tantivy 倒排索引构建

---

## 七、Rust 并发与异步模型

### 1. 异步运行时

- **Tokio**：作为底层异步运行时，处理所有 I/O 密集型操作（HTTP、gRPC、S3 访问）
- **Rayon**：用于 CPU 密集型任务（Parquet 编码、DataFusion 查询执行的并行化）

### 2. 并发控制关键点

| 场景 | 机制 | 说明 |
|------|------|------|
| Schema 演化 | 分布式锁（PostgreSQL Advisory Lock / etcd） | 防止并发修改 Stream Schema |
| WAL 写入 | 单线程顺序写 + `tokio::sync::Mutex` | 保证 WAL 顺序一致性 |
| Memtable 转换 | `std::sync::RwLock` | 读多写少，Immutable 转换时加写锁 |
| Querier 任务分发 | gRPC 流式传输 | Leader 通过 gRPC streaming 向 Workers 发送文件列表 |

### 3. 内存安全设计

- **零拷贝（Zero-Copy）**：Arrow RecordBatch 在 Memtable → Immutable → Parquet 全链路中避免数据复制
- **生命周期管理**：WAL 文件上传 S3 成功后通过 RAII 模式自动删除，防止磁盘泄漏
- **内存限制**：通过 `ZO_MAX_FILE_SIZE_IN_MEMORY` 和 `ZO_MEMORY_CACHE_MAX_SIZE` 硬限制内存使用，避免 OOM

---

## 八、技术栈精确版本

### HTTP / Web 层（axum 生态）

| Crate | 版本 | Features | 说明 |
|-------|------|----------|------|
| `axum` | **0.8** | `macros`, `multipart`, `tracing` | HTTP 服务框架 |
| `axum-extra` | **0.12** | `typed-header`, `query`, `cookie` | 扩展功能 |
| `axum-server` | **0.8** | `tls-rustls` | TLS 支持 |
| `axum-client-ip` | **1.3** | - | 客户端 IP 提取 |
| `tower` | **0.5** | `full` | 中间件/服务组合 |
| `tower-http` | **0.6** | `cors`, `compression-*`, `trace`, `timeout`, `request-id` | HTTP 中间件 |
| `hyper` | **1.8** | `full` | HTTP 协议实现 |
| `hyper-util` | **0.1** | `tokio`, `server`, `http1`, `http2` | Hyper 工具 |
| `http` | **1.4** | - | HTTP 类型 |
| `http-body` | **1.0** | - | Body 抽象 |
| `http-body-util` | **0.1** | - | Body 工具 |
| `utoipa` | **5.4** | `axum_extras`, `openapi_extensions` | OpenAPI 文档 |
| `utoipa-axum` | **0.2** | - | axum 集成 |
| `utoipa-swagger-ui` | **9** | `axum`, `vendored` | Swagger UI |

### Arrow / DataFusion 数据层

| Crate | 版本 | Features | 说明 |
|-------|------|----------|------|
| `arrow` | **58** | `ipc_compression`, `prettyprint` | Arrow 内存格式 |
| `arrow-flight` | **58** | - | Flight 协议 |
| `arrow-json` | **58** | - | JSON 解析 |
| `arrow-schema` | **58** | `serde` | Schema 序列化 |
| `parquet` | **58** | `arrow`, `async`, `object_store` | 列式存储 |
| `object_store` | **0.13.2** | `aws`, `azure`, `gcp` | 对象存储抽象 |
| `datafusion` | **53** | - | 查询引擎 |
| `datafusion-proto` | **53** | - | 序列化 |
| `datafusion-functions-aggregate-common` | **53** | - | 聚合函数 |
| `datafusion-functions-json` | **0.53** | - | JSON 函数 |
| `sqlparser` | **0.61** | `serde`, `visitor` | SQL 解析 |

### gRPC / 通信层

| Crate | 版本 | Features | 说明 |
|-------|------|----------|------|
| `tonic` | **0.14** | `gzip`, `tls-webpki-roots`, `tls-native-roots` | gRPC 框架 |
| `tonic-prost` | **0.14** | - | Protobuf 生成 |
| `prost` | **0.14** | - | Protobuf 编解码 |
| `prost-wkt-types` | **0.7** | - | Well-Known Types |
| `async-nats` | **0.47** | - | NATS 客户端 |

### 数据库 / ORM 层

| Crate | 版本 | Features | 说明 |
|-------|------|----------|------|
| `sea-orm` | **1.1.20** | `sqlx-postgres`, `sqlx-sqlite`, `tokio-rustls`, `macros` | ORM |
| `sea-orm-migration` | **1.1.20** | 同上 | 迁移工具 |
| `sqlx` | **0.8.6** | `runtime-tokio-rustls`, `postgres`, `sqlite`, `chrono` | SQL 客户端 |
| `dashmap` | **6.1** | `serde` | 并发 HashMap |

### 安全 / 认证层

| Crate | 版本 | Features | 说明 |
|-------|------|----------|------|
| `argon2` | **0.5** | `alloc`, `password-hash` | 密码哈希 |
| `jsonwebtoken` | **10.3** | `aws_lc_rs` | JWT |
| `rustls` | **0.23** | `std`, `tls12` | TLS |
| `rustls-native-certs` | **0.8** | - | 系统证书 |
| `webpki-roots` | **1.0** | - | Web PKI 根证书 |
| `tokio-rustls` | **0.26** | `logging`, `tls12` | Tokio TLS |

### 压缩 / 编码层

| Crate | 版本 | 说明 |
|-------|------|------|
| `zstd` | **0.13** | Zstandard 压缩 |
| `snap` | **1** | Snappy 压缩 |
| `flate2` | **1.0** | zlib (gzip) |
| `brotli` | **8.0.2** | Brotli 压缩 |
| `zip` | **8.0** | ZIP 归档 |

### 可观测性 / OpenTelemetry

| Crate | 版本 | Features | 说明 |
|-------|------|----------|------|
| `opentelemetry` | **0.31** | - | OTel API |
| `opentelemetry_sdk` | **0.31** | `rt-tokio`, `trace`, `metrics` | SDK |
| `opentelemetry-otlp` | **0.31** | `http-proto`, `grpc-tonic`, `reqwest-client` | OTLP 导出 |
| `opentelemetry-proto` | **0.31** | `gen-tonic`, `logs`, `metrics`, `trace` | Protobuf |
| `tracing` | **0.1.44** | - | 结构化日志 |
| `tracing-subscriber` | **0.3.22** | `env-filter`, `json`, `registry` | 订阅者 |
| `tracing-opentelemetry` | **0.32** | - | Tracing-OTel 桥接 |
| `tracing-appender` | **0.2.4** | - | 文件日志追加 |
| `prometheus` | **0.14** | `process` | Prometheus 指标 |

### 内存分配器（可选）

| Crate | 版本 | Features | Feature 开关 |
|-------|------|----------|-------------|
| `mimalloc` | **0.1.48** | `v3` | `mimalloc` |
| `tikv-jemallocator` | **0.6** | `profiling`, `stats`, `unprefixed_malloc_on_supported_platforms` | `jemalloc` |
| `tikv-jemalloc-ctl` | **0.6** | `use_std`, `stats`, `profiling` | `profiling` |
| `tikv-jemalloc-sys` | **0.6** | `profiling` | `profiling` |

### 其他重要依赖

| Crate | 版本 | 说明 |
|-------|------|------|
| `tokio` | **1** | `full` 异步运行时 |
| `reqwest` | **0.12** | HTTP 客户端（rustls-tls/gzip/brotli） |
| `vrl` | **0.31** | Vector Remap Language |
| `tantivy` | **0.26** | `quickwit` 全文索引 |
| `tantivy-fst` | **0.5** | FST 索引 |
| `chromiumoxide` | git | Headless Chrome（报表截图） |
| `lettre` | **0.11** | SMTP 邮件发送 |
| `rquickjs` | **0.11** | QuickJS 引擎（JS 函数） |
| `rayon` | **1.10** | 数据并行 |
| `blake3` | **1.8** | `rayon` 高性能哈希 |
| `roaring` | **0.11.3** | Bitmap 压缩 |
| `cron` | **0.15** | 定时任务 |
| `csv` | **1.3** | CSV 处理 |
| `maxminddb` | **0.27** | GeoIP |
| `uaparser` | **0.6.4** | User-Agent 解析 |
| `rust-embed-for-web` | **11.3** | 静态资源嵌入二进制 |
| `prettytable-rs` | **0.10.0** | 表格输出 |
| `segment` | **~0.2.4** | 分析（Segment） |

### Patch 覆盖（crates-io 替换）

| 原始 Crate | 替换来源 | 说明 |
|-----------|---------|------|
| `object_store` | `openobserve/arrow-rs-object-store#openobserve-v0.13.2` | 自定义对象存储，可能包含 S3 兼容修复 |
| `proc-macro-error2` | `hengfeiyang/proc-macro-error-2#main` | 修复 proc-macro 错误处理 |

---

## 九、本地单机部署方案

### 场景需求

| 指标 | 要求 |
|------|------|
| 日志量 | 2000 GB（约 2TB） |
| 保留期 | 30 天 |
| 部署模式 | 本地单机版（单节点） |
| 自动清理 | 超过 30 天自动清理 |
| 资源限制 | 合理设置 CPU request/limit |

### 容量估算

| 项目 | 估算 |
|------|------|
| 日均日志量 | 1000 GB / 30 天 ≈ **33.3 GB/天** |
| 峰值流量 | 按 2 倍峰值 ≈ **66.7 GB/天** |
| 压缩后存储 | Parquet 压缩率约 40x，原始日志约 40 TB，压缩后约 **1 TB** |
| 内存需求 | 50% 内存用于缓存 + Memtable + 查询缓存 ≈ **16 GB** |
| CPU 需求 | 摄入 + 查询 + Compactor 并行 ≈ **4-8 核** |
| 磁盘需求 | WAL + 本地 Parquet 缓冲 ≈ **300 GB SSD** |

### 推荐资源配置

| 资源 | Request | Limit | 说明 |
|------|---------|-------|------|
| CPU | 4 核 | 8 核 | 保证摄入和查询性能，Limit 防止资源争抢 |
| 内存 | 16 GB | 32 GB | 50% 用于缓存，16GB 为安全基线 |
| 磁盘 | 300 GB | - | SSD/NVMe，用于 WAL 和本地 Parquet 缓冲 |
| 网络 | 1 Gbps | - | 保证 S3/MinIO 传输带宽 |

### Docker Compose 部署配置

```yaml
version: '3.8'

services:
  openobserve:
    image: public.ecr.aws/zinclabs/openobserve:v0.91.0
    container_name: openobserve
    restart: unless-stopped

    # 资源限制
    deploy:
      resources:
        limits:
          cpus: '8.0'
          memory: 32G
        reservations:
          cpus: '4.0'
          memory: 16G

    # 等价于 Kubernetes 的 request/limit
    # cpu: request=8, limit=16
    # memory: request=32G, limit=64G

    ports:
      - "5080:5080"  # HTTP API / Web UI
      - "5081:5081"  # gRPC

    environment:
      # === 单节点模式 ===
      - ZO_LOCAL_MODE=true

      # === 数据目录 ===
      - ZO_DATA_DIR=/data

      # === 内存配置 ===
      # Memtable 内存上限 256MB（默认）
      - ZO_MAX_FILE_SIZE_IN_MEMORY=256
      # WAL/本地文件上限 128MB（默认）
      - ZO_MAX_FILE_SIZE_ON_DISK=128

      # === 刷盘与上传间隔 ===
      # Immutable 每 5 秒刷盘为 Parquet
      - ZO_MEM_PERSIST_INTERVAL=5
      # 每 10 秒检查上传
      - ZO_FILE_PUSH_INTERVAL=10

      # === 合并配置 ===
      # 合并后最大文件 2GB（默认）
      - ZO_COMPACT_MAX_FILE_SIZE=2048

      # === 查询缓存 ===
      # 使用 50% 可用内存作为查询缓存（默认）
      # 64GB 内存时约 32GB 用于缓存
      # - ZO_MEMORY_CACHE_MAX_SIZE=34359738368  # 32GB in bytes

      # === 数据保留策略（关键） ===
      # 30 天数据保留，超过自动清理
      - ZO_LOGS_RETENTION=30d
      - ZO_METRICS_RETENTION=30d
      - ZO_TRACES_RETENTION=30d

      # === 对象存储（本地 MinIO） ===
      - ZO_S3_PROVIDER=minio
      - ZO_S3_SERVER_URL=http://minio:9000
      - ZO_S3_BUCKET_NAME=openobserve
      - ZO_S3_ACCESS_KEY=minioadmin
      - ZO_S3_SECRET_KEY=minioadmin
      - ZO_S3_REGION=us-east-1

      # === 元数据存储（SQLite 单节点） ===
      # 单节点默认使用 SQLite，无需额外配置
      # - ZO_META_STORE=sqlite

      # === 索引配置 ===
      # 开启倒排索引加速全文搜索
      - ZO_ENABLE_INVERTED_INDEX=true
      # 布隆过滤器（可选）
      # - ZO_BLOOM_FILTER_ON_ALL_FIELDS=true

      # === 性能优化 ===
      # 使用 jemalloc 内存分配器（生产推荐）
      # 需使用 jemalloc feature 构建的镜像
      # - ZO_JEMALLOC_ENABLED=true

      # === 日志级别 ===
      - RUST_LOG=info

    volumes:
      - ./data:/data
      # 挂载本地磁盘用于 WAL 和临时 Parquet
      - /mnt/fast-ssd/openobserve:/data

    networks:
      - openobserve-net

    depends_on:
      - minio

    # 健康检查
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:5080/healthz"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s

  # 本地 MinIO 作为对象存储
  minio:
    image: minio/minio:RELEASE.2024-06-10T-xxx
    container_name: minio
    restart: unless-stopped

    ports:
      - "9000:9000"  # S3 API
      - "9001:9001"  # Web Console

    environment:
      - MINIO_ROOT_USER=minioadmin
      - MINIO_ROOT_PASSWORD=minioadmin

    volumes:
      - ./minio-data:/data

    command: server /data --console-address ":9001"

    networks:
      - openobserve-net

    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9000/minio/health/live"]
      interval: 30s
      timeout: 10s
      retries: 3

  # MinIO 初始化（创建 bucket）
  minio-init:
    image: minio/mc:RELEASE.2024-06-10T-xxx
    container_name: minio-init
    depends_on:
      - minio
    entrypoint: >
      /bin/sh -c "
      sleep 10;
      mc alias set local http://minio:9000 minioadmin minioadmin;
      mc mb local/openobserve || true;
      mc policy set public local/openobserve || true;
      exit 0;
      "
    networks:
      - openobserve-net

networks:
  openobserve-net:
    driver: bridge
```

### 官方 Kubernetes StatefulSet 部署配置（推荐单节点）

> 参考官方文档：https://openobserve.ai/downloads/

OpenObserve 官方提供基于 **StatefulSet** 的单节点部署方式，适用于本地开发和测试环境。以下配置已针对 **1000GB/30天** 场景进行资源调整。

#### 基础版
- 官方原始配置如下：https://openobserve.ai/downloads/
- deploy部署：https://github.com/openobserve/openobserve/blob/main/deploy/k8s/statefulset.yaml
```yaml
apiVersion: v1
kind: Service
metadata:
  name: openobserve
  namespace: openobserve
spec:
  clusterIP: None
  selector:
    app: openobserve
  ports:
  - name: http
    port: 5080
    targetPort: 5080
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: openobserve
  namespace: openobserve
  labels:
    name: openobserve
spec:
  serviceName: openobserve
  replicas: 1
  selector:
    matchLabels:
      name: openobserve
      app: openobserve
  template:
    metadata:
      labels:
        name: openobserve
        app: openobserve
    spec:
      securityContext:
        fsGroup: 2000
        runAsUser: 10000
        runAsGroup: 3000
        runAsNonRoot: true
      containers:
        - name: openobserve
          image: o2cr.ai/openobserve/openobserve:v0.90.3
          env:
            - name: ZO_ROOT_USER_EMAIL
              value: root@example.com
            - name: ZO_ROOT_USER_PASSWORD
              value: Complexpass#123
            - name: ZO_DATA_DIR
              value: /data
          imagePullPolicy: Always
          resources:
            limits:
              cpu: 4096m
              memory: 2048Mi
            requests:
              cpu: 256m
              memory: 50Mi
          ports:
            - containerPort: 5080
              name: http
          volumeMounts:
          - name: data
            mountPath: /data
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes:
        - ReadWriteOnce
      resources:
        requests:
          storage: 10Gi
```

由于网络和权限问题，下面的版本，是我经过了调整后的版本，支持500GB，同时30天自动清理数据。修改后的deployment.yaml如下：
```yaml
apiVersion: v1
kind: Service
metadata:
  name: openobserve
  namespace: openobserve
spec:
  clusterIP: None
  selector:
    app: openobserve
  ports:
  - name: http
    port: 5080
    targetPort: 5080
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: openobserve
  namespace: openobserve
  labels:
    name: openobserve
spec:
  serviceName: openobserve
  replicas: 1
  selector:
    matchLabels:
      name: openobserve
      app: openobserve
  template:
    metadata:
      labels:
        name: openobserve
        app: openobserve
    spec:
      securityContext:
        fsGroup: 2000
        runAsUser: 10000
        runAsGroup: 3000
        runAsNonRoot: true
      containers:
        - name: openobserve
          # 这里的镜像用开源版本的，例如：docker镜像为openobserve/openobserve:v0.90.3
          image: public.ecr.aws/zinclabs/openobserve:v0.90.3
          env:
            - name: ZO_ROOT_USER_EMAIL
              value: root@example.com
            - name: ZO_ROOT_USER_PASSWORD
              value: Complexpass#123
            - name: ZO_DATA_DIR
              value: /data
            # === 数据保留策略（关键：30天自动清理） ===
            - name: ZO_LOGS_RETENTION
              value: "30d"
            - name: ZO_METRICS_RETENTION
              value: "30d"
            - name: ZO_TRACES_RETENTION
              value: "30d"
          imagePullPolicy: Always
          # 这里建议使用1核2g,最大8核16g
          resources:
            limits:
              cpu: "8"
              memory: "16Gi"
            requests:
              cpu: "2"
              memory: "4Gi"
          ports:
            - containerPort: 5080
              name: http
          volumeMounts:
          - name: data
            mountPath: /data
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes:
        - ReadWriteOnce
      #storageClassName: gp3  # EKS 推荐 gp3，这里注释会自动创建pvc
      resources:
        requests:
          storage: 500Gi
```
备注：
- 部署之前，需要先通过 kubectl create ns openobserve 创建好命名空间后，再执行kubectl apply -f deployment.yaml部署。
- 如果在测试或线上环境，建议resources使用1核2g,最大8核16g，避免运行过程中发生异常。同时，storge建议500Gi，然后开启30天自动清理。
- 对于密钥信息，建议放在k8s secret管理，具体参考官方k8s手册：https://kubernetes.io/zh-cn/docs/tasks/configmap-secret/managing-secret-using-kubectl/
- 如果需要使用企业版，需要经过openobserve官方授权许可证才可以使用。
- resources这里可以使用storageClass，例如：aws的gp3 sc类型的pvc。
- 云版本每天50GB免费，镜像为: public.ecr.aws/zinclabs/openobserve:latest
- 社区版的镜像为: o2cr.ai/openobserve/openobserve:v0.90.3 需要权限，建议使用docker镜像openobserve/openobserve:v0.90.3 或者官方 AWS Public ECR 镜像
- 官方 AWS Public ECR 镜像 docker pull public.ecr.aws/zinclabs/openobserve:v0.90.3
- docker镜像：docker pull openobserve/openobserve:v0.90.3
- 如果pvc使用aws sc配置，那volumeClaimTemplates配置如下，这里如果gp3模版，没有创建，需要提前创建好gp3。
```yaml
volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes:
        - ReadWriteOnce
      storageClassName: gp3  # EKS 推荐 gp3，或你的 nfs-client
      resources:
        requests:
          storage: 10Gi
```
对应的sc创建gp3-sc.yaml如下：
```yaml
# gp3-sc.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ebs-gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"  # 设为默认
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  encrypted: "true"           # 启用加密
  iops: "3000"                # gp3 默认 IOPS
  throughput: "125"           # MiB/s，gp3 支持 125-1000
  fsType: ext4
volumeBindingMode: WaitForFirstConsumer  # 延迟绑定，优化调度
allowVolumeExpansion: true      # 支持扩容
reclaimPolicy: Delete           # 删除 PVC 时删除 PV
```

部署步骤如下
```shell
# 创建命名空间
kubectl create ns openobserve

# 应用修改后的 YAML
kubectl apply -f deployment.yaml

# 验证openobserve运行状态
kubectl get pvc -n openobserve
kubectl get pod -n openobserve

# 根据实际情况部署ingress以及域名解析即可，这里省略
```

#### 生产适配版（1000GB/30天场景，可根据实际情况调整）

以下配置在官方基础上增加了 **数据保留策略**、**资源限制**、**健康检查**、**对象存储** 等生产必需配置：

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: openobserve
---
# Secret: 管理员密码（建议生产环境使用更复杂的密码）
apiVersion: v1
kind: Secret
metadata:
  name: openobserve-admin
  namespace: openobserve
type: Opaque
stringData:
  password: "Complexpass#123"
---
# Service: Headless Service for StatefulSet
apiVersion: v1
kind: Service
metadata:
  name: openobserve
  namespace: openobserve
  labels:
    app: openobserve
spec:
  clusterIP: None
  selector:
    app: openobserve
  ports:
  - name: http
    port: 5080
    targetPort: 5080
  - name: grpc
    port: 5081
    targetPort: 5081
---
# StatefulSet: 单节点 OpenObserve
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: openobserve
  namespace: openobserve
  labels:
    name: openobserve
    app: openobserve
spec:
  serviceName: openobserve
  replicas: 1
  selector:
    matchLabels:
      name: openobserve
      app: openobserve
  template:
    metadata:
      labels:
        name: openobserve
        app: openobserve
    spec:
      securityContext:
        fsGroup: 2000
        runAsUser: 10000
        runAsGroup: 3000
        runAsNonRoot: true

      containers:
        - name: openobserve
          image: public.ecr.aws/zinclabs/openobserve:v0.91.0
          imagePullPolicy: IfNotPresent

          # === 资源限制（适配 1000GB/30天） ===
          resources:
            limits:
              cpu: "8"           # 最大 8 核 CPU
              memory: "32Gi"     # 最大 32GB 内存
            requests:
              cpu: "4"           # 保证 4 核 CPU
              memory: "16Gi"     # 保证 16GB 内存

          ports:
            - containerPort: 5080
              name: http
              protocol: TCP
            - containerPort: 5081
              name: grpc
              protocol: TCP

          env:
            # === 管理员认证 ===
            - name: ZO_ROOT_USER_EMAIL
              value: "root@example.com"
            - name: ZO_ROOT_USER_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: openobserve-admin
                  key: password

            # === 单节点模式 ===
            - name: ZO_LOCAL_MODE
              value: "true"

            # === 数据目录 ===
            - name: ZO_DATA_DIR
              value: "/data"

            # === 内存配置 ===
            - name: ZO_MAX_FILE_SIZE_IN_MEMORY
              value: "256"       # Memtable 256MB
            - name: ZO_MAX_FILE_SIZE_ON_DISK
              value: "128"       # WAL 128MB

            # === 刷盘与上传间隔 ===
            - name: ZO_MEM_PERSIST_INTERVAL
              value: "5"         # 5秒刷盘
            - name: ZO_FILE_PUSH_INTERVAL
              value: "10"        # 10秒检查上传

            # === 合并配置 ===
            - name: ZO_COMPACT_MAX_FILE_SIZE
              value: "2048"      # 合并后最大2GB

            # === 数据保留策略（关键：30天自动清理） ===
            - name: ZO_LOGS_RETENTION
              value: "30d"
            - name: ZO_METRICS_RETENTION
              value: "30d"
            - name: ZO_TRACES_RETENTION
              value: "30d"

            # === 对象存储（本地 MinIO） ===
            - name: ZO_S3_PROVIDER
              value: "minio"
            - name: ZO_S3_SERVER_URL
              value: "http://minio.openobserve.svc.cluster.local:9000"
            - name: ZO_S3_BUCKET_NAME
              value: "openobserve"
            - name: ZO_S3_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: minio-credentials
                  key: access-key
            - name: ZO_S3_SECRET_KEY
              valueFrom:
                secretKeyRef:
                  name: minio-credentials
                  key: secret-key
            - name: ZO_S3_REGION
              value: "us-east-1"

            # === 索引配置 ===
            - name: ZO_ENABLE_INVERTED_INDEX
              value: "true"

            # === 日志级别 ===
            - name: RUST_LOG
              value: "info"

          volumeMounts:
            - name: data
              mountPath: /data

          # 健康检查
          livenessProbe:
            httpGet:
              path: /healthz
              port: 5080
            initialDelaySeconds: 60
            periodSeconds: 30
            timeoutSeconds: 10
            failureThreshold: 3

          readinessProbe:
            httpGet:
              path: /healthz
              port: 5080
            initialDelaySeconds: 30
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 3

          # 优雅关闭
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sh", "-c", "sleep 30"]

  # === PVC 模板（1000GB/30天 适配 300GB） ===
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes:
        - ReadWriteOnce
      resources:
        requests:
          storage: 300Gi      # 300GB SSD 存储
      storageClassName: fast-ssd  # 高性能存储类
```

#### 部署步骤

```bash
# 1. 创建命名空间
kubectl create namespace openobserve

# 2. 应用配置
kubectl apply -f openobserve-statefulset.yaml

# 3. 查看 Pod 状态
kubectl -n openobserve get pods -w

# 4. 端口转发（本地访问）
kubectl -n openobserve port-forward svc/openobserve 5080:5080

# 5. 访问 Web UI
# http://localhost:5080
# 用户名: root@example.com
# 密码: Complexpass#123
```

#### 与官方配置的差异说明

| 配置项 | 官方原始值 | 生产适配版（1000GB/30天） | 原因 |
|--------|-----------|-------------------------|------|
| `resources.limits.cpu` | 4096m (4核) | **8** (8核) | 1000GB/30天需要更高计算能力 |
| `resources.limits.memory` | 2048Mi (2GB) | **32Gi** (32GB) | 缓存 + Memtable + 查询需要 |
| `resources.requests.cpu` | 256m (0.25核) | **4** (4核) | 保证基础计算资源 |
| `resources.requests.memory` | 50Mi | **16Gi** (16GB) | 保证基础内存 |
| `storage` | 10Gi | **300Gi** | 30天 WAL + 本地缓冲 |
| `ZO_LOGS_RETENTION` | 未设置 | **30d** | 自动清理超过30天数据 |
| `ZO_S3_PROVIDER` | 未设置 | **minio** | 本地对象存储 |
| `livenessProbe` | 无 | **有** | 生产健康检查 |
| `readinessProbe` | 无 | **有** | 生产就绪检查 |

---

### Kubernetes Deployment 部署配置（可根据实际情况调整）

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: openobserve
  namespace: openobserve
  labels:
    app: openobserve
spec:
  replicas: 1  # 单节点模式
  selector:
    matchLabels:
      app: openobserve
  template:
    metadata:
      labels:
        app: openobserve
    spec:
      containers:
        - name: openobserve
          image: public.ecr.aws/zinclabs/openobserve:v0.91.0

          # === CPU/Memory Request & Limit ===
          resources:
            requests:
              cpu: "4"           # 保证 4 核 CPU
              memory: "16Gi"     # 保证 16GB 内存
            limits:
              cpu: "8"           # 最大 8 核 CPU
              memory: "32Gi"     # 最大 32GB 内存

          ports:
            - containerPort: 5080
              name: http
              protocol: TCP
            - containerPort: 5081
              name: grpc
              protocol: TCP

          env:
            # === 单节点模式 ===
            - name: ZO_LOCAL_MODE
              value: "true"

            # === 数据目录 ===
            - name: ZO_DATA_DIR
              value: "/data"

            # === 内存配置 ===
            - name: ZO_MAX_FILE_SIZE_IN_MEMORY
              value: "256"       # 256MB
            - name: ZO_MAX_FILE_SIZE_ON_DISK
              value: "128"       # 128MB

            # === 刷盘与上传间隔 ===
            - name: ZO_MEM_PERSIST_INTERVAL
              value: "5"         # 5 秒
            - name: ZO_FILE_PUSH_INTERVAL
              value: "10"        # 10 秒

            # === 合并配置 ===
            - name: ZO_COMPACT_MAX_FILE_SIZE
              value: "2048"      # 2GB

            # === 数据保留策略（关键：30天自动清理） ===
            - name: ZO_LOGS_RETENTION
              value: "30d"
            - name: ZO_METRICS_RETENTION
              value: "30d"
            - name: ZO_TRACES_RETENTION
              value: "30d"

            # === 对象存储（MinIO） ===
            - name: ZO_S3_PROVIDER
              value: "minio"
            - name: ZO_S3_SERVER_URL
              value: "http://minio.openobserve.svc.cluster.local:9000"
            - name: ZO_S3_BUCKET_NAME
              value: "openobserve"
            - name: ZO_S3_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: openobserve-secrets
                  key: s3-access-key
            - name: ZO_S3_SECRET_KEY
              valueFrom:
                secretKeyRef:
                  name: openobserve-secrets
                  key: s3-secret-key
            - name: ZO_S3_REGION
              value: "us-east-1"

            # === 索引配置 ===
            - name: ZO_ENABLE_INVERTED_INDEX
              value: "true"

            # === 日志级别 ===
            - name: RUST_LOG
              value: "info"

          volumeMounts:
            - name: data
              mountPath: /data

          # 健康检查
          livenessProbe:
            httpGet:
              path: /healthz
              port: 5080
            initialDelaySeconds: 60
            periodSeconds: 30
            timeoutSeconds: 10
            failureThreshold: 3

          readinessProbe:
            httpGet:
              path: /healthz
              port: 5080
            initialDelaySeconds: 30
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 3

          # 优雅关闭
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sh", "-c", "sleep 30"]

      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: openobserve-data

      # 节点亲和性（可选：绑定到高性能节点）
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: node-type
                    operator: In
                    values:
                      - high-memory

      # 容忍（可选）
      tolerations:
        - key: "dedicated"
          operator: "Equal"
          value: "openobserve"
          effect: "NoSchedule"

---
# PVC 配置
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: openobserve-data
  namespace: openobserve
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 300Gi  # 本地 SSD 存储
  storageClassName: fast-ssd  # 高性能存储类

---
# Service 配置
apiVersion: v1
kind: Service
metadata:
  name: openobserve
  namespace: openobserve
spec:
  type: ClusterIP
  ports:
    - port: 5080
      targetPort: 5080
      name: http
    - port: 5081
      targetPort: 5081
      name: grpc
  selector:
    app: openobserve

---
# Secret 配置（MinIO 凭证）
apiVersion: v1
kind: Secret
metadata:
  name: openobserve-secrets
  namespace: openobserve
type: Opaque
stringData:
  s3-access-key: "minioadmin"
  s3-secret-key: "minioadmin"
```

### 关键环境变量说明（单机部署）

| 环境变量 | 推荐值 | 说明 |
|----------|--------|------|
| `ZO_LOCAL_MODE` | `true` | **必须**：单节点模式 |
| `ZO_DATA_DIR` | `/data` | 数据目录 |
| `ZO_MAX_FILE_SIZE_IN_MEMORY` | `256` | Memtable 内存上限 256MB |
| `ZO_MAX_FILE_SIZE_ON_DISK` | `128` | WAL/本地文件上限 128MB |
| `ZO_MEM_PERSIST_INTERVAL` | `5` | Immutable 刷盘间隔 5 秒 |
| `ZO_FILE_PUSH_INTERVAL` | `10` | S3 上传检查间隔 10 秒 |
| `ZO_COMPACT_MAX_FILE_SIZE` | `2048` | 合并后最大文件 2GB |
| `ZO_LOGS_RETENTION` | `30d` | **日志保留 30 天** |
| `ZO_METRICS_RETENTION` | `30d` | **指标保留 30 天** |
| `ZO_TRACES_RETENTION` | `30d` | **追踪保留 30 天** |
| `ZO_S3_PROVIDER` | `minio` | 对象存储类型 |
| `ZO_S3_SERVER_URL` | `http://minio:9000` | MinIO 地址 |
| `ZO_S3_BUCKET_NAME` | `openobserve` | 存储桶名 |
| `ZO_ENABLE_INVERTED_INDEX` | `true` | 开启倒排索引 |
| `ZO_MEMORY_CACHE_MAX_SIZE` | 自动 | 默认 50% 内存用于缓存 |

### 数据保留与自动清理机制

OpenObserve 通过 **Compactor** 后台任务执行数据保留策略：

1. **保留期检查**：Compactor 每 10 秒扫描文件列表，检查文件时间戳
2. **过期删除**：超过 `ZO_LOGS_RETENTION`（30 天）的 Parquet 文件自动从 S3 删除
3. **File List 同步**：删除后更新 PostgreSQL/SQLite 的 `file_list` 索引
4. **本地清理**：同时清理本地磁盘缓存中的过期文件

**验证保留策略生效**：

```bash
# 查看当前保留配置
curl http://localhost:5080/api/v1/settings/retention

# 手动触发 Compactor（调试用）
curl -X POST http://localhost:5080/api/v1/trigger/compactor
```

### 性能调优建议（2000GB/30天场景）

| 调优项 | 建议 | 原因 |
|--------|------|------|
| CPU Limit | 8 核 | 保证 Compactor 合并和查询并行度 |
| Memory Limit | 32 GB | 50% 缓存 + Memtable + 查询缓冲 |
| 磁盘类型 | NVMe SSD | WAL 顺序写和 Parquet 随机读需要低延迟 |
| 磁盘大小 | 300 GB | 容纳 30 天 WAL + 本地 Parquet 缓冲 |
| 网络带宽 | 1 Gbps+ | MinIO 与 OpenObserve 间数据传输 |
| `ZO_MEM_PERSIST_INTERVAL` | 5 秒 | 平衡数据新鲜度和磁盘 I/O |
| `ZO_FILE_PUSH_INTERVAL` | 10 秒 | 平衡上传频率和 S3 请求成本 |
| `ZO_COMPACT_MAX_FILE_SIZE` | 2048 MB | 2GB 大文件减少查询时文件句柄 |
| `ZO_ENABLE_INVERTED_INDEX` | true | 加速全文搜索，但增加索引构建 CPU 开销 |
| 镜像 Feature | `jemalloc` | 生产环境使用 jemalloc 减少内存碎片 |

### 监控与告警

```yaml
# Prometheus ServiceMonitor
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: openobserve
  namespace: openobserve
spec:
  selector:
    matchLabels:
      app: openobserve
  endpoints:
    - port: http
      path: /metrics
      interval: 30s
```

**关键监控指标**：

| 指标 | 告警阈值 | 说明 |
|------|---------|------|
| `zo_ingest_bytes_per_sec` | < 50 MB/s | 摄入速率异常 |
| `zo_query_duration_seconds` | > 10s | 查询延迟过高 |
| `zo_compactor_pending_files` | > 1000 | 合并任务积压 |
| `zo_memory_cache_usage_ratio` | > 0.9 | 内存缓存即将耗尽 |
| `zo_disk_usage_bytes` | > 450 GB | 磁盘空间不足 |

---

## 十、参考文档

- [OpenObserve 官方架构文档](https://openobserve.ai/docs/architecture/)
- [OpenObserve GitHub 仓库](https://github.com/openobserve/openobserve)
- [OpenObserve HA 模式部署实践](https://www.51cto.com/article/795585.html)
- [OpenObserve 环境变量完整列表](https://openobserve.ai/docs/environment-variables/)
- [OpenObserve Docker 部署指南](https://openobserve.ai/docs/installation/docker/)
- [OpenObserve Kubernetes 部署指南](https://openobserve.ai/docs/installation/kubernetes/)

---

> **文档版本**：v1.0  
> **基于 OpenObserve 版本**：v0.91.0  
> **Rust Edition**：2024  
> **最后更新**：2026-06-10
