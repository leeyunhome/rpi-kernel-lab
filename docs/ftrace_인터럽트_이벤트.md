# ftrace로 인터럽트 핸들러 진입/종료 시점 캡처

> 모르는 용어가 나오면 [`용어정리.md`](용어정리.md) 참고.

## 목적

`irq_handler_entry`/`irq_handler_exit`는 ftrace가 제공하는 tracepoint로, 인터럽트 핸들러가 **언제 시작해서 언제 끝났는지**를 마이크로초 단위로 보여준다. 지금까지 본 `/proc/interrupts`(누적 횟수)나 sysfs(정적 속성)와 달리, **시간축을 따라가며** 인터럽트를 관찰하는 첫 실습이다.

## 설정 순서

```bash
echo 0 > /sys/kernel/debug/tracing/tracing_on
echo nop > /sys/kernel/debug/tracing/current_tracer
echo 0 > /sys/kernel/debug/tracing/events/enable
echo 1 > /sys/kernel/debug/tracing/events/sched/sched_switch/enable
echo 1 > /sys/kernel/debug/tracing/events/irq/irq_handler_entry/enable
echo 1 > /sys/kernel/debug/tracing/events/irq/irq_handler_exit/enable
echo 1 > /sys/kernel/debug/tracing/tracing_on
```

참고 자료에 나온 것과 동일한 순서다 — 이 tracer는 커널에 기본 포함된 표준 기능이라, **커널 재빌드 없이** 바로 쓸 수 있었다 (물리 접근 불가 상태에서 실행 가능했던 이유).

## 실제로 잡힌 로그

```
  NetworkManager-595     [000] d.h1. 169203.758042: irq_handler_entry: irq=28 name=eth0
  NetworkManager-595     [000] d.h1. 169203.758054: irq_handler_exit: irq=28 ret=handled
  NetworkManager-595     [000] d.H2. 169203.758143: irq_handler_entry: irq=29 name=eth0
  NetworkManager-595     [000] d.H2. 169203.758147: irq_handler_exit: irq=29 ret=handled
            sshd-11649   [002] d.h.. 169203.758224: irq_handler_entry: irq=2 name=IPI
            sshd-11649   [002] d.h.. 169203.758249: irq_handler_exit: irq=2 ret=handled
   cpptools-srv2-116885  [000] d.h.. 169203.758739: irq_handler_entry: irq=28 name=eth0
   cpptools-srv2-116885  [000] d.h.. 169203.758744: irq_handler_exit: irq=28 ret=handled
          <idle>-0       [002] d.h1. 169203.760155: irq_handler_entry: irq=2 name=IPI
          <idle>-0       [002] dNh1. 169203.760200: irq_handler_exit: irq=2 ret=handled
```

### 핸들러 실행 시간 계산 (참고 자료와 같은 방식)

```
0.000012 = 169203.758054 - 169203.758042   (eth0, IRQ 28)
```

**12마이크로초** 동안 `eth0` 핸들러가 실행됐다.

## 이전 실습들과의 교차 검증

이번 로그의 `irq=28 name=eth0`, `irq=2 name=IPI`는 [`인터럽트_디스크립터_조회.md`](인터럽트_디스크립터_조회.md)에서 `/proc/interrupts`와 sysfs로 이미 확인했던 것과 **정확히 같은 번호·이름**이다.

| 확인 방법 | 본 것 |
|---|---|
| `cat /proc/interrupts` | IRQ 28 = eth0 (누적 횟수) |
| `/sys/kernel/irq/28/` | actions=eth0, hwirq=189 (정적 속성) |
| **ftrace (이번 실습)** | IRQ 28 = eth0이 **실제로 처리되는 순간**, 처리 프로세스, 소요 시간 |

같은 인터럽트를 정적 스냅샷(sysfs) → 누적 카운터(`/proc/interrupts`) → 시간 흐름(ftrace) 세 가지 다른 각도로 확인한 셈이다.

## 시행착오 — 이번에도 몇 가지 문제를 만났다

### 1. `sched_switch`를 같이 켜니 버퍼가 노이즈로 가득 찼다

참고 자료는 "어느 프로세스가 인터럽트를 처리하는지 보려고" `sched_switch`를 같이 켜라고 안내한다. 그런데 이 보드는 (커널 빌드로 인한 SSH·tmux 활동, `NetworkManager`, `wireplumber`, `node-red` 등 백그라운드 서비스가 많아) 컨텍스트 스위치가 초당 수천 번 발생해서, **버퍼가 몇 초 만에 `sched_switch` 로그로 가득 차고 정작 `irq_handler_entry`는 밀려서 사라졌다.**

