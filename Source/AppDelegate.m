/*
    Copyright (c) 2017-2018 Ricci Adams

    Permission is hereby granted, free of charge, to any person obtaining
    a copy of this software and associated documentation files (the
    "Software"), to deal in the Software without restriction, including
    without limitation the rights to use, copy, modify, merge, publish,
    distribute, sublicense, and/or sell copies of the Software, and to
    permit persons to whom the Software is furnished to do so, subject to
    the following conditions:

    The above copyright notice and this permission notice shall be
    included in all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
    EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
    MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
    NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
    LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
    OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
    WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
*/


#import "AppDelegate.h"
#import "RestlessEngine.h"
#import "PreferencesController.h"
#import "RestlessApplication.h"


@import ServiceManagement;

static NSString * const LaunchAtLoginPreferenceKey        = @"LaunchAtLogin";
static NSString * const RestlessApplicationsPreferenceKey = @"RestlessApplications";
static NSString * const ManualPreventionKey               = @"ManualPrevention";
static NSString * const UpdateFrequencyKey                = @"UpdateFrequency";
static NSString * const ReenableDelayKey                  = @"ReenableDelay";


@interface AppDelegate ()

@property (weak) IBOutlet NSMenu *statusItemMenu;
@property (weak) IBOutlet NSMenuItem *lidCloseMenuItem;

@end


@implementation AppDelegate {
    NSStatusItem   *_statusItem;
    NSImage *_onImage;
    NSImage *_offImage;
    
    RestlessEngine *_engine;
    PreferencesController *_preferencesController;
    NSTimer *_timer;

    BOOL _applicationIsTerminating;

    BOOL _manualPreventionActive;
    NSArrayController *_applicationsController;
}


- (void) applicationDidFinishLaunching:(NSNotification *)aNotification
{
    NSDictionary *defaults = @{
        LaunchAtLoginPreferenceKey: @NO,
        ManualPreventionKey: @NO,
        RestlessApplicationsPreferenceKey: @[ @{
            @"name": @"Embrace",
            @"bundle-identifier": @"com.iccir.Embrace",
            @"action": @( RestlessActionPreventLidCloseSleepWhenIdleSleepPrevented )
        } ],
        
        UpdateFrequencyKey: @10,
        ReenableDelayKey:   @10
    };
    
    [[NSUserDefaults standardUserDefaults] registerDefaults:defaults];

    _engine = [[RestlessEngine alloc] init];
    [_engine addObserver:self forKeyPath:@"preventingLidCloseSleep" options:0 context:NULL];
    
    [_engine checkHelper];
    
    _statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:30.0];

    _onImage  = [NSImage imageNamed:@"StatusItemIconOn"];
    _offImage = [NSImage imageNamed:@"StatusItemIconOff"];

    [_statusItem setImage:_offImage];
    [_statusItem setHighlightMode:YES];
    [_statusItem setMenu:[self statusItemMenu]];
    
    [self _updateTimer];

    [self _loadState];

    [self _updateEngineManually:YES];
    [self _updateLaunchHelper];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_handleUserDefaultsDidChangeNotification:)        name:NSUserDefaultsDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_handleRestlessApplicationDidUpdateNotification:) name:RestlessApplicationDidUpdateNotification object:nil];

    [[NSDistributedNotificationCenter defaultCenter] addObserver: self 
                                                        selector: @selector(_handleFermataUpdateNotification:)
                                                            name: @"com.iccir.Fermata.Update"
                                                          object: nil
                                              suspensionBehavior: NSNotificationSuspensionBehaviorDeliverImmediately];

    [[NSWorkspace sharedWorkspace] addObserver:self forKeyPath:@"runningApplications" options:0 context:NULL];
}


- (NSApplicationTerminateReply) applicationShouldTerminate:(NSApplication *)sender
{
    _applicationIsTerminating = YES;
    
    [_engine allowLidCloseSleepWithCallback:^{
        [[NSApplication sharedApplication] replyToApplicationShouldTerminate:YES];
    }];

    return NSTerminateLater;
}


- (BOOL) validateMenuItem:(NSMenuItem *)menuItem
{
    SEL action = [menuItem action];

    if (action == @selector(preventLidCloseSleep:)) {
        [menuItem setState:(_manualPreventionActive ? NSOnState : NSOffState)];
    }
    
    return YES;
}


- (void) _updateTimer
{
    NSTimeInterval updateFrequency = [[NSUserDefaults standardUserDefaults] doubleForKey:UpdateFrequencyKey];
    
    if ([_timer timeInterval] != updateFrequency) {
        [_timer invalidate];

        __weak id weakSelf = self;
        _timer = [NSTimer scheduledTimerWithTimeInterval:updateFrequency repeats:YES block:^(NSTimer *timer) {
            [weakSelf _updateEngineManually:NO];
        }];

        [_timer setTolerance:(updateFrequency < 2.0) ? 0.1 : 1.0];
    }
}



#pragma mark - Private Methods

