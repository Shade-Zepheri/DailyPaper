#import "Global.h"
#import "HBDPPreferences.h"
#import "HBDPXMLParserHell.h"

#import <Foundation/NSDistributedNotificationCenter.h>
#import <PersistentConnection/PCPersistentTimer.h>
#import <PhotoLibrary/PLStaticWallpaperImageViewController.h>
#import <SpringBoard/SpringBoard.h>
#import <SpringBoard/SBWiFiManager.h>
#import <SpringBoardFoundation/SBFWallpaperParallaxSettings.h>

HBDPPreferences *preferences;

static NSString *const HBDPErrorDomain = @"HBDPErrorDomain";

void HBDPUpdateWallpaperMetadata();

BOOL isRunning, isWaitingForWiFi, isFirstRun;

@interface SpringBoard (DailyPaper)

- (void)_dailypaper_configureTimer;
- (void)_dailypaper_updateWallpaper;

@end

UIImage *HBDPRetrieveWallpaperWithSize(CGSize screenSize, NSError **error) {
	if (CGSizeEqualToSize(screenSize, CGSizeZero)) {
		screenSize = [SBFWallpaperParallaxSettings minimumWallpaperSizeForCurrentDevice];

		if (preferences.useRetina && [UIScreen mainScreen].scale > 1.0) {
			screenSize.width *= [UIScreen mainScreen].scale;
			screenSize.height *= [UIScreen mainScreen].scale;
		}
	}

  // https://www.bing.com/ImageResolution.aspx?w=375&h=667&mkt=en-us
	NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://www.bing.com/ImageResolution.aspx?w=%li&h=%li&mkt=%@", (long)screenSize.width, (long)screenSize.height, HBDPBingRegionToMarket(preferences.region)]];
	NSError *requestError = nil;
	NSData *data = [NSURLConnection sendSynchronousRequest:[NSURLRequest requestWithURL:url] returningResponse:nil error:&requestError];

	if (requestError) {
		*error = requestError;
		return nil;
	} else {
		return [UIImage imageWithData:data];
	}
}

void HBDPUpdateWallpaper(void(^completion)(NSError *error), BOOL onDemand) {
	if (isRunning) {
		completion([NSError errorWithDomain:HBDPErrorDomain code:2 userInfo:@{ NSLocalizedDescriptionKey: @"A wallpaper update is already running." }]);
		return;
	}

	[(SpringBoard *)[UIApplication sharedApplication] _dailypaper_configureTimer];

	if (!onDemand) {
		if (!preferences.enabled) {
			completion([NSError errorWithDomain:HBDPErrorDomain code:1 userInfo:@{ NSLocalizedDescriptionKey: @"Wallpaper updating is disabled." }]);
			return;
		}

		if (preferences.useWiFiOnly) {
			BOOL failed = NO;

			if (isWaitingForWiFi) {
				failed = YES;
			} else if (((SBWiFiManager *)[%c(SBWiFiManager) sharedInstance]).signalStrengthBars < 2) {
				failed = YES;
				isWaitingForWiFi = YES;
			}

			if (failed) {
				completion([NSError errorWithDomain:HBDPErrorDomain code:3 userInfo:@{ NSLocalizedDescriptionKey: @"Wallpaper updating is waiting for a Wi-Fi connection." }]);
				return;
			}
		}
	}

	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		isRunning = YES;

		NSError *error = nil;
		UIImage *image = HBDPRetrieveWallpaperWithSize(CGSizeZero, &error);

		if (error) {
			completion(error);
			isRunning = NO;
			return;
		}

		PLStaticWallpaperImageViewController *wallpaperViewController = [[PLStaticWallpaperImageViewController alloc] initWithUIImage:image];
		wallpaperViewController.saveWallpaperData = YES;

/* Just trynna compile RN
		uintptr_t address = (uintptr_t)&preferences.wallpaperMode;
		object_setInstanceVariable(wallpaperViewController, "_wallpaperMode", *(PLWallpaperMode **)address);
*/
		[wallpaperViewController _savePhoto];

		isRunning = NO;

		completion(nil);
	});

	HBDPUpdateWallpaperMetadata();
}

void HBDPUpdateWallpaperOnDemand() {
	HBDPUpdateWallpaper(^(NSError *error) {
		if (error) {
			HBLogError(@"wallpaper update error: %@", error);
		}

		[[NSDistributedNotificationCenter defaultCenter] postNotificationName:HBDPWallpaperDidUpdateNotification object:nil userInfo:error ? @{ kHBDPErrorKey: error.localizedDescription } : nil];
	}, YES);
}

