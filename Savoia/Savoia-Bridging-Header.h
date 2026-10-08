// WebKit's C API, which WebKit.framework exports and the SDK does not declare. Copied from WebKit's
// own WKBase.h, WKContext.h, WKGeolocation*.h, WKNotification*.h and the value types' headers; docs/permissions.md.

// Apple's WebKit only: WebKitGTK has API of its own for all of this.
#if defined(__APPLE__)

#import <WebKit/WebKit.h>
#include <stdbool.h>
#include <stdint.h>
#include <CoreFoundation/CoreFoundation.h>

typedef const struct OpaqueWKContext *WKContextRef;
typedef const struct OpaqueWKGeolocationManager *WKGeolocationManagerRef;
typedef const struct OpaqueWKGeolocationPosition *WKGeolocationPositionRef;

void WKRelease(const void *object);

// Values

typedef const void *WKTypeRef;
typedef const struct OpaqueWKString *WKStringRef;
typedef const struct OpaqueWKUInt64 *WKUInt64Ref;
typedef const struct OpaqueWKBoolean *WKBooleanRef;
typedef const struct OpaqueWKArray *WKArrayRef;
typedef struct OpaqueWKArray *WKMutableArrayRef;
typedef const struct OpaqueWKDictionary *WKDictionaryRef;
typedef struct OpaqueWKDictionary *WKMutableDictionaryRef;
typedef const struct OpaqueWKSecurityOrigin *WKSecurityOriginRef;
typedef const struct OpaqueWKPage *WKPageRef;

WKStringRef WKStringCreateWithUTF8CString(const char *string);
CFStringRef WKStringCopyCFString(CFAllocatorRef allocator, WKStringRef string) CF_RETURNS_RETAINED;
WKUInt64Ref WKUInt64Create(uint64_t value);
uint64_t WKUInt64GetValue(WKUInt64Ref value);
WKBooleanRef WKBooleanCreate(bool value);
WKMutableArrayRef WKMutableArrayCreate(void);
void WKArrayAppendItem(WKMutableArrayRef array, WKTypeRef item);
size_t WKArrayGetSize(WKArrayRef array);
WKTypeRef WKArrayGetItemAtIndex(WKArrayRef array, size_t index);
WKMutableDictionaryRef WKMutableDictionaryCreate(void);
bool WKDictionarySetItem(WKMutableDictionaryRef dictionary, WKStringRef key, WKTypeRef item);
WKSecurityOriginRef WKSecurityOriginCreateFromString(WKStringRef string);

// Tells every page of the origin that `navigator.permissions` has a new answer for it.
void WKPagePermissionChanged(WKStringRef permissionName, WKStringRef originString);

// Geolocation

typedef void (*WKGeolocationProviderStartUpdatingCallback)(WKGeolocationManagerRef manager, const void *clientInfo);
typedef void (*WKGeolocationProviderStopUpdatingCallback)(WKGeolocationManagerRef manager, const void *clientInfo);
typedef void (*WKGeolocationProviderSetEnableHighAccuracyCallback)(WKGeolocationManagerRef manager, bool enabled, const void *clientInfo);

typedef struct WKGeolocationProviderBase {
    int version;
    const void *clientInfo;
} WKGeolocationProviderBase;

// The layout is the contract: WebKit reads as many fields as `version` says.
typedef struct WKGeolocationProviderV1 {
    WKGeolocationProviderBase base;
    WKGeolocationProviderStartUpdatingCallback startUpdating;
    WKGeolocationProviderStopUpdatingCallback stopUpdating;
    WKGeolocationProviderSetEnableHighAccuracyCallback setEnableHighAccuracy;
} WKGeolocationProviderV1;

WKGeolocationManagerRef WKContextGetGeolocationManager(WKContextRef context);
void WKGeolocationManagerSetProvider(WKGeolocationManagerRef manager, const WKGeolocationProviderBase *provider);
void WKGeolocationManagerProviderDidChangePosition(WKGeolocationManagerRef manager, WKGeolocationPositionRef position);
void WKGeolocationManagerProviderDidFailToDeterminePosition(WKGeolocationManagerRef manager);

WKGeolocationPositionRef WKGeolocationPositionCreate_b(double timestamp, double latitude, double longitude, double accuracy,
                                                       bool providesAltitude, double altitude,
                                                       bool providesAltitudeAccuracy, double altitudeAccuracy,
                                                       bool providesHeading, double heading,
                                                       bool providesSpeed, double speed);

