# 全量激活 Honker 绑定 + 实质 Benchmark

本文说明如何把 **LiteJob / LiteCache / LiteCable** 上所有 Honker 相关选项打开，
以及如何跑一份多进程、可对比的实质 benchmark。

---

## 1. 前置条件（缺一不可）

| 条件 | 说明 |
|------|------|
| Ruby ≥ 4.0 | 本仓库要求 |
| `gem "honker", "0.4.0"` | GitHub Packages `sunfang3`，见 [HONKER.md](HONKER.md) |
| **文件路径** SQLite | **禁止** `:memory:` — Honker 无法 watch 内存库 |
| 认证 | `BUNDLE_RUBYGEMS__PKG__GITHUB__COM=user:PAT`（`read:packages`） |

```bash
export BUNDLE_RUBYGEMS__PKG__GITHUB__COM="YOUR_USER:YOUR_PAT"
bundle install

# 确认激活
bundle exec rake litestack:honker:status
# 期望：四个组件均为 active
```

---

## 2. 配置清单（全部打开）

### 2.1 LiteJob — `config/litejob.yml`

```yaml
production:   # 或 development 调试
  path: storage/production/queue.sqlite3   # 必须是文件
  workers: 5
  queues:
    - [default, 1]
    - [urgent, 10]

  # 唤醒
  wakeup: honker
  watcher_poll_interval_ms: 5
  fallback_interval: 5
  queue_notify: true
  wakeup_filter_notifications: true

  # claim/ack（崩溃可回收）
  backend: honker
  visibility_timeout: 300
  heartbeat_interval: 60      # 长任务续约；0 = 关
  # heartbeat_extend: 300

  # 协调 / 可观测
  leadership: true
  job_results: true
  result_ttl: 3600
  lifecycle_stream: true      # LiteBoard 生命周期流

  # 可选：与 Rails primary 同库 outbox
  # database: primary
  # outbox: true
  # table_prefix: litestack_
```

Rails：

```ruby
# config/environments/production.rb
config.active_job.queue_adapter = :litejob
```

### 2.2 LiteCache — `config/litecache.yml` + cache_store

```yaml
production:
  l1: true
  invalidate: honker          # 多 worker 必须；单进程可用 none/ttl
  l1_max_entries: 10000
  l1_max_value_bytes: 65536
  l1_ttl_default: 5           # 丢 notify 时的软 TTL 兜底
  notify_ops: [set, delete, clear]
  notify_channel: litecache
  watcher_poll_interval_ms: 5
  sleep_interval: 30
```

```ruby
# config/environments/production.rb
config.cache_store = :litecache, {
  path: Rails.root.join("storage", Rails.env, "cache.sqlite3").to_s,
  config_path: Rails.root.join("config/litecache.yml").to_s
  # 也可直接写: l1: true, invalidate: :honker
}
```

### 2.3 LiteCable — `config/cable.yml`

```yaml
production:
  adapter: litecable
  path: storage/production/cable.sqlite3
  transport: honker
  watcher_poll_interval_ms: 5
  expire_after: 5
  leadership: true
```

### 2.4 一键脚手架（推荐）

仓库内已有「全开」overlays：

```bash
bundle exec rake examples:honker_rails
# 使用 examples/honker_rails/config/* 全量 Honker 配置
```

参考副本：

| 文件 | 用途 |
|------|------|
| `examples/honker_rails/config/litejob.yml` | 全开 job |
| `examples/honker_rails/config/litecache.yml` | L1 + invalidate |
| `examples/honker_rails/config/cable.yml` | transport:honker |
| `samples/*.honker.yml` | 注释版样例 |

---

## 3. 如何确认「真的激活」

```bash
# A. 状态探针（live 实例）
LITESTACK_HONKER_PATH=storage/production/queue.sqlite3 \
  bundle exec rake litestack:honker:status

# B. 严格模式（任一 inactive → exit 1）
LITESTACK_HONKER_STRICT=1 bundle exec rake litestack:honker:status
```

期望输出片段：

