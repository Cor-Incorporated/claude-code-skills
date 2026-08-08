## Summary

## H5 admission (block-capable guard / completion verifier only)

- [ ] **H5-guard: no** — this PR does **not** add/change a block-capable guard or completion verifier
- [ ] **H5-guard: yes** — fill the three sections below (required check `h5-admission` will fail if incomplete)

### 陰性テスト (negative test — known-bad → red measured)

```
# command + expected fail / red log
```

### 台帳 (H6 ledger wiring)

How fire events append to `guard-ledger.jsonl` / `aidd_ledger_append`:

### 廃止条件 (retirement)

e.g. 90 days zero fires / FP rate >50% → retirement issue

## Test plan

- [ ]
