// WeChatBridge v3.0 - receive messages + auto-reply foundation
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "WCHTTPServer.h"

static WCHTTPServer *gServer = nil;
static NSMutableArray *gSpyLog = nil;
static NSMutableArray *gSwizzled = nil;

// Current active logic controller
static __weak id gCurrentLogicController = nil;
static NSString *gCurrentChatUser = nil;

// ── Incoming message queue ────────────────────────────────────
static NSMutableArray *gIncomingMsgs = nil;   // ring buffer, max 200
static NSString       *gWebhookURL   = nil;   // Mac webhook URL

static void PostToWebhook(NSDictionary *msg) {
    if (!gWebhookURL) return;
    NSURL *url = [NSURL URLWithString:gWebhookURL];
    if (!url) return;
    NSData *body = [NSJSONSerialization dataWithJSONObject:msg options:0 error:nil];
    if (!body) return;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 5;
    req.HTTPMethod = @"POST";
    req.HTTPBody   = body;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req] resume];
}

static void AddIncoming(NSString *fromUser, NSString *toUser, NSString *content, NSUInteger msgType) {
    if (!fromUser.length) return;
    if (msgType == 43) return;                    // ads
    if ([fromUser hasPrefix:@"gh_"]) return;      // official accounts
    if ([fromUser isEqualToString:@"weixin"]) return; // system

    NSMutableDictionary *msg = [NSMutableDictionary dictionary];
    msg[@"from"]    = fromUser;
    msg[@"to"]      = toUser ?: @"";
    msg[@"content"] = content ?: @"";
    msg[@"type"]    = @(msgType);
    msg[@"time"]    = @((long long)([[NSDate date] timeIntervalSince1970] * 1000));

    if (!gIncomingMsgs) gIncomingMsgs = [NSMutableArray array];
    [gIncomingMsgs addObject:msg];
    if (gIncomingMsgs.count > 200) [gIncomingMsgs removeObjectAtIndex:0];

    NSLog(@"[WCB] RECV from=%@ type=%lu: %.80s", fromUser, (unsigned long)msgType, [content UTF8String]);

    dispatch_async(dispatch_get_global_queue(0,0), ^{ PostToWebhook(msg); });
}

// ── Spy entry ──────────────────────────────────────────────────
static void AddSpy(NSString *method, NSString *info, NSString *chatUser) {
    NSLog(@"[WCB] SPY: %@ | %@ | chat=%@", method, info, chatUser);
    NSMutableDictionary *e = [NSMutableDictionary dictionary];
    e[@"method"] = method ?: @"?";
    e[@"info"] = info ?: @"";
    if (chatUser) e[@"chat_user"] = chatUser;
    if (!gSpyLog) gSpyLog = [NSMutableArray array];
    [gSpyLog addObject:e];
    if (gSpyLog.count > 50) [gSpyLog removeObjectAtIndex:0];
}

// ── Hook IMPs ─────────────────────────────────────────────────
static IMP orig_AsyncSendMessage = NULL;
static void hook_AsyncSendMessage(id self, SEL _cmd, NSString *text, id replyMsg, id ref, BOOL isPasted) {
    AddSpy([NSString stringWithFormat:@"%@.AsyncSendMessage:", NSStringFromClass([self class])],
           text ?: @"", gCurrentChatUser);
    if (orig_AsyncSendMessage) ((void(*)(id,SEL,NSString*,id,id,BOOL))orig_AsyncSendMessage)(self,_cmd,text,replyMsg,ref,isPasted);
}

static IMP orig_SendTextMessage_reply = NULL;
static void hook_SendTextMessage_reply(id self, SEL _cmd, NSString *text, id replyMsg, BOOL isPasted) {
    // Save current logic controller instance
    gCurrentLogicController = self;
    // Try to get current chat user
    @try {
        id contact = [self valueForKey:@"m_contact"]; id chatName = contact ? [contact valueForKey:@"m_nsUsrName"] : nil; if (chatName) gCurrentChatUser = [chatName description];
    } @catch(...) {}
    AddSpy([NSString stringWithFormat:@"%@.SendTextMessage:replyingMessage:isPasted:", NSStringFromClass([self class])],
           text ?: @"", gCurrentChatUser);
    if (orig_SendTextMessage_reply) ((void(*)(id,SEL,NSString*,id,BOOL))orig_SendTextMessage_reply)(self,_cmd,text,replyMsg,isPasted);
}

