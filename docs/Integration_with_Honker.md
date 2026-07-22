## 核心判断

**Honker 最适合先作为 LiteStack 的“唤醒与协调层”，而不是直接替换 LiteQueue。**

建议把职责分开：

```text
LiteQueue / LiteJob
负责：任务存储、队列优先级、序列化、执行框架

Honker
负责：跨进程提交感知、通知唤醒、进程协调、可选可靠领取
```

最有价值的融合顺序是：

1. 用 Honker watcher 替换 LiteJob 的空队列轮询；
2. 用 `notify/listen` 做按队列定向唤醒；
3. 用 Honker 改进 LiteCable；
4. 可选引入 claim/ack、visibility timeout，提高 LiteJob 崩溃恢复能力；
5. 最后再考虑 transactional outbox、stream、scheduler 和 named lock。

不建议一开始就把 LiteQueue 的表全部替换为 Honker 表。那样会迅速变成一次队列系统重写。

---

# 一、当前 LiteJob 最明显的问题：轮询

LiteJob 的 worker 在空队列时按下面的间隔逐级休眠：

```ruby
[0.001, 0.005, 0.025, 0.125, 0.625, 1.0, 2.0]
```

每个 worker 都会不断执行 `pop`；找不到任务时退避，最长睡眠 2 秒。一旦有任务，就重新回到 1ms 轮询。

具体循环是：

```ruby
while @running
  # 遍历队列
  while payload = pop(queue, 1)
    process_job(...)
  end

  if processed == 0
    sleep sleep_intervals[index]
  end
end
```

因此，在队列已经空闲较长时间后，一个新任务的启动延迟理论上可能接近 2 秒。多个 worker 还会分别执行空 `pop`。

Honker 的 watcher 则用一个独立连接周期性读取 `PRAGMA data_version`。默认每 1ms 检查一次，数据库提交后向本进程的监听者分发 wake event；多个 subscriber 可以共享一个 watcher。

这里的关键收益不是“彻底不轮询”，而是：

```text
当前：
5 个 worker × 不断执行 DELETE ... RETURNING

Honker：
1 个 watcher × 轻量 PRAGMA data_version
数据库变化后才让 worker 尝试 DELETE ... RETURNING
```

SQLite 官方也明确说明，同一个监控连接两次读取 `PRAGMA data_version` 时，如果其他连接提交了修改，值就会发生变化。([SQLite 主页][1])

---

# 二、最推荐的第一阶段：只把 Honker 当作 wakeup backend

这一阶段完全保留：

* LiteQueue 的 `queue` 表；
* `push`、`repush`、`pop` API；
* LiteJob 的 payload；
* 队列优先级；
* 现有 retry 和 `_dead` 队列；
* Active Job adapter。

只增加一个抽象：

```ruby
module Litequeue
  module Wakeup
    class Polling
    end

    class Honker
    end
  end
end
```

配置可以设计为：

```yaml
production:
  wakeup:
    adapter: honker
    poll_interval_ms: 5
    fallback_interval: 5
```

或者：

```ruby
Litejobqueue.new(
  wakeup: :honker,
  watcher_poll_interval_ms: 5
)
```

## 推荐结构

```text
queue.sqlite3
     │
     ├── LiteQueue connection
     │      push / pop / repush
     │
     └── Honker watcher connection
            PRAGMA data_version
                    │
                    ▼
             process-local signal
                    │
          ┌─────────┼─────────┐
          ▼         ▼         ▼
       worker 1  worker 2  worker 3
```

Honker 的 Ruby binding 已经提供了底层 watcher：

```ruby
db = Honker::Database.new(
  queue_path,
  watcher_poll_interval_ms: 5
)

db.wait_for_update(timeout_seconds)
```

Ruby 实现内部通过 Fiddle 调用 Honker 的 watcher C ABI，并提供 `wait_for_update`。

## 重要：不要每个 worker 建一个 watcher

正确方式是：

```text
每个进程一个 watcher
        ↓
一个 dispatcher
        ↓
唤醒本进程的全部或部分 workers
```

否则会把“五个 LiteQueue 轮询者”变成“五个 Honker 轮询者”，失去主要价值。

另外，Honker 的 `wait_for_update` 是阻塞式 FFI 接口。LiteStack 同时支持 Thread、Fiber Scheduler、Polyphony 和 Iodine，因此 watcher 最好运行在一个专用原生线程中，再通过 LiteStack 自己的事件对象唤醒 Fiber，而不是直接在 Fiber scheduler 所在线程中阻塞。LiteStack 目前的调度抽象只有 `spawn`、`switch` 和 `Mutex`，适合补充一个统一的 `Litescheduler::Signal` 或 `Event`。

