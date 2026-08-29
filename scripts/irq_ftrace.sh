#!/bin/bash
# 참고 자료의 irq_ftrace.sh를 기반으로 하되, 이 장비에서 확인된 문제 때문에
# sched_switch는 기본으로 켜지 않는다.
#
# 이유: 이 보드는 백그라운드 서비스(NetworkManager, wireplumber, node-red 등)와
# SSH/tmux 활동이 많아서 sched_switch를 같이 켜면 컨텍스트 스위치 로그가
# 버퍼를 몇 초 만에 채워버리고, 정작 보려던 irq_handler_entry가 밀려서 사라진다.
# (docs/ftrace_인터럽트_이벤트.md 참고)
#
# 어느 프로세스가 인터럽트를 처리하는지 보고 싶으면 --with-sched 옵션을 준다.

set -e

WITH_SCHED=0
if [ "$1" = "--with-sched" ]; then
    WITH_SCHED=1
fi

TRACE_DIR=/sys/kernel/debug/tracing

echo "0" > "$TRACE_DIR/tracing_on"
sleep 1
echo "tracing_off"

echo "nop" > "$TRACE_DIR/current_tracer"
echo "0" > "$TRACE_DIR/events/enable"
sleep 1

if [ "$WITH_SCHED" = "1" ]; then
    echo "1" > "$TRACE_DIR/events/sched/sched_switch/enable"
    echo "sched_switch: on (버퍼가 빨리 찰 수 있음)"
fi

echo "1" > "$TRACE_DIR/events/irq/irq_handler_entry/enable"
echo "1" > "$TRACE_DIR/events/irq/irq_handler_exit/enable"

# 이전 실행에서 남은 로그를 비워 깨끗한 상태로 시작
echo > "$TRACE_DIR/trace"

echo "1" > "$TRACE_DIR/tracing_on"
echo "tracing_on"

echo ""
echo "확인: cat $TRACE_DIR/events/irq/irq_handler_entry/enable  (1이어야 함)"
echo "로그 보기: sudo bash -c 'echo 0 > $TRACE_DIR/tracing_on; cat $TRACE_DIR/trace' | tail -40"