static IMP orig_SendTextMessage = NULL;
static void hook_SendTextMessage(id self, SEL _cmd, NSString *text) {
    gCurrentLogicController = self;
    @try { id _c=[self valueForKey:@"m_contact"]; id cn=_c?[_c valueForKey:@"m_nsUsrName"]:nil; if(cn) gCurrentChatUser=[cn description]; } @catch(...) {}
    AddSpy([NSString stringWithFormat:@"%@.SendTextMessage:", NSStringFromClass([self class])], text?:@"", gCurrentChatUser);
    if (orig_SendTextMessage) ((void(*)(id,SEL,NSString*))orig_SendTextMessage)(self,_cmd,text);
}

static IMP orig_sendMsg = NULL;
static void hook_sendMsg(id self, SEL _cmd, id wrap, NSString *to) {
    NSString *content = @"?";
    @try { content=[wrap valueForKey:@"m_nsContent"]?:@"(nil)"; } @catch(...) {}
    AddSpy([NSString stringWithFormat:@"%@.sendMsg:toContactUsrName:", NSStringFromClass([self class])],
           [NSString stringWithFormat:@"to=%@ content=%@", to, content], nil);
    if (orig_sendMsg) ((void(*)(id,SEL,id,NSString*))orig_sendMsg)(self,_cmd,wrap,to);
}

// Forward declarations
static NSString *GetSelfWxid(void);

// ── Receive hook ───────────────────────────────────────────────
static IMP orig_AsyncOnPreAddMsg = NULL;
static void hook_AsyncOnPreAddMsg(id self, SEL _cmd, id chat, id wrap) {
    @try {
        NSString   *fromUser = nil, *toUser = nil, *content = nil;
        NSUInteger  msgType  = 0;
        @try { id t=[wrap valueForKey:@"m_uiMessageType"]; if(t) msgType=[t unsignedIntegerValue]; } @catch(...) {}
        if (msgType == 0) { @try { id t=[wrap valueForKey:@"m_uiMsgType"]; if(t) msgType=[t unsignedIntegerValue]; } @catch(...) {} }
        if (msgType == 0) { @try { id t=[wrap valueForKey:@"m_nMsgType"]; if(t) msgType=[t unsignedIntegerValue]; } @catch(...) {} }
        @try { fromUser = [wrap valueForKey:@"m_nsFromUsr"];  } @catch(...) {}
        @try { toUser   = [wrap valueForKey:@"m_nsToUsr"];    } @catch(...) {}
        @try { content  = [wrap valueForKey:@"m_nsContent"];  } @catch(...) {}
        // Only capture incoming (not self-sent)
        NSString *me = GetSelfWxid();
        if ([fromUser isEqualToString:me]) {
            if (orig_AsyncOnPreAddMsg) ((void(*)(id,SEL,id,id))orig_AsyncOnPreAddMsg)(self,_cmd,chat,wrap);
            return;
        }
        AddIncoming(fromUser, toUser, content, msgType);
    } @catch(...) {}
    if (orig_AsyncOnPreAddMsg) ((void(*)(id,SEL,id,id))orig_AsyncOnPreAddMsg)(self,_cmd,chat,wrap);
}

// ── Install ────────────────────────────────────────────────────
static void TrySwizzle(Class cls, SEL sel, IMP newIMP, IMP *origOut) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { NSLog(@"[WCB] NOT FOUND: %@.%@", NSStringFromClass(cls), NSStringFromSelector(sel)); return; }
    IMP prev = method_setImplementation(m, newIMP);
    if (*origOut == NULL) *origOut = prev;
    NSString *entry = [NSString stringWithFormat:@"%@.%@", NSStringFromClass(cls), NSStringFromSelector(sel)];
    [gSwizzled addObject:entry];
    NSLog(@"[WCB] Swizzled: %@", entry);
}