`cat trace`(파이프 없이)로 전체를 출력하려 하자 수만 줄이 쏟아졌다 — 무한 루프가 아니라, 버퍼 자체가 그만큼 컸던 것이다. 해결책:

1. `sched_switch`를 끄고
2. `echo > trace`로 버퍼를 비우고
3. 다시 `tracing_on`

### 2. `irq_handler_entry`가 의도치 않게 꺼져 있었다

한 차례 재설정 이후 `irq_handler_exit`만 계속 보이고 `irq_handler_entry`는 하나도 안 보이는 상황이 발생했다. `cat .../irq_handler_entry/enable`로 직접 값을 확인해보니 `0`(꺼짐)이었다 — 이전 설정 과정에서 명령어 일부가 유실되며 이 줄이 빠졌던 것으로 추정된다. **"설정했다고 믿지 말고, `enable` 파일 값을 직접 읽어서 확인"** 하는 것으로 문제를 잡았다.

### 3. 입력 잘림 — 근본 원인은 tmux가 아니었다

이번 실습 내내 명령어 일부가 잘리거나(`for f in /sys/kernel` 앞부분 소실 등) 한글 낱자가 섞여 들어가는 문제가 반복됐다. `tmux`의 `escape-time`(500, 기본값)을 확인했으나 정상이었고, 라즈베리파이는 중계 서버를 거치지 않는 단일 홉 연결이라 지연 문제도 아니었다. 화면에 `ㅊㅁ`, `ㄷ` 같은 한글 조합 낱자가 튀어나온 것으로 보아, **Windows 클라이언트 쪽 한/영 입력기(IME)가 원인**으로 추정된다. 붙여넣기 대신 직접 타이핑하니 재현되지 않았다.

## 5.7.3 대체 — IPI의 인터럽트 핸들러 함수 찾기

참고 자료는 `name=3f00b880.mailbox` 로그를 보고 핸들러 함수(`bcm2835_mbox_irq`)를 찾는다. 방법은: `name=`에 찍히는 문자열이 `request_irq()` 계열 함수에 넘긴 이름 인자 그대로이므로, 그 이름을 소스에서 검색해 등록 코드를 찾고, 같은 호출 안에 있는 핸들러 함수를 확인한다.

우리 캡처에는 `name=IPI`가 나왔다. mailbox와 달리 장치트리 노드가 아니라 아키텍처 레벨 구조라, 이름으로 검색하는 방식이 안 통한다 — 대신 "IPI를 등록하는 코드가 어디 있는가"로 직접 찾았다.

```
$ grep -n "IPI\|ipi_handler\|set_smp_ipi_range" arch/arm64/kernel/smp.c
1004:static irqreturn_t ipi_handler(int irq, void *data)
1067:void __init set_smp_ipi_range(int ipi_base, int n)
1083:            err = request_percpu_irq(ipi_base + i, ipi_handler, ...)
```

`request_percpu_irq()`(코어마다 하나씩 등록하는 버전)로 **`ipi_handler()`**가 등록돼 있다. mailbox가 `request_irq()` 하나로 끝나는 것과 달리, IPI는 핸들러 안에서 한 번 더 갈라진다:

```c
static irqreturn_t ipi_handler(int irq, void *data)
{
    do_handle_IPI(irq - ipi_irq_base);
    return IRQ_HANDLED;
}
```

```c
switch (ipinr) {
case IPI_RESCHEDULE:   scheduler_ipi(); break;
case IPI_CALL_FUNC:    generic_smp_call_function_interrupt(); break;
case IPI_TIMER:        tick_receive_broadcast(); break;
...
```

`/proc/interrupts`에서 본 `IPI1: Function call interrupts`(950만 회)가 정확히 `IPI_CALL_FUNC` 케이스다. sysfs에서 `actions`가 8개 다 똑같이 `IPI`로만 보였던 이유도 여기서 확인된다 — 세부 구분(재스케줄링/함수호출/타이머 등)은 `ipinr` 번호로만 나뉘고, `action->name`은 전부 `"IPI"`로 하드코딩돼 있기 때문이다.

| | mailbox | IPI |
|---|---|---|
| 등록 함수 | `request_irq()` | `request_percpu_irq()` (코어별 등록) |
| 핸들러 | `bcm2835_mbox_irq()` — 그대로 끝 | `ipi_handler()` → `do_handle_IPI()` → 8갈래 분기 |
| `action->name` | 장치별로 고유 (`fe00b880.mailbox`) | 전부 동일 (`"IPI"`) |

## 스크립트로 재현 — `scripts/irq_ftrace.sh`

