# Rails 全栈使用 Litestack：核心栈与可选原生扩展

本文说明在 **Rails 8.1+** 应用中把 Litestack 作为全栈数据层引入时：

1. **默认全栈**（DB / Cache / Job / Cable）怎么装；  
2. **可选原生扩展**（中文/拼音 FTS 的 **libsimple**、向量检索的 **vectorlite**）如何下载、配置、部署；  
3. 扩展**不是** `litestack:install` 自动装好的——需要显式启用。

相关文档：

| 文档 | 内容 |
|------|------|
| [RELEASE_GITHUB_PACKAGES.md](RELEASE_GITHUB_PACKAGES.md) | **本 fork 安装 / 权限 / CI**（Packages `sunfang3`，1.1.0） |
| [HONKER.md](HONKER.md) | **可选** Honker：安装、能力表、配置样例 |
| [HONKER_FULL_STACK_BENCH.md](HONKER_FULL_STACK_BENCH.md) | 全量激活 + 实质 bench |
| [MIGRATING_TO_RUBY4_RAILS81.md](MIGRATING_TO_RUBY4_RAILS81.md) | 1.0 升级、备份、Solid 清理 |
| [LITESEARCH_ZH_PINYIN.md](LITESEARCH_ZH_PINYIN.md) | `:simple` 中文/拼音 API |
| [LITEVECTOR.md](LITEVECTOR.md) | Litevector API 与限制 |

---

## 0. 应用 Gemfile：Litestack + 可选 Honker（GitHub Packages）

本 fork 的 **litestack 1.1.0+** 与 **honker 0.4.0** 均在 Packages，**不在** rubygems.org。

```ruby
# Gemfile
source "https://rubygems.org"

gem "rails", "~> 8.1"

source "https://rubygems.pkg.github.com/sunfang3" do
  gem "litestack", "1.1.0"
  # Optional — multi-worker wake / L1 invalidate / job lifecycle stream
  gem "honker", "0.4.0"
end
```

```bash
# PAT needs read:packages（私有 package 时常还需要 repo）
export BUNDLE_RUBYGEMS__PKG__GITHUB__COM="YOUR_GH_USERNAME:YOUR_PAT"
bundle install
```

权限、可见性、CI secret 名称见 **[RELEASE_GITHUB_PACKAGES.md](RELEASE_GITHUB_PACKAGES.md)**。

生成器会写入注释版 `config/litejob.yml`、`config/litecache.yml` 与 `cable.yml` 提示；**不会**自动打开 Honker 特性。细节与能力矩阵：[HONKER.md](HONKER.md)。

---

## 1. 默认全栈（不需要原生扩展）

这些组件**只依赖** gem 自带的 Ruby + `sqlite3` 2.x，**不需要** `.so`：

| 能力 | 组件 | 配置位置 |
|------|------|----------|
| 主库 | Litedb | `config/database.yml` → `adapter: litedb` |
| 缓存 | Litecache | `config.cache_store = :litecache`（可加 path / L1 选项） |
| 任务 | Litejob | `config.active_job.queue_adapter = :litejob` |
| Cable | Litecable | `config/cable.yml` → `adapter: litecable` |
| 英文 FTS | Litesearch | `tokenizer :porter` / `:trigram` 等内置分词器 |
| 指标 | Litemetric / Liteboard | 可选 |

### Litecache：进程内 L1 与多 worker 失效（可选）

默认 **不开启** L1，避免写放大。单进程开发可只开 L1；多 Puma worker 需要跨进程一致时再开失效。

```ruby
# config/environments/production.rb（生成器会写入 path；L1 需自行打开）
config.cache_store = :litecache, {
  path: Rails.root.join("storage", Rails.env, "cache.sqlite3").to_s,
  # gem "honker" 后：
  # l1: true,
  # invalidate: :honker,  # 或 :ttl（仅软 TTL，无需 honker）
}
```

| `invalidate` | 含义 |
|--------------|------|
| `:none`（默认） | 仅同进程 L1（若 `l1: true`） |
| `:ttl` | 软 TTL 背书，多进程最终一致 |
| `:honker` | 与 cache 文件同事务 `notify`，对端丢 L1；不可用时回退 `:ttl` |

完整 YAML 样例：`samples/litecache.honker.yml`。设计与 benchmark：`docs/plans/litecache-l1-honker-design-review.md`、`bench/bench_litecache_l1.rb`。