static void InstallAllSwizzles(void) {
    gSwizzled = [NSMutableArray array];
    Class baseVC    = NSClassFromString(@"BaseMsgContentViewController");
    Class baseLogic = NSClassFromString(@"BaseMsgContentLogicController");
    Class cMsgMgr   = NSClassFromString(@"CMessageMgr");

    TrySwizzle(baseVC,    NSSelectorFromString(@"AsyncSendMessage:replyingMsg:referPartialInfo:isPasted:"), (IMP)hook_AsyncSendMessage,       &orig_AsyncSendMessage);
    TrySwizzle(baseLogic, NSSelectorFromString(@"SendTextMessage:replyingMessage:isPasted:"),              (IMP)hook_SendTextMessage_reply,    &orig_SendTextMessage_reply);
    TrySwizzle(baseLogic, NSSelectorFromString(@"SendTextMessage:"),                                       (IMP)hook_SendTextMessage,          &orig_SendTextMessage);
    TrySwizzle(cMsgMgr,   NSSelectorFromString(@"sendMsg:toContactUsrName:"),                             (IMP)hook_sendMsg,                  &orig_sendMsg);
    // Use only AsyncOnAddMsg (fires after message is added, not pre)
    TrySwizzle(cMsgMgr,   NSSelectorFromString(@"AsyncOnAddMsg:MsgWrap:"),                                (IMP)hook_AsyncOnPreAddMsg,         &orig_AsyncOnPreAddMsg);

    NSLog(@"[WCB] InstallAllSwizzles: %lu hooks", (unsigned long)gSwizzled.count);
}

// ── Send via WeixinContentLogicController ──────────────────────
// Find a logic controller for a specific chat user by scanning view hierarchy
static id FindLogicControllerForUser(NSString *targetUser) {
    // First check if current matches
    if (gCurrentLogicController) {
        @try {
            id _lc_contact = [gCurrentLogicController valueForKey:@"m_contact"]; id chatName = _lc_contact ? [_lc_contact valueForKey:@"m_nsUsrName"] : nil; if ([chatName isEqualToString:targetUser]) return gCurrentLogicController;
        } @catch(...) {}
    }
    return nil;
}

// Try to send via logic controller (best quality, no red exclamation)
static BOOL SendViaLogicController(NSString *toUser, NSString *text) {
    __block BOOL ok = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
        id lc = FindLogicControllerForUser(toUser);
        if (!lc) { NSLog(@"[WCB] No logic controller for %@", toUser); return; }
        SEL sendSel = NSSelectorFromString(@"SendTextMessage:replyingMessage:isPasted:");
        if ([lc respondsToSelector:sendSel]) {
            NSMethodSignature *sig = [lc methodSignatureForSelector:sendSel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.target = lc; inv.selector = sendSel;
            NSString * __unsafe_unretained textArg = text;
            [inv setArgument:&textArg atIndex:2];
            id __unsafe_unretained nilMsg = nil; [inv setArgument:&nilMsg atIndex:3];
            BOOL no = NO; [inv setArgument:&no atIndex:4];
            [inv invoke];
            ok = YES;
            NSLog(@"[WCB] Sent via LogicController to %@: %@", toUser, text);
        }
    });
    return ok;
}

// Fallback: CMessageMgr direct (may show red exclamation)
static id GetMsgMgr(void) {
    Class svc=NSClassFromString(@"MMServiceCenter"), mgr=NSClassFromString(@"CMessageMgr");
    if(!svc||!mgr) return nil;
    id c=[svc performSelector:@selector(defaultCenter)];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    return [c performSelector:@selector(getService:) withObject:mgr];
#pragma clang diagnostic pop
}

static NSString *GetSelfWxid(void) {
    // Try CContactMgr first
    Class cls=NSClassFromString(@"CContactMgr"); if(!cls) return @"your_wxid";  // fallback wxid
    SEL s=NSSelectorFromString(@"sharedInstance"); if(![cls respondsToSelector:s]) return @"your_wxid";  // fallback wxid
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id mgr=[cls performSelector:s];
    for (NSString *selName in @[@"getLocalUsrName",@"getSelfUsrName",@"selfUsrName"]) {
        SEL ws=NSSelectorFromString(selName);
        if(mgr&&[mgr respondsToSelector:ws]){NSString *x=[mgr performSelector:ws]; if(x.length) return x;}
    }
#pragma clang diagnostic pop
    return @"your_wxid";  // fallback wxid
}

