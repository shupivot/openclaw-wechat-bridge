#import "WCHTTPServer.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>

@interface WCHTTPServer ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, WCHTTPHandler> *routes;
@property (nonatomic, assign) int serverFd;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, assign) BOOL running;
@end

@implementation WCHTTPServer

- (instancetype)initWithPort:(uint16_t)port {
    self = [super init];
    if (self) {
        _port = port;
        _serverFd = -1;
        _routes = [NSMutableDictionary new];
        _queue = dispatch_queue_create("com.pivot.wechatbridge.http", DISPATCH_QUEUE_CONCURRENT);
        _webhookURL = @"http://127.0.0.1:36060/wechat";
    }
    return self;
}

- (void)addRoute:(NSString *)path handler:(WCHTTPHandler)handler {
    _routes[path] = [handler copy];
}

- (void)start {
    _serverFd = socket(AF_INET, SOCK_STREAM, 0);
    if (_serverFd < 0) return;

    int yes = 1;
    setsockopt(_serverFd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_in addr = {0};
    addr.sin_family      = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY); // listen on all interfaces (LAN accessible)
    addr.sin_port        = htons(_port);

    if (bind(_serverFd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(_serverFd); _serverFd = -1; return;
    }
    if (listen(_serverFd, 10) < 0) {
        close(_serverFd); _serverFd = -1; return;
    }

    _running = YES;
    int fd = _serverFd;
    dispatch_async(_queue, ^{
        while (self.running) {
            int client = accept(fd, NULL, NULL);
            if (client < 0) continue;
            dispatch_async(self.queue, ^{
                [self handleClient:client];
            });
        }
    });

    NSLog(@"[WeChatBridge] HTTP server started on 0.0.0.0:%d", _port);
}

- (void)stop {
    _running = NO;
    if (_serverFd >= 0) { close(_serverFd); _serverFd = -1; }
}

- (void)handleClient:(int)client {
    // Read request (max 64KB)
    NSMutableData *data = [NSMutableData data];
    char buf[4096];
    ssize_t n;
    while ((n = recv(client, buf, sizeof(buf), 0)) > 0) {
        [data appendBytes:buf length:n];
        // Check if we have a complete HTTP request (headers + body)
        NSString *raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!raw) break;
        NSRange sep = [raw rangeOfString:@"\r\n\r\n"];
        if (sep.location == NSNotFound) continue;
        // Parse Content-Length to know if body is complete
        NSString *headers = [raw substringToIndex:sep.location];
        NSString *body    = [raw substringFromIndex:sep.location + 4];
        NSInteger contentLength = 0;
        for (NSString *line in [headers componentsSeparatedByString:@"\r\n"]) {
            if ([line.lowercaseString hasPrefix:@"content-length:"]) {
                contentLength = [[[line componentsSeparatedByString:@":"].lastObject stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] integerValue];
            }
        }
        if ((NSInteger)body.length >= contentLength) break;
    }

    NSString *raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!raw) { close(client); return; }

    // Parse method + path
    NSArray *lines = [raw componentsSeparatedByString:@"\r\n"];
    NSArray *requestLine = [lines[0] componentsSeparatedByString:@" "];
    if (requestLine.count < 2) { close(client); return; }
    __unused NSString *method = requestLine[0];
    NSString *path   = requestLine[1];

    // Get body
    NSRange sep = [raw rangeOfString:@"\r\n\r\n"];
    NSString *bodyStr = sep.location != NSNotFound ? [raw substringFromIndex:sep.location + 4] : @"";
    NSDictionary *bodyDict = nil;
    NSData *bodyData = [bodyStr dataUsingEncoding:NSUTF8StringEncoding];
    if (bodyData.length > 0) {
        bodyDict = [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:nil];
    }

    // Route
    WCHTTPHandler handler = _routes[path];

    if (!handler) {
        [self sendResponse:client status:404 json:@{@"status":@"not_found"}];
        return;
    }

    handler(bodyDict ?: @{}, ^(NSInteger status, NSDictionary *json) {
        [self sendResponse:client status:status json:json];
    });
}

- (void)sendResponse:(int)client status:(NSInteger)status json:(NSDictionary *)json {
    NSData *body = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
    NSString *header = [NSString stringWithFormat:
        @"HTTP/1.1 %ld OK\r\nContent-Type: application/json\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n",
        (long)status, (unsigned long)body.length];
    NSData *headerData = [header dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableData *response = [NSMutableData dataWithData:headerData];
    [response appendData:body];
    send(client, response.bytes, response.length, 0);
    close(client);
}

- (void)forwardReceivedMessage:(NSDictionary *)msg {
    if (!_webhookURL) return;
    NSData *body = [NSJSONSerialization dataWithJSONObject:msg options:0 error:nil];
    NSURL *url = [NSURL URLWithString:_webhookURL];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.HTTPBody = body;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSURLSession *session = [NSURLSession sharedSession];
    [[session dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        // fire and forget
    }] resume];
}

@end
