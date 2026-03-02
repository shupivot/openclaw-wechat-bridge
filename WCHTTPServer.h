#pragma once
#import <Foundation/Foundation.h>

typedef void (^WCHTTPHandler)(NSDictionary *body, void (^respond)(NSInteger status, NSDictionary *json));

@interface WCHTTPServer : NSObject

@property (nonatomic, assign) uint16_t port;
@property (nonatomic, copy)   NSString *webhookURL; // where to POST received messages

- (instancetype)initWithPort:(uint16_t)port;
- (void)addRoute:(NSString *)path handler:(WCHTTPHandler)handler;
- (void)start;
- (void)stop;

// Call this when WeChat receives a message to forward to OpenClaw
- (void)forwardReceivedMessage:(NSDictionary *)msg;

@end