수동으로 한 줄씩 실행하며 문제를 다 잡은 뒤, 검증된 순서를 `scripts/irq_ftrace.sh`로 정리했다 (`sched_switch`는 기본으로 끄도록 만들어, 위에서 겪은 버퍼 flood를 원천 차단). 실행 후 절차:

```bash
sudo bash /home/manager/irq_ftrace.sh
# 스크립트가 tracing_off -> 이벤트 재설정 -> tracing_on 순으로 진행하고,
# 마지막에 확인용 명령어를 화면에 출력해준다.

# "설정했다"고 믿지 않고 실제 값을 읽어서 확인
sudo cat /sys/kernel/debug/tracing/events/irq/irq_handler_entry/enable  # -> 1
sudo cat /sys/kernel/debug/tracing/events/irq/irq_handler_exit/enable   # -> 1
sudo cat /sys/kernel/debug/tracing/tracing_on                          # -> 1

# 5초 정도 기다린 뒤 로그 확인 (sched_switch가 꺼져 있어 안전하게 파이프 사용 가능)
cat /sys/kernel/debug/tracing/trace | tail -60
```

## 발견 — 규칙적으로 반복되는 IPI

이번 캡처에서 `<idle>-0` (CPU3)이 `irq=2 name=IPI`를 아주 규칙적인 간격으로 계속 받는 패턴이 나왔다:

```
<idle>-0 [003] d.h1. 170653.340747: irq_handler_entry: irq=2 name=IPI
<idle>-0 [003] dNh1. 170653.340767: irq_handler_exit:  irq=2 ret=handled
<idle>-0 [003] d.h1. 170653.340952: irq_handler_entry: irq=2 name=IPI
<idle>-0 [003] dNh1. 170653.340970: irq_handler_exit:  irq=2 ret=handled
<idle>-0 [003] d.h1. 170653.341157: irq_handler_entry: irq=2 name=IPI
...
```

**핸들러 실행 시간 계산** (직접 계산, 검산 완료):

```
0.000020 = 170653.340767 - 170653.340747   (IPI, 20마이크로초)
```

entry 시각 간격도 거의 일정하다 (340747 → 340952 → 341157, 약 200~205마이크로초 간격). CPU3이 idle 상태인데도 다른 코어로부터 주기적으로 뭔가를 요청받고 있다는 뜻 — 정확한 발신 주체는 추가 확인이 필요하지만, 스케줄러의 로드밸런싱이나 타이머 관련 코어 간 동기화로 추정된다.

같은 캡처에서 `arch_timer`(IRQ 11)는 **네 코어 모두에서 같은 마이크로초에 동시에** entry가 찍혔다 — 각 코어가 독립적인 자기 타이머를 갖고 있어서 스케줄러 틱이 코어별로 동시에 울리기 때문이다 (`/proc/interrupts`에서 `arch_timer`가 코어별로 고르게 분산돼 있던 것과 같은 현상을 시간축에서 재확인한 것).

## `trace_irq_handler_entry()` 호출 지점 — 참고 자료엔 없던 부분

참고 자료는 `irq_handler_entry`/`irq_handler_exit` 로그가 `kernel/irq/handle.c`의 `__handle_irq_event_percpu()` 한 곳에서 나온다고 설명한다. tracepoint 이름(`irq_handler_entry`)을 실제 호출 함수명(`trace_irq_handler_entry`)으로 바꿔 소스 전체를 검색해보면, 그 설명이 **일부만 맞다**는 게 드러난다.

```
$ grep -rn "trace_irq_handler_entry(" linux/kernel/
kernel/irq/handle.c:157:      trace_irq_handler_entry(irq, action);
kernel/irq/chip.c:760: trace_irq_handler_entry(irq, action);
kernel/irq/chip.c:941:         trace_irq_handler_entry(irq, action);
kernel/irq/chip.c:976: trace_irq_handler_entry(irq, action);
```

`handle.c:157`은 참고 자료가 설명한 지점과 일치하지만, **`kernel/irq/chip.c`에서 3곳이 더 호출**하고 있다. `chip.c`는 `handle_simple_irq`, `handle_edge_irq`, `handle_level_irq` 등 **인터럽트 트리거 방식(Level/Edge)별로 다른 처리 함수**를 담은 파일이다 — 일부 처리 경로는 `__handle_irq_event_percpu()`를 거치지 않고 자체적으로 핸들러를 호출하면서 tracepoint도 따로 찍는 구조로 추정된다.

**정리**: "이벤트 이름 → `trace_<이벤트이름>()` 함수명 → 소스 전체 grep"이라는 방법 자체는 어떤 tracepoint에도 그대로 적용된다. 다만 참고 자료가 보여준 것은 "가장 대표적인 경로 하나"였고, 실제로는 인터럽트 처리 방식에 따라 여러 경로 중 하나를 탄다는 걸 이번 검색으로 확인했다.