例如：

```ruby
signal.wait(timeout:)
signal.signal
signal.broadcast
signal.close
```

后端分别实现为：

* Thread：`Mutex + ConditionVariable`
* Fiber scheduler：`IO.pipe` 或 scheduler-aware event
* Polyphony：对应的 condition/event primitive
* Iodine：线程事件

---

# 三、延迟任务不能只靠通知

这是融合中最容易遗漏的问题。

立即任务在 `push` 提交后可以产生 wake event；但延迟任务：

```ruby
queue.push(payload, 3600)
```

在一小时后变成可执行状态时，数据库并不会自动产生新的提交。

所以不能这样写：

```text
没有通知
    ↓
无限等待
    ↓
延迟任务永远不执行
```

必须同时维护“下一次任务到期时间”。

建议为 LiteQueue增加一个 prepared statement：

```sql
SELECT MIN(fire_at)
FROM queue
WHERE name IN (...)
  AND fire_at > unixepoch('subsec');
```

worker dispatcher 的逻辑应当是：

```ruby
loop do
  drain_all_ready_jobs

  next_fire_at = find_next_fire_at
  timeout = if next_fire_at
    [next_fire_at - Time.now.to_f, 0].max
  else
    fallback_interval
  end

  wakeup.wait(timeout: [timeout, fallback_interval].min)
end
```

也就是同时等待两个条件：

```text
条件 A：其他进程提交了新任务
条件 B：最近的延迟任务到期了
```

Honker 自己的队列也采用类似设计，提供 `honker_queue_next_claim_at()` 查询下一次可能领取任务的时间。

因此，LiteStack 若只引入通知而不加入 deadline-aware wait，反而会破坏现有 delayed job 的正确性。

---

# 四、第二阶段：真正使用 `notify/listen`，做定向唤醒

第一阶段甚至不必调用 `notify()`：

```text
LiteQueue push 提交
    ↓
data_version 改变
    ↓
Honker watcher 唤醒
    ↓
worker 重新 pop
```

因为 watcher 能感知同一数据库文件上的任何提交。

但这种简单方案存在一个问题：

* enqueue 会唤醒；
* pop 删除任务也会唤醒；
* repush 会唤醒；
* GC 删除死任务也会唤醒；
* 每个 worker 的领取提交都可能唤醒其他进程。

Honker 本身明确接受“数据库任何提交都先唤醒，再由 listener 查询自己关注的状态”的 overtrigger 模型。

对于 LiteQueue，可以进一步用通知表过滤：

```text
任何数据库提交
       ↓
Honker watcher 唤醒 listener
       ↓
查询是否新增 litequeue:* 通知
       ↓
有 enqueue 通知才唤醒 worker
```

## enqueue 时事务性发送通知

建议修改 `Litequeue#push`：

```ruby
def push(value, delay = 0, queue = "default")
  transaction do
    result = run_stmt(:push, queue, delay, value)[0]

    run_sql(
      "SELECT notify(?, ?)",
      "litequeue:#{queue}",
      Oj.dump(
        id: result[0],
        delay: delay
      )
    )

    result
  end
end
```

队列行和 notification 行处于同一个事务：

```text
COMMIT 成功：任务和通知同时出现
ROLLBACK：任务和通知同时消失
```

这正是 Honker 的核心设计：`notify()`、enqueue 或 stream publish 都只是当前事务中的插入。

## 哪些操作需要发送通知

至少包括：

| 操作               | 是否需要通知 | 原因                       |
| ---------------- | -----: | ------------------------ |
| immediate `push` |      是 | 立即唤醒 worker              |
| delayed `push`   |      是 | 可能提前下一 deadline          |
| `repush`         |      是 | retry 时间可能改变             |
| 删除最早延迟任务         |   最好通知 | dispatcher 要重算 deadline  |
| `clear`          |   最好通知 | dispatcher 要取消旧 deadline |
| `pop`            |      否 | 不应再次唤醒其他 worker          |
| GC 删除 `_dead`    |      否 | 与可执行任务无关                 |

## 不推荐用行级 trigger 作为默认方案

可以创建：

```sql
CREATE TRIGGER queue_after_insert
AFTER INSERT ON queue
BEGIN
  SELECT notify(
    'litequeue:' || NEW.name,
    json_object('id', NEW.id, 'fire_at', NEW.fire_at)
  );
END;
```

