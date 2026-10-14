// HOPE Dome Sim – Syphon bridge
// Created by Sonarkon – https://github.com/sonarkon/Dome-Sim – MIT License
//
// Connects Syphon (macOS) with the HOPE Dome Sim running in the browser:
//   • Syphon server  →  browser   (JPEG frames over WebSocket, slots 0–7)
//   • browser        →  Syphon    (raw BGRA frames over WebSocket, published as Syphon servers)
//   • also serves index.html (http://localhost:8766)
//
// Syphon.framework is loaded at runtime (e.g. from an installed app such as Millumin);
// nothing is bundled. Binds to 127.0.0.1 only and accepts only localhost origins.
// Syphon is © the Syphon contributors, BSD 2-clause licence: https://github.com/Syphon/Syphon-Framework
//
// Build:  ./build.sh      Run:  ./syphon-bridge [--port 8766] [--root ..] [--framework /path/Syphon.framework]

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <CommonCrypto/CommonDigest.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <pthread.h>

/* ───── minimale Deklarationen der Syphon-API (Syphon 5, Metal) ───── */
@protocol SYClient <NSObject>
- (instancetype)initWithServerDescription:(NSDictionary *)description device:(id<MTLDevice>)device
                                  options:(nullable NSDictionary *)options newFrameHandler:(nullable void (^)(id client))handler;
- (nullable id<MTLTexture>)newFrameImage;
- (void)stop;
@end
@protocol SYServer <NSObject>
- (nullable instancetype)initWithName:(nullable NSString *)name device:(id<MTLDevice>)device options:(nullable NSDictionary *)options;
- (void)publishFrameTexture:(id<MTLTexture>)texture onCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                imageRegion:(NSRect)region flipped:(BOOL)isFlipped;
- (void)stop;
@property (readonly) BOOL hasClients;
@property (readonly) NSDictionary *serverDescription;
@end
@protocol SYDirectoryClass <NSObject>
+ (id)sharedDirectory;
@end
@protocol SYDirectory <NSObject>
@property (readonly) NSArray *servers;
@end

static id<MTLDevice> gDevice;
static id<MTLCommandQueue> gQueue;
static CIContext *gCI;
static CGColorSpaceRef gSRGB;
static Class gClientClass, gServerClass;
static id<SYDirectory> gDirectory;
static NSString *gRoot;
static int gPort = 8766;
static dispatch_queue_t gEncodeQueue;
static NSMutableArray *gConns;
static NSData *gLastServerList;

/* ───── Verbindungen ───── */
@interface Sub : NSObject
@property id<SYClient> client;
@property int slot, maxWidth;
@property double minInterval;
@property double last;
@property int origW, origH;
@property (atomic) int busy;
@end
@implementation Sub @end

@interface Conn : NSObject
@property int fd;
@property (atomic) BOOL alive;
@property NSLock *sendLock;
@property NSMutableDictionary<NSNumber *, Sub *> *subs;
@property NSMutableDictionary<NSNumber *, id<SYServer>> *outs;
@property NSMutableDictionary<NSNumber *, id<MTLTexture>> *outTex;
@end
@implementation Conn @end

static BOOL writeAll(int fd, const void *buf, size_t n) {
    const uint8_t *p = buf;
    while (n) { ssize_t w = send(fd, p, n, 0); if (w <= 0) return NO; p += w; n -= w; }
    return YES;
}
static BOOL readAll(int fd, void *buf, size_t n) {
    uint8_t *p = buf;
    while (n) { ssize_t r = recv(fd, p, n, 0); if (r <= 0) return NO; p += r; n -= r; }
    return YES;
}
static BOOL wsSend(Conn *c, int opcode, const void *data, size_t len) {
    if (!c.alive) return NO;
    uint8_t hdr[10]; size_t hl = 0;
    hdr[hl++] = 0x80 | opcode;
    if (len < 126) hdr[hl++] = (uint8_t)len;
    else if (len <= 0xFFFF) { hdr[hl++] = 126; hdr[hl++] = len >> 8; hdr[hl++] = len & 0xFF; }
    else { hdr[hl++] = 127; for (int i = 7; i >= 0; i--) hdr[hl++] = (uint8_t)((uint64_t)len >> (8 * i)); }
    [c.sendLock lock];
    BOOL ok = writeAll(c.fd, hdr, hl) && (len == 0 || writeAll(c.fd, data, len));
    [c.sendLock unlock];
    if (!ok) c.alive = NO;
    return ok;
}
static void sendJSON(Conn *c, NSDictionary *d) {
    NSData *j = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
    if (j) wsSend(c, 1, j.bytes, j.length);
}

