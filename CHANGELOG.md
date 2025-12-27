# Changelog

## Unreleased

## 0.1.1 - 2025-12-27
- feat: `imsg chats --json`
- fix: drop sqlite `immutable` flag so new messages/replies show up (thanks @zleman1593)
- chore: update go dependencies

## 0.1.0 - 2025-12-20
- feat: `imsg chats` list recent conversations
- feat: `imsg history` with filters (`--participants`, `--start`, `--end`) + `--json`
- feat: `imsg watch` polling stream (`--interval`, `--since-rowid`) + filters + `--json`
- feat: `imsg send` text and/or one attachment (`--service imessage|sms|auto`, `--region`)
- feat: attachment metadata output (`--attachments`) incl. resolved path + missing flag
- fix: clearer Full Disk Access error for `~/Library/Messages/chat.db`