- (void) _loadState
{
    NSUserDefaults *defaults     = [NSUserDefaults standardUserDefaults];
    NSArray        *dictionaries = [defaults objectForKey:RestlessApplicationsPreferenceKey];
    NSMutableArray *applications = [NSMutableArray array];

    for (NSDictionary *dictionary in dictionaries) {
        [applications addObject:[[RestlessApplication alloc] initWithDictionary:dictionary]];
    }

    _manualPreventionActive = [defaults boolForKey:ManualPreventionKey];

    _applicationsController = [[NSArrayController alloc] initWithContent:applications];
    [_applicationsController addObserver:self forKeyPath:@"arrangedObjects" options:0 context:NULL];
    
    NSSortDescriptor *sortDescriptor = [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES];
    [_applicationsController setSortDescriptors:@[ sortDescriptor ]];
}


- (void) _saveState
{
    NSMutableArray *dictionaries = [NSMutableArray array];

    for (RestlessApplication *application in [_applicationsController arrangedObjects]) {
        [dictionaries addObject:[application dictionaryRepresentation]];
    }
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:dictionaries forKey:RestlessApplicationsPreferenceKey];
    [defaults setBool:_manualPreventionActive forKey:ManualPreventionKey];
    
    [defaults synchronize];
}


- (void) _updateLaunchHelper
{
    BOOL launchAtLogin = [[NSUserDefaults standardUserDefaults] boolForKey:@"LaunchAtLogin"];

    CFStringRef bundleID = CFSTR("com.iccir.Fermata.Launcher");

    if (launchAtLogin) {
        if (!SMLoginItemSetEnabled(bundleID, YES)) {
            NSString *errorMessage = NSLocalizedString(@"Couldn't add Fermata to Login Items list.", nil);

            NSAlert *alert = [[NSAlert alloc] init];
            [alert setInformativeText:errorMessage];
            [alert runModal];
            
            [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"LaunchAtLogin"];
        }

    } else {
        SMLoginItemSetEnabled(bundleID, NO);
    }
}


- (void) _handleUserDefaultsDidChangeNotification:(NSNotification *)note
{
    [self _updateLaunchHelper];
    [self _updateTimer];
}


- (void) _handleRestlessApplicationDidUpdateNotification:(NSNotification *)note
{
    [self _updateEngineManually:NO];
    [self _saveState];
}


- (void) _handleFermataUpdateNotification:(NSNotification *)note
{
    [self _updateEngineManually:NO];
}


- (void) _updateEngineManually:(BOOL)isManual
{
    BOOL shouldPrevent = NO;
    NSMutableDictionary *bundleIDToApplicationMap = nil;

    if (_applicationIsTerminating) return;

    // Step 1 - Check manual trigger
    //
    if (_manualPreventionActive) {
        shouldPrevent = YES;
    }

    // Step 2a - Check RestlessActionPreventLidCloseSleepWhenRunning
    // Step 2b - Also build bundleIDToApplicationMap
    //
    if (!shouldPrevent) {
        bundleIDToApplicationMap = [NSMutableDictionary dictionary];

        for (RestlessApplication *application in [_applicationsController arrangedObjects]) {
            NSString       *bundleIdentifier = [application bundleIdentifier];
            RestlessAction  action           = [application action];
            
            if (!bundleIdentifier) continue;
            
            [bundleIDToApplicationMap setObject:application forKey:bundleIdentifier];

            if (action == RestlessActionPreventLidCloseSleepWhenRunning) {
                if ([[NSRunningApplication runningApplicationsWithBundleIdentifier:bundleIdentifier] count]) {
                    shouldPrevent = YES;
                    break;
                }
            }
        }
    }
    
    // Step 3 - Check RestlessActionPreventLidCloseSleepWhenIdleSleepPrevented
    //
    if (!shouldPrevent) {
        for (NSNumber *pidNumber in [_engine pidsPreventingIdleSleep]) {
            pid_t pid = (pid_t)[pidNumber integerValue];

            NSString *bundleIdentifier = [[NSRunningApplication runningApplicationWithProcessIdentifier:pid] bundleIdentifier];
            
            RestlessApplication *app = [bundleIDToApplicationMap objectForKey:bundleIdentifier];
            
            if ([app action] == RestlessActionPreventLidCloseSleepWhenIdleSleepPrevented) {
                shouldPrevent = YES;
                break;
            }
        }
    }

    if (shouldPrevent) {
        [_engine preventLidCloseSleep];
    } else {
        NSTimeInterval delay = [[NSUserDefaults standardUserDefaults] doubleForKey:ReenableDelayKey];
        if (isManual) delay = 0;
        [_engine allowLidCloseSleepAfter:delay];
    }
}


#pragma mark - KVO

- (void) observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if ([object isEqual:_engine]) {
        NSImage *image = [_engine isPreventingLidCloseSleep] ? _onImage : _offImage;
        [_statusItem setImage:image];

    } else {
        [self _updateEngineManually:NO];
        [self _saveState];
    }
}


#pragma mark - IBActions

- (IBAction) preventLidCloseSleep:(id)sender
{
    _manualPreventionActive = !_manualPreventionActive;

    [self _updateEngineManually:YES];
    [self _saveState];
}


- (IBAction) showPreferences:(id)sender
{
    if (!_preferencesController) {
        _preferencesController = [[PreferencesController alloc] init];
        [_preferencesController setApplicationsController:_applicationsController];
    }

    [_preferencesController showWindow:self];
    [NSApp activateIgnoringOtherApps:YES];
}


@end
