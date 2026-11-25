# Changelog

## 0.4.0

Upgrading from 0.3.0 — behavior to know before you ship:

- Every signed-in user becomes a contact at once: `identify()` with a
  `userId` or an `email` creates the contact without a chat, so Contacts
  grow by everyone who logs in to your app.
- The SDK reports app sessions (launch, return after 20 seconds or more in
  the background, user switch). Attributes and sessions need `channelId` in
  the config.
- The chat UI follows the conversation language the server sets, not the
  app or device locale.
- The public API only grows: existing integrations compile unchanged.

- Conversation rating. When a conversation is closed in a way that asks the
  customer for a rating (the same closes as in the web widget), the chat shows
  "How was your experience?" at the end of the conversation: a score from 1 to
  5, then an optional comment ("Tell us more", up to 1,000 characters) sent
  with Send. The score can be changed while the conversation stays closed, and
  the comment can be edited once with Edit. The score and the comment are
  saved as the conversation's rating, the same as from the web widget. The
  texts come from the server in the customer's language; the SDK's own strings
  are a fallback. Nothing to set up in the app.
- The chat language is the conversation language set by the server. The
  server takes it from the customer's own words, a teammate's choice, an
  explicit request from the customer, or the language saved on the contact,
  and keeps it for the conversation. The chat switches to it with the first
  reply of a new conversation and follows it from then on; before, the first
  conversation stayed in the device language until it ended. Until the server
  knows the language, the chat uses the device language (or `locale` from the
  SDK config); a conversation continued from an earlier launch starts in the
  language it already had. (The language comes from the `lang` field of every
  `/chat` response, the `conversation_updated` event, and, for a continued
  conversation, `visitor_language` in the widget config.)
- The SDK no longer guesses the language from the text the customer types:
  the chat changes language only when the server's conversation language
  changes.
- The SDK's own strings exist in English, Russian, Ukrainian, German, French,
  Spanish, Portuguese and Polish: in any other language they show in English,
  while the texts from the server follow the conversation language either
  way.
- Chinese conversations: the texts the server sends for the conversation
  (notices, the rating block) follow the customer's script, Traditional or
  Simplified. The SDK's own strings have no Chinese and show in English.
  (The server tags Chinese as `zh-Hans` or `zh-Hant`; the SDK reads these
  tags by their base code.)
- A quick-question chip, an AI suggestion, or the "files sent" text of an
  attachment without a message no longer switches the conversation away from
  the customer's language, even when written in your app's language: the SDK
  marks texts it sends on the customer's behalf, as the web widget does, and
  the server does not take the language from them. (Field `input_source`:
  `quick_question`, `suggestion`, `files_placeholder`, or `typed` for typed
  text; a retry keeps the mark.)
- Incoming markdown keeps paragraph spacing: a blank line between blocks
  renders as a paragraph gap instead of a plain line break.
- `#`…`######` headings render as a bold line without the hashes, and `> `
  quote lines render without the marker.
- `![alt](url)` images render as a link labelled with the alt text (or the
  URL), without a stray `!`.
- A numbered list starts from its first number and counts on, across blank
  lines: items typed as `1.` on every line, or a list split by blank lines,
  show 1, 2, 3; a list that starts at 3 shows 3, 4, 5.
- An escaped `\#` at the start of a line renders as a literal `#` (no
  backslash, no heading).
- Chat attachments are uploaded with `agent_id` and the conversation keys, and the upload no longer gets 401. In 0.3.0 every attachment upload failed.
- Cold-start push open: a push tapped before the SDK knows the push token
  (before `initialize`, while it runs or after it) reports its open
  (`POST /api/v1/widget/push/opened`) as soon as `setPushToken` passes the
  token (up to 10 taps; `clearPushToken()` and `reset()` drop them), and the
  beacon uses the latest token even before its registration finishes.
  Before, such a beacon went with an empty token and the open was lost. A
  push handled while `initialize` is still running is no longer dropped as
  a duplicate when the buffered calls replay, and an `initialize` called
  again before the first one finishes replays the calls made before it
  instead of dropping them (only an `initialize` over a ready SDK drops
  them; an `initialize` with an identity drops the earlier `identify`
  calls).
