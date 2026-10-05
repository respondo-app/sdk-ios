# Respondo iOS SDK

**Respondo is an AI-powered customer support platform — an AI agent plus seamless human handoff. This SDK puts that support experience right inside your iOS app, built with Swift and SwiftUI.**

## Why Respondo

Respondo answers your customers instantly. An AI agent resolves questions in real time from your own knowledge base, and escalates to a human teammate the moment a conversation needs one — with full context, no repetition. Every channel (in-app chat, email, Slack, Discord, Telegram, WhatsApp) lands in the same shared inbox, so support stays in one place.

`RespondoSDK` is the iOS client for that platform: a drop-in chat surface that presents itself as a native sheet, with a UIKit wrapper for manual embedding.

## Features

- **AI + human support chat** presented as a native SwiftUI bottom-sheet with system detents, themed from your Respondo widget config.
- **Realtime messaging** over WebSocket, with automatic fallback to SSE and polling plus reconnect.
- **File attachments** — pick, upload, and preview images and files in the chat.
- **Push notifications** over APNs — the host app owns the device token; the SDK registers it and routes taps back to the right conversation.
- **Identity verification** with HMAC-signed users — the trusted pattern you already know from tools like Intercom.
- **Engagement surfaces**: surveys (NPS / CSAT), news, checklists, and proactive messages.
- **8 UI languages** with automatic locale detection.
- **SwiftUI-first, with a UIKit wrapper** (`RespondoChatViewController`) for embedding the chat in a `UINavigationController` or custom flow.
- **Zero third-party dependencies** — pure Swift on Foundation and SwiftUI.

## Requirements

- **iOS 15+**
- **Swift 5.9+**

## Install

Add the package in **Xcode → File → Add Package Dependencies…** using the URL:

```
https://github.com/respondo-app/sdk-ios
```

Or add it to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/respondo-app/sdk-ios", from: "0.3.0")
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "RespondoSDK", package: "sdk-ios")
        ]
    )
]
```

## Quick start

```swift
import RespondoSDK

// 1. Initialise once — e.g. in your App init or AppDelegate.
Respondo.initialize(
    RespondoConfig(
        agentId: "<agent-uuid>",
        channelId: "<channel-uuid>"
    )
)

// 2. Open the chat from anywhere — the SDK presents the sheet for you.
Respondo.open()
```

Prefer to embed the chat yourself (e.g. push it onto a navigation stack)? Use the UIKit wrapper instead of `Respondo.open()`:

```swift
if let chat = RespondoChatViewController.make() {
    navigationController?.pushViewController(chat, animated: true)
}
```

### Identify a signed-in user

```swift
Respondo.identify(
    RespondoIdentity(
        userId: "u_123",
        email: "jane@example.com",
        userHash: "<hmac-from-your-backend>"
    )
)

Respondo.reset() // on logout: revoke the session and start a fresh anonymous visitor
```

`userHash` is an HMAC computed by **your** backend over the signed identity — the SDK never computes it and the secret must never ship in the app. See the identity verification guide in the docs at https://respondo.ai/docs. Without a `userHash`, the chat simply works anonymously.

### Push notifications

```swift
// Your app owns the APNs device token; the SDK only registers it.
Respondo.setPushToken(deviceToken)
Respondo.clearPushToken() // on logout

// On an incoming notification or a tap on it:
let handled = Respondo.handlePush(userInfo: userInfo)
```

### Observe unread state

```swift
// Reactive, via an AsyncStream:
Task {
    for await count in Respondo.unreadCountStream {
        updateBadge(count)
    }
}

// Or imperative, via the delegate:
Respondo.delegate = self

func respondoUnreadChanged(_ count: Int) { updateBadge(count) }
func respondoUrlRequested(_ url: URL) -> Bool { false } // false → the SDK opens it externally
```

## Where to get agentId and channelId

Open the **Respondo dashboard → Channels → Widget** — the agent and channel IDs are shown there. No API key is required: the SDK talks to your public widget channel.

## License

MIT.

## Links

- Product and dashboard: **https://respondo.ai**
- Documentation and guides: **https://respondo.ai/docs**

---

**Ready to add AI-powered support to your iOS app?** Get started at **https://respondo.ai**.