void HBDPUpdateWallpaperMetadata() {
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
		HBDPXMLParserHell *parser = [[HBDPXMLParserHell alloc] init];
		[parser loadWithBingMarket:HBDPBingRegionToMarket(preferences.region) completion:^(NSString *copyright, NSURL *url, NSError *error) {
			if (error) {
				HBLogError(@"failed to load metadata: %@", error);
			}

			[@{
				kHBDPDescriptionKey: error ? @"Couldn’t load the wallpaper details." : copyright,
				kHBDPURLKey: url ? url.absoluteString : @"https://www.bing.com/"
			} writeToFile:kHBDPMetadataPath atomically:YES];
		}];
	});
}

void HBDPSaveWallpaper() {
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		NSError *error = nil;
		UIImage *image = HBDPRetrieveWallpaperWithSize(CGSizeMake(1366.f, 768.f), &error);

		if (!error) {
			UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil);
		}

		[[NSDistributedNotificationCenter defaultCenter] postNotificationName:HBDPWallpaperDidSaveNotification object:nil userInfo:error ? @{ kHBDPErrorKey: error.localizedDescription } : nil];
	});
}

#pragma mark - Scheduling

%hook SpringBoard

- (void)applicationDidFinishLaunching:(UIApplication *)application {
	%orig;
	[self _dailypaper_configureTimer];
}

%new - (void)_dailypaper_configureTimer {
	NSCalendar *calendar = [NSCalendar autoupdatingCurrentCalendar];
	calendar.timeZone = HBDPBingRegionToTimezone(preferences.region);

	NSDateComponents *dateComponents = [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay | NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond fromDate:[NSDate date]];
	dateComponents.day++;
	dateComponents.hour = 0;
	dateComponents.minute = arc4random_uniform(3); // let's not ddos bing
	dateComponents.second = arc4random_uniform(61);
	HBLogDebug(@"scheduling next update for %@", [calendar dateFromComponents:dateComponents]);

	PCPersistentTimer *timer = [[PCPersistentTimer alloc] initWithFireDate:[calendar dateFromComponents:dateComponents] serviceIdentifier:@"ws.hbang.dailypaper" target:self selector:@selector(_dailypaper_updateWallpaper) userInfo:nil];
	[timer scheduleInRunLoop:[NSRunLoop mainRunLoop]];
}

%new - (void)_dailypaper_updateWallpaper {
	HBLogDebug(@"update!");

	HBDPUpdateWallpaper(^(NSError *error) {
		HBLogError(@"wallpaper update error: %@", error);
	}, NO);
}

%end

#pragma mark - Wi-Fi postponing

/*
 probably a lazy hack. i'm sure there has to be something
 in PersistentConnection for this
*/

%hook SBWiFiManager

- (void)_updateWiFiState {
	%orig;

	if (isWaitingForWiFi && self.signalStrengthBars > 1) {
		isWaitingForWiFi = NO;
		[(SpringBoard *)[UIApplication sharedApplication] _dailypaper_updateWallpaper];
	}
}

%end

#pragma mark - First run

%hook SBLockScreenManager

- (void)_finishUIUnlockFromSource:(NSInteger)source withOptions:(NSDictionary *)options {
	%orig;

	if (isFirstRun) {
		isFirstRun = NO;

		NSURL *url;

		if ([[NSFileManager defaultManager] fileExistsAtPath:@"/Library/MobileSubstrate/DynamicLibraries/PreferenceOrganizer2.dylib"]) {
			// this is broken... https://github.com/angelXwind/PreferenceOrganizer2/issues/3
			url = [NSURL URLWithString:@"prefs:root=Tweaks&path=DailyPaper"];
		} else {
			url = [NSURL URLWithString:@"prefs:root=DailyPaper"];
		}

		[[UIApplication sharedApplication] openURL:url];
	}
}

%end

%ctor {
    preferences = [HBDPPreferences mainPreferences];

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)HBDPUpdateWallpaperOnDemand, CFSTR("ws.hbang.dailypaper/ForceUpdate"), NULL, kNilOptions);
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)HBDPSaveWallpaper, CFSTR("ws.hbang.dailypaper/SaveWallpaper"), NULL, kNilOptions);

    %init;
}
