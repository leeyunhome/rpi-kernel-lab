# rpi-kernel-lab

Raspberry Pi 4B에서 리눅스 커널을 직접 빌드하고, ftrace로 커널 내부 동작(인터럽트 처리, 스케줄링)을 추적하는 실습 기록.

참고 서적의 실습을 따라가되, **책이 상정한 환경과 실제 장비가 다른 지점을 매번 확인하고 재구성**하는 방식으로 진행한다. 그 차이를 메우는 과정 자체가 이 저장소의 주된 기록 대상이다.

## 환경

| 항목 | 값 |
|---|---|
| 보드 | Raspberry Pi 4B Rev 1.2 (BCM2711) |
| CPU / RAM | 4코어 / 1.8GiB (2GB 모델) |
| 커널 | `6.12.25+rpt-rpi-v8` (Raspberry Pi Foundation 표준 빌드) |
| 아키텍처 | aarch64 (arm64) |
| OS | Debian (Raspberry Pi OS) Bookworm |
| 부팅 파티션 | `/boot/firmware/` (Bookworm 이후 레이아웃) |

## 참고 자료와의 환경 차이

참고 서적은 **Raspberry Pi 3B / 커널 4.19 / 32비트**를 기준으로 한다. 실제 장비와 다른 지점은 다음과 같고, 각 항목은 실습 중 확인한 내용이다.

| 항목 | 참고 자료 | 이 장비 | 영향 |
|---|---|---|---|
| 보드 | Pi 3B (BCM2837) | Pi 4B (BCM2711) | USB 컨트롤러가 `dwc_otg` → 네이티브 xHCI로 바뀜. 인터럽트 컨트롤러도 브로드컴 자체 → ARM 표준 GICv2로 변경되어 **인터럽트 번호 체계 자체가 다름** |
| 아키텍처 | 32비트 (armv7) | **64비트 (aarch64)** | 커널 이미지 타겟이 `zImage` → `Image.gz`, 이미지 파일명이 `kernel7l` → `kernel8` |
| 커널 | 4.19 | 6.12.25 | 32비트 전용 심볼(`__irq_svc` 등)은 대응 코드가 아예 없음. 일부 함수는 리팩터링으로 이름이 바뀜 |
| 부팅 파티션 | `/boot/` 직접 | `/boot/firmware/` | 커널 설치 경로가 달라짐 |

## 문서

| 문서 | 내용 |
|---|---|
| [`docs/용어정리.md`](docs/용어정리.md) | **용어·약어 풀이** — GIC, IPI, MSI, DTB, softirq 등. 다른 문서에서 모르는 용어가 나오면 여기부터 |
| [`docs/커널빌드_및_인터럽트디버깅.md`](docs/커널빌드_및_인터럽트디버깅.md) | 커널 소스 확보부터 빌드까지의 진행 기록과 시행착오 |
| [`docs/function_graph_비교.md`](docs/function_graph_비교.md) | `function_graph` tracer로 `write()` 시스템콜의 커널 내부 경로 추적 |
| [`docs/인터럽트_디스크립터_조회.md`](docs/인터럽트_디스크립터_조회.md) | 커널 패치 없이 sysfs로 `irq_desc` 조회 — IRQ 번호가 커널 버전마다 달라지는 문제 |
| [`docs/proc_interrupts.txt`](docs/proc_interrupts.txt) · [`docs/sys_kernel_irq.txt`](docs/sys_kernel_irq.txt) | 위 문서의 원본 데이터 |

## 빌드

```sh
# 소스: rpi_kernel_src/linux, 산출물: rpi_kernel_src/build_out (out-of-tree 빌드)
./build_kernel.sh
```

`scripts/build_kernel.sh` 참고. out-of-tree 빌드(`make O=<dir>`)를 쓰는 이유는 소스 트리를 깨끗하게 유지하면서 설정을 바꿔가며 여러 번 빌드하기 위해서다.

## 관련 저장소

- [`jetson-perf-profiling`](https://github.com/leeyunhome/jetson-perf-profiling) — Jetson Orin에서 진행한 perf/ftrace 프로파일링 실습. 이 저장소와는 **별개 실습**이며, 두 장비 간 비교(벤더 커스텀 커널 vs 표준 커널)는 추후 별도로 정리 예정.
