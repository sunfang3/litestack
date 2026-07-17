# Diagnostic scripts

Finite, relocatable smoke utilities for Litestack on Ruby 4.

```bash
bundle exec ruby scripts/test_metrics.rb   # prefer short runs; close components
bundle exec ruby scripts/verify_package.rb # package gate used by CI
```

Scripts are not packaged in the gem. Prefer `bundle exec rake test` for compatibility evidence.
