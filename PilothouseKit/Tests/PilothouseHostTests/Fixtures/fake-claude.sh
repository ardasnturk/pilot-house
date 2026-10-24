#!/bin/sh
# FakeClaude — stands in for `claude -p --input-format stream-json
# --output-format stream-json --verbose --include-partial-messages` in tests.
#
# The reply depends on keywords in the user message:
#   PERMISSION  asks the Pilothouse MCP permission tool (via curl) to run Bash
#   EDIT        reports an Edit with a structured patch
#   SLOW        streams one chunk, then waits 30 s (for interrupt tests)
#   CRASH       writes to stderr and exits with status 3
#   LOGIN       fails like a signed-out CLI
#   ECHOARGS    replies with the flags it was started with
#   anything else: a short streamed greeting
#
# Output lines mirror the shapes recorded from Claude Code 2.1.310.

session=""
resume="no"
model="default"
mode="default"
mcp=""
while [ $# -gt 0 ]; do
  case "$1" in
    --session-id) session="$2"; shift ;;
    --resume) session="$2"; resume="yes"; shift ;;
    --model) model="$2"; shift ;;
    --permission-mode) mode="$2"; shift ;;
    --mcp-config) mcp="$2"; shift ;;
  esac
  shift
done

if [ -n "$FAKE_CLAUDE_ARGS_LOG" ]; then
  printf 'session=%s resume=%s model=%s mode=%s\n' "$session" "$resume" "$model" "$mode" >> "$FAKE_CLAUDE_ARGS_LOG"
fi

turn=0
sleeper=""

emit() { printf '%s\n' "$1"; }

interrupted() {
  [ -n "$sleeper" ] && kill "$sleeper" 2>/dev/null
  emit '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]},"parent_tool_use_id":null,"session_id":"'"$session"'"}'
  emit '{"type":"result","subtype":"error_during_execution","is_error":true,"duration_ms":15,"num_turns":1,"session_id":"'"$session"'"}'
  exit 130
}
trap interrupted INT
trap 'exit 143' TERM

emit '{"type":"system","subtype":"init","cwd":"'"$(pwd)"'","session_id":"'"$session"'","model":"fake-'"$model"'","permissionMode":"'"$mode"'","slash_commands":["review","compact"],"claude_code_version":"0.0.0-fake","tools":["Bash","Edit"]}'

text_block() {
  # $1 message id, $2 text
  emit '{"type":"stream_event","event":{"type":"message_start","message":{"id":"'"$1"'","role":"assistant","content":[]}},"parent_tool_use_id":null,"api_message_id":"'"$1"'"}'
  emit '{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}},"parent_tool_use_id":null,"api_message_id":"'"$1"'"}'
  emit '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"'"$2"'"}},"parent_tool_use_id":null,"api_message_id":"'"$1"'"}'
  emit '{"type":"assistant","message":{"id":"'"$1"'","role":"assistant","content":[{"type":"text","text":"'"$2"'"}]},"parent_tool_use_id":null,"session_id":"'"$session"'"}'
}

result_ok() {
  emit '{"type":"result","subtype":"success","is_error":false,"duration_ms":42,"num_turns":1,"total_cost_usd":0.0012,"usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100,"cache_creation_input_tokens":0},"result":"'"$1"'","session_id":"'"$session"'"}'
}

while IFS= read -r line; do
  turn=$((turn + 1))
  id="msg_fake_$turn"
  case "$line" in
    *PERMISSION*)
      emit '{"type":"assistant","message":{"id":"'"$id"'","role":"assistant","content":[{"type":"tool_use","id":"toolu_fake_'"$turn"'","name":"Bash","input":{"command":"echo hi","description":"Say hi"}}]},"parent_tool_use_id":null}'
      url=$(printf '%s' "$mcp" | sed -n 's/.*"url":"\([^"]*\)".*/\1/p')
      token=$(printf '%s' "$mcp" | sed -n 's/.*"Authorization":"Bearer \([^"]*\)".*/\1/p')
      answer=$(curl -s -X POST "$url" -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","id":'"$turn"',"method":"tools/call","params":{"name":"approve_permission","arguments":{"tool_name":"Bash","input":{"command":"echo hi","description":"Say hi"},"tool_use_id":"toolu_fake_'"$turn"'"}}}')
      if printf '%s' "$answer" | grep -q 'behavior[^a-z]*allow'; then
        emit '{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_fake_'"$turn"'","type":"tool_result","content":"hi","is_error":false}]},"parent_tool_use_id":null}'
        text_block "${id}_b" "Ran it."
        result_ok "Ran it."
      else
        emit '{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_fake_'"$turn"'","type":"tool_result","content":"<tool_use_error>Permission denied</tool_use_error>","is_error":true}]},"parent_tool_use_id":null}'
        text_block "${id}_b" "Not allowed."
        result_ok "Not allowed."
      fi
      ;;
    *EDIT*)
      emit '{"type":"assistant","message":{"id":"'"$id"'","role":"assistant","content":[{"type":"tool_use","id":"toolu_edit_'"$turn"'","name":"Edit","input":{"file_path":"/tmp/a.txt","old_string":"two","new_string":"three"}}]},"parent_tool_use_id":null}'
      emit '{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_edit_'"$turn"'","type":"tool_result","content":"The file /tmp/a.txt has been updated successfully."}]},"parent_tool_use_id":null,"tool_use_result":{"filePath":"/tmp/a.txt","oldString":"two","newString":"three","structuredPatch":[{"oldStart":1,"oldLines":3,"newStart":1,"newLines":3,"lines":[" one","-two","+three"," four"]}]}}'
      result_ok "Edited."
      ;;
    *SLOW*)
      emit '{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}},"parent_tool_use_id":null,"api_message_id":"'"$id"'"}'
      emit '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Working on it"}},"parent_tool_use_id":null,"api_message_id":"'"$id"'"}'
      sleep 30 &
      sleeper=$!
      wait "$sleeper"
      sleeper=""
      text_block "$id" "Done slowly."
      result_ok "Done slowly."
      ;;
    *CRASH*)
      echo "fatal: simulated crash" >&2
      exit 3
      ;;
    *LOGIN*)
      emit '{"type":"result","subtype":"success","is_error":true,"duration_ms":5,"num_turns":1,"result":"Invalid API key · Please run /login","session_id":"'"$session"'"}'
      ;;
    *ECHOARGS*)
      text_block "$id" "session=$session resume=$resume model=$model mode=$mode"
      result_ok "args"
      ;;
    *)
      text_block "$id" "Hello from FakeClaude"
      result_ok "Hello from FakeClaude"
      ;;
  esac
done
exit 0