但它有两个缺点：

1. 所有可能写 `queue` 表的连接都必须加载 Honker 扩展，否则会因为找不到 `notify()` 函数而失败；
2. 批量插入 1000 个任务会生成 1000 个通知。

更好的方式是由 LiteQueue API 在事务末尾做一次合并通知：

```json
{
  "queue": "default",
  "count": 1000,
  "earliest_fire_at": 1784672200.5
}
```

notification 只是 wake hint；任务表始终是事实来源。

---

# 五、当前 Ruby binding 的现实限制

Honker 目前的 Ruby binding：

* queue：支持；
* stream：支持；
* notify：支持；
* **listen：尚未支持完整的 Ruby API**；
* watcher：底层可用。

Honker 自己的 binding support 表明确把 Ruby 标为“notify yes, listen no”，并将 Ruby async listen parity 列入尚未完成的部分。

因此 Litestack 当前有两条路线。

## 路线 A：Litestack 自己实现一个小型 Listener

基于现成的：

```ruby
Honker::Database#wait_for_update
```

再查询：

```sql
SELECT id, channel, payload
FROM _honker_notifications
WHERE id > ?
  AND channel IN (...)
ORDER BY id;
```

需要保留：

```ruby
@last_notification_id
```

正确初始化顺序是：

```text
1. 先打开 watcher
2. 再读取当前 MAX(id)
3. 查询新通知
4. 没有新通知时 wait
```

这样避免在“读取 MAX(id)”和“开始等待”之间漏掉提交。Honker 的 Python Listener 也是先订阅更新事件，再读取当前最大 notification id。

## 路线 B：向 Honker 上游补齐 Ruby Listener

从长期看，这可能是更好的投入：

```ruby
listener = db.listen("litequeue:default")

listener.each do |notification|
  signal.broadcast
end
```

LiteStack 可以成为 Honker Ruby listen API 的实际使用方和测试场景，特别是：

* Thread 模式；
* Ruby Fiber Scheduler；
* Polyphony；
* Puma fork；
* 多进程 Action Cable；
* Rails reloader。

这会比 Litestack 自己长期维护私有 listener 更有生态价值。

---

# 六、比 wakeup 更重要的改进：避免任务因进程崩溃而丢失

当前 LiteQueue 的 `pop` 是：

```sql
DELETE FROM queue
WHERE ...
RETURNING id, value;
```

也就是说，任务在交给 `perform` 之前就从数据库删除了。

当前流程是：

```text
DELETE task row
      ↓
Ruby 取得 payload
      ↓
开始 perform
      ↓
成功：结束
异常：repush
```

如果进程在下面这个窗口被 `kill -9`：

```text
DELETE 已提交
但 perform 尚未完成
```

任务就无法恢复。LiteJob 的异常 retry 只能处理 Ruby 捕获到的异常，不能处理进程直接死亡。

Honker 队列提供的是：

```text
pending
   ↓ claim
processing + claim_expires_at
   ↓
成功 → ack/delete
失败 → retry
worker 崩溃 → visibility timeout 后重新领取
```

Ruby binding 已提供：

* `claim_one`

* `claim_batch`

* `ack`

* `retry`

* `fail`

* `heartbeat`

* `sweep_expired`

这比 listen/notify 更能实质性提升 LiteJob。

## 但不应直接改变 `Litequeue#pop`

因为 LiteQueue 目前是一个通用 destructive queue：

```ruby
value = queue.pop
```

用户会认为 `pop` 之后任务已被消费。

如果改成 visibility claim，就必须引入：

```ruby
job = queue.claim(worker_id)
job.ack
job.retry
job.heartbeat
```

所以更好的边界是：

```text
Litequeue
继续保持简单 push/pop 语义

Litejobqueue
增加可选可靠后端
```

例如：

```yaml
production:
  backend: litequeue
  # 或
  backend: honker
```

接口可以设计成：

```ruby
module LitejobBackend
  class DestructiveQueue
  end

  class HonkerQueue
  end
end
```

这样：

* LiteQueue 仍然轻量；
* LiteJob 可以选择 at-most-once 或 at-least-once；
* Active Job 用户可以使用可靠模式；
* 不破坏已有 LiteQueue API。

---

# 七、LiteCable 是另一个非常适合 Honker 的融合点

事实上，Honker 的 `notify/listen` 与 LiteCable 比与 LiteQueue更加“语义对位”。