```text
litejob.wakeup: active — adapter=honker
litejob.backend: active — class=Litestack::JobBackend::Honker
litecache.invalidate: active — … honker=true
litecable.transport: active — transport=honker
```

若出现 `falling back to polling` / `invalidate:ttl`：

1. 路径是否是文件？
2. `require "honker"` 是否成功？
3. YAML 是否被对应 env（production/development）加载？

---

## 4. 实质型 Benchmark

### 4.1 全栈对比（推荐）

多进程测量：

| 场景 | 指标 |
|------|------|
| LiteJob polling vs honker | 完成 N 个 job 的吞吐 jobs/s |
| LiteCache | 无 L1 / 有 L1 热读 IPS；跨进程 invalidate p50/p99 |
| LiteCable | polling vs honker 跨进程投递延迟 p50/p99 |

```bash
# 默认规模
bundle exec rake bench:honker_stack

# 加大负载
LITESTACK_BENCH_JOBS=300 \
LITESTACK_BENCH_WORKERS=3 \
LITESTACK_BENCH_CACHE_KEYS=80 \
LITESTACK_BENCH_CABLE_MSGS=80 \
  bundle exec rake bench:honker_stack

# 或直接
bundle exec ruby bench/bench_honker_stack.rb --jobs 300 --workers 3 --cache-keys 80 --cable-msgs 80
```

结果 JSON：`bench/results/honker_stack.json`（可用 `LITESTACK_BENCH_OUT=` 改路径）。

### 4.2 仅 LiteCache L1 / invalidate

```bash
bundle exec rake bench:litecache_l1          # baseline + 95% 回归门
bundle exec rake bench:litecache_l1_full     # + l1_local + invalidate
# 或
bundle exec ruby bench/bench_litecache_l1.rb all
```

### 4.3 多进程 soak（正确性 + 粗性能）

```bash
bundle exec rake soak:honker
# LITESTACK_SOAK_JOBS=50 LITESTACK_SOAK_CACHE_KEYS=30 bundle exec rake soak:honker
```

### 4.4 解读要点（本机样例量级）

一次 `bench:honker_stack` 参考输出（机器相关，仅作形状参考）：

| 指标 | polling / no-L1 | honker / L1 |
|------|-----------------|-------------|
| Job 吞吐（批量连续入队） | 往往更高 | claim/ack 更重，吞吐可能更低 |
| Cache 热读 IPS | 基线 | 常 **10–30×** |
| Cache invalidate p50 | — | 亚毫秒～数 ms |
| Cable 投递 p50 | ~20–50ms（轮询） | 常 **数 ms**（约 **5–10×** 更快） |

- **Job**：Honker **wakeup** 的价值在「空闲队列上突然有任务」时的尾延迟；**backend: honker** 换的是 crash 后的 claim 语义，不是峰值 jobs/s。
- **Cache L1**：热 key 收益最大；多 worker 靠 `invalidate: honker` 保证不脏读。
- **Cable**：Honker 主要砍掉 ~50ms 轮询间隔带来的延迟。

---

## 5. Rails 生产检查单

- [ ] Gemfile：`litestack` + `honker` 均来自 Packages（或 path）
- [ ] 三个 path 均在 `storage/<env>/` 且可写
- [ ] `litejob.yml`：`backend` + `wakeup` + `lifecycle_stream` 等已开
- [ ] `litecache.yml`：`l1` + `invalidate: honker`
- [ ] `cable.yml`：`transport: honker`
- [ ] 多 Puma worker 时 cache/queue/cable 路径**进程间共享同一文件**
- [ ] `rake litestack:honker:status` 全绿
- [ ] `bench:honker_stack` 已在目标机跑过并保存 JSON

---

## 6. 相关文档

- [HONKER.md](HONKER.md) — 安装与能力矩阵  
- [RELEASE_GITHUB_PACKAGES.md](RELEASE_GITHUB_PACKAGES.md) — 1.1.0 发包  
- [examples/honker_rails/](../examples/honker_rails/) — 一键全开 Rails  
- [BENCHMARKS.md](../BENCHMARKS.md) — 历史微基准  
