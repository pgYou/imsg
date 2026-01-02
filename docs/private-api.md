# Private API (IMCore) Send Mode

This repo includes an **experimental** send backend that uses private Apple frameworks (`IMCore`, `IMFoundation`, `IMDaemonCore`, `IMSharedUtilities`). It is **unsupported** by Apple and may break on any macOS update.

## Enable
- Set `IMSG_ALLOW_PRIVATE=1`
- Use `--mode imcore` or `send_mode: "imcore"`
- Optional: `IMSG_SEND_MODE=imcore` to default the mode

Examples:
```
IMSG_ALLOW_PRIVATE=1 imsg send --mode imcore --text "hi" --to "+14155551212"
IMSG_ALLOW_PRIVATE=1 imsg send --mode imcore --reply-to-guid <guid> --text "reply"
IMSG_ALLOW_PRIVATE=1 imsg send --mode imcore --reaction like --reaction-to-guid <guid>
IMSG_ALLOW_PRIVATE=1 imsg send --mode imcore --reaction 😂 --reaction-to-guid <guid> --reaction-remove
```

RPC:
```
{"jsonrpc":"2.0","id":"1","method":"send","params":{"to":"+14155551212","text":"hi","send_mode":"imcore"}}
```

## Capabilities
- Text send to a handle or chat identifier/guid.
- Reply support via `reply_to_guid` (best effort).
- Reaction send via `reaction` + `reaction_to_guid` (best effort).
- Attachments are **not** supported in IMCore mode (throws error).

## How it works (current best guess)
- Loads private frameworks at runtime via `dlopen`.
- Resolves an `IMChat` via `IMChatRegistry.sharedInstance`.
- Builds an `IMMessage` with `associatedMessageGUID` for replies.
- Builds an `IMMessage` with `associatedMessageType` for tapbacks.
- Sends via `_sendMessage:adjustingSender:shouldQueue:`.

## Limitations
- Requires macOS private frameworks available and unchanged.
- May require system permissions/entitlements that are not granted.
- Failures are surfaced as `Private API failure: ...`.

## Debug tips
- Run with `IMSG_SEND_MODE=imcore` to force mode.
- Use `IMSG_ALLOW_PRIVATE=1` or it will refuse to send.
- Inspect console logs for IMDaemon / Messages errors.
