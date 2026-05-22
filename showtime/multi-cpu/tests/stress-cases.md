# Stress Cases

## hello-world cargo build

- purpose: 快速确认多核是否真的加速。
- current result:
  - `-j1`: 176s
  - `-j4`: 62s
- next: 每个组合重复 5 次。

## futex private/shared regression

- purpose: 验证 `FUTEX_PRIVATE_FLAG` 语义。
- expected:
  - private futex 只在同一地址空间内 wake。
  - shared futex 可跨共享映射 wake。
  - private/shared key 不串。

## mutex stress

- purpose: 验证 unlock ordering。
- shape:
  - N threads
  - shared counter
  - high iteration count
  - assert final counter

## cargo build medium workspace

- purpose: 比 hello-world 更接近真实 Rust workload。
- variables:
  - `CARGO_BUILD_JOBS=1/2/4/8`
  - `RAYON_NUM_THREADS=1/4`
  - cold/incremental

## M6 selfbuild subset

- purpose: 最终目标的前置验证。
- note: 目前 M6 稳定默认仍是 `CARGO_BUILD_JOBS=1`、`RAYON_NUM_THREADS=1`，多核版本要逐步放开。

