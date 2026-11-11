// iOS side of Orchard's shared provider host.
//
// Mirrors mobile/android/app/src/main/cpp/js/provider_jni.cpp: the host lives on one
// thread with an 8 MiB stack; fetches, timers and settlements are delivered back on
// that thread. Networking uses NSURLSession with cookies left manual, because the
// provider signs the exact cookie snapshot it sends.

#import "OrchardEngine.h"

#include <cstdint>
#include <memory>
#include <string>
#include <unordered_map>

#include "provider_host/provider_host.h"

extern "C" char *orchard_youtube_extract(const uint8_t *source, size_t length);
extern "C" void orchard_youtube_extract_free(char *result);

namespace {

using orchard::provider::FetchRequest;
using orchard::provider::FetchResponse;
using orchard::provider::ProviderHost;

constexpr size_t kHostStackSize = 8 * 1024 * 1024;
constexpr size_t kPlayerCacheLimit = 8 * 1024 * 1024;

std::string toStd(NSString *value) {
  if (!value) return {};
  const char *utf8 = value.UTF8String;
  return utf8 ? std::string(utf8) : std::string();
}

NSString *toNS(const std::string &value) {
  NSString *text = [[NSString alloc] initWithBytes:value.data()
                                            length:value.size()
                                          encoding:NSUTF8StringEncoding];
  return text ?: @"";
}

NSURL *playerCacheURL() {
  NSURL *caches = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory
                                                       inDomains:NSUserDomainMask].firstObject;
  return [caches URLByAppendingPathComponent:@"youtube-player-cache.json"];
}

}  // namespace

@class OrchardEngine;

@interface OrchardEngine ()
- (void)performOnHost:(dispatch_block_t)block;
- (void)deliverFetch:(uint64_t)fetchId response:(FetchResponse)response;
- (void)fireTimer:(int)timerId;
@end

namespace {

// The Platform contract from core/native/provider_host/provider_host.h.
// Every method here runs on the host thread.
class IOSPlatform final : public orchard::provider::Platform {
public:
  explicit IOSPlatform(OrchardEngine *engine) : m_engine(engine) {}

  NSURLSession *session() {
    if (!m_session) {
      NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
      config.HTTPCookieStorage = nil;
      config.HTTPShouldSetCookies = NO;
      config.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyNever;
      config.URLCache = nil;
      config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
      config.timeoutIntervalForRequest = 30;
      config.timeoutIntervalForResource = 90;
      config.HTTPMaximumConnectionsPerHost = 6;
      m_session = [NSURLSession sessionWithConfiguration:config];
    }
    return m_session;
  }

  void fetch(FetchRequest request) override {
    NSURL *url = [NSURL URLWithString:toNS(request.url)];
    const uint64_t fetchId = request.id;
    __weak OrchardEngine *engine = m_engine;
    if (!url) {
      FetchResponse failed;
      failed.status = 0;
      failed.error = "Invalid URL";
      failed.url = request.url;
      [m_engine deliverFetch:fetchId response:failed];
      return;
    }
    NSMutableURLRequest *urlRequest = [NSMutableURLRequest requestWithURL:url];
    urlRequest.HTTPMethod = request.method.empty() ? @"GET" : toNS(request.method);
    urlRequest.HTTPShouldHandleCookies = NO;
    for (const auto &header : request.headers) {
      [urlRequest addValue:toNS(header.second) forHTTPHeaderField:toNS(header.first)];
    }
    if (!request.body.empty()) {
      urlRequest.HTTPBody = [NSData dataWithBytes:request.body.data() length:request.body.size()];
    }
    const std::string originalUrl = request.url;

    NSURLSessionDataTask *task = [session() dataTaskWithRequest:urlRequest
                                              completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
      FetchResponse result;
      result.url = originalUrl;
      if (error || ![response isKindOfClass:NSHTTPURLResponse.class]) {
        result.status = 0;
        result.error = error ? toStd(error.localizedDescription) : "No HTTP response";
      } else {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        result.status = static_cast<int>(http.statusCode);
        result.statusText = toStd([NSHTTPURLResponse localizedStringForStatusCode:http.statusCode]);
        if (http.URL) {
          result.url = toStd(http.URL.absoluteString);
          result.redirected = result.url != originalUrl;
        }
        NSDictionary *fields = http.allHeaderFields;
        for (id key in fields) {
          NSString *name = [key description].lowercaseString;
          NSString *text = [fields[key] description];
          result.headers.emplace_back(toStd(name), toStd(text));
          if ([name isEqualToString:@"content-type"]) result.contentType = toStd(text);
        }
        if (data.length) result.body.assign(static_cast<const char *>(data.bytes), data.length);
      }
      [engine deliverFetch:fetchId response:std::move(result)];
    }];
    [task resume];
  }