LiteCable 当前配置：

```ruby
listen_interval: 0.05
```

也就是每 50ms 查询一次消息表。

listener 当前不断执行：

```ruby
run_stmt(:fetch, @last_fetched_id, @pid)
sleep @options[:listen_interval]
```

另外 broadcaster 每 20ms 批量把内存消息写入数据库，pruner 再周期性清理消息。

Honker 可以把这部分改成：

```text
LiteCable.broadcast
       │
       ├── 本进程 local_broadcast，立即送达
       │
       └── SELECT notify('litecable:<channel>', payload)
                         │
                         ▼
               其他进程 Honker listener
                         │
                         ▼
                  local_broadcast
```

收益包括：

* 跨进程延迟从固定约 50ms 降到 watcher cadence 附近；
* 空闲时不再每 50ms 查询完整消息表；
* channel 语义天然对应；
* notification 的 ephemeral 语义与 Action Cable 广播一致；
* 可以删掉或简化 LiteCable 自己的 message transport 表；
* `expire_after` 可映射为 Honker notification pruning。

我认为 **LiteCable 是第二个应当落地的 PR**，甚至可能比 Honker-backed LiteJob 更容易形成明显效果。

---

# 八、Transactional outbox：需要让队列与业务表位于同一数据库文件

Honker 强调的一个重要能力是：

```text
INSERT INTO orders
+
enqueue job / notify
+
同一个 COMMIT
```

这样业务数据和任务不存在 dual-write。

但 LiteQueue 默认使用：

```ruby
queue.sqlite3
```

而 Rails 业务表通常在另一个 SQLite 文件中。

因此默认结构下：

```text
app.sqlite3   COMMIT order
queue.sqlite3 COMMIT job
```

仍然不是一个原子事务。

不要把 `ATTACH queue.sqlite3` 当作 WAL 模式下的完整解决方案。SQLite 官方说明，在 WAL 模式下，跨多个 attached 数据库文件的事务只保证每个文件内部原子，主机在提交期间崩溃时，多个文件之间可能不一致。([SQLite][2])

如果要真正利用 transactional outbox，Litestack 可以增加一种模式：

```yaml
litejob:
  database: primary
  table_prefix: litestack_
```

即把：

```text
queue
_honker_notifications
_honker_live
_honker_dead
```

放在 Rails primary SQLite 文件中。

代价是 primary DB 上任何业务提交都会改变 `data_version`。Honker 的设计就是允许这种过度唤醒，然后通过按 channel 的索引查询判断是否有相关事件。

因此可以提供两种部署模式：

| 模式                 | 优点                      | 缺点                 |
| ------------------ | ----------------------- | ------------------ |
| 独立 `queue.sqlite3` | 隔离好，唤醒噪声小               | 不能与业务写入原子提交        |
| primary DB 共库      | 真正 transactional outbox | 所有业务提交都会唤醒 watcher |

---

# 九、Honker 还可以改善 Litestack 的几个辅助功能

## 1. 只让一个进程运行 GC/pruner

当前每个 LiteJobqueue 实例都会创建 garbage collector；LiteCable 每个进程也会创建 pruner。

多 Puma worker 时，可能有多个相同清理任务同时运行。

Honker 提供 named lock，可以让一个进程获得：

```ruby
litestack:litejob:gc
litestack:litecable:pruner
litestack:scheduler
```

只有持锁进程执行维护工作，其余进程等待或定期竞争。Honker 当前公开了 named locks、scheduler 和 rate limits。

## 2. Job result 与等待

可以扩展 LiteJob：

```ruby
handle = ReportJob.perform_async(params)

result = handle.wait(timeout: 30)
```

worker 完成后写 result，等待方通过 watcher 被唤醒，而不是反复查询。

## 3. Durable event stream

将 job 生命周期写入 stream：

```text
job.enqueued
job.claimed
job.started
job.succeeded
job.retried
job.dead
```

可以支持：

* LiteBoard 实时界面；
* 审计；
* 延迟统计；
* 故障分析；
* 外部进程订阅。

## 4. LiteCache 本地一级缓存失效

如果未来在 SQLite LiteCache 前增加进程内 L1 cache，可以用 notification 广播：

```text
cache:set:key
cache:delete:key
cache:clear
```

避免每次都直接访问 SQLite。

---

# 十、需要特别处理的工程问题

## Fork 安全

LiteStack 已经在 fork 后重新执行 `setup`，重新创建 SQLite 连接和后台线程。

Honker watcher 也必须遵循同样规则：

