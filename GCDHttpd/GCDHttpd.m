//
//  GCDHttpd.m
//  GCDHttpd
//
//  Created by Zeng Ke on 13-1-16.
//  Copyright (c) 2013 zengke. All rights reserved.
//
#import <ifaddrs.h>
#import <arpa/inet.h>

#import "GCDHttpd.h"
#import "GCDRequest.h"

#import "NSData+Utils.h"
#import "NSString+QueryString.h"
#import "NSURL+IntactPath.h"
#import "GCDMultipart.h"

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#endif

static const long kTagWriteAndClose = 1000;

static const long kTagReadStatusLine = 1101;
static const long kTagReadHeaderLine = 1102;


static const long kTagReadPostContentLength = 1103;
static const long kTagReadMultipartBoundary = 1104;
//static const long kTagReadMultipartEndTest = 1105;
//static const long kTagReadMultipartHeader = 1106;

static const long kTagReadMultipartBody = 1110;

@implementation GCDHttpd {
    GCDAsyncSocket * _listenSocket;
    NSMutableArray * _roles;
    dispatch_queue_t _dispatchQueue;

    GCDAsyncSocket * _newAcceptSocket;
}

@synthesize netService=_netService;
@synthesize delegate, maxAgeOfCacheControl, maxBodyLength;
@synthesize port, interface, httpdState;

+ (NSArray *)interfaceList {
    struct ifaddrs *interfaces = NULL;
    struct ifaddrs *temp_addr = NULL;
    int success = 0;
    success = getifaddrs(&interfaces);
    NSMutableArray * arr = [[NSMutableArray alloc] init];
    if (success == 0) {
        // Loop through linked list of interfaces
        temp_addr = interfaces;
        while(temp_addr != NULL) {
            if(temp_addr->ifa_addr->sa_family == AF_INET) {
                NSString * interface = [NSString stringWithUTF8String:temp_addr->ifa_name];
                NSString * address = [NSString stringWithUTF8String:inet_ntoa(((struct sockaddr_in *)temp_addr->ifa_addr)->sin_addr)];
                NSDictionary * addrInfo = [NSDictionary dictionaryWithObjectsAndKeys:
                                           interface, @"interface",
                                           address, @"address",
                                           nil];
                [arr addObject:addrInfo];
            }
            temp_addr = temp_addr->ifa_next;
        }
    }
    // Free memory
    freeifaddrs(interfaces);
    return arr;
}

- (dispatch_queue_t)dispatchQueue {
    return _dispatchQueue;
}

- (id) initWithDispatchQueue:(dispatch_queue_t)queue {
    self = [super init];
    if (self) {
        _dispatchQueue = queue;
        _roles = [[NSMutableArray alloc] init];
        self.maxBodyLength = 4 * 1024 * 1024; // 4M bytes
        self.maxAgeOfCacheControl = 2; // 2 seconds
        self.port = 3000;
        self.interface = nil;

        self.httpdState = kHttpdStateInitialized;
    }
    return self;
}

- (void)start {
    _listenSocket = [[GCDAsyncSocket alloc] initWithDelegate:self delegateQueue:_dispatchQueue];
    NSError * error = nil;
    if (![_listenSocket acceptOnInterface:self.interface port:self.port error:&error]) {
        NSLog(@"Error on listen %@", [error description]);
        self.httpdState = kHttpdStateInError;
    } else {
        self.httpdState = kHttpdStateStarted;
        [self publishBonjour];
    }
}

- (void)stop {
    if (self.httpdState != kHttpdStateStarted) {
        NSLog(@"Weird http state %ld on httpdState", (long)self.httpdState);
    }
    [_listenSocket disconnect];
    self.httpdState = kHttpdStateStopped;
}


- (void)assertTrue:(BOOL)condition message:(NSString *)message {
    if (!condition) {
        NSDictionary * excInfo = [NSDictionary dictionaryWithObject:message forKey:@"description"];
        NSException * exception = [NSException exceptionWithName:@"GCDHttpd" reason:message userInfo:excInfo];
        //            NSError * except = [NSError errorWithDomain:@"MultipartError" code:1021 userInfo:errorInfo];
        //        NSLog(@"error %@ on multi part", error);
        @throw exception;
    }
}


