# `function_graph`로 `write()` 시스템콜의 커널 내부 경로 추적

## 이 문서의 목적

`function_graph` tracer는 커널 함수의 호출/반환을 들여쓰기 형태로 그대로 기록해준다. 이걸로 유저스페이스에서
`write()`를 한 번 호출했을 때 커널 안에서 실제로 어떤 함수들이 순서대로 불리는지 확인한다.

> **참고**: 이 tracer가 항상 쓸 수 있는 건 아니다. 벤더가 커스텀 빌드한 커널에서는 `CONFIG_FUNCTION_GRAPH_TRACER`가
> 빠져 있어 `available_tracers`에 `nop`밖에 없는 경우가 있다. 이 보드는 Raspberry Pi Foundation 표준 빌드라 정상적으로 존재한다.
> (다른 장비에서 확인한 대조 사례는 [`jetson-perf-profiling`](https://github.com/leeyunhome/jetson-perf-profiling) 참고)

## 측정 환경

| 항목 | 값 |
|---|---|
| 보드 | Raspberry Pi 4B (BCM2711) |
| Kernel | `6.12.25+rpt-rpi-v8` (Raspberry Pi Foundation 표준 빌드) |
| 아키텍처 | aarch64 |
| OS | Debian (Raspberry Pi OS) Bookworm |

## 결과: `available_tracers`에 `function_graph` 존재 확인

```
$ sudo cat /sys/kernel/debug/tracing/available_tracers
blk function_graph wakeup_dl wakeup_rt wakeup function nop
```

x86 때와 같은 방식으로(`ksys_write`에 그래프 필터를 걸어 `write()` syscall의 커널 내부 경로를 추적), **검증 후 실행(verify-then-arm)** 절차를 지켜 안전하게 캡처했다.

```
$ sudo cat /sys/kernel/debug/tracing/current_tracer   # -> function_graph 확인 후에만 진행
$ sudo cat /sys/kernel/debug/tracing/set_graph_function  # -> ksys_write 확인 후에만 tracing_on
```

`dd if=/dev/zero of=~/ftrace-review/test.bin bs=64 count=3 conv=fsync` 실행 중 캡처된 콜스택 (총 910줄 — x86 때의 2,210줄보다 훨씬 적어서 노이즈도 적었다):

```
sh-2199  =>  dd-2200
------------------------------------------
ksys_write() {
  fdget_pos();
  vfs_write() {
    rw_verify_area() {
      security_file_permission();
    }
    ext4_file_write_iter() {
      ext4_buffered_write_iter() {
        down_write();
        ext4_generic_write_checks() {
          generic_write_checks() {
            generic_write_check_limits();
          }
        }
        file_modified() {
          file_remove_privs_flags() {
            setattr_should_drop_suidgid();
            security_inode_need_killpriv() {
              cap_inode_need_killpriv();
            }
          }
          inode_needs_update_time() {
            ktime_get_coarse_real_ts64();
            timestamp_truncate();
          }
        }
        generic_perform_write() {
          balance_dirty_pages_ratelimited() {
            balance_dirty_pages_ratelimited_flags() {
              inode_to_bdi();
              inode_to_bdi();
              __rcu_read_lock();
              __rcu_read_unlock();
              balance_dirty_pages();
            }
          }
          fault_in_readable();
          ext4_da_write_begin() { ... }
        }
      }
    }
  }
}
```

읽어보면 `write()` 한 번이 커널 안에서 이런 순서로 처리된다:

1. `ksys_write` → `vfs_write` (VFS 계층 진입)
2. `rw_verify_area` → `security_file_permission` — 쓰기 권한 검사
3. `ext4_file_write_iter` → `ext4_buffered_write_iter` — 파일시스템 계층으로 내려감
4. `down_write` — inode 락 획득
5. `file_modified` — 타임스탬프 갱신, setuid 비트 제거 검토
6. `generic_perform_write` → `balance_dirty_pages_ratelimited` — **dirty page 스로틀링** (더러운 페이지가 너무 쌓이지 않게 쓰기 속도를 조절하는 지점)
7. `ext4_da_write_begin` — 지연 할당(delayed allocation) 시작

즉 "파일에 쓴다"는 한 줄이 실제로는 **권한 검사 → 락 → 메타데이터 갱신 → 쓰기 속도 조절 → 페이지 할당**이라는 여러 단계를 거친다는 걸 함수 단위로 확인할 수 있다.

## 정리

- 표준 커널이라 `function_graph`를 그대로 쓸 수 있었고, `write()`의 커널 내부 경로를 함수 호출 트리로 확인했다.
- **안전 절차(설정 → 확인 → 실행 → 즉시 정리)** 를 지켰다. `set_graph_function` 필터를 확인하지 않고 `tracing_on`을 켜면 시스템 전체 커널 함수를 추적하게 되어 부하가 크다 — 반드시 필터가 걸렸는지 확인한 뒤 켜야 한다.
