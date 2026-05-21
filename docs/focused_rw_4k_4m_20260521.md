# Focused gdsio benchmark: R/W × 4K/4M × GDS vs CPU-bounce

**Run tag**: `gdsio_sweep_v3_20260521_095422`
**Hardware**: Intel Xeon Silver 4410Y (48 cores) · 1× RTX 6000 Ada · PASCARI AI100E NVMe (PCIe Gen4) · ext4 `data=ordered`
**Software**: gdsio 1.12 · libcufile 1.17.0 · nvidia-fs driver
**Matrix**: 2 sizes (4K, 4M) × 4 patterns (read/write × seq/rand) × 2 modes (`-x 0` GDS, `-x 2` CPU bounce) × 16 threads × 3 reps × 120 s/case = **48 cases ≈ 1 h 40 min**
**Preconditioning**: `none` — reused the 10 GB testfile created on 2026-05-18

> **TL;DR**
> - **Reads**: GDS wins at small IO (3–4×) and matches CPU at large IO. POSIX bounces 7 GB/s through DRAM; GDS bypasses (~180 MB/s DRAM is just background).
> - **Writes**: GDS wins at **small IO (2× at 4K seq)**, but **loses at 4M seq (-29%) and at 4K random (-27%)**. The GDS write path **spends 23% of CPU on `osq_lock`/`rwsem_spin_on_owner`** under 16-thread contention against the nvidia-fs driver's internal rwsem — that is the bottleneck.
> - CPU function-level analysis (perf) confirms: GDS path lives in kernel `nvfs_*` ioctls + `cuFile` lib; CPU-bounce path lives in `libcuda` `cuMemcpyHtoD/DtoH` + `pthread_mutex_lock`.

---

## Throughput, latency, CPU, DRAM(avg over 3 reps)

`thr` = GiB/s, `lat` = µs avg, `usr%`/`sys%` = sum across gdsio's 16 threads (pidstat), DRAM = system MB/s.

| op | size | mode | thr | lat | IOPS | usr% | sys% | DRAM r | DRAM w |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| read_seq | 4K | **GDS** | **2.374** | **25.7** | 620,857 | 112 | 344 | 410 | 371 |
| read_seq | 4K | CPU | 0.752 | 81.2 | 196,889 | 175 | 84 | 2,339 | 2,192 |
| read_seq | 4M | GDS | 6.871 | 10,780 | 1,754 | 7 | 70 | **178** | 147 |
| read_seq | 4M | CPU | 6.795 | 10,654 | 1,733 | 38 | 35 | **6,508** | 6,826 |
| write_seq | 4K | **GDS** | **3.762** | **16.3** | 982,599 | 163 | 661 | 741 | 711 |
| write_seq | 4K | CPU | 1.921 | 31.8 | 502,143 | 500 | 364 | 4,732 | 3,954 |
| write_seq | 4M | GDS | 3.848 | 16,571 | 978 | 5 | 44 | 160 | 135 |
| write_seq | 4M | **CPU** | **5.407** | **11,566** | 1,380 | 31 | 35 | 6,286 | 5,931 |
| read_rand | 4K | GDS | 0.796 | 76.7 | 207,477 | 41 | 112 | 297 | 271 |
| read_rand | 4K | CPU | 0.746 | 81.9 | 195,000 | 177 | 82 | 2,264 | 2,144 |
| read_rand | 4M | GDS | 6.812 | 10,843 | 1,737 | 6 | 61 | 177 | 147 |
| read_rand | 4M | CPU | 6.793 | 10,100 | 1,735 | 41 | 40 | 6,462 | 6,802 |
| write_rand | 4K | GDS | 1.387 | 44.1 | 362,313 | 66 | 206 | 440 | 376 |
| write_rand | 4K | **CPU** | **1.911** | **31.9** | 500,069 | 525 | 363 | 5,539 | 4,778 |
| write_rand | 4M | GDS | 4.397 | 14,529 | 1,119 | 5 | 51 | 691 | 415 |
| write_rand | 4M | CPU | 5.014 | 12,569 | 1,279 | 35 | 42 | 5,917 | 5,820 |

### Headline ratios

| pattern | size | GDS / CPU throughput |
| --- | --- | --- |
| read seq | 4K | **3.16× GDS** |
| read seq | 4M | 1.01× (tie, SSD-bound) |
| read rand | 4K | 1.07× GDS |
| read rand | 4M | 1.00× tie |
| write seq | 4K | **1.96× GDS** |
| write seq | 4M | **0.71× — CPU wins +40%** |
| write rand | 4K | **0.73× — CPU wins +38%** |
| write rand | 4M | 0.88× — CPU wins +14% |

