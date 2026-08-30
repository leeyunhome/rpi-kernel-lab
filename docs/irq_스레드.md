# IRQ 스레드(threaded IRQ) — 확인, 우선순위 추적, 실행 여부 검증

> 모르는 용어가 나오면 [`용어정리.md`](용어정리.md) 참고.

## 목적

인터럽트 후반부 처리 기법 중 하나인 IRQ 스레드를, 이 장비에서 목록 확인 → 스케줄링 속성 검증 → 소스 추적 → 실제 실행 여부 확인까지 진행한다.

## 1. IRQ 스레드 목록 — 참고 자료와 개수부터 다르다

```
$ ps -ely | grep irq/
S     0      71       2  0   9   -     0     0 irq_th ?        00:00:00 irq/27-aerdrv
S     0      94       2  0   9   -     0     0 irq_th ?        00:00:00 irq/40-mmc0
S     0     160       2  0   9   -     0     0 irq_th ?        00:00:00 irq/42-vc4 hdmi hpd connected
S     0     161       2  0   9   -     0     0 irq_th ?        00:00:00 irq/43-vc4 hdmi hpd disconnected
S     0     163       2  0   9   -     0     0 irq_th ?        00:00:00 irq/44-vc4 hdmi cec rx
S     0     164       2  0   9   -     0     0 irq_th ?        00:00:00 irq/45-vc4 hdmi cec tx
S     0     165       2  0   9   -     0     0 irq_th ?        00:00:00 irq/46-vc4 hdmi hpd connected
S     0     168       2  0   9   -     0     0 irq_th ?        00:00:00 irq/47-vc4 hdmi hpd disconnected
S     0     172       2  0   9   -     0     0 irq_th ?        00:00:00 irq/48-vc4 hdmi cec rx
S     0     175       2  0   9   -     0     0 irq_th ?        00:00:00 irq/49-vc4 hdmi cec tx
S     0     358       2  0   9   -     0     0 irq_th ?        00:00:00 irq/56-feb00000.codec
```

| | 참고 자료 (Pi 3B, 4.19) | 이 장비 (Pi 4B, 6.12) |
|---|---|---|
| 개수 | **1개** (`irq/86-mmc1`) | **11개** |
| `WCHAN` | `irq_th` | 동일 |
| `PRI` / `NI` | `9` / `-` | 동일 |

개수만 다르고 속성(`WCHAN`, `PRI`, `NI`)은 8년이 지나도 그대로다. HDMI(`vc4`) 관련 스레드가 다수를 차지하는데, 참고 자료 시절엔 없던 서브시스템이 threaded IRQ를 쓰도록 늘어난 것으로 보인다.

## 2. `ps`의 `PRI` 열은 믿으면 안 된다 — 신뢰할 수 있는 확인 방법

```
$ ps -eLo pid,class,rtprio,comm | grep irq/
71  FF  50  irq/27-aerdrv
94  FF  50  irq/40-mmc0
... (11개 전부 FF / 50)
```

`class=FF`(SCHED_FIFO, 실시간), `rtprio=50` — 참고 자료의 "IRQ 스레드는 실시간(RT) 프로세스로 구동된다"는 서술과 일치한다. Jetson에서 분석했던 `irq/189-aerdrv`도 같은 RT 50이었다 — 같은 드라이버, 다른 IRQ 번호, 같은 우선순위.

`/proc/<pid>/stat`으로 더 정확히 대조하면:

```
$ awk '{print "prio="$18, "rt_priority="$40, "policy="$41}' /proc/71/stat
prio=-51 rt_priority=50 policy=1

$ awk '{print "prio="$18, "rt_priority="$40, "policy="$41}' /proc/17/stat   # ksoftirqd/0
prio=20 rt_priority=0 policy=0
```

| | `irq/27-aerdrv` | `ksoftirqd/0` |
|---|---|---|
| `policy` | 1 = SCHED_FIFO | 0 = SCHED_NORMAL |
| `rt_priority` | 50 | 0 |
| `prio` | **-51** | 20 |

실시간 프로세스의 `prio`는 `-(rt_priority) - 1`로 저장된다 (`-(50)-1=-51`). 커널은 **숫자가 작을수록 우선순위가 높다** — `-51`이 `20`보다 압도적으로 높다.

**함정**: `ps -ely`의 `PRI` 열만 보면 IRQ 스레드(9)가 `ksoftirqd`(80)보다 낮아 보인다. 하지만 실제는 정반대다. `ps`의 `PRI` 표시 방식은 실시간 프로세스에서 오해를 부르므로, `class`/`rtprio`나 `/proc/<pid>/stat`의 `policy` 필드로 확인해야 한다.

## 3. `rtprio 50`의 출처를 소스에서 추적

참고 자료는 `setup_irq_thread()` 안에서 `struct sched_param { .sched_priority = MAX_USER_RT_PRIO/2 }`로 우선순위를 설정한다고 설명한다. 우리 커널에는 이 코드가 없다 — `MAX_USER_RT_PRIO` 매크로 자체가 사라졌다.

대신 우선순위 설정이 다른 곳으로 옮겨갔다:

