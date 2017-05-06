//
//  BNCDeviceInfo.m
//  Branch-TestBed
//
//  Created by Sojan P.R. on 3/22/16.
//  Copyright © 2016 Branch Metrics. All rights reserved.
//


#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <sys/sysctl.h>
#import "BNCDeviceInfo.h"
#import "BNCPreferenceHelper.h"
#import "BNCSystemObserver.h"
#import "BNCXcode7Support.h"
#import "BNCLog.h"
#import "NSMutableDictionary+Branch.h"
#import "BranchConstants.h"
#import "BNCEncodingUtils.h"


@interface BNCDeviceInfo()
@end


@implementation BNCDeviceInfo

static BNCDeviceInfo *bncDeviceInfo;

+ (BNCDeviceInfo *)getInstance {
    if (!bncDeviceInfo) {
        bncDeviceInfo = [[BNCDeviceInfo alloc] init];
    }
    return bncDeviceInfo;
}

- (id)init {
    self = [super init];
    if (!self) return self;

    BNCPreferenceHelper *preferenceHelper = [BNCPreferenceHelper preferenceHelper];
    BOOL isRealHardwareId;
    NSString *hardwareIdType;
    NSString *hardwareId =
        [BNCSystemObserver getUniqueHardwareId:&isRealHardwareId
            isDebug:preferenceHelper.isDebug
            andType:&hardwareIdType];
    if (hardwareId) {
        self.hardwareId = hardwareId;
        self.isRealHardwareId = isRealHardwareId;
        self.hardwareIdType = hardwareIdType;
    }

    self.vendorId = [BNCSystemObserver getVendorId];
    self.brandName = [BNCSystemObserver getBrand];
    self.modelName = [BNCSystemObserver getModel];
    self.osName = [BNCSystemObserver getOS];
    self.osVersion = [BNCSystemObserver getOSVersion];
    self.screenWidth = [BNCSystemObserver getScreenWidth];
    self.screenHeight = [BNCSystemObserver getScreenHeight];
    self.isAdTrackingEnabled = [BNCSystemObserver adTrackingSafe];
    self.notificationToken = [BNCPreferenceHelper preferenceHelper].notificationToken;
    self.isProductionApp = [self.class isProductionApp];

    //  Get the locale info --
    CGFloat systemVersion = [UIDevice currentDevice].systemVersion.floatValue;
    if (systemVersion < 9.0) {

        self.language = [[NSLocale preferredLanguages] firstObject];
        NSString *rawLocale = [NSLocale currentLocale].localeIdentifier;
        NSRange range = [rawLocale rangeOfString:@"_"];
        if (range.location != NSNotFound) {
            range = NSMakeRange(range.location+1, rawLocale.length-range.location-1);
            self.country = [rawLocale substringWithRange:range];
        }

    } else if (systemVersion < 10.0) {

        NSString *rawLanguage = [[NSLocale preferredLanguages] firstObject];
        NSDictionary *languageDictionary = [NSLocale componentsFromLocaleIdentifier:rawLanguage];
        self.country = [languageDictionary objectForKey:@"kCFLocaleCountryCodeKey"];
        self.language = [languageDictionary  objectForKey:@"kCFLocaleLanguageCodeKey"];

    } else {

        NSLocale *locale = [NSLocale currentLocale];
        self.country = [locale countryCode];
        self.language = [locale languageCode ];

    }

    self.browserUserAgent = [self.class userAgentString];
    return self;
}

+ (NSString*) systemBuildVersion {
    int mib[2] = { CTL_KERN, KERN_OSVERSION };
    u_int namelen = sizeof(mib) / sizeof(mib[0]);

    //	Get the size for the buffer --

    size_t bufferSize = 0;
    sysctl(mib, namelen, NULL, &bufferSize, NULL, 0);
	if (bufferSize <= 0) return nil;

    u_char buildBuffer[bufferSize];
    int result = sysctl(mib, namelen, buildBuffer, &bufferSize, NULL, 0);

	NSString *version = nil;
    if (result >= 0) {
        version = [[NSString alloc]
            initWithBytes:buildBuffer
            length:bufferSize-1
            encoding:NSUTF8StringEncoding];
    }
    return version;
}