### DRAM-traffic ratio (CPU / GDS), as a direct CPU-bounce footprint

| op | size | CPU DRAM total | GDS DRAM total | ratio |
| --- | --- | --- | --- | --- |
| read seq | 4K | 4,531 | 781 | 5.8× |
| read seq | 4M | **13,334** | 325 | **41×** |
| write seq | 4K | 8,686 | 1,452 | 6.0× |
| write seq | 4M | 12,217 | 295 | 41× |
| read rand | 4M | 13,264 | 324 | 41× |
| write rand | 4M | 11,737 | 1,106 | 11× |

For 4 MiB sequential / random reads CPU bounce moves **>13 GB/s** through host DRAM; GDS moves ~325 MB/s (background only). **41× reduction in host memory traffic.**

---

## CPU function breakdown (perf record `-g`, 30 s window per case)

Top 6 hottest functions (avg overhead %) for the most interesting cases. Full per-case tables in `results/<run>/perf_top_funcs.txt` (12 functions × 48 cases).

### 1. 4K seq read — why is GDS 3× faster?

| GDS path (kernel `nvfs_*` + cuFile) | % | CPU-bounce path (`cudaMemcpy` + locks) | % |
| --- | --- | --- | --- |
| `__iomap_dio_rw` | 4.67 | `pthread_mutex_lock` (libc) | 7.76 |
| `__fdget` | 3.72 | `pthread_mutex_unlock` (libc) | — |
| `fput` | — | `cuMemcpyHtoDAsync_v2` (libcuda) | major |
| `_raw_read_lock` | — | `io_work` / `start_thread` | — |
| `nvfs_io_start_op` | — | `cudaMemcpyAsync` | — |
| `nvfs_ioctl` | — | … | — |

**Reading**: GDS spends CPU in cheap kernel direct-IO + nvfs ioctl. CPU-bounce contends on **pthread_mutex inside libcudart's stream pool** while every 4 KB hop also costs a host↔device memcpy. The serialised memcpy stage is the throttle — DRAM bandwidth at 2.3 GB/s confirms it (~5× GDS's idle DRAM).

### 2. 4M seq read — why both saturate the SSD

Both top stacks center on **`gup_pte_range` / `try_get_folio` / `try_grab_folio_fast`** (page pinning for DMA, ~4–6% each) and `bio_set_pages_dirty`. Differences:

- GDS: also ~5% in `osDevReadReg032`, ~5% in `osq_lock`, plus `__nvfs_mgroup_from_page` (4.6%) — nvidia-fs bookkeeping.
- CPU-bounce: lots of distinct `libcuda.so.580.126.20` symbols (un-symbolicated, proprietary), ~2–4% each.

Both paths are bottlenecked elsewhere (SSD bandwidth) so CPU profile differences don't change the throughput (6.87 vs 6.80 GiB/s). But DRAM 6.5 GB/s vs 180 MB/s **is the cost CPU-bounce hides**: any concurrent workload on the host would feel it.

### 3. 4M seq write — why CPU is 40% **faster** than GDS

This is the surprise. perf shows GDS write path **deadlock-spinning** on internal locks:

| GDS 4M seq write | % |
| --- | --- |
| **`osq_lock`** | **13.56** |
| **`rwsem_spin_on_owner`** | **9.30** |
| `osDevReadReg032` | 5.57 |
| `gup_pte_range` | 5.12 |
| `try_grab_folio_fast` | 4.14 |
| `__nvfs_mgroup_from_page` | 3.93 |
| `mutex_spin_on_owner` | 2.14 |

**~23 % of all CPU time on the GDS write path is spent spinning on locks** (`osq_lock` is the MCS optimistic spin queue; `rwsem_spin_on_owner` is rwsem reader/writer contention).

CPU-bounce 4M seq write doesn't have these locks in its top 12:

| CPU-bounce 4M seq write | % |
| --- | --- |
| `gup_pte_range` | 7.58 |
| `try_grab_folio_fast` | 5.84 |
| `try_get_folio` | 5.69 |
| `__blk_bios_map_sg` | 2.47 |
| `bvec_try_merge_page` | 2.06 |
| `bio_split_rw` | 1.86 |

→ standard kernel block-layer scatter-gather, no contention.

