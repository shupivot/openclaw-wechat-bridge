# WeChatBridge

> iOS WeChat tweak — exposes a local HTTP API for programmatic message send/receive, with Mac-side AI auto-reply.

**Status**: Working proof-of-concept. Receive ✅ | Send to current chat ✅ | Send to arbitrary contact ⏳

---

## How It Works

```
┌─────────────────────────────────────────────────────┐
│  iPhone (jailbroken)                                │
│  WeChat.app + WeChatBridge.dylib (injected)         │
│  HTTP server on :58080                              │
│    /recv      ← drain message queue                 │
│    /send_private_msg  ← send text                   │
│    /set_webhook  ← push incoming to Mac             │
└────────────────┬────────────────────────────────────┘
                 │  webhook POST (LAN)
                 ▼
┌─────────────────────────────────────────────────────┐
│  Mac  (webhook-server.js, port 58081)               │
│  Receives incoming → calls Claude AI → replies      │
└─────────────────────────────────────────────────────┘
```

The dylib hooks two WeChat internals:
- **Receive**: `CMessageMgr.AsyncOnAddMsg:MsgWrap:` fires on every incoming message
- **Send**: `WeixinContentLogicController.SendTextMessage:replyingMessage:isPasted:` — the real UI send path (no red exclamation mark)

---

## Requirements

| Component | Version |
|-----------|---------|
| iPhone jailbreak | Dopamine2 / rootHIDE |
| iOS | 16.x (arm64e / A12+) |
| Theos | latest |
| Mac | Any (Node.js 18+) |

---

## Build & Deploy

```bash
# On Mac
THEOS=~/theos make package

# On iPhone (via SSH)
dpkg --force-architecture -i /var/mobile/Documents/com.pivot.wechatbridge_*.deb
chmod 644 /var/jb/usr/lib/TweakInject/WeChatBridge.plist
killall -9 WeChat
```

TweakInject path: `/var/jb/usr/lib/TweakInject/` (not MobileSubstrate)

---

## HTTP API (iPhone side, port 58080)

| Endpoint | Method | Body | Description |
|----------|--------|------|-------------|
| `/ping` | GET | — | Status, current chat, swizzled hooks list |
| `/recv` | GET | — | Drain incoming message queue (max 200) |
| `/set_webhook` | POST | `{"url":"http://mac:port"}` | Push incoming messages to Mac |
| `/send_private_msg` | POST | `{"user_id":"wxid","message":"text"}` | Send text to contact |
| `/send_group_msg` | POST | `{"group_id":"chatroom@chatroom","message":"text"}` | Send to group |
| `/spy` | GET | — | Last 50 outgoing message events |
| `/inspect_lc` | GET | — | Dump LogicController debug info |

---

## Mac Side (webhook-server.js)

```bash
# 1. SSH tunnel (Mac → iPhone, so Node.js can reach phone)
sshpass -p 'PASSWORD' ssh -fN -L 58082:127.0.0.1:58080 root@PHONE_IP

# 2. Start webhook server
node webhook-server.js

# 3. Register webhook on phone
curl -X POST http://127.0.0.1:58082/set_webhook \
  -H "Content-Type: application/json" \
  -d '{"url":"http://MAC_IP:58081"}'
```

Edit `webhook-server.js` to set your AI API key and whitelist.

---

## Key Reverse Engineering Findings

### ⚠️ Critical: `%init()` required in `%ctor`

Without calling `%init()` inside your custom `%ctor`, **all `%hook` blocks are silently ignored**. This burned hours of debugging.

```objc
%ctor {
    %init();  // ← MANDATORY
}
```

### Send Chain

```
User tap "Send"
  → BaseMsgContentViewController.AsyncSendMessage:replyingMsg:referPartialInfo:isPasted:
  → WeixinContentLogicController.SendTextMessage:replyingMessage:isPasted:   ← hook here
  → CMessageMgr.sendMsg:toContactUsrName:
```

