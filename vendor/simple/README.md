# wangfenjin/simple binaries

Chinese + Pinyin FTS5 tokenizer used by Litesearch (`tokenizer :simple`).

```bash
bundle exec ruby scripts/fetch_simple.rb
```

Layout after fetch:

```
vendor/simple/linux-x86_64/libsimple.so
vendor/simple/linux-x86_64/dict/   # jieba dict (optional)
```

See `docs/LITESEARCH_ZH_PINYIN.md`. Upstream: https://github.com/wangfenjin/simple