- (void)___assertTrue:(BOOL)condition message:(NSString *)message {
    if (!condition) {
        NSDictionary * errorInfo = [NSDictionary dictionaryWithObject:message forKey:@"description"];
        NSError * error = [NSError errorWithDomain:@"GCDHttpd" code:1021 userInfo:errorInfo];
        @throw error;
    }
}

- (void)socket:(GCDAsyncSocket*)sock readLineWithTag:(long)tag {
    [sock readDataToData:[GCDAsyncSocket CRLFData] withTimeout:-1 tag:tag];
}

- (void)socket:(GCDAsyncSocket *)sock didAcceptNewSocket:(GCDAsyncSocket *)newSocket {
    GCDRequest * request = [[GCDRequest alloc] init];
    request.socket = newSocket;
    request.httpd = self;
    newSocket.userData = request;
    [self socket:newSocket readLineWithTag:kTagReadStatusLine];
  
    /* For some reaseon, with newer GCDAsyncSocket implementation, this gets deallocated too soon. I'm not even sure why it works with the old version (included with GCDHttpd), but this is needed to keep the socket around long enough to read any late-coming data */
    _newAcceptSocket = newSocket;
}

- (void)socket:(GCDAsyncSocket *)sock didWriteDataWithTag:(long)tag {
    if (tag == kTagWriteAndClose) {
        [sock disconnect];
    }
}

- (void)processMetaDataOfRequest:(GCDRequest*)request {
    // Handle Meta variables
    [request setMetaVariable:request.requestURL.query forKey:@"QUERY_STRING"];
    [request setMetaVariable:request.method forKey:@"METHOD"];
    
    // Parse Authorization
    NSString * auth = request.META[@"HTTP_AUTHORIZATION"];
    if (auth) {
        NSError * error;
        NSRegularExpression * regexp = [NSRegularExpression regularExpressionWithPattern:@"Basic ([a-zA-Z0-9\\+\\=/]+)" options:NSRegularExpressionCaseInsensitive error:&error];
        NSTextCheckingResult * match = [regexp firstMatchInString:auth options:0 range:NSMakeRange(0, auth.length)];
        if (match) {
            NSRange range = [match rangeAtIndex:1];
            NSData * base64EncodedAuth = [[auth substringWithRange:range] dataUsingEncoding:NSASCIIStringEncoding];
            NSData * userAndPass = [base64EncodedAuth base64Decode];
            NSString * userAndPassStr = [[NSString alloc] initWithData:userAndPass encoding:NSUTF8StringEncoding];
            NSArray * arr = [userAndPassStr componentsSeparatedByString:@":"];
            if (arr.count == 2) {
                [request setMetaVariable:[arr objectAtIndex:0] forKey:@"AUTH_USER"];
                [request setMetaVariable:[arr objectAtIndex:1] forKey:@"AUTH_PW"];
            }
        }
    }
}

/**
 * The big state machine to handle HTTP Request and Response
 */
