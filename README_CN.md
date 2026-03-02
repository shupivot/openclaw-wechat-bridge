# WeChatBridge 微信桥接

> iOS 微信插件 —— 通过 HTTP API 实现微信消息的收发，支持 Mac 端 AI 自动回复。

**状态**：可用的概念验证版本。接收消息 ✅ | 发送到当前聊天 ✅ | 发送给任意联系人 ⏳

---

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

插件 hook 了两个微信内部方法：
- **接收**：`CMessageMgr.AsyncOnAddMsg:MsgWrap:` — 每条新消息都会触发
- **发送**：`WeixinContentLogicController.SendTextMessage:replyingMessage:isPasted:` — 真正的 UI 发送路径（不会出现红叹号）

---

## 环境要求

| 组件 | 版本 |
|------|------|
| iPhone 越狱 | Dopamine2 / rootHIDE |
| iOS | 16.x（arm64e / A12 及以上） |
| Theos | 最新版 |
| Mac | 任意（Node.js 18+） |

---

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

---

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

---

## Mac 端（webhook-server.js）

```bash
# 1. 建立 SSH 隧道（让 Mac 的 Node.js 能访问手机）
sshpass -p '密码' ssh -fN -L 58082:127.0.0.1:58080 root@手机IP

# 2. 启动 webhook 服务
node webhook-server.js

# 3. 在手机上注册 webhook
curl -X POST http://127.0.0.1:58082/set_webhook \
  -H "Content-Type: application/json" \
  -d '{"url":"http://MacIP:58081"}'
```

在 `webhook-server.js` 里配置你的 AI API Key 和白名单。

---

## 关键逆向发现

### ⚠️ 血泪教训：`%ctor` 里必须调用 `%init()`

不调用的话，**所有 `%hook` 块都会被静默忽略**，浪费大量调试时间。

```objc
%ctor {
    %init();  // ← 必须！
}
```

### 发送链路

```
用户点击"发送"
  → BaseMsgContentViewController.AsyncSendMessage:replyingMsg:referPartialInfo:isPasted:
  → WeixinContentLogicController.SendTextMessage:replyingMessage:isPasted:   ← hook 这里
  → CMessageMgr.sendMsg:toContactUsrName:
```

**关键**：`WeixinContentLogicController` 是 `BaseMsgContentLogicController` 的**子类**，子类重写了 `SendTextMessage:`，必须 hook 子类而不是父类。

直接调用 `CMessageMgr` 发送在本地能显示（消息气泡出现），但服务端会拒绝（红叹号）——猜测缺少鉴权或序列号字段。始终通过 LogicController 发送。

### 接收 Hook

```objc
%hook CMessageMgr
- (void)AsyncOnAddMsg:(id)chat MsgWrap:(id)wrap {
    %orig;
    NSString *from    = [wrap m_nsFromUsr];
    NSString *to      = [wrap m_nsToUsr];
    NSString *content = [wrap m_nsContent];
    uint32_t  type    = [wrap m_uiMessageType];  // 注意：不是 m_uiMsgType
    // type: 1=文本 3=图片 34=语音 43=广告
}
%end
```

### CMessageWrap 字段

| 属性 | Selector | 备注 |
|------|----------|------|
| 发送方 | `m_nsFromUsr` | wxid |
| 接收方 | `m_nsToUsr` | wxid |
| 内容 | `m_nsContent` | 文本内容 |
| 消息类型 | `m_uiMessageType` | **不是** `m_uiMsgType`（错误名称） |
| 设置类型 | `setM_uiMessageType:` | |

### 特殊 wxid

| wxid | 含义 |
|------|------|
| `filehelper` | 文件传输助手（调试用） |
| `gh_*` | 公众号（过滤掉） |
| type 43 | 广告消息（过滤掉） |
| type 10000 | 系统通知（过滤掉） |

---

## 待完成（欢迎 PR）

### 🔴 最重要

**向任意联系人发送消息（不依赖当前打开的聊天窗口）**

目前 `SendViaLogicController()` 只有在目标聊天*正在屏幕上打开*时才能工作。修法是先程序化导航到目标聊天：

```objc
// WechatPushMsgPage 方案
[pushMsgPage openMessageContentView:contact
              startSendMessage:NO
              msgWrapToAdd:nil
              animated:NO
              jumpToFirstUnreadNode:NO
              indexPath:nil];
// 然后调用 SendTextMessage:
```

Hook `WechatPushMsgPage` 并通过 HTTP 暴露出来即可解决。

### 🟡 中优先级

**发送语音消息**

从 WeChatTweak 逆向得到的 API：
```objc
// PCM → SILK 编码
[encoder encodeSilkFromPCM:pcmPath toBitstream:silkPath sampleRate:16000 bitrate:25000 tencent:YES];

// 发送语音
[mgr sendVoiceMessage:wrap fromUser:selfWxid filePath:silkPath isCh:NO ys:NO];
```

TTS 方案：FishAudio、火山引擎（字节）、MINIMAX。

**发送图片**

```objc
[helper sendPic1:imageData tousername:targetWxid];
```

### 🟢 锦上添花

- 稳定的 SSH 隧道 / iproxy USB 方案
- 白名单、系统提示词、AI 模型的配置文件
- 群消息完整支持
- 撤回消息 hook

---

## 参考的其他插件

分析了以下插件的 API 模式，感谢原作者。

| 插件 | 主要 API |
|------|---------|
| **WeChatTweak** | ffmpeg + SILK SDK、TTS（3 个服务商）、`sendVoiceWithUser:audPath:mp3Time:` |
| **PKCWeChatTools** | OpenAI 对话、DALL-E/Flux/Luma 图片视频生成、SILK 编解码 |
| **HBWechatHelper** | `sendPic1:tousername:`、`convertMP3ToSilk:delegate:` |
| **WechatPushMsgPage** | `openMessageContentView:startSendMessage:msgWrapToAdd:animated:` |
| **FuckWeChatAds** | type 43 = 广告消息 |

---

## 参与贡献

1. Fork → 新建分支 → 提 PR
2. 我来 review 和合并

最需要帮助的地方：
- **向任意联系人发送**（WechatPushMsgPage 方案）
- **在其他 iOS 版本上测试**（目前只在 iOS 16.5 A12 上验证）
- **稳定性**（同时加载多个插件时微信偶尔崩溃）

---

## License

MIT。请合法使用，禁止用于垃圾消息/骚扰。