/* ───── Server-Liste ───── */
static NSArray *currentServerList(void) {
    NSMutableSet *own = [NSMutableSet set];
    @synchronized (gConns) {
        for (Conn *c in gConns) for (id<SYServer> o in c.outs.allValues) { NSString *u = o.serverDescription[@"SyphonServerDescriptionUUIDKey"]; if (u) [own addObject:u]; }
    }
    NSMutableArray *list = [NSMutableArray array];
    for (NSDictionary *s in gDirectory.servers) {
        NSString *uuid = s[@"SyphonServerDescriptionUUIDKey"], *name = s[@"SyphonServerDescriptionNameKey"], *app = s[@"SyphonServerDescriptionAppNameKey"];
        if (![uuid isKindOfClass:NSString.class] || [own containsObject:uuid]) continue;
        [list addObject:@{ @"uuid": uuid, @"name": [name isKindOfClass:NSString.class] ? name : @"", @"app": [app isKindOfClass:NSString.class] ? app : @"" }];
    }
    return list;
}
static NSDictionary *descriptionForUUID(NSString *uuid) {
    for (NSDictionary *s in gDirectory.servers) if ([s[@"SyphonServerDescriptionUUIDKey"] isEqual:uuid]) return s;
    return nil;
}
static void broadcastServers(BOOL force) {
    NSData *j = [NSJSONSerialization dataWithJSONObject:@{ @"type": @"servers", @"servers": currentServerList() } options:NSJSONWritingSortedKeys error:nil];
    if (!force && [j isEqualToData:gLastServerList]) return;
    gLastServerList = j;
    NSArray *cs; @synchronized (gConns) { cs = [gConns copy]; }
    for (Conn *c in cs) wsSend(c, 1, j.bytes, j.length);
}

/* ───── Syphon → Browser ───── */
static void stopSub(Sub *s) { [s.client stop]; s.client = nil; }
static void encodeAndSend(Conn *c, Sub *sub) {
    @autoreleasepool {
        id<MTLTexture> tex = [sub.client newFrameImage];
        if (!tex || !c.alive) return;
        int w = (int)tex.width, h = (int)tex.height;
        if (w != sub.origW || h != sub.origH) {
            sub.origW = w; sub.origH = h;
            sendJSON(c, @{ @"type": @"info", @"slot": @(sub.slot), @"w": @(w), @"h": @(h) });
        }
        CIImage *img = [CIImage imageWithMTLTexture:tex options:@{ kCIImageColorSpace: (__bridge id)gSRGB }];
        if (!img) return;
        if (sub.maxWidth > 0 && w > sub.maxWidth) {
            CGFloat k = (CGFloat)sub.maxWidth / w;
            img = [img imageByApplyingTransform:CGAffineTransformMakeScale(k, k)];
        }
        NSData *jpg = [gCI JPEGRepresentationOfImage:img colorSpace:gSRGB
                                             options:@{ (__bridge id)kCGImageDestinationLossyCompressionQuality: @0.82 }];
        if (!jpg) return;
        NSMutableData *msg = [NSMutableData dataWithCapacity:jpg.length + 1];
        uint8_t slot = (uint8_t)sub.slot;
        [msg appendBytes:&slot length:1];
        [msg appendData:jpg];
        wsSend(c, 2, msg.bytes, msg.length);
    }
}
static void subscribe(Conn *c, int slot, NSString *uuid, int maxW, double fps) {
    Sub *old = c.subs[@(slot)];
    if (old) { stopSub(old); [c.subs removeObjectForKey:@(slot)]; }
    NSDictionary *desc = descriptionForUUID(uuid);
    if (!desc) { sendJSON(c, @{ @"type": @"error", @"slot": @(slot), @"code": @"server_not_found", @"message": @"Syphon server not found" }); return; }
    Sub *sub = [Sub new];
    sub.slot = slot; sub.maxWidth = maxW; sub.minInterval = 1.0 / MAX(5.0, MIN(fps, 120.0));
    __weak Conn *wc = c;
    __weak Sub *ws = sub;
    id<SYClient> cl = [(id<SYClient>)[gClientClass alloc] initWithServerDescription:desc device:gDevice options:nil newFrameHandler:^(id client) {
        Conn *cc = wc; Sub *ss = ws;
        if (!cc || !ss || !cc.alive) return;
        double now = CFAbsoluteTimeGetCurrent();
        if (now - ss.last < ss.minInterval) return;
        if (ss.busy) return;
        ss.busy = 1; ss.last = now;
        dispatch_async(gEncodeQueue, ^{ encodeAndSend(cc, ss); ss.busy = 0; });
    }];
    if (!cl) { sendJSON(c, @{ @"type": @"error", @"slot": @(slot), @"code": @"client_failed", @"message": @"Client could not be created" }); return; }
    sub.client = cl;
    c.subs[@(slot)] = sub;
    sendJSON(c, @{ @"type": @"subscribed", @"slot": @(slot) });
}