- (void)socket:(GCDAsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag {
    [self socket:sock reallyReadData:data withTag:tag];
}

- (void)socket:(GCDAsyncSocket *)sock reallyReadData:(NSData *)data withTag:(long)tag {
    GCDRequest * request = (GCDRequest *)(sock.userData);
    if (tag > kTagReadHeaderLine) {
        request.readedBodyLength += data.length;
        if (request.readedBodyLength > self.maxBodyLength) {
            [self socket:sock httpErrorStatus:413 message:@"Entity Too Large\n"];
            return;
        }
    }
    if (tag == kTagReadStatusLine) {
        NSString * line = [[NSString alloc] initWithData:data encoding:NSASCIIStringEncoding];
        line = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSArray * parts = [line componentsSeparatedByString:@" "];
        [self assertTrue:(parts.count == 3) message:@"Bad status line"];
        request.method = [parts objectAtIndex:0];
        request.pathString = [parts objectAtIndex:1];
        [self socket:sock readLineWithTag:kTagReadHeaderLine];
    } else if (tag == kTagReadHeaderLine) {
        if (data.length > 2) {
            NSString * line = [[NSString alloc] initWithData:data encoding:NSASCIIStringEncoding];
            line = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            NSRange range = [line rangeOfString:@":"];
            NSString * key = [line substringToIndex:range.location];
            NSString * value = [[line substringFromIndex:NSMaxRange(range)] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            [request setMetaVariable:value forKey:key];
            [self socket:sock readLineWithTag:kTagReadHeaderLine];
        } else {
            // Empty lines
            // Handle Meta variables
            [self processMetaDataOfRequest:request];

            NSInteger contentLength = [request.META[@"CONTENT_LENGTH"] intValue];
            if (contentLength > 0 && contentLength > self.maxBodyLength) {
                [self socket:sock httpErrorStatus:413 message:@"Entity Too Large\n"];
                return; 
            }
            
            if (
                [request.method isEqualToString:@"GET"] ||
                [request.method isEqualToString:@"DELETE"]
                ) {
                [self socket:sock endParsingRequest:request];
            } else if(
                      [request.method isEqualToString:@"POST"] ||
                      [request.method isEqualToString:@"PUT"]
                      ) {
                if ([request isMultipart]){
                    NSString * boundary = [request multipartBoundaryWithPrefix:@"--"];
                    request.multipart = [[GCDMultipart alloc] initWithBundary:boundary];
                    
                    [self assertTrue:(boundary != nil) message:@"boundary is nil"];
                    [sock readDataWithTimeout:-1 tag:kTagReadMultipartBody];
                    return;
                }
                if (contentLength > 0) {
                    [sock readDataToLength:contentLength withTimeout:-1 tag:kTagReadPostContentLength];
                } else {
                    [self socket:sock endParsingRequest:request];
                }
            }
        }
    } else if (tag == kTagReadPostContentLength) {
        request.rawData = data;
        NSString * contentType = request.META[@"CONTENT_TYPE"];
        if ([contentType isEqualToString:@"application/x-www-form-urlencoded"]) {
             NSString * postBody = [[NSString alloc] initWithData:data encoding:NSASCIIStringEncoding];
            [request.POST setValuesForKeysWithDictionary:[postBody explodeToQueryDictionary]];
        } else if ([request isMultipart]){
            NSString * boundary = [request multipartBoundaryWithPrefix:@"--"];
            [self assertTrue:(boundary != nil) message:@"boundary is nil"];
            [sock readDataToData:[boundary dataUsingEncoding:NSASCIIStringEncoding] withTimeout:-1 tag:kTagReadMultipartBoundary];
            return;
        }
        [self socket:sock endParsingRequest:request];
    } else if (tag == kTagReadMultipartBody) {
        NSError * error;
        [request.multipart feed:data error:&error];
        if (error != nil) {
            [self socket:sock httpErrorStatus:400 message:@"Bad request\n"];
            return;
        }
        if (request.multipart.finished) {
            request.FILES = request.multipart.FILES;
            request.POST = request.multipart.POST;
            [self socket:sock endParsingRequest:request];
        } else {
            [sock readDataWithTimeout:-1 tag:kTagReadMultipartBody];
        }
    }
}

- (void)socket:(GCDAsyncSocket *)sock endParsingRequest:(GCDRequest *)request {
    NSString * path = request.requestURL.intactPath;
    for (GCDRouterRole * roleEntry in _roles) {
        NSDictionary * bindings = [roleEntry matchMethod:request.method path:path];
        if (bindings != nil) {
            request.pathBindings = bindings;
            request.selectedRouterRole = roleEntry;
            NSLog(@"%@ %@", request.method, request.pathString);
            if (self.delegate && [self.delegate respondsToSelector:@selector(willStartRequest:)]) {
                id response = [self.delegate willStartRequest:request];
                if (response != nil) {
                    [self socket:sock respond:response];
                    return;
                }
            }
            
            if (roleEntry.actionBlock) {
                id response = roleEntry.actionBlock(request);
                [self socket:sock respond:response];
                return;
            }
            else if (roleEntry.target) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                id response = [roleEntry.target performSelector:roleEntry.action withObject:request];
#pragma clang diagnostic pop
                [self socket:sock respond:response];
                return;
            }
        }
    }
    [self socket:sock httpErrorStatus:404 message:@"Object Not Found\n"];
}


- (void)socket:(GCDAsyncSocket * )sock writeString:(NSString *)str tag:(long)tag {
    [sock writeData:[str dataUsingEncoding:NSUTF8StringEncoding] withTimeout:-1 tag:tag];
}

- (void)socket:(GCDAsyncSocket * )sock writeString:(NSString *)str {
    [self socket:sock writeString:str tag:0];
}


- (void)socket:(GCDAsyncSocket *)sock respond:(id)response {
    GCDResponse * resp;
    GCDRequest * request = (GCDRequest*)sock.userData;
    NSData * payload = nil;
    if ([response isKindOfClass:[NSString class]]) {
        payload = [(NSString *)response dataUsingEncoding:NSUTF8StringEncoding];
        resp = [request responseWithContentLength:payload.length];
    } else if ([response isKindOfClass:[NSData class]]){
        payload = (NSData*)response;
        resp = [request responseWithContentLength:payload.length];
    } else {
        assert([response isKindOfClass:[GCDResponse class]]);
        resp = (GCDResponse *)response;
    }

    // If there is payload, just send them
    if (payload) {
        [resp sendData:payload];
        [resp finish];
    } else if (!resp.deferred) {
        [resp finish];
    }
}

- (void)socketDidDisconnect:(GCDAsyncSocket *)sock withError:(NSError *)err {
    NSLog(@"socket closed %@", err);
}

# pragma mark - GHResponseDelegate
- (void)responseBeginSendData:(GCDResponse *)response {
    GCDRequest * request = (GCDRequest *)(response.socket.userData);
    if(self.delegate && [self.delegate respondsToSelector:@selector(didFinishedRequest:withResponse:)]) {
        [self.delegate didFinishedRequest:request withResponse:response];
    }
    
    // Output headers
    NSString * statusLine = [NSString stringWithFormat:@"HTTP/1.1 %d %@\r\n", response.status, [GCDResponse statusBrief:response.status]];
    [self socket:response.socket writeString:statusLine];

    for(NSString * key in response.headers) {
        NSString * value = [response.headers objectForKey:key];
        NSString * headerLine = [NSString stringWithFormat:@"%@: %@\r\n", key, value];
        [self socket:response.socket writeString:headerLine];
    }
    [self socket:response.socket writeString:@"\r\n"];
}

- (void)responseWantToFinish:(GCDResponse *)response {
    if (response.chunked) {
        NSData * zero = [@"0\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
        [response.socket writeData:zero withTimeout:-1 tag:kTagWriteAndClose];
    } else {
        [response.socket writeData:[GCDAsyncSocket ZeroData] withTimeout:-1 tag:kTagWriteAndClose];
    }
    
    GCDRequest * request = (GCDRequest *)response.socket.userData;
    if(request) {
        //for (NSString * name in request.FILES) {
            //GCDFormPart * part = request.FILES[name];
            //[part close];
        //}
        request.FILES = nil;
    }
}

- (void)response:(GCDResponse *)response hasData:(NSData *)data {
    if (response.chunked) {
        NSMutableData * buffer = [[NSMutableData alloc] init];
        NSString * cntData = [NSString stringWithFormat:@"%lX\r\n", (unsigned long)data.length];
        NSData * cnt = [cntData dataUsingEncoding:NSUTF8StringEncoding];
        [buffer appendData:cnt];
        [buffer appendData:data];
        [buffer appendData:[GCDAsyncSocket CRLFData]];
        [response.socket writeData:buffer withTimeout:-1 tag:0];
    } else {
        [response.socket writeData:data withTimeout:-1 tag:0];
    }
}

- (GCDRouterRole *)addTarget:(id)target action:(SEL)action forMethod:(NSString *)method role:(NSString *)role  {
    GCDRouterRole * roleEntry = [[GCDRouterRole alloc] init];
    roleEntry.target = target;
    roleEntry.action = action;
    roleEntry.method = method;
    roleEntry.pathPattern = role;
    [_roles addObject:roleEntry];
    return roleEntry;
}

- (GCDRouterRole *)addRouteforMethod:(NSString *)method role:(NSString *)role withAction:(id (^)(GCDRequest *))actionBlock
{
    GCDRouterRole * roleEntry = [[GCDRouterRole alloc] init];
    roleEntry.actionBlock = actionBlock;
    roleEntry.method = method;
    roleEntry.pathPattern = role;
    [_roles addObject:roleEntry];
    return roleEntry;
}

+ (NSString * )contentTypeForExtension:(NSString * )extension {
    static NSDictionary * typeMap;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        typeMap = [NSDictionary dictionaryWithObjectsAndKeys:
                   @"text/html", @"html",
                   @"text/html", @"htm",
                   @"text/plain", @"txt",
                   @"text/javascript", @"js",
                   @"text/css", @"css",
                   @"image/icon", @"ico",
                   @"image/jpeg", @"jpg",
                   @"image/jpeg", @"jpeg",
                   @"image/gif", @"gif",
                   @"image/png", @"png",
                   @"audio/mp3", @"mp3",
                   @"audio/aac", @"aac",
                   @"video/mov", @"mov",
                   @"video/avi", @"avi",
                   @"application/json", @"json",
                   nil];
    });
    NSString * type = typeMap[[extension lowercaseString]];
    if (type == nil) {
        return @"application/octet-stream";
    }
    return type;
}

