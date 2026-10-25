#!/bin/sh
# FakeCodex: answers `codex app-server` JSON-RPC like Codex 0.162 for one turn.
# Request ids follow CodexAdapter: initialize = 1, thread/start = 2, turn/start = 3.
while IFS= read -r line; do
  case "$line" in
    *'"initialized"'*) ;;
    *'"initialize"'*) echo '{"jsonrpc":"2.0","id":1,"result":{"userAgent":"fake"}}' ;;
    *'"thread/start"'*) echo '{"jsonrpc":"2.0","id":2,"result":{"thread":{"id":"fake-thread"},"model":"fake-model"}}' ;;
    *'"turn/start"'*)
      echo '{"jsonrpc":"2.0","id":3,"result":{"turn":{"id":"turn-1","status":"inProgress"}}}'
      echo '{"jsonrpc":"2.0","method":"turn/started","params":{"threadId":"fake-thread","turn":{"id":"turn-1"}}}'
      echo '{"jsonrpc":"2.0","method":"item/agentMessage/delta","params":{"threadId":"fake-thread","turnId":"turn-1","itemId":"m1","delta":"FAKE "}}'
      echo '{"jsonrpc":"2.0","method":"item/completed","params":{"item":{"type":"agentMessage","id":"m1","text":"FAKE CODEX ANSWER"}}}'
      echo '{"jsonrpc":"2.0","method":"turn/completed","params":{"threadId":"fake-thread","turn":{"id":"turn-1","status":"completed","error":null,"durationMs":5}}}'
      ;;
  esac
done