/* ───── Browser → Syphon ───── */
static void outStart(Conn *c, int oid, NSString *name) {
    id<SYServer> old = c.outs[@(oid)];
    if (old) { [old stop]; [c.outs removeObjectForKey:@(oid)]; [c.outTex removeObjectForKey:@(oid)]; }
    id<SYServer> sv = [(id<SYServer>)[gServerClass alloc] initWithName:name.length ? name : @"HOPE Dome Sim" device:gDevice options:nil];
    if (!sv) { sendJSON(c, @{ @"type": @"error", @"code": @"server_create_failed", @"message": @"Syphon server could not be created" }); return; }
    c.outs[@(oid)] = sv;
    sendJSON(c, @{ @"type": @"out", @"id": @(oid), @"active": @YES });
    broadcastServers(NO);
}
static void outStop(Conn *c, int oid) {
    id<SYServer> old = c.outs[@(oid)];
    if (old) { [old stop]; [c.outs removeObjectForKey:@(oid)]; [c.outTex removeObjectForKey:@(oid)]; }
    sendJSON(c, @{ @"type": @"out", @"id": @(oid), @"active": @NO });
}
// Frame: uint32 id, uint32 w, uint32 h (little endian), danach w*h*4 Byte BGRA (oberste Zeile = unterste im Bild, GL-Reihenfolge)
static void outFrame(Conn *c, const uint8_t *data, size_t len) {
    if (len < 12) return;
    uint32_t oid, w, h; memcpy(&oid, data, 4); memcpy(&w, data + 4, 4); memcpy(&h, data + 8, 4);
    id<SYServer> sv = c.outs[@(oid)];
    if (!sv || w < 1 || h < 1 || w > 8192 || h > 8192 || len < 12 + (size_t)w * h * 4) return;
    @autoreleasepool {
        id<MTLTexture> tex = c.outTex[@(oid)];
        if (!tex || tex.width != w || tex.height != h) {
            MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
            d.usage = MTLTextureUsageShaderRead; d.storageMode = MTLStorageModeShared;
            tex = [gDevice newTextureWithDescriptor:d];
            c.outTex[@(oid)] = tex;
        }
        [tex replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:data + 12 bytesPerRow:(NSUInteger)w * 4];
        id<MTLCommandBuffer> cb = [gQueue commandBuffer];
        [sv publishFrameTexture:tex onCommandBuffer:cb imageRegion:NSMakeRect(0, 0, w, h) flipped:NO];
        [cb commit];
    }
}