+ (NSString*) userAgentString {

    static NSString* browserUserAgentString = nil;
	void (^setBrowserUserAgent)() = ^() {
		if (!browserUserAgentString) {
			browserUserAgentString =
				[[[UIWebView alloc]
				  initWithFrame:CGRectZero]
					stringByEvaluatingJavaScriptFromString:@"navigator.userAgent"];
            BNCPreferenceHelper *preferences = [BNCPreferenceHelper preferenceHelper];
            preferences.browserUserAgentString = browserUserAgentString;
            preferences.lastSystemBuildVersion = self.systemBuildVersion;
			BNCLogDebug(@"userAgentString: '%@'.", browserUserAgentString);
		}
	};

	//	We only get the string once per app run:

	if (browserUserAgentString)
		return browserUserAgentString;

    //  Did we cache it?

    BNCPreferenceHelper *preferences = [BNCPreferenceHelper preferenceHelper];
    if (preferences.browserUserAgentString &&
        preferences.lastSystemBuildVersion &&
        [preferences.lastSystemBuildVersion isEqualToString:self.systemBuildVersion]) {
        browserUserAgentString = [preferences.browserUserAgentString copy];
        return browserUserAgentString;
    }

	//	Make sure this executes on the main thread.
	//	Uses an implied lock through dispatch_queues:  This can deadlock if mis-used!

	if (NSThread.isMainThread) {
		setBrowserUserAgent();
		return browserUserAgentString;
	}

    //  Different case for iOS 7.0:
    if ([UIDevice currentDevice].systemVersion.floatValue  < 8.0) {
        dispatch_sync(dispatch_get_main_queue(), ^ {
            setBrowserUserAgent();
        });
        return browserUserAgentString;
    }

	//	Wait and yield to prevent deadlock:

	int retries = 10;
	int64_t timeoutDelta = (dispatch_time_t)((long double)NSEC_PER_SEC * (long double)0.100);
	while (!browserUserAgentString && retries > 0) {

        dispatch_block_t agentBlock = dispatch_block_create_with_qos_class(
            DISPATCH_BLOCK_DETACHED | DISPATCH_BLOCK_ENFORCE_QOS_CLASS,
            QOS_CLASS_USER_INTERACTIVE,
            0,
            ^ { setBrowserUserAgent(); }
        );
        dispatch_async(dispatch_get_main_queue(), agentBlock);

		dispatch_time_t timeoutTime = dispatch_time(DISPATCH_TIME_NOW, timeoutDelta);
        dispatch_block_wait(agentBlock, timeoutTime);
		retries--;
	}
	return browserUserAgentString;
}

+ (BOOL) isProductionApp {
    NSDictionary *entitlements =
        [NSDictionary dictionaryWithContentsOfFile:
            [[NSBundle mainBundle]
                pathForResource:@"archived-expanded-entitlements" ofType:@"xcent"]];
    NSString *environment = entitlements[@"aps-environment"];
    BNCLogDebug(@"Found aps-environment %@.", environment);
    BOOL isProduction = ([environment isEqualToString:@"production"]);
    return isProduction;
}

- (NSDictionary*) dictionary {

    NSMutableDictionary *dictionary = [NSMutableDictionary new];

    #define set(member, key) \
        [dictionary bnc_safeSetObject:self.member forKey:key]

    #define setBool(member, key) \
        [dictionary bnc_safeSetObject:@(self.member) forKey:key]

    if (self.hardwareId && self.hardwareIdType && self.isRealHardwareId) {
        set(hardwareId,         BRANCH_REQUEST_KEY_HARDWARE_ID);
        set(hardwareIdType,     BRANCH_REQUEST_KEY_HARDWARE_ID_TYPE);
        setBool(isRealHardwareId,BRANCH_REQUEST_KEY_IS_HARDWARE_ID_REAL);
    }

    set(vendorId,       BRANCH_REQUEST_KEY_IOS_VENDOR_ID);
    set(brandName,      BRANCH_REQUEST_KEY_BRAND);
    set(modelName,      BRANCH_REQUEST_KEY_MODEL);
    set(osName,         BRANCH_REQUEST_KEY_OS);
    set(osVersion,      BRANCH_REQUEST_KEY_OS_VERSION);
    set(screenWidth,    BRANCH_REQUEST_KEY_SCREEN_WIDTH);
    set(screenHeight,   BRANCH_REQUEST_KEY_SCREEN_HEIGHT);

    setBool(isAdTrackingEnabled, BRANCH_REQUEST_KEY_AD_TRACKING_ENABLED);

    set(country,            @"country");
    set(language,           @"language");
    set(browserUserAgent,   @"user_agent");

    setBool(isProductionApp,@"is_production_app");
    set(notificationToken,  @"notification_token");

    #undef set
    #undef setBool
    
    return dictionary;
}

@end