**默认策略：** 生成器与 gem 默认保持 `l1: false` / `invalidate: :none`。在本地跑通 `compare` 与多 worker soak 前，不要把 L1/honker 设成全局默认。

### 安装步骤

```bash
# Gemfile / 依赖
bundle add litestack   # Ruby >= 4.0, Rails >= 8.1

# 一键改配置（仅核心栈）
bin/rails generate litestack:install
bin/rails db:prepare
```

生成器会处理：

- `database.yml` / `cable.yml`（含可选 `transport: honker` 注释）
- `config/litejob.yml` / `config/litecache.yml`（Honker 选项注释）
- production 的 cache / Active Job
- `.gitignore` / `.dockerignore` 中的 SQLite 路径  
- `config/initializers/litestack_extensions.rb`（扩展 path 探测）

**默认不会**下载 vectorlite / libsimple，也**不会**删除 Solid gems（见迁移文档），**不会**把 Honker 写进应用 Gemfile（需按 §0 自行添加）。

### 安装时一并下载扩展（推荐显式一键）

需要中文/拼音和/或向量时，用 generator 参数（需网络 + `python3`）：

```bash
# 只要中文/拼音 FTS
bin/rails generate litestack:install --with-simple

# 只要向量检索
bin/rails generate litestack:install --with-vectorlite

# 两个都要
bin/rails generate litestack:install --with-extensions
```

效果：

1. 仍配置核心全栈 + initializer  
2. 以 `LITESTACK_EXTENSION_ROOT=<app root>` 运行 gem 内 `scripts/fetch_*.rb`  
3. 二进制落到 **`应用`** 的 `vendor/simple/...`、`vendor/vectorlite/...`  

无网环境可先装配置、稍后再下：

```bash
LITESTACK_GENERATOR_SKIP_FETCH=1 bin/rails g litestack:install --with-extensions
# 之后在应用根：
export LITESTACK_EXTENSION_ROOT="$PWD"
bundle exec ruby "$(bundle show litestack)/scripts/fetch_simple.rb"
bundle exec ruby "$(bundle show litestack)/scripts/fetch_vectorlite.rb"
```

### 数据目录（推荐）

```ruby
# config/application.rb
module MyApp
  class Application < Rails::Application
    # 持久化路径（晚于 require 求值，兼容 dotenv）
    config.litestack.data_path = Rails.root.join("storage")
  end
end
```

或：

```bash
export LITESTACK_DATA_PATH=/var/lib/myapp
```

---

## 2. 何时需要原生扩展？