**Critical**: `WeixinContentLogicController` is a *subclass* of `BaseMsgContentLogicController`. The subclass overrides `SendTextMessage:`. You must hook the subclass, not the base.

Direct `CMessageMgr` sends work locally (message appears in UI) but fail at server level (red exclamation mark) — likely missing auth/sequence fields. Always go through LogicController.

### Receive Hook

```objc
%hook CMessageMgr
- (void)AsyncOnAddMsg:(id)chat MsgWrap:(id)wrap {
    %orig;
    // wrap is CMessageWrap
    NSString *from    = [wrap m_nsFromUsr];
    NSString *to      = [wrap m_nsToUsr];
    NSString *content = [wrap m_nsContent];
    uint32_t  type    = [wrap m_uiMessageType];  // NOT m_uiMsgType
    // type 1 = text, 3 = image, 34 = voice, 43 = ad
}
%end
```

### CMessageWrap Fields

| Property | Selector | Notes |
|----------|----------|-------|
| From user | `m_nsFromUsr` | wxid |
| To user | `m_nsToUsr` | wxid |
| Content | `m_nsContent` | text content |
| Type | `m_uiMessageType` | **NOT** `m_uiMsgType` (wrong name) |
| Set type | `setM_uiMessageType:` | |

### Useful wxids

| wxid | Meaning |
|------|---------|
| `filehelper` | File Transfer Helper (safe for testing) |
| `gh_*` | Official accounts (skip these) |
| type 43 | Ad messages (skip) |
| type 10000 | System notification (skip) |

---

## What's Left (PRs welcome)

### 🔴 High priority

**Send to arbitrary contacts (not just current chat)**

Currently `SendViaLogicController()` only works when the target chat is *currently open* on screen. The fix is to programmatically navigate to the chat first:

```objc
// WechatPushMsgPage pattern
[pushMsgPage openMessageContentView:contact
              startSendMessage:NO
              msgWrapToAdd:nil
              animated:NO
              jumpToFirstUnreadNode:NO
              indexPath:nil];
// then call SendTextMessage:
```

Hook `WechatPushMsgPage` and expose it via HTTP.

### 🟡 Medium priority

**Voice message send**

From WeChatTweak reverse engineering:
```objc
// encode PCM → SILK
[encoder encodeSilkFromPCM:pcmPath toBitstream:silkPath sampleRate:16000 bitrate:25000 tencent:YES];

// send voice
[mgr sendVoiceMessage:wrap fromUser:selfWxid filePath:silkPath isCh:NO ys:NO];
```

TTS options found in other tweaks: FishAudio, Volcano (ByteDance), MINIMAX.

**Image send**

```objc
[helper sendPic1:imageData tousername:targetWxid];
```

### 🟢 Nice to have

- Persistent SSH tunnel / `iproxy` USB alternative
- Config file for whitelist, system prompt, AI model
- Group message support
- Message recall hook

---

## Other Tweaks Reversed

These tweaks were analyzed for API patterns. Full credit to their authors.

| Tweak | Notable APIs |
|-------|-------------|
| **WeChatTweak** | ffmpeg + SILK SDK, TTS (3 providers), `sendVoiceWithUser:audPath:mp3Time:` |
| **PKCWeChatTools** | OpenAI `/chat/completions`, DALL-E/Flux/Luma image+video gen, SILK encode/decode |
| **HBWechatHelper** | `sendPic1:tousername:`, `convertMP3ToSilk:delegate:` |
| **WechatPushMsgPage** | `openMessageContentView:startSendMessage:msgWrapToAdd:animated:` |
| **FuckWeChatAds** | Type 43 = ad msgs |

---

## Contributing

1. Fork → branch → PR
2. I'll review and merge

Areas where help is most needed:
- **Arbitrary-contact send** (the `WechatPushMsgPage` approach)
- **Testing on other iOS versions** (currently only verified on iOS 16.5 A12+)
- **Stability** (WeChat crashes occasionally with multiple tweaks loaded)

---

## License

MIT. Use responsibly. Don't build spam bots.