## 패치 적용 연습 — 재부팅 없이 소스만 건드려보기

참고 자료의 5.7.3 패치(`kernel/irq/handle.c`)나 5.4.2 패치(`drivers/mailbox/bcm2835-mailbox.c`에 `interrupt_debug_irq_desc()` 추가)를 실제로 빌드·설치까지 하려면 재부팅이 필요해 위험하다. 대신 **소스에 패치를 적용하고 `git diff`로 결과만 확인**하는 안전한 범위로 연습했다 (빌드·설치는 안 함).

### 시행착오 1 — 파이썬으로 코드를 생성하다 `\n`이 깨졌다

`printk("...\n", ...)` 같은 C 문자열의 `\n`을 파이썬 문자열로 만들어 파일에 쓰는 과정에서, **의도한 두 글자(`\`, `n`)가 아니라 진짜 줄바꿈 문자로 들어가버렸다.** 결과적으로 문자열 리터럴이 중간에 끊겨 컴파일 안 되는 코드가 됐다.

```
+  pr_err("invalid desc at %s line: %d
+", __func__, __LINE__);   <- 문자열이 줄바꿈으로 깨짐
```

두 번 더 시도했지만 계속 실패했고 (일반 문자열 `"\\n"`으로도 안 됨, 일부만 raw string으로 해도 안 됨), **모든 텍스트를 raw string(`r"""..."""`)으로 통일**하고 나서야 해결됐다. 원인은 정확히 특정하지 못했지만, 도구 호출 경로 어딘가에서 백슬래시 이스케이프가 한 겹 사라지는 것으로 추정된다 — 이스케이프 문자가 포함된 텍스트를 다룰 때는 **raw string을 기본으로 쓰는 게 안전**하다는 교훈을 얻었다.

또한 매칭용 앵커 문자열에 `\n`이 포함되면 같은 문제로 매칭 자체가 실패했다. **매칭 앵커는 백슬래시가 없는, 구조적으로 고유한 텍스트로 잡는 것**이 더 안전했다.

### 시행착오 2 — `~`가 계정마다 다른 곳을 가리킨다

`root` 셸(`sudo su`)에서 `cd ~/rpi_kernel_src`를 실행했더니 **`/root/rpi_kernel_src`(실제로 존재하지만 텅 빈, 별개의 디렉터리)**로 이동했다. 실제 작업 디렉터리는 `/home/manager/rpi_kernel_src`(일반 계정 `manager`의 홈 아래)였다.

`~`는 **현재 로그인한 계정의 홈**을 가리킨다 — `sudo su`로 root가 되면 `~`도 `/root`로 바뀐다. 여러 계정을 오가며 작업할 때는 `~` 대신 **절대경로**를 쓰는 게 안전하다.

### 시행착오 3 — `tracing_on`을 켜둔 채 방치해 시스템이 한동안 응답 불능이었다

IPI 캡처 실습 이후 `tracing_on`을 끄지 않고 다른 작업(패치 연습)으로 넘어갔다. 이후 SSH가 **배너 교환 단계에서 30초 넘게 응답하지 않는 상태**가 됐다 (핑은 정상이라 네트워크 자체는 살아있었음). `load average`가 35까지 치솟았다가 서서히 내려왔다.

정확한 인과관계는 특정하지 못했지만(다른 작업이 겹쳤을 수도 있음), **작업이 끝나면 `tracing_on`을 반드시 끄는 습관**이 필요하다는 걸 재확인했다. 이번엔 `sudo cat tracing_on`으로 직접 값을 확인하고 나서야 켜져 있던 걸 발견했다 — 이것도 "설정했다고 믿지 말고 값을 읽어서 확인"이라는, 앞서 `irq_handler_entry`가 꺼져 있던 사고에서 배운 것과 같은 교훈이다.

## 다음

- 5.7.3: 참고 자료는 커널 패치로 핸들러 함수 이름(`bcm2835_mbox_irq` 등)을 알아내지만, 물리 접근 불가로 패치는 못 한다. 대신 `function_graph` tracer를 `__handle_irq_event_percpu` 함수에 걸어 같은 정보를 재빌드 없이 확인할 예정.
- `local_irq_disable()`/`local_irq_enable()` — 커널 모듈(`.ko`)로 만들어 `insmod`/`rmmod`로 재부팅 없이 실습 예정. 책 5.8 정리의 남은 항목이자, 실제 드라이버 코드를 처음부터 작성해보는 첫 실습.
