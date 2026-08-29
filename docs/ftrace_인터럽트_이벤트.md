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

## 다음

- 5.7.3: 참고 자료는 커널 패치로 핸들러 함수 이름(`bcm2835_mbox_irq` 등)을 알아내지만, 물리 접근 불가로 패치는 못 한다. 대신 `function_graph` tracer를 `__handle_irq_event_percpu` 함수에 걸어 같은 정보를 재빌드 없이 확인할 예정.