```c
// kernel/irq/manage.c:1310 — IRQ 스레드가 실행을 시작하며 스스로 설정
static int irq_thread(void *data)
{
    ...
    sched_set_fifo(current);
```

```c
// kernel/sched/syscalls.c:856
void sched_set_fifo(struct task_struct *p)
{
    struct sched_param sp = { .sched_priority = MAX_RT_PRIO / 2 };
    sched_setscheduler_nocheck(p, SCHED_FIFO, &sp);
}
```

```c
// include/linux/sched/prio.h:16
#define MAX_RT_PRIO  100
```

`100 / 2 = 50` — 측정값과 일치. **설정 위치(생성 시점 → 실행 시작 시점)와 매크로 이름(`MAX_USER_RT_PRIO` → `MAX_RT_PRIO`)은 바뀌었지만 결과값 50은 그대로**다.

## 4. IRQ별 발생 빈도 ↔ 스레드 유무 대조 — 6.1.5 설계 지침의 실물 증거

참고 자료 6.1.5: "인터럽트가 자주 발생하면 Soft IRQ나 태스크릿이 좋다. IRQ 스레드 방식은 그리 적합하지 않다."

```
IRQ    이름                       총발생횟수    IRQ스레드
11     arch_timer                   75,968,553    -
2      IPI                          44,025,407    -
28     eth0                         43,708,808    -
40     mmc1,mmc0                     5,446,608    있음
42~49  vc4 hdmi (8개)                        0    있음
56     feb00000.codec                        0    있음
27     PCIe PME,aerdrv                        0    있음
```

**발생 빈도가 가장 높은 상위 3개(arch_timer, IPI, eth0)는 전부 IRQ 스레드가 없다.** `eth0`는 NAPI/softirq로 처리된다. **IRQ 스레드가 있는 것들은 `mmc0` 하나만 빼고 전부 0회** — HDMI 케이블 연결/해제, CEC 신호처럼 아주 드물게 발생하는 것들이다. 조언이 아니라 실제 설계에 그대로 반영돼 있다는 것을 숫자로 확인했다.

## 5. IRQ 스레드가 실제로 실행된 적이 있는가 — CPU 시간으로 검증

`ps`의 `TIME`이 전부 `00:00:00`이길래, `/proc/<pid>/stat`의 정밀한 틱 단위로 재확인했다.

```
PID  이름                              utime  stime  합계(ms)
71   irq/27-aerdrv                       0      0      0
94   irq/40-mmc0                         0      0      0
...  (11개 전부 0)

PID 17 ksoftirqd/0: utime=0 stime=4083  합계=40,830ms
```

**IRQ 스레드 11개는 가동 2일 17시간 동안 단 한 번도 실행되지 않았다.** 특히 `irq/40-mmc0`는 그 IRQ(40번, `mmc1,mmc0`)가 544만 번 발생했는데도 0ms다.

이는 6.4절의 핵심과 정확히 일치한다:

> "인터럽트 핸들러에서 `IRQ_WAKE_THREAD`를 반환할 때 IRQ 스레드를 깨운다."

**IRQ 스레드가 등록돼 있다고 인터럽트마다 실행되는 게 아니다.** 핸들러가 매번 `IRQ_HANDLED`를 반환하면 스레드는 계속 잠들어 있고, 후반부 처리가 필요한 특수 상황에서만 `IRQ_WAKE_THREAD`를 반환해 깨운다.

### 드라이버 확인 — 참고 자료와 다른 드라이버, 같은 패턴

```
$ dmesg | grep -i mmc
mmc-bcm2835 fe300000.mmcnr: ...      # mmc1 — 참고 자료가 분석한 bcm2835 전용 드라이버
mmc0: SDHCI controller on fe340000.mmc using ADMA   # mmc0 — 표준 SDHCI
```

참고 자료는 `bcm2835_mmc_probe()`/`bcm2835_mmc_irq()`(전용 드라이버)를 분석했지만, 이 장비의 `mmc0`는 범용 `drivers/mmc/host/sdhci.c`를 쓴다. 소스를 확인하면:

```c
// drivers/mmc/host/sdhci.c
request_threaded_irq(host->irq, sdhci_irq, sdhci_thread_irq, IRQF_SHARED, ...)
                                  ↑            ↑
                              핸들러       IRQ 스레드 처리 함수
```

함수 이름은 다르지만 **"핸들러 + IRQ 스레드 처리 함수" 쌍으로 등록하는 구조(표 6.3)는 드라이버가 바뀌어도 그대로**다.

## 정리

- IRQ 스레드 개수(1개 → 11개)는 커널·드라이버 구성에 따라 달라지지만, 스레드의 스케줄링 속성(RT, prio 50)과 이름 규칙(`irq/번호-이름`)은 8년이 지나도 동일하다.
- `ps -ely`의 `PRI` 열은 실시간 프로세스에서 오독을 유발한다 — `class`/`rtprio` 또는 `/proc/stat`을 봐야 한다.
- 등록된 IRQ 스레드가 실제로 실행되는지는 별개 문제다 — 핸들러가 `IRQ_WAKE_THREAD`를 반환하지 않으면 인터럽트가 수백만 번 발생해도 스레드는 0ms로 남는다.
