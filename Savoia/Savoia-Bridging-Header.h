// WebKit's C API, which WebKit.framework exports and the SDK does not declare. Copied from WebKit's
// own WKBase.h, WKContext.h, WKGeolocationManager.h and WKGeolocationPosition.h; docs/permissions.md.

// Apple's WebKit only: WebKitGTK has API of its own for all of this.
#if defined(__APPLE__)

#include <stdbool.h>

typedef const struct OpaqueWKContext *WKContextRef;
typedef const struct OpaqueWKGeolocationManager *WKGeolocationManagerRef;
typedef const struct OpaqueWKGeolocationPosition *WKGeolocationPositionRef;

void WKRelease(const void *object);

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

#endif