```text
fork 前：
关闭或不启动子进程 watcher

fork 后：
重新打开 Honker CoreWatcher
重新建立 notification cursor
重新建立 dispatcher thread
```

不能让子进程继承父进程的 Fiddle watcher handle 和 Rust watcher thread。

## PRAGMA 配置冲突

LiteQueue 默认：

```ruby
sync: 0
```

即写连接使用非常偏性能的同步设置。

Honker Ruby 默认：

```sql
PRAGMA synchronous = NORMAL;
```

融合时应明确区分：

```yaml
durability: fast
# synchronous=OFF

durability: normal
# synchronous=NORMAL
```

不要由两个库分别隐式修改 PRAGMA。特别是引入 at-least-once 和 transactional outbox 后，继续默认 `sync:0` 会削弱它们在断电场景下的意义。

## Alpha 状态

Honker 当前 README 明确标记为 alpha，并且 Ruby async listen 尚未补齐。

所以现阶段更适合：

```text
可选依赖
feature flag
保留 polling fallback
通过 soak test 后再成为默认
```

而不宜立刻成为 LiteStack 的强制核心依赖。

---

# 十一、建议的实施路线

## PR 1：Honker wakeup adapter

目标：

* 不修改 queue schema；
* 不修改 LiteQueue 公共 API；
* 保留 polling backend；
* 每进程一个 Honker watcher；
* 加入 deadline-aware wait；
* 正确处理 fork 和 shutdown。

新增：

```text
lib/litestack/wakeup.rb
lib/litestack/wakeup/polling.rb
lib/litestack/wakeup/honker.rb
```

SQL 增加：

```yaml
next_fire_at: >
  SELECT min(fire_at)
  FROM queue
  WHERE name = ?
    AND fire_at > unixepoch('subsec');
```

主要衡量指标：

* idle CPU；
* 空队列时每秒 SQL 次数；
* enqueue 到 perform 的 p50/p95/p99；
* 1、5、20 个 worker 的锁竞争；
* 多进程 wake latency；
* delayed job 时间误差。

## PR 2：queue notification filtering

目标：

* enqueue/repush 与 `notify()` 同事务；
* watcher 只在发现相关 notification 后广播 worker；
* 避免 pop/GC 提交造成 worker wake cascade；
* 支持 queue-specific channel；
* 增加 notification pruning。

## PR 3：LiteCable Honker transport

目标：

* 保留本地立即 broadcast；
* 跨进程使用 Honker notification；
* 移除固定 50ms fetch polling；
* 保留原 transport 作为 fallback。

## PR 4：可靠 LiteJob backend

增加：

```yaml
backend: honker
visibility_timeout: 300
heartbeat_interval: 60
```

实现：

```text
claim → perform → ack
          │
          ├── exception → retry
          └── process crash → claim timeout 后重新领取
```

## PR 5：primary database / outbox 模式

让 Active Record 事务可以同时完成：

```ruby
Order.transaction do
  order = Order.create!(...)
  ReportJob.perform_later(order.id)
end
```

真正做到一个 SQLite COMMIT 中同时写业务表和 job row。

---

# 最终建议

对 LiteStack 而言，Honker 最理想的定位不是“竞争队列实现”，而是逐步成为：

```text
                    Litestack
                       │
        ┌──────────────┼──────────────┐
        ▼              ▼              ▼
    LiteJob         LiteCable       LiteCache
        │              │              │
        └──────────────┼──────────────┘
                       ▼
             Honker notification/watcher
                       │
                       ▼
                    SQLite
```

优先级可以明确排成：

1. **LiteJob wakeup：立即做，风险最低；**
2. **LiteCable transport：语义最匹配，效果明显；**
3. **LiteJob claim/ack：价值最大，但需要新 backend；**
4. **同库 transactional outbox：作为 Rails SQLite 完整方案；**
5. **stream、locks、scheduler：完善 Litestack 的协调能力。**

其中第一步应当坚持一个原则：

> **Honker 负责告诉 LiteJob“现在值得查一次”，LiteQueue 表负责回答“究竟有没有可执行任务”。**

这样既能保护您已经在 Litestack 上的投入，也可以让 Honker 成为增强层，而不是迫使 Litestack 全面改弦更张。

[1]: https://www2.sqlite.org/pragma.html?utm_source=chatgpt.com "Pragma statements supported by SQLite"
[2]: https://www.sqlite.org/lang_attach.html?utm_source=chatgpt.com "ATTACH DATABASE"