#pragma mark - Bonjour Publishing
- (void)publishBonjour
{
#if TARGET_OS_IPHONE
    NSString *deviceName = [[UIDevice currentDevice] name];
#else
    NSString *deviceName = [[NSHost currentHost] localizedName];
#endif
    NSString *bundleName = NSLocalizedString([[NSBundle mainBundle] infoDictionary][@"CFBundleDisplayName"],nil);
    
    if (_netService == nil)
    {
        _netService = [[NSNetService alloc] initWithDomain:@"" type:@"_http._tcp." name:[deviceName stringByAppendingFormat:@".%@",bundleName] port:self.port];
        _netService.delegate = self;
    }
    NSNetService *service = _netService;
    
    dispatch_block_t bonjourBlock = ^{
        [service removeFromRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        [service scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
        [service publish];
    };
    [[self class] startBonjourThreadIfNeeded];
    [[self class] performBonjourBlock:bonjourBlock];
}

- (void)unpublishBonjour
{
	if (_netService)
	{
		NSNetService *theNetService = _netService;
		dispatch_block_t bonjourBlock = ^{
			[theNetService stop];
		};
		[[self class] performBonjourBlock:bonjourBlock];
		_netService = nil;
	}
}

/**
 * Called when our bonjour service has been successfully published.
 * This method does nothing but output a log message telling us about the published service.
 **/
- (void)netServiceDidPublish:(NSNetService *)ns
{
	// Override me to do something here...
	//
	// Note: This method is invoked on our bonjour thread.
	NSLog(@"Bonjour Service Published: domain(%@) type(%@) name(%@)", [ns domain], [ns type], [ns name]);
}

/**
 * Called if our bonjour service failed to publish itself.
 * This method does nothing but output a log message telling us about the published service.
 **/
- (void)netService:(NSNetService *)ns didNotPublish:(NSDictionary *)errorDict
{
	// Override me to do something here...
	//
	// Note: This method in invoked on our bonjour thread.
	
	NSLog(@"Failed to Publish Service: domain(%@) type(%@) name(%@) - %@",
                [ns domain], [ns type], [ns name], errorDict);
}

#pragma mark - Class methods
static NSThread *bonjourThread;

+ (void)startBonjourThreadIfNeeded
{
	static dispatch_once_t predicate;
	dispatch_once(&predicate, ^{
		bonjourThread = [[NSThread alloc] initWithTarget:self
		                                        selector:@selector(bonjourThread)
		                                          object:nil];
		[bonjourThread start];
	});
}

+ (void)bonjourThread
{
	@autoreleasepool {
		// We can't run the run loop unless it has an associated input source or a timer.
		// So we'll just create a timer that will never fire - unless the server runs for 10,000 years.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
		[NSTimer scheduledTimerWithTimeInterval:[[NSDate distantFuture] timeIntervalSinceNow]
		                                 target:self
		                               selector:@selector(donothingatall:)
		                               userInfo:nil
		                                repeats:YES];
#pragma clang diagnostic pop
        
		[[NSRunLoop currentRunLoop] run];
	}
}

+ (void)executeBonjourBlock:(dispatch_block_t)block
{
	NSAssert([NSThread currentThread] == bonjourThread, @"Executed on incorrect thread");
	block();
}

+ (void)performBonjourBlock:(dispatch_block_t)block
{
	[self performSelector:@selector(executeBonjourBlock:)
	             onThread:bonjourThread
	           withObject:block
	        waitUntilDone:YES];
}

#pragma mark - static file hosting
- (void)serveDirectory:(NSString *)directory  forURLPrefix:(NSString *)prefix {
    NSString * staticRole = [NSString stringWithFormat:@"%@::path", prefix];
    GCDRouterRole * role = [self addTarget:self action:@selector(serveStaticFile:) forMethod:@"GET" role:staticRole];
    role.userData = directory;
}

- (id) serveStaticFile:(GCDRequest *)request {
    NSString * relativePath = request.pathBindings[@"path"];
    if (relativePath == nil || relativePath.length == 0) {
        relativePath = @"/";
    }
    if ([[relativePath substringFromIndex:relativePath.length-1] isEqualToString:@"/"]) {
        relativePath = [NSString stringWithFormat:@"%@index.html", relativePath];
    }
    
    NSString * directory = request.selectedRouterRole.userData;
    NSMutableArray * arr =  [NSMutableArray arrayWithArray:[directory componentsSeparatedByString:@"/"]];
    [arr addObjectsFromArray:[relativePath componentsSeparatedByString:@"/"]];
    NSString * absPath = [arr componentsJoinedByString:@"/"];
    NSFileManager * fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:absPath]) {
        return [request responseWithStatus:404 message:@"Object Not Found"];
    }

    NSData * data = [NSData dataWithContentsOfFile:absPath];
    GCDResponse * response = [request responseWithContentLength:data.length];
    [response.headers setObject:[NSString stringWithFormat:@"max-age=%d", self.maxAgeOfCacheControl] forKey:@"Cache-Control"];
    [response.headers setObject:[[self class] contentTypeForExtension:[absPath pathExtension]] forKey:@"Content-Type"];
    [response sendData:data];
    return response;
}