// Notifications

typedef const struct OpaqueWKNotification *WKNotificationRef;
typedef const struct OpaqueWKNotificationManager *WKNotificationManagerRef;

typedef void (*WKNotificationProviderShowCallback)(WKPageRef page, WKNotificationRef notification, const void *clientInfo);
typedef void (*WKNotificationProviderCancelCallback)(WKNotificationRef notification, const void *clientInfo);
typedef void (*WKNotificationProviderDidDestroyNotificationCallback)(WKNotificationRef notification, const void *clientInfo);
typedef void (*WKNotificationProviderAddNotificationManagerCallback)(WKNotificationManagerRef manager, const void *clientInfo);
typedef void (*WKNotificationProviderRemoveNotificationManagerCallback)(WKNotificationManagerRef manager, const void *clientInfo);
typedef WKDictionaryRef (*WKNotificationProviderNotificationPermissionsCallback)(const void *clientInfo);
typedef void (*WKNotificationProviderClearNotificationsCallback)(WKArrayRef notificationIDs, const void *clientInfo);

typedef struct WKNotificationProviderBase {
    int version;
    const void *clientInfo;
} WKNotificationProviderBase;

typedef struct WKNotificationProviderV0 {
    WKNotificationProviderBase base;
    WKNotificationProviderShowCallback show;
    WKNotificationProviderCancelCallback cancel;
    WKNotificationProviderDidDestroyNotificationCallback didDestroyNotification;
    WKNotificationProviderAddNotificationManagerCallback addNotificationManager;
    WKNotificationProviderRemoveNotificationManagerCallback removeNotificationManager;
    WKNotificationProviderNotificationPermissionsCallback notificationPermissions;
    WKNotificationProviderClearNotificationsCallback clearNotifications;
} WKNotificationProviderV0;

WKNotificationManagerRef WKContextGetNotificationManager(WKContextRef context);
WKNotificationManagerRef WKNotificationManagerGetSharedServiceWorkerNotificationManager(void);
void WKNotificationManagerSetProvider(WKNotificationManagerRef manager, const WKNotificationProviderBase *provider);
void WKNotificationManagerProviderDidShowNotification(WKNotificationManagerRef manager, uint64_t notificationID);
void WKNotificationManagerProviderDidClickNotification(WKNotificationManagerRef manager, uint64_t notificationID);
void WKNotificationManagerProviderDidCloseNotifications(WKNotificationManagerRef manager, WKArrayRef notificationIDs);
void WKNotificationManagerProviderDidUpdateNotificationPolicy(WKNotificationManagerRef manager, WKSecurityOriginRef origin, bool allowed);
void WKNotificationManagerProviderDidRemoveNotificationPolicies(WKNotificationManagerRef manager, WKArrayRef origins);

WKStringRef WKNotificationCopyTitle(WKNotificationRef notification);
WKStringRef WKNotificationCopyBody(WKNotificationRef notification);
WKStringRef WKNotificationCopyTag(WKNotificationRef notification);
WKSecurityOriginRef WKNotificationGetSecurityOrigin(WKNotificationRef notification);
uint64_t WKNotificationGetID(WKNotificationRef notification);
WKStringRef WKNotificationCopyIconURL(WKNotificationRef notification);
WKStringRef WKNotificationCopyDataStoreIdentifier(WKNotificationRef notification);
bool WKNotificationGetIsPersistent(WKNotificationRef notification);

// The data store's private half, from _WKWebsiteDataStoreDelegate.h and WKWebsiteDataStorePrivate.h.

NS_ASSUME_NONNULL_BEGIN

@protocol _WKWebsiteDataStoreDelegate <NSObject>
@optional
- (void)websiteDataStore:(WKWebsiteDataStore *)dataStore openWindow:(NSURL *)url fromServiceWorkerOrigin:(WKSecurityOrigin *)serviceWorkerOrigin completionHandler:(void (^)(WKWebView * _Nullable newWebView))completionHandler;
@end

@interface WKWebsiteDataStore (SavoiaPrivate)
@property (nullable, nonatomic, weak) id <_WKWebsiteDataStoreDelegate> _delegate;
@end

NS_ASSUME_NONNULL_END

#endif