  void startTimer(int id, int delayMs, bool repeat) override {
    stopTimer(id);
    __weak OrchardEngine *engine = m_engine;
    const NSTimeInterval interval = MAX(delayMs, 0) / 1000.0;
    NSTimer *timer = [NSTimer timerWithTimeInterval:interval
                                            repeats:repeat
                                              block:^(NSTimer *timer) {
                                              (void)timer;
                                              [engine fireTimer:id];
                                            }];
    [NSRunLoop.currentRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
    m_timers[id] = Timer{timer, repeat};
  }

  void stopTimer(int id) override {
    auto found = m_timers.find(id);
    if (found == m_timers.end()) return;
    [found->second.timer invalidate];
    m_timers.erase(found);
  }

  // One-shot timers are done after they fire; forget them so the map stays small.
  void timerFired(int id) {
    auto found = m_timers.find(id);
    if (found != m_timers.end() && !found->second.repeat) m_timers.erase(found);
  }

  bool loadBundle(std::string_view name, std::string &bytes) override {
    NSString *file = toNS(std::string(name));
    NSString *path = [NSBundle.mainBundle pathForResource:file.stringByDeletingPathExtension
                                                   ofType:file.pathExtension];
    if (!path) return false;
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (!data) return false;
    bytes.assign(static_cast<const char *>(data.bytes), data.length);
    return true;
  }

  bool readPlayerCache(std::string &data) override {
    NSData *stored = [NSData dataWithContentsOfURL:playerCacheURL()];
    if (!stored || stored.length > kPlayerCacheLimit) return false;
    data.assign(static_cast<const char *>(stored.bytes), stored.length);
    return true;
  }

  bool writePlayerCache(std::string_view data) override {
    if (data.size() > kPlayerCacheLimit) return false;
    NSData *bytes = [NSData dataWithBytes:data.data() length:data.size()];
    return [bytes writeToURL:playerCacheURL() atomically:YES];
  }

  std::string extractPlayer(std::string_view source) override {
    char *json = orchard_youtube_extract(reinterpret_cast<const uint8_t *>(source.data()), source.size());
    if (!json) return {};
    std::string result(json);
    orchard_youtube_extract_free(json);
    return result;
  }

  void settled(std::uint64_t requestId, bool ok, std::string result) override {
    auto found = m_completions.find(requestId);
    if (found == m_completions.end()) return;
    OrchardEngineCompletion completion = found->second;
    m_completions.erase(found);
    NSString *text = toNS(result);
    dispatch_async(dispatch_get_main_queue(), ^{ completion(ok, text); });
  }

  void remember(std::uint64_t requestId, OrchardEngineCompletion completion) {
    m_completions[requestId] = [completion copy];
  }

  ProviderHost &host() {
    if (!m_host) m_host = std::make_unique<ProviderHost>(*this);
    return *m_host;
  }

private:
  __weak OrchardEngine *m_engine;
  NSURLSession *m_session = nil;
  struct Timer {
    NSTimer *timer;
    bool repeat;
  };
  std::unordered_map<int, Timer> m_timers;
  std::unordered_map<std::uint64_t, OrchardEngineCompletion> m_completions;
  std::unique_ptr<ProviderHost> m_host;
};

}  // namespace

@implementation OrchardEngine {
  NSThread *_thread;
  CFRunLoopRef _runLoop;
  dispatch_semaphore_t _ready;
  std::unique_ptr<IOSPlatform> _platform;
  uint64_t _nextRequestId;
}

+ (instancetype)shared {
  static OrchardEngine *engine;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ engine = [[OrchardEngine alloc] initPrivate]; });
  return engine;
}

- (instancetype)initPrivate {
  if ((self = [super init])) {
    _ready = dispatch_semaphore_create(0);
    _nextRequestId = 0;
    _thread = [[NSThread alloc] initWithTarget:self selector:@selector(hostMain) object:nil];
    _thread.name = @"orchard-provider-host";
    _thread.stackSize = kHostStackSize;
    _thread.qualityOfService = NSQualityOfServiceUserInitiated;
    [_thread start];
    dispatch_semaphore_wait(_ready, DISPATCH_TIME_FOREVER);
  }
  return self;
}

- (void)hostMain {
  @autoreleasepool {
    _runLoop = CFRunLoopGetCurrent();
    CFRetain(_runLoop);
    _platform = std::make_unique<IOSPlatform>(self);
    // A port keeps the run loop alive while it waits for work.
    [NSRunLoop.currentRunLoop addPort:[NSMachPort port] forMode:NSDefaultRunLoopMode];
    dispatch_semaphore_signal(_ready);
  }
  while (true) {
    @autoreleasepool {
      [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:NSDate.distantFuture];
    }
  }
}

- (void)performOnHost:(dispatch_block_t)block {
  CFRunLoopPerformBlock(_runLoop, kCFRunLoopDefaultMode, ^{
    @autoreleasepool { block(); }
  });
  CFRunLoopWakeUp(_runLoop);
}

- (void)invoke:(NSString *)method payload:(NSString *)payloadJSON completion:(OrchardEngineCompletion)completion {
  NSString *methodCopy = [method copy];
  NSString *payloadCopy = [payloadJSON copy];
  OrchardEngineCompletion done = [completion copy];
  [self performOnHost:^{
    const uint64_t requestId = ++self->_nextRequestId;
    self->_platform->remember(requestId, done);
    self->_platform->host().invoke(requestId, toStd(methodCopy), toStd(payloadCopy));
  }];
}

- (void)deliverFetch:(uint64_t)fetchId response:(FetchResponse)response {
  auto shared = std::make_shared<FetchResponse>(std::move(response));
  [self performOnHost:^{
    self->_platform->host().completeFetch(fetchId, *shared);
  }];
}

- (void)fireTimer:(int)timerId {
  // NSTimer blocks already run on the host run loop.
  _platform->timerFired(timerId);
  _platform->host().fireTimer(timerId);
}

@end
