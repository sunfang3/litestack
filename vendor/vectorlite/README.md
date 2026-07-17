# vectorlite binaries

Place platform builds here after running:

```bash
bundle exec ruby scripts/fetch_vectorlite.rb
```

Layout:

```
vendor/vectorlite/linux-x86_64/vectorlite.so
vendor/vectorlite/darwin-arm64/vectorlite.dylib
...
```

Binaries are gitignored. Pin: **vectorlite 0.2.0** (see `docs/plans/litevector-spike-notes.md`).
