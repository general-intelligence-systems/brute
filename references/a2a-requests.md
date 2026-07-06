You want the actual JSON-RPC request bodies. Here they are.

## 1. `message/send`

```json
{
  "jsonrpc": "2.0",
  "id": "req-1",
  "method": "message/send",
  "params": {
    "message": {
      "role": "user",
      "messageId": "msg-abc",
      "parts": [{ "kind": "text", "text": "fix the failing tests" }]
    },
    "configuration": {
      "acceptedOutputModes": ["text/plain"],
      "blocking": false,
      "pushNotificationConfig": {
        "url": "https://client.example.com/webhook",
        "token": "validation-token",
        "authentication": { "schemes": ["Bearer"], "credentials": "..." }
      }
    }
  }
}
```

## 2. `message/stream`

```json
{
  "jsonrpc": "2.0",
  "id": "req-2",
  "method": "message/stream",
  "params": {
    "message": {
      "role": "user",
      "messageId": "msg-def",
      "parts": [{ "kind": "text", "text": "explain this codebase" }]
    },
    "configuration": {
      "acceptedOutputModes": ["text/plain"]
    }
  }
}
```

## 3. `tasks/get`

```json
{
  "jsonrpc": "2.0",
  "id": "req-3",
  "method": "tasks/get",
  "params": {
    "id": "task-789",
    "historyLength": 20
  }
}
```

## 4. `tasks/list`

```json
{
  "jsonrpc": "2.0",
  "id": "req-4",
  "method": "tasks/list",
  "params": {
    "contextId": "ctx-456",
    "state": "working",
    "pageSize": 50,
    "pageToken": null
  }
}
```

## 5. `tasks/cancel`

```json
{
  "jsonrpc": "2.0",
  "id": "req-5",
  "method": "tasks/cancel",
  "params": {
    "id": "task-789"
  }
}
```

## 6. `tasks/resubscribe`

```json
{
  "jsonrpc": "2.0",
  "id": "req-6",
  "method": "tasks/resubscribe",
  "params": {
    "id": "task-789"
  }
}
```

## 7. `tasks/pushNotificationConfig/set`

```json
{
  "jsonrpc": "2.0",
  "id": "req-7",
  "method": "tasks/pushNotificationConfig/set",
  "params": {
    "taskId": "task-789",
    "pushNotificationConfig": {
      "url": "https://client.example.com/webhook",
      "token": "validation-token",
      "authentication": { "schemes": ["Bearer"], "credentials": "..." }
    }
  }
}
```

## 8. `tasks/pushNotificationConfig/get`

```json
{
  "jsonrpc": "2.0",
  "id": "req-8",
  "method": "tasks/pushNotificationConfig/get",
  "params": {
    "taskId": "task-789",
    "pushNotificationConfigId": "cfg-001"
  }
}
```

## 9. `tasks/pushNotificationConfig/list`

```json
{
  "jsonrpc": "2.0",
  "id": "req-9",
  "method": "tasks/pushNotificationConfig/list",
  "params": {
    "taskId": "task-789"
  }
}
```

## 10. `tasks/pushNotificationConfig/delete`

```json
{
  "jsonrpc": "2.0",
  "id": "req-10",
  "method": "tasks/pushNotificationConfig/delete",
  "params": {
    "taskId": "task-789",
    "pushNotificationConfigId": "cfg-001"
  }
}
```

## 11. `agent/getAuthenticatedExtendedCard`

```json
{
  "jsonrpc": "2.0",
  "id": "req-11",
  "method": "agent/getAuthenticatedExtendedCard"
}
```

All POST to your single JSON-RPC endpoint with `Content-Type: application/json`. Auth goes in the HTTP `Authorization` header, not the body.