| 需求 | 扩展 | 配置项 | 何时加载 |
|------|------|--------|----------|
| 中文 / 拼音全文检索 | [wangfenjin/simple](https://github.com/wangfenjin/simple) → `libsimple.so` | `config.litestack.simple_extension_path` | 创建/打开 `tokenizer :simple` 的 Litesearch 索引，或执行 `simple_query` |
| 向量 / 嵌入 kNN | [vectorlite](https://github.com/1yefuwang1/vectorlite) → `vectorlite.so` | `config.litestack.vector_extension_path` | `require "litestack/litevector"` 后创建 `Litevector::Index` 或 `Litevector::Model` |

**可以只装其中一个，也可以都不装。** 未配置时，核心全栈与英文 FTS 不受影响；一旦使用 `:simple` / Litevector 却找不到 `.so`，会抛出命名错误（`Litesearch::SimpleExtension::NotFoundError` / `Litevector::ExtensionNotFoundError`）。

架构关系：

```
┌─────────────────────────────────────────────────────────┐
│  Rails app                                              │
│  bin/rails g litestack:install  →  核心配置             │
│                                                         │
│  Litedb / Litecache / Litejob / Litecable / Litesearch  │
│       │                        │                        │
│       │  内置 FTS tokenizers   │  可选                  │
│       ▼                        ▼                        │
│  sqlite3 gem ────────── load_extension ───────────────  │
│                              │                          │
│              vendor/simple/.../libsimple.so             │
│              vendor/vectorlite/.../vectorlite.so        │
└─────────────────────────────────────────────────────────┘
```

扩展通过 SQLite 的 **`enable_load_extension` + `load_extension`** 挂到**同一条**（或 Litevector 自己的）连接上，不是独立服务进程。

---

## 3. 把扩展装进「应用」而不是 gem 目录

### 3.1 下载到 Rails 应用根目录

在 **Rails 应用根**执行（需要网络；`python3` 用于解压 wheel/zip）：

```bash
# 解析 litestack gem 里的脚本路径
GEM_LITESTACK="$(bundle show litestack)"

# 下载到当前应用的 vendor/ 下
export LITESTACK_EXTENSION_ROOT="$PWD"

bundle exec ruby "$GEM_LITESTACK/scripts/fetch_simple.rb"
# → vendor/simple/<platform>/libsimple.so
# → vendor/simple/<platform>/dict/   (jieba 用)

bundle exec ruby "$GEM_LITESTACK/scripts/fetch_vectorlite.rb"
# → vendor/vectorlite/<platform>/vectorlite.so
```

`<platform>` 示例：

| 主机 | 目录名 |
|------|--------|
| Linux x86_64 | `linux-x86_64` |
| Linux aarch64 | `linux-arm64` |
| macOS Apple Silicon | `darwin-arm64` |
| macOS Intel | `darwin-x86_64` |

开发机与生产机架构不一致时，**必须在目标平台各自 fetch 一份**，或在 CI/镜像构建阶段下载对应二进制。

### 3.2 配置 Rails（推荐：initializer）

生成器会放一份示例（若已存在则跳过）：

`config/initializers/litestack_extensions.rb`

```ruby
# frozen_string_literal: true

# 按本机 platform 选择路径。生产请在镜像构建时放入对应 .so。
platform =
  case RUBY_PLATFORM
  when /linux.*aarch64|linux.*arm64/ then "linux-arm64"
  when /linux/ then "linux-x86_64"
  when /darwin.*arm64|darwin.*aarch64/ then "darwin-arm64"
  when /darwin/ then "darwin-x86_64"
  else
    "linux-x86_64"
  end

simple = Rails.root.join("vendor/simple", platform, "libsimple.so")
vector = Rails.root.join("vendor/vectorlite", platform, "vectorlite.so")

# 中文 / 拼音 FTS（可选）
if simple.exist?
  Rails.application.config.litestack.simple_extension_path = simple
else
  Rails.logger&.info("[litestack] libsimple not found at #{simple}; tokenizer :simple unavailable")
end

# 向量检索（可选）
if vector.exist?
  Rails.application.config.litestack.vector_extension_path = vector
else
  Rails.logger&.info("[litestack] vectorlite not found at #{vector}; Litevector unavailable")
end
```

Railtie 在启动时读取上述 config：

- 设置 `Litesearch.simple_extension_path`（并 `require` litesearch 相关路径逻辑）  
- 设置 `Litevector.extension_path`（`require "litestack/litevector"`）

也可用环境变量（适合 Docker secret / 多路径）：

```bash
export LITESEARCH_SIMPLE_EXTENSION_PATH=/app/vendor/simple/linux-x86_64/libsimple.so
export LITEVECTOR_EXTENSION_PATH=/app/vendor/vectorlite/linux-x86_64/vectorlite.so
```

优先级（简要）：

1. `config.litestack.*_extension_path` / `Litesearch.simple_extension_path` / `Litevector.extension_path`  
2. 环境变量  
3. 自动探测：`Rails.root/vendor/{simple,vectorlite}/<platform>/…`，以及 gem 内 `vendor/`（开发 litestack 自身时）

### 3.3 `.gitignore` 建议

二进制体积大、与平台绑定，通常**不提交**到 git：

```gitignore
# Litestack optional SQLite extensions (fetch at build/deploy)
/vendor/simple/**/*.so
/vendor/simple/**/*.dylib
/vendor/simple/**/*.dll
/vendor/vectorlite/**/*.so
/vendor/vectorlite/**/*.dylib
/vendor/vectorlite/**/*.dll
```

`dict/`（jieba）可随 release 解压得到，也可选择提交文本词典；默认 fetch 会带上。

---

## 4. 在业务代码中启用

### 4.1 中文 / 拼音搜索

```ruby
# app/models/article.rb
class Article < ApplicationRecord
  include Litesearch::Model

  litesearch do |schema|
    schema.fields [:title, :body]
    schema.tokenizer :simple
    # schema.query_builder :jieba  # 需 dict/ 与 libsimple 同级
  end
end

Article.search("中华国歌")
Article.search("zhonghua")
```

确保 **boot 后** `simple_extension_path` 已指向真实文件，否则建索引时会失败。

### 4.2 向量检索

```ruby
# 显式 require（或由 Railtie 在配置了 path 时加载）
require "litestack/litevector"

class Document < ApplicationRecord
  include Litevector::Model

  litevector do |schema|
    schema.dimensions 1536
    schema.distance :cosine
    schema.max_elements 100_000
    schema.source :embedding   # 返回 float 数组或 float32 二进制
  end
end

doc.reindex_vector!
Document.nearest_neighbors(query_embedding, k: 10)
```

嵌入向量需由应用自己生成（OpenAI / 本地模型等）；Litevector **不**做推理。

---

## 5. Docker / 生产部署清单

1. **构建阶段**在目标架构上执行 `fetch_simple` / `fetch_vectorlite`（`LITESTACK_EXTENSION_ROOT=/app`）。  
2. 镜像内路径与 `config.litestack.*_extension_path` 一致。  
3. 确认镜像里的 `sqlite3` gem 支持 `enable_load_extension`（官方预编译 2.x 一般可用）。  
4. 持久卷只挂载业务 SQLite / `storage`；**扩展 `.so` 放在镜像层**即可，不必进数据卷。  
5. 多架构（amd64 + arm64）构建时用 buildx 分别 fetch，或使用多阶段复制对应文件。  
6. 健康检查：启动后可在 console 试一次  
   - `Litesearch::SimpleExtension.available?`  
   - `Litevector.available?`（需已 require litevector）

示例 Dockerfile 片段：

```dockerfile
WORKDIR /app
COPY Gemfile Gemfile.lock ./
RUN bundle install

# 在镜像构建机架构上下载扩展
ENV LITESTACK_EXTENSION_ROOT=/app
RUN bundle exec ruby "$(bundle show litestack)/scripts/fetch_simple.rb" \
 && bundle exec ruby "$(bundle show litestack)/scripts/fetch_vectorlite.rb"

COPY . .
```

---

## 6. 与「仅 gem 内 vendor」开发方式的区别

| 场景 | 扩展放哪 | 怎么配 |
|------|----------|--------|
| 开发 **litestack gem** 自己 | 仓库 `vendor/simple`、`vendor/vectorlite` | 自动探测 / 测试 helper |
| **业务 Rails 应用** | **应用** `vendor/simple`、`vendor/vectorlite` | initializer 或 ENV（推荐） |

不要依赖「bundle 里 gem 目录下的 vendor」作为生产路径：gem 更新/路径变化会导致丢失。

---

## 7. 故障排查

| 现象 | 可能原因 | 处理 |
|------|----------|------|
| `libsimple … not found` | 未 fetch 或 path 错误 | 查 `platform` 目录名、文件是否存在 |
| `vectorlite binary not found` | 同上 | 同上 |
| `failed to load … load_extension` | SQLite 禁止加载扩展 / 架构不匹配 | 换官方 sqlite3 2.x gem；核对 so 架构 |
| 中文搜不到 | 未用 `tokenizer :simple` 或仍用旧索引 | 重建索引；确认 query 走 `simple_query` |
| 拼音偶尔慢首次 | simple 首次加载拼音表 | 可接受冷启动；或预热一次查询 |
| jieba 失败 | 无 `dict/` | 使用完整 fetch 产物，或 `query_builder :simple` |

---

## 8. 最小检查清单（上线前）

- [ ] `bin/rails g litestack:install` + `db:prepare` 核心栈正常  
- [ ] （可选）fetch simple / vectorlite 到 **应用** `vendor/`  
- [ ] `config/initializers/litestack_extensions.rb`（或 ENV）路径在生产存在  
- [ ] 使用 `:simple` / Litevector 的模型在 staging 跑通搜索/kNN  
- [ ] `.gitignore` 忽略 `*.so`；CI/镜像负责下载  
- [ ] 阅读 [LITEVECTOR.md](LITEVECTOR.md) 限制（float32、非负 id、close 刷盘）  

---

## 9. 一键命令备忘

```bash
# 核心 only
bundle add litestack
bin/rails generate litestack:install
bin/rails db:prepare

# 核心 + 扩展（推荐）
bin/rails generate litestack:install --with-extensions
bin/rails db:prepare

# 或只下其中一个
bin/rails g litestack:install --with-simple
bin/rails g litestack:install --with-vectorlite

# 手动扩展（在 Rails 根目录）
export LITESTACK_EXTENSION_ROOT="$PWD"
export GEM_LITESTACK="$(bundle show litestack)"
bundle exec ruby "$GEM_LITESTACK/scripts/fetch_simple.rb"
bundle exec ruby "$GEM_LITESTACK/scripts/fetch_vectorlite.rb"

# 开发 litestack 本仓库时
bundle exec rake extensions:fetch
bundle exec rake extensions:test
```