static BOOL SendTextDirect(NSString *toUser, NSString *text) {
    __block BOOL ok=NO;
    dispatch_sync(dispatch_get_main_queue(),^{
        id mgr=GetMsgMgr(); if(!mgr) return;
        Class wc=NSClassFromString(@"CMessageWrap"); if(!wc) return;
        id wrap=[[wc alloc] init]; NSString *me=GetSelfWxid();
        SEL st=NSSelectorFromString(@"setM_uiMessageType:"), sc=NSSelectorFromString(@"setM_nsContent:"),
            su=NSSelectorFromString(@"setM_nsToUsr:"),   sf=NSSelectorFromString(@"setM_nsFromUsr:");
        if([wrap respondsToSelector:st]){
            NSMethodSignature *sig=[wrap methodSignatureForSelector:st];
            NSInvocation *inv=[NSInvocation invocationWithMethodSignature:sig];
            inv.target=wrap; inv.selector=st; NSUInteger t=1; [inv setArgument:&t atIndex:2]; [inv invoke];
        }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        if([wrap respondsToSelector:sc])[wrap performSelector:sc withObject:text];
        if([wrap respondsToSelector:su])[wrap performSelector:su withObject:toUser];
        if(me&&[wrap respondsToSelector:sf])[wrap performSelector:sf withObject:me];
        SEL send=NSSelectorFromString(@"sendMsg:toContactUsrName:");
        if([mgr respondsToSelector:send]){[mgr performSelector:send withObject:wrap withObject:toUser]; ok=YES;}
#pragma clang diagnostic pop
    });
    return ok;
}

static NSString *ExtractText(NSDictionary *b) {
    id m=b[@"message"];
    if([m isKindOfClass:[NSString class]]) return m;
    if([m isKindOfClass:[NSArray class]]){
        NSMutableString *r=[NSMutableString string];
        for(NSDictionary *s in m) if([s[@"type"] isEqualToString:@"text"]){NSString *t=s[@"data"][@"text"];if(t)[r appendString:t];}
        return r.length?r:nil;
    }
    return nil;
}

