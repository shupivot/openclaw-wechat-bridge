# WeChatBridge · OpenClaw

[English](#english) | [中文](#中文)

---

<a name="english"></a>

> iOS WeChat tweak — exposes a local HTTP API for programmatic message send/receive, with Mac-side AI auto-reply.

**Status**: Working proof-of-concept. Receive ✅ | Send to current chat ✅ | Send to arbitrary contact ⏳

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

## Requirements

| Component | Version |
|-----------|---------|
| iPhone jailbreak | Dopamine2 / rootHIDE |
| iOS | 16.x (arm64e / A12+) |
| Theos | latest |
| Mac | Any (Node.js 18+) |

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

## Mac Side (webhook-server.js)

```bash
# 1. SSH tunnel (so Node.js can reach the phone)
sshpass -p 'PASSWORD' ssh -fN -L 58082:127.0.0.1:58080 root@PHONE_IP

# 2. Start webhook server
node webhook-server.js

# 3. Register webhook on phone
curl -X POST http://127.0.0.1:58082/set_webhook \
  -H "Content-Type: application/json" \
  -d '{"url":"http://MAC_IP:58081"}'
```

Edit `webhook-server.js` to set your AI API key and whitelist.

## Key Reverse Engineering Findings

### ⚠️ Critical: `%init()` required in `%ctor`

Without calling `%init()` inside your custom `%ctor`, **all `%hook` blocks are silently ignored**.

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

**Critical**: `WeixinContentLogicController` is a *subclass* of `BaseMsgContentLogicController`. Hook the subclass, not the base. Direct `CMessageMgr` sends cause red exclamation marks.

### CMessageWrap Fields

| Property | Selector | Notes |
|----------|----------|-------|
| From | `m_nsFromUsr` | wxid |
| To | `m_nsToUsr` | wxid |
| Content | `m_nsContent` | text |
| Type | `m_uiMessageType` | **NOT** `m_uiMsgType` |

Type values: `1`=text, `3`=image, `34`=voice, `43`=ad, `10000`=system

## What's Left (PRs welcome)

### 🔴 Send to arbitrary contacts

Currently only works when the target chat is open on screen. Fix: hook `WechatPushMsgPage`:

```objc
[pushMsgPage openMessageContentView:contact
              startSendMessage:NO msgWrapToAdd:nil
              animated:NO jumpToFirstUnreadNode:NO indexPath:nil];
```

### 🟡 Voice messages

```objc
// PCM → SILK encode
[encoder encodeSilkFromPCM:pcmPath toBitstream:silkPath sampleRate:16000 bitrate:25000 tencent:YES];
// Send
[mgr sendVoiceMessage:wrap fromUser:selfWxid filePath:silkPath isCh:NO ys:NO];
```

### 🟢 Nice to have
- Config file for whitelist / system prompt / AI model
- `iproxy` USB alternative to SSH tunnel
- Message recall hook

## Contributing

Fork → branch → PR. I'll review and merge.

Most needed: arbitrary-contact send, testing on other iOS versions, stability fixes.

## License

MIT. Use responsibly. No spam bots.

---

<a name="中文"></a>

# WeChatBridge · OpenClaw（中文说明）

> iOS 微信插件 —— 通过 HTTP API 实现微信消息的收发，支持 Mac 端 AI 自动回复。

**状态**：可用的概念验证版本。接收消息 ✅ | 发送到当前聊天 ✅ | 发送给任意联系人 ⏳

## 工作原理

```
┌─────────────────────────────────────────────────────┐
│  iPhone（越狱）                                      │
│  微信.app + WeChatBridge.dylib（注入）               │
│  本地 HTTP 服务，端口 :58080                         │
│    /recv            ← 取消息队列                     │
│    /send_private_msg ← 发送文本                      │
│    /set_webhook     ← 推送新消息到 Mac               │
└────────────────┬────────────────────────────────────┘
                 │  webhook POST（局域网）
                 ▼
┌─────────────────────────────────────────────────────┐
│  Mac（webhook-server.js，端口 58081）                │
│  收到消息 → 调用 Claude AI → 自动回复                │
└─────────────────────────────────────────────────────┘
```

## 环境要求

| 组件 | 版本 |
|------|------|
| iPhone 越狱 | Dopamine2 / rootHIDE |
| iOS | 16.x（arm64e / A12 及以上） |
| Theos | 最新版 |
| Mac | 任意（Node.js 18+） |

## 编译 & 部署

```bash
# 在 Mac 上编译
THEOS=~/theos make package

# SSH 到 iPhone 部署
dpkg --force-architecture -i /var/mobile/Documents/com.pivot.wechatbridge_*.deb
chmod 644 /var/jb/usr/lib/TweakInject/WeChatBridge.plist
killall -9 WeChat
```

插件安装路径：`/var/jb/usr/lib/TweakInject/`（不是 MobileSubstrate）

## HTTP 接口（iPhone 端，端口 58080）

| 接口 | 方法 | 请求体 | 说明 |
|------|------|--------|------|
| `/ping` | GET | — | 状态、当前聊天、已注入的 hook 列表 |
| `/recv` | GET | — | 取出消息队列（最多 200 条） |
| `/set_webhook` | POST | `{"url":"http://mac:port"}` | 设置推送地址 |
| `/send_private_msg` | POST | `{"user_id":"wxid","message":"文本"}` | 发私信 |
| `/send_group_msg` | POST | `{"group_id":"xxx@chatroom","message":"文本"}` | 发群消息 |
| `/spy` | GET | — | 最近 50 条发出消息记录 |
| `/inspect_lc` | GET | — | LogicController 调试信息 |

## Mac 端（webhook-server.js）

```bash
# 1. 建立 SSH 隧道
sshpass -p '密码' ssh -fN -L 58082:127.0.0.1:58080 root@手机IP

# 2. 启动 webhook 服务
node webhook-server.js

# 3. 在手机上注册 webhook
curl -X POST http://127.0.0.1:58082/set_webhook \
  -H "Content-Type: application/json" \
  -d '{"url":"http://MacIP:58081"}'
```

## 关键逆向发现

### ⚠️ 血泪教训：`%ctor` 里必须调用 `%init()`

```objc
%ctor {
    %init();  // ← 必须！否则所有 hook 静默失效
}
```

### 发送链路

```
用户点击"发送"
  → BaseMsgContentViewController.AsyncSendMessage:...
  → WeixinContentLogicController.SendTextMessage:replyingMessage:isPasted:  ← hook 这里
  → CMessageMgr.sendMsg:toContactUsrName:
```

必须 hook **子类** `WeixinContentLogicController`，不是父类。直接用 `CMessageMgr` 发送会出红叹号。

### CMessageWrap 字段

| 属性 | Selector | 备注 |
|------|----------|------|
| 发送方 | `m_nsFromUsr` | wxid |
| 接收方 | `m_nsToUsr` | wxid |
| 内容 | `m_nsContent` | 文本 |
| 消息类型 | `m_uiMessageType` | **不是** `m_uiMsgType` |

类型值：`1`=文本，`3`=图片，`34`=语音，`43`=广告，`10000`=系统通知

## 待完成（欢迎 PR）

### 🔴 向任意联系人发送

当前只有目标聊天在屏幕上打开时才能发送。修法：hook `WechatPushMsgPage`：

```objc
[pushMsgPage openMessageContentView:contact
              startSendMessage:NO msgWrapToAdd:nil
              animated:NO jumpToFirstUnreadNode:NO indexPath:nil];
```

### 🟡 发送语音消息

```objc
// PCM → SILK 编码
[encoder encodeSilkFromPCM:pcmPath toBitstream:silkPath sampleRate:16000 bitrate:25000 tencent:YES];
// 发送
[mgr sendVoiceMessage:wrap fromUser:selfWxid filePath:silkPath isCh:NO ys:NO];
```

### 🟢 锦上添花
- 白名单、AI 提示词、模型的配置文件
- iproxy USB 方案替代 SSH 隧道
- 撤回消息 hook

## 参与贡献

Fork → 新建分支 → 提 PR，我来 review 合并。

最需要帮助：向任意联系人发送、其他 iOS 版本测试、稳定性修复。

## License

MIT。请合法使用，禁止用于垃圾消息/骚扰。