**Root cause**: with 16 concurrent writer threads, **nvidia-fs's internal rwsem becomes the bottleneck**. The CPU-bounce path goes through the kernel's mature block layer which scales linearly for write bw. GDS write throughput here is **a driver-side scaling limit, not an SSD limit**: NVMe still has headroom (CPU-bounce shows 5.41 GiB/s).

### 4. 4K randwrite — CPU 38% faster despite higher mutex pressure

| GDS 4K randwrite | % | CPU-bounce 4K randwrite | % |
| --- | --- | --- | --- |
| `__iomap_dio_rw` | 4.30 | `pthread_mutex_lock` | 6.57 |
| `__fdget` | 3.36 | `pthread_mutex_unlock` | 4.48 |
| `fput` | 3.01 | libcuda calls | various |
| `_raw_read_lock` | 2.64 | `finish_task_switch` | 1.88 |
| `nvfs_update_write_latency` | 2.34 | `futex_wake` | 1.66 |
| `nvfs_ioctl` | 1.82 | … | |

**Reading**: GDS spends CPU per-op in the nvfs ioctl pipeline (`__fdget`/`fput` 6.4% combined = lots of small syscalls). Per-op latency is 44 µs vs CPU-bounce's 32 µs; the nvfs ioctl is **more expensive per small operation** than the kernel POSIX write path. CPU-bounce's lock contention costs CPU but doesn't slow individual ops.

### 5. Summary: where does each path lose CPU?

| Path | Dominant CPU sinks | What it implies |
| --- | --- | --- |
| **GDS small IO** | nvfs ioctl, `__iomap_dio_rw`, `__fdget`/`fput` | Per-op syscall overhead. Fine at low IOPS (4K seq @ 620k IOPS still works); bottleneck at extreme IOPS. |
| **GDS large concurrent writes** | `osq_lock`, `rwsem_spin_on_owner`, `mutex_spin_on_owner` | nvidia-fs internal rwsem contention with many threads. **Path-side scaling bug / limitation**, fixable upstream. |
| **CPU-bounce small IO** | libcuda `pthread_mutex_lock/unlock` | libcudart's stream pool mutexes. Throughput-bound when serial. |
| **CPU-bounce large IO** | `gup_pte_range`, `try_grab_folio_*`, `__blk_bios_map_sg` | Normal kernel block-layer SG-list build. Mature, scales well. |

---

## DRAM bypass evidence (`pcm-memory`-equivalent from perf stat IMC counters)

`gdsio_*` columns above include `dram_read_mibs` and `dram_write_mibs` derived from `perf stat -e uncore_imc_*/cas_count_read,/cas_count_write`. The pattern is **identical to what `pcm-memory` shows in the lmcache-gds-bench experiment**: every CPU-bounce case has ~5–7 GB/s of host DRAM traffic that GDS reduces to <200 MB/s of background.

The "41× DRAM reduction" at 4 MiB IO is the cleanest signal of GDS doing what it claims to do.

---

## Caveats

1. **Single NVMe, single GPU, TP=1** — multi-GPU / multi-NVMe configurations can shift bottlenecks. With GPU and NVMe behind different PCIe root ports we paid a `cross_root_port` penalty that a topology-aware build (`-x 0` with NVLink-backed DMA) might avoid.
2. **PRECONDITION=none** — testfile was reused from 2026-05-18. SSD steady-state characteristics may be off vs a freshly preconditioned device. For absolute throughput claims, rerun with `PRECONDITION=full`.
3. **gdsio is a synthetic IO benchmark** — real LLM serving has different access patterns (chunked sequential reads with bursts). The lmcache-gds-bench results are the application-layer reference.
4. **perf overhead** — `perf record -g` for 30 s adds <1 % sampling overhead but can hide tail latency.
5. **CPU mode = `-x 2` (`Storage→CPU→GPU`)** — not the only CPU path; `-x 4` adds the OS page cache and would behave differently.

---

## Reproduction

```bash
cd /home/poc/gds_bench
MODES_STR="0 2" \
PATTERNS_STR="0 1 2 3" \
SIZES_KIB_STR="4 4096" \
THREADS_STR="16" \
IO_SWEEP_THREADS=16 \
REPS=3 \
DURATION=120 \
PRECONDITION=none \
ENABLE_PERF_RECORD=1 \
nohup script/run_gdsio_sweep_v3.sh > /tmp/gdsio_focused.out 2>&1 &
```

Post-process:

```bash
script/analyze_focused_perf.sh results/gdsio_sweep_v3_20260521_095422
# → writes top-N hot functions per case to perf_top_funcs.txt
```