// ── Constructor ────────────────────────────────────────────────
%ctor {
    @autoreleasepool {
        if(![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.tencent.xin"]) return;
        dispatch_async(dispatch_get_main_queue(),^{ InstallAllSwizzles(); });

        gServer=[[WCHTTPServer alloc] initWithPort:58080];

        [gServer addRoute:@"/ping" handler:^(NSDictionary *b, void(^r)(NSInteger,NSDictionary*)) {
            r(200,@{@"status":@"ok",@"bridge":@"WeChatBridge/2.0",@"swizzled":gSwizzled?:@[],
                    @"current_chat":gCurrentChatUser?:@"(none)"});
        }];

        [gServer addRoute:@"/spy" handler:^(NSDictionary *b, void(^r)(NSInteger,NSDictionary*)) {
            r(200,@{@"log":gSpyLog?:@[], @"current_chat":gCurrentChatUser?:@"(none)"});
        }];

        [gServer addRoute:@"/swizzle_now" handler:^(NSDictionary *b, void(^r)(NSInteger,NSDictionary*)) {
            InstallAllSwizzles(); r(200,@{@"swizzled":gSwizzled?:@[]});
        }];

        [gServer addRoute:@"/inspect_lc" handler:^(NSDictionary *b, void(^r)(NSInteger,NSDictionary*)) {
            __block NSMutableDictionary *res = [NSMutableDictionary dictionary];
            dispatch_sync(dispatch_get_main_queue(), ^{
                id lc = gCurrentLogicController;
                if (!lc) { res[@"error"] = @"no logic controller"; return; }
                res[@"class"] = NSStringFromClass([lc class]);
                // Enumerate all properties
                NSMutableArray *props = [NSMutableArray array];
                Class cls = [lc class];
                while (cls && cls != [NSObject class]) {
                    unsigned int cnt = 0;
                    objc_property_t *ps = class_copyPropertyList(cls, &cnt);
                    for (unsigned int i = 0; i < cnt; i++) {
                        NSString *name = @(property_getName(ps[i]));
                        @try {
                            id val = [lc valueForKey:name];
                            NSString *valStr = val ? [[val description] substringToIndex:MIN(80u, (unsigned int)[[val description] length])] : @"(nil)";
                            if ([name.lowercaseString containsString:@"user"] ||
                                [name.lowercaseString containsString:@"name"] ||
                                [name.lowercaseString containsString:@"chat"] ||
                                [name.lowercaseString containsString:@"contact"] ||
                                [name.lowercaseString containsString:@"wxid"]) {
                                [props addObject:[NSString stringWithFormat:@"%@=%@", name, valStr]];
                            }
                        } @catch(...) {}
                    }
                    free(ps);
                    cls = [cls superclass];
                }
                res[@"user_related_props"] = props;
            });
            r(200, res);
        }];

        [gServer addRoute:@"/send_private_msg" handler:^(NSDictionary *b, void(^r)(NSInteger,NSDictionary*)) {
            NSString *uid=b[@"user_id"], *text=ExtractText(b);
            if(!uid||!text){r(400,@{@"status":@"error",@"msg":@"missing params"});return;}
            @try {
                // Try logic controller first (high quality), fallback to direct CMessageMgr
                BOOL ok = SendViaLogicController(uid, text);
                if (!ok) ok = SendTextDirect(uid, text);
                r(200,@{@"status":ok?@"ok":@"error", @"method": ok?(gCurrentLogicController?@"logic_controller":@"direct"):@"failed"});
            } @catch(NSException *e){r(500,@{@"status":@"error",@"msg":e.reason?:@"ex"});}
        }];

        [gServer addRoute:@"/send_group_msg" handler:^(NSDictionary *b, void(^r)(NSInteger,NSDictionary*)) {
            NSString *gid=b[@"group_id"], *text=ExtractText(b);
            if(!gid||!text){r(400,@{@"status":@"error",@"msg":@"missing params"});return;}
            @try {
                BOOL ok=SendViaLogicController(gid,text);
                if(!ok) ok=SendTextDirect(gid,text);
                r(200,@{@"status":ok?@"ok":@"error"});
            }@catch(NSException *e){r(500,@{@"status":@"error",@"msg":e.reason?:@"ex"});}
        }];

        [gServer addRoute:@"/recv" handler:^(NSDictionary *b, void(^r)(NSInteger,NSDictionary*)) {
            NSArray *msgs = [gIncomingMsgs copy];
            [gIncomingMsgs removeAllObjects];
            r(200, @{@"messages": msgs ?: @[], @"count": @(msgs.count)});
        }];

        [gServer addRoute:@"/set_webhook" handler:^(NSDictionary *b, void(^r)(NSInteger,NSDictionary*)) {
            NSString *url = b[@"url"];
            if (url.length) { gWebhookURL = url; r(200, @{@"status":@"ok", @"webhook":url}); }
            else            { gWebhookURL = nil;  r(200, @{@"status":@"ok", @"webhook":@"cleared"}); }
        }];

        [gServer addRoute:@"/wrap_setters" handler:^(NSDictionary *b, void(^r)(NSInteger,NSDictionary*)) {
            __block NSMutableArray *out=[NSMutableArray array];
            dispatch_sync(dispatch_get_main_queue(),^{
                Class wc=NSClassFromString(@"CMessageWrap"); if(!wc)return;
                unsigned int cnt=0; Method *ms=class_copyMethodList(wc,&cnt);
                for(unsigned int i=0;i<cnt;i++){
                    NSString *n=NSStringFromSelector(method_getName(ms[i]));
                    if([n hasPrefix:@"set"]||[n.lowercaseString containsString:@"content"]||[n.lowercaseString containsString:@"text"]||[n.lowercaseString containsString:@"msg"])[out addObject:n];
                }
                free(ms); [out sortUsingSelector:@selector(compare:)];
            });
            r(200,@{@"methods":out});
        }];

        [gServer start];
        NSLog(@"[WCB] v2.0 started on :58080");
    }
}