/* ───── WebSocket / HTTP ───── */
static void handleText(Conn *c, NSData *d) {
    NSDictionary *m = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    if (![m isKindOfClass:NSDictionary.class]) return;
    NSString *cmd = m[@"cmd"];
    dispatch_sync(dispatch_get_main_queue(), ^{   // Syphon-Verzeichnis/-Objekte auf dem Main-Thread anfassen
        if ([cmd isEqual:@"list"]) broadcastServers(YES);
        else if ([cmd isEqual:@"subscribe"]) subscribe(c, [m[@"slot"] intValue], m[@"uuid"], [m[@"maxWidth"] intValue], m[@"fps"] ? [m[@"fps"] doubleValue] : 30.0);
        else if ([cmd isEqual:@"unsubscribe"]) { Sub *s = c.subs[m[@"slot"]]; if (s) { stopSub(s); [c.subs removeObjectForKey:m[@"slot"]]; } }
        else if ([cmd isEqual:@"out_start"]) outStart(c, [m[@"id"] intValue], m[@"name"]);
        else if ([cmd isEqual:@"out_stop"]) outStop(c, [m[@"id"] intValue]);
    });
}
static NSString *mimeFor(NSString *p) {
    NSString *e = p.pathExtension.lowercaseString;
    NSDictionary *t = @{ @"html": @"text/html; charset=utf-8", @"js": @"text/javascript", @"css": @"text/css", @"json": @"application/json",
                         @"md": @"text/markdown; charset=utf-8", @"png": @"image/png", @"svg": @"image/svg+xml" };
    return t[e] ?: @"application/octet-stream";
}
static void httpReply(int fd, int code, NSString *status, NSString *type, NSData *body) {
    NSString *h = [NSString stringWithFormat:@"HTTP/1.1 %d %@\r\nContent-Type: %@\r\nContent-Length: %lu\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n",
                   code, status, type, (unsigned long)body.length];
    NSData *hd = [h dataUsingEncoding:NSUTF8StringEncoding];
    writeAll(fd, hd.bytes, hd.length);
    if (body.length) writeAll(fd, body.bytes, body.length);
}
static NSString *originHostOK(NSString *origin) {
    if (!origin.length) return @"";
    NSURL *u = [NSURL URLWithString:origin];
    NSString *host = u.host.lowercaseString;
    return ([host isEqual:@"localhost"] || [host isEqual:@"127.0.0.1"] || [host isEqual:@"[::1]"] || [host isEqual:@"::1"]) ? @"" : nil;
}
static void *connThread(void *arg) {
    @autoreleasepool {
        int fd = (int)(intptr_t)arg;
        int one = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        // Request lesen
        NSMutableData *req = [NSMutableData data];
        uint8_t b;
        while (req.length < 16384) {
            if (recv(fd, &b, 1, 0) <= 0) { close(fd); return NULL; }
            [req appendBytes:&b length:1];
            if (req.length >= 4 && memcmp((const char *)req.bytes + req.length - 4, "\r\n\r\n", 4) == 0) break;
        }
        NSString *text = [[NSString alloc] initWithData:req encoding:NSUTF8StringEncoding];
        NSArray *lines = [text componentsSeparatedByString:@"\r\n"];
        NSArray *first = [lines.firstObject componentsSeparatedByString:@" "];
        if (first.count < 2) { close(fd); return NULL; }
        NSString *path = first[1];
        NSMutableDictionary *hdr = [NSMutableDictionary dictionary];
        for (NSString *l in lines) {
            NSRange r = [l rangeOfString:@":"];
            if (r.location != NSNotFound && r.location > 0) hdr[[l substringToIndex:r.location].lowercaseString] = [[l substringFromIndex:r.location + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        }
        BOOL isWS = [[hdr[@"upgrade"] lowercaseString] isEqual:@"websocket"];
        if (!isWS) {   // statische Dateien
            if ([path containsString:@".."] || ![first[0] isEqual:@"GET"]) { httpReply(fd, 400, @"Bad Request", @"text/plain", [NSData data]); close(fd); return NULL; }
            NSString *rel = [path componentsSeparatedByString:@"?"].firstObject;
            if ([rel isEqual:@"/"]) rel = @"/index.html";
            NSData *body = [NSData dataWithContentsOfFile:[gRoot stringByAppendingString:rel.stringByRemovingPercentEncoding]];
            if (body) httpReply(fd, 200, @"OK", mimeFor(rel), body); else httpReply(fd, 404, @"Not Found", @"text/plain", [@"404" dataUsingEncoding:NSUTF8StringEncoding]);
            close(fd); return NULL;
        }
        if (originHostOK(hdr[@"origin"]) == nil || !hdr[@"sec-websocket-key"]) { httpReply(fd, 403, @"Forbidden", @"text/plain", [NSData data]); close(fd); return NULL; }
        // Handshake
        NSString *key = [hdr[@"sec-websocket-key"] stringByAppendingString:@"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"];
        NSData *kd = [key dataUsingEncoding:NSUTF8StringEncoding];
        uint8_t sha[CC_SHA1_DIGEST_LENGTH]; CC_SHA1(kd.bytes, (CC_LONG)kd.length, sha);
        NSString *acc = [[NSData dataWithBytes:sha length:sizeof sha] base64EncodedStringWithOptions:0];
        NSString *resp = [NSString stringWithFormat:@"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %@\r\n\r\n", acc];
        NSData *rd = [resp dataUsingEncoding:NSUTF8StringEncoding];
        writeAll(fd, rd.bytes, rd.length);

        Conn *c = [Conn new];
        c.fd = fd; c.alive = YES; c.sendLock = [NSLock new]; c.subs = [NSMutableDictionary dictionary]; c.outs = [NSMutableDictionary dictionary]; c.outTex = [NSMutableDictionary dictionary];
        @synchronized (gConns) { [gConns addObject:c]; }
        dispatch_async(dispatch_get_main_queue(), ^{ broadcastServers(YES); });

        NSMutableData *msg = [NSMutableData data]; int msgOp = 0;
        while (c.alive) {
            uint8_t h2[2];
            if (!readAll(fd, h2, 2)) break;
            int fin = h2[0] & 0x80, op = h2[0] & 0x0F, masked = h2[1] & 0x80;
            uint64_t len = h2[1] & 0x7F;
            if (len == 126) { uint8_t e[2]; if (!readAll(fd, e, 2)) break; len = (e[0] << 8) | e[1]; }
            else if (len == 127) { uint8_t e[8]; if (!readAll(fd, e, 8)) break; len = 0; for (int i = 0; i < 8; i++) len = (len << 8) | e[i]; }
            if (len > (160u << 20)) break;
            uint8_t mask[4] = {0};
            if (masked && !readAll(fd, mask, 4)) break;
            NSMutableData *pl = [NSMutableData dataWithLength:(NSUInteger)len];
            if (len && !readAll(fd, pl.mutableBytes, (size_t)len)) break;
            if (masked) { uint8_t *p = pl.mutableBytes; for (uint64_t i = 0; i < len; i++) p[i] ^= mask[i & 3]; }
            if (op == 8) break;
            if (op == 9) { wsSend(c, 10, pl.bytes, pl.length); continue; }
            if (op == 10) continue;
            if (op == 1 || op == 2) { [msg setLength:0]; msgOp = op; }
            [msg appendData:pl];
            if (fin) {
                @autoreleasepool {
                    if (msgOp == 1) handleText(c, msg);
                    else outFrame(c, msg.bytes, msg.length);
                }
                [msg setLength:0];
            }
        }
        c.alive = NO;
        @synchronized (gConns) { [gConns removeObject:c]; }
        dispatch_sync(dispatch_get_main_queue(), ^{
            for (Sub *s in c.subs.allValues) stopSub(s);
            [c.subs removeAllObjects];
            for (id<SYServer> o in c.outs.allValues) [o stop];
            [c.outs removeAllObjects];
        });
        close(fd);
    }
    return NULL;
}
static void *acceptThread(void *arg) {
    int srv = (int)(intptr_t)arg;
    for (;;) {
        int fd = accept(srv, NULL, NULL);
        if (fd < 0) continue;
        pthread_t t; pthread_attr_t a; pthread_attr_init(&a); pthread_attr_setdetachstate(&a, PTHREAD_CREATE_DETACHED);
        pthread_create(&t, &a, connThread, (void *)(intptr_t)fd);
    }
    return NULL;
}

/* ───── Start ───── */
static NSString *findFramework(NSString *explicit) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray *cands = [NSMutableArray array];
    if (explicit) [cands addObject:explicit];
    NSString *env = NSProcessInfo.processInfo.environment[@"SYPHON_FRAMEWORK"]; if (env) [cands addObject:env];
    [cands addObject:[[NSBundle mainBundle].executablePath.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"Syphon.framework"]];
    [cands addObject:@"/Library/Frameworks/Syphon.framework"];
    [cands addObject:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Frameworks/Syphon.framework"]];
    for (NSString *dir in @[@"/Applications", [NSHomeDirectory() stringByAppendingPathComponent:@"Applications"]])
        for (NSString *app in [fm contentsOfDirectoryAtPath:dir error:nil])
            if ([app hasSuffix:@".app"]) [cands addObject:[NSString stringWithFormat:@"%@/%@/Contents/Frameworks/Syphon.framework", dir, app]];
    for (NSString *p in cands) if ([fm fileExistsAtPath:p]) {
        NSBundle *b = [NSBundle bundleWithPath:p];
        if (b && [b load] && NSClassFromString(@"SyphonMetalClient") && NSClassFromString(@"SyphonMetalServer") && NSClassFromString(@"SyphonServerDirectory")) return p;
    }
    return nil;
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *fw = nil;
        gRoot = nil;
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--port") && i + 1 < argc) gPort = atoi(argv[++i]);
            else if (!strcmp(argv[i], "--root") && i + 1 < argc) gRoot = [NSString stringWithUTF8String:argv[++i]];
            else if (!strcmp(argv[i], "--framework") && i + 1 < argc) fw = [NSString stringWithUTF8String:argv[++i]];
        }
        if (!gRoot) gRoot = [NSBundle mainBundle].executablePath.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
        gRoot = gRoot.stringByStandardizingPath;
        setvbuf(stdout, NULL, _IOLBF, 0);

        NSString *used = findFramework(fw);
        if (!used) {
            fprintf(stderr, "No Syphon.framework found.\n"
                    "Put one next to this program, set SYPHON_FRAMEWORK=/path/Syphon.framework,\n"
                    "or install an app that ships it (e.g. Millumin, Resolume, VDMX).\n");
            return 1;
        }
        gClientClass = NSClassFromString(@"SyphonMetalClient");
        gServerClass = NSClassFromString(@"SyphonMetalServer");
        gDevice = MTLCreateSystemDefaultDevice();
        if (!gDevice) { fprintf(stderr, "No Metal device.\n"); return 1; }
        gQueue = [gDevice newCommandQueue];
        gCI = [CIContext contextWithMTLDevice:gDevice];
        gSRGB = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        gEncodeQueue = dispatch_queue_create("syphon.encode", DISPATCH_QUEUE_CONCURRENT);
        gConns = [NSMutableArray array];
        gDirectory = [(Class<SYDirectoryClass>)NSClassFromString(@"SyphonServerDirectory") sharedDirectory];

        int srv = socket(AF_INET, SOCK_STREAM, 0);
        int one = 1; setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
        struct sockaddr_in a = { .sin_len = sizeof a, .sin_family = AF_INET, .sin_port = htons(gPort), .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
        if (bind(srv, (struct sockaddr *)&a, sizeof a) != 0 || listen(srv, 16) != 0) { perror("bind/listen"); return 1; }
        pthread_t t; pthread_attr_t at; pthread_attr_init(&at); pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
        pthread_create(&t, &at, acceptThread, (void *)(intptr_t)srv);

        printf("HOPE Dome Sim – Syphon bridge running.\n  Framework: %s\n  Page:      http://localhost:%d\n  Folder:    %s\n", used.UTF8String, gPort, gRoot.UTF8String);
        [NSTimer scheduledTimerWithTimeInterval:0.8 repeats:YES block:^(NSTimer *tm) { broadcastServers(NO); }];
        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}
