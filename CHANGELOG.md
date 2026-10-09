# Changelog

All notable changes to NotchGram, newest first, in the
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) style.
`make release VERSION=x.y.z` takes the `## x.y.z` section below as the
GitHub release notes and the text of the in-app update dialog, so write for
users: what changed and why it matters, no internals. A heading that still
says "Unreleased" is stamped with the release date by the release itself.

## 0.1.0 — 2026-10-09

The first public release: Telegram, living in your MacBook's notch.

### Telegram in the notch

- Hover the notch and a full Telegram client unfolds from it; move the
  pointer away and it folds back. Nothing sits in the Dock or the menu bar.
- Displays without a notch — external monitors included — get a drawn one,
  and the panel can be summoned over full-screen apps too.
- Three panel sizes, or your own, fitted to each screen.
- A standalone client: NotchGram talks to Telegram directly. There is no
  server of ours in between, and your messages stay between you and Telegram.

### Chats

- Sign in inside the panel with your phone number, the login code and your
  two-step verification password, if you have one.
- Your chat list as in Telegram: folders as tabs, pinned chats, unread and
  muted counters, drafts and typing indicators.
- Chats open where Telegram opens them — where you left off, at the first
  unread message under an "Unread messages" divider, or at the bottom — and a
  chat is marked read only as far as you have actually scrolled.
- Send text, photos and files; delivery ticks show sent and read.
- Replies show the quoted message above the bubble, and links in messages
  are clickable.
- Search across your chats, public chats and messages.

### Media

- Photos, stickers, GIFs and albums laid out as one mosaic post.
- A built-in viewer for photos and videos — nothing opens in another app.
- Voice messages and round video messages play right in the chat, and can be
  transcribed where Telegram offers it (Telegram Premium, or its free weekly
  trial).

### Around the app

- Esc steps back one level at a time; a two-finger swipe closes a chat.
- Launch at login, in Settings.
- English and Russian, following your Mac's language; switch in Settings.
- Built-in updates: NotchGram checks for new versions in the background and
  offers to install them; Settings › Updates checks on demand.

Requires macOS 26 Tahoe on a Mac with Apple silicon.
