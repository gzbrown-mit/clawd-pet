#!/bin/bash
# Fakes a Claude Code session so you can watch the pet react without running Claude.
#   scripts/simulate.sh          full session: start, work, compact, finish
#   scripts/simulate.sh limit    hit the 5-hour usage limit (faints for 2 minutes)
#   scripts/simulate.sh reset    clear the fake session
PORT="${CLAWD_PET_PORT:-4242}"
SID="sim-$$"
CWD="$HOME/simulated-project"
NOW=$(date +%s)

post() { curl -s -m 2 -o /dev/null -X POST "http://127.0.0.1:$PORT/$1" -H 'Content-Type: application/json' -H 'Expect:' -d "$2"; }
ev()   { post hook "{\"hook_event_name\":\"$1\",\"session_id\":\"$SID\",\"cwd\":\"$CWD\"$2}"; }

case "${1:-}" in
  limit)
    post status "{\"session_id\":\"$SID\",\"cwd\":\"$CWD\",\"rate_limits\":{\"five_hour\":{\"used_percentage\":100,\"resets_at\":$((NOW+120))},\"seven_day\":{\"used_percentage\":90,\"resets_at\":$((NOW+86400))}}}"
    echo "5-hour limit hit. Clawd faints until it 'resets' in 2 minutes."; exit 0;;
  reset)
    post status "{\"session_id\":\"$SID\",\"cwd\":\"$CWD\",\"rate_limits\":{\"five_hour\":{\"used_percentage\":0},\"seven_day\":{\"used_percentage\":0}}}"
    ev SessionEnd; echo "cleared"; exit 0;;
esac

echo "session start";              ev SessionStart
sleep 1; echo "prompt submitted";  ev UserPromptSubmit
for i in 1 2 3 4 5 6; do sleep 2; echo "tool use $i"; ev PostToolUse ',"tool_name":"Bash"'; done
sleep 1; echo "status: context 85%, 5h 40%"
post status "{\"session_id\":\"$SID\",\"cwd\":\"$CWD\",\"model\":{\"display_name\":\"Fable\"},\"context_window\":{\"used_percentage\":85},\"rate_limits\":{\"five_hour\":{\"used_percentage\":40,\"resets_at\":$((NOW+3600))},\"seven_day\":{\"used_percentage\":20,\"resets_at\":$((NOW+86400))}}}"
sleep 4; echo "compacting";        ev PreCompact
sleep 3;                           ev PostCompact
sleep 4; echo "Claude finished. Move your mouse: Clawd should come find it."
ev Stop ',"stop_reason":"end_turn"'
echo "Click the pet to calm it (it opens the project). Ending the fake session in 40s."
sleep 40; ev SessionEnd
