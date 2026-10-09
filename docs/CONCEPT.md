> Imported verbatim from the founding concept discussion (2026-08-22).
> The Open Questions below have since been resolved — see
> [ARCHITECTURE.md](ARCHITECTURE.md) § Decisions and [ROADMAP.md](ROADMAP.md).
> This file stays unedited as the origin document.

# NotchGram — Concept Spec

## Vision

NotchGram is a native macOS app that turns the MacBook notch into a fully
functional pocket-sized Telegram client. Hover over the notch, and a compact
but genuinely complete Telegram interface expands — independent of whether
the official Telegram Desktop app is installed or running.

This is a concept/vision document, not a technical task breakdown. The goal
is to hand this to a fresh session for collaborative implementation planning.

## Background & Precedent

- **UX pattern precedent**: builds directly on the hover-over-notch →
  expanding-panel interaction already shipped in Dictate (Phase 1). There,
  the panel is a small dictation text box. Here, the panel is much larger —
  sized like a genuine mini standalone messenger window, not a small popup.
- **Genre precedent**: a mature "notch overlay" app category already exists
  on macOS (TheBoringNotch, QuakeNotch, NotchNook, Alcove, NotchDrop), proving
  the interaction pattern is well understood by users with notched machines
  and technically well-trodden (borderless floating `NSWindow`, notch
  geometry detection via `NSScreen` auxiliary-area APIs, `NSTrackingArea`
  for hover).
- **Telegram integration approach**: use TDLib (Telegram's official library
  for building third-party clients) rather than wrapping/automating the real
  Telegram.app via Accessibility API or screen capture. TDLib is officially
  sanctioned for exactly this use case and is a direct MTProto client —
  no custom backend/server required. The app talks straight to Telegram's
  own servers, same as any official client.
- **Distribution/signing infra**: reuses what's already set up for Dictate —
  Apple Developer Program account, direct `.dmg` distribution outside the
  App Store sandbox (also avoids sandbox entitlement friction for TDLib's
  file/network access).
- **Stack**: same as Dictate — Swift 6, AppKit/SwiftUI hybrid, strict
  concurrency. Target macOS version to be confirmed (see Open Questions —
  Phase 3's older-hardware fallback may push the minimum lower than
  Dictate's macOS 26+).

## Naming

Settled on **NotchGram**. Follows the established third-party-Telegram-client
naming convention (`-gram` suffix: Unigram, Kotatogram, Materialgram,
AyuGram) and avoids using "Telegram" as the literal app name, per the
community convention around unofficial clients.

## Dev Credentials Status

A Telegram app is already registered at my.telegram.org under the title
"NotchGram" — `api_id` and `api_hash` exist and are ready to use. These must
be stored in a gitignored config or Keychain, never hardcoded into committed
source or shared publicly.

## Core Interaction Model

- Default trigger: hover cursor over the physical notch on notch-equipped
  MacBooks.
- On hover, the notch overlay expands from its resting/collapsed state into
  a much larger panel than Dictate's — a compact but fully interactive
  mini-Telegram, not a glance/preview widget.
- The expanded panel supports real usage: browsing chats, opening
  conversations, searching, replying — a genuine (if simplified) client.
- Works independent of whether Telegram Desktop is installed or running.
  NotchGram is its own standalone TDLib-based client, always available
  regardless of other apps' state — the "pocket Telegram" on any screen.

## MVP Scope (Phase 1) — Single Account

Goal: a genuinely usable, simplified Telegram client, fully operable from
the notch panel, for one Telegram account.

In scope:
- Account/profile view
- Chat list: regular chats, group chats, pinned chats surfaced distinctly
- Search across chats
- Opening a chat from the list → full conversation view
- Sending and receiving messages within a chat (core messaging loop)
- Overall UX bar: reads as "Telegram, simplified" — a real client, not a
  stripped-down notification widget

Not yet specified (needs resolving in the next session — see Open
Questions): depth of media handling (photos/stickers/voice/video), typing
indicators, message editing/deletion, reactions, collapsed-state behavior.

## Phase 2 — Multi-Account

- Support for multiple Telegram accounts registered on the same device.
- A dedicated author's-own UX addition beyond stock Telegram behavior: a
  fast account-switch control designed to avoid repeated multi-click
  account switching — one clearly reachable action to cycle/select between
  logged-in accounts.

## Phase 3 — Non-Notch Fallback

For older MacBooks without a physical notch, two directions were raised
(not yet decided which, or whether both should ship):

1. **Corner trigger**: same expand-on-hover interaction, anchored to a
   screen corner (e.g. bottom-right) instead of the notch.
2. **Synthetic/drawn notch**: reuse the approach already implemented in
   Dictate for notch-less screens — draw a narrower, artificial "notch" UI
   element (roughly half the width of a real one), so it reads as an
   intentional stylistic UI element rather than an attempt to fake hardware,
   and stays unobtrusive.

## Open Questions (for the implementation-planning session)

- Exact target dimensions for the expanded panel — explicitly bigger than
  Dictate's dictation box, but needs concrete sizing decided against real
  chat-list + conversation UI needs.
- Which Swift binding/wrapper for TDLib (e.g. TDLibKit or similar) vs. a
  thinner custom JSON-interface bridge — needs a build/maintenance-risk
  evaluation.
- MVP message composition scope: text-only, or does Phase 1 need basic
  media (at minimum, photos)?
- Collapsed-state behavior: should the resting/un-hovered notch show
  anything (unread badge, latest-message preview, à la Boring Notch's
  now-playing widget), or stay fully passive until hovered?
- Local encrypted DB (TDLib-managed SQLite): confirm Keychain-based
  approach for where the encryption key is generated/stored.
- Minimum macOS version: Dictate targets macOS 26+; confirm whether
  NotchGram should match or go broader, given Phase 3's fallback targets
  older hardware (which often means older macOS — affects API availability
  like `NSScreen` auxiliary-area detection, available since macOS 12.1+).
- Relationship to Dictate: fully separate app/bundle ID, or is there a case
  for factoring the notch-overlay window engine into a small shared
  internal package used by both?

## Execution Notes for the Next Session

This document is intentionally a concept spec, not a technical task
breakdown. The next session should take this as input, resolve the open
questions above collaboratively, and turn it into an actionable phased
implementation plan — detailed enough to run as a long, largely autonomous
build session with minimal need for founder input mid-flight.