#pragma mark - resource in an bundle
- (void)serveResource:(NSString *)resource forRole:(NSString *)resourceRole {
    GCDRouterRole * role = [self addTarget:self action:@selector(serveResource:) forMethod:@"GET" role:resourceRole];
    role.userData = resource;
}

- (id)serveResource:(GCDRequest * )request {
    NSBundle * bundle = [NSBundle mainBundle];
    NSString * resource = request.selectedRouterRole.userData;
    NSURL * url = [bundle URLForResource:resource withExtension:nil];
    if (url == nil) {
        return [request responseWithStatus:404 message:@"Resource cannot be located\n"];
    }
    NSData * data = [NSData dataWithContentsOfURL:url];
    GCDResponse * response = [request responseWithContentLength:data.length];
    [response.headers setObject:[NSString stringWithFormat:@"max-age=%d", self.maxAgeOfCacheControl] forKey:@"Cache-Control"];
    [response.headers setObject:[[self class] contentTypeForExtension:[resource pathExtension]] forKey:@"Content-Type"];
    [response sendData:data];
    return response;
}

// Handlers
// error response
- (void)socket:(GCDAsyncSocket *)sock httpErrorStatus:(int32_t)status message:(NSString *)message {
    GCDRequest * request = (GCDRequest*)sock.userData;
    GCDResponse * response = [request responseWithStatus:status message:message];
    [self socket:sock respond:response];
}

@end