- `initialize(_:identity:)`: the startup `/widget/identify` is the first
  request of `initialize`, and the launch app session
  (`POST /api/v1/widget/app-session`) is sent after it answers (or fails).
  Before, the session went first and created the contact from the user id
  alone, without the email, so an imported row with that email was not
  merged. Every app session (launch, return from background, contact
  change), `track()` event (`POST /api/v1/widget/events`) and push token
  registration (`setPushToken`, re-registration after `identify()`) waits
  for every `/widget/identify` in flight, including one started later (each
  at most the request timeout), the same way (sessions and events keep the
  identity they were made with); a repeated `identify()` with the same
  identity waits for the request in flight, and the same registration
  (token and identity) is not sent twice.
- `reset()` keeps the push token: the new anonymous visitor registers it
  after the reset, as on Android and Flutter. Before, the token was lost
  until the app passed it again.
- `identify()` with a `userId` or an `email` creates the contact right away
  (`POST /api/v1/widget/identify`), even with no properties — as signing a
  user in to Intercom's Messenger does — so a user who logs in and never
  chats is in Contacts, segments and Series. An anonymous identity with no
  properties still sends nothing; an identical repeat call sends nothing.
- New `RespondoIdentity.signedUpAt` (`Date?`, Intercom's `signedUpAt`): when
  the person signed up in your product, sent as `signed_up_at` (Unix
  seconds). Without it the contact's signup date stays empty — the first app
  open is not a signup. A signed identity (`userHash`) can change a known
  date; an unsigned one only fills an empty date.
- `identify()` properties reach the contact profile right away
  (`POST /api/v1/widget/identify`, the web widget's contract) instead of
  waiting for the first chat message, so segments, Series and Workflows see
  them for people who never chat. Requires `channelId`. An identical repeat
  call sends nothing.
- `RespondoIdentity.languageOverride` — the contact's explicit language
  (Intercom `languageOverride`), sent as the `language_override` property on
  identify and on `/chat`.
- App sessions: the SDK reports a session (`POST /api/v1/widget/app-session`:
  platform, bundle id, app and SDK version, device language, name) without
  push permission, following Intercom's rule — an app backgrounded for at
  least 20 seconds and then resumed starts a new session. Reported on launch
  once per process (re-initializing the SDK, e.g. after `destroy()`, is not a
  new launch) and only when the app actually opens: a process started in the background (silent push,
  background fetch, `BGTask`) reports nothing until the first
  `willEnterForeground` / `didBecomeActive`, and nothing is reported while the
  app is in the background. Also reported on a return from
  background that lasted at least 20 seconds, measured from the first
  background moment of that episode, and when `identify()` switches
  to another identified user (after the identify request completes, so the
  contact is created with its name and properties) — not on `reset()`. An
  anonymous open is recorded only for a visitor whose contact already exists.
  Requires `channelId`. The WebSocket `identify` frame declares the
  `app_sessions` feature, so the server no longer counts it as app activity.
- The chat's own notices speak the customer's language, not the app's UI
  locale: "handed to a person", "back to the AI assistant", "conversation
  closed", and the "Talk to a person" confirmation or failure now use the
  texts the server sends (`handover_card_text`, `status_texts`, the
  `/escalate` message). The SDK's own strings are only a fallback for an
  older backend or no network. A standard handover notice is shown once,
  without a second card under it.
- A handover reply that echoes the customer's own message no longer shows
  that message a second time.
- Setup (works with any SDK version): take `agentId` and `channelId` from
  your Mobile SDK channel (Respondo dashboard → Settings › Channels) and pass
  both; conversations from the app then show as Mobile SDK in the inbox.

## 0.3.1 (not published; ships in 0.4.0)

- Bare `http://` and `https://` links in operator and assistant messages are
  clickable and reach `RespondoDelegate.respondoUrlRequested(_:)`.
- Links are trimmed at sentence punctuation, keep balanced parentheses, and
  reject unsafe schemes, malformed hosts, control characters, and code spans.
- Chat messages show local calendar-day separators and message times.
