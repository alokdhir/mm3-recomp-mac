/*
 * app_macos.m -- the process entry point on macOS.
 *
 * AppKit must own the real main thread: windows, events and the display
 * link only work there. The game's own main() (upstream src/main.c, built as
 * mm3_main) runs on a worker thread with a large stack -- every guest call is
 * a host call, so the recompiled code's call depth is the title's -- while
 * the main thread runs the application.
 */
#import <Cocoa/Cocoa.h>
#import <IOKit/IOKitLib.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <fcntl.h>

int mm3_main(void);

#define GAME_STACK_BYTES ((size_t)512 << 20)

static void *game_thread(void *unused)
{
    int rc;
    (void)unused;
    pthread_setname_np("mm3 main");
    rc = mm3_main();
    fflush(stdout);
    fflush(stderr);
    exit(rc);
    return NULL;
}

@interface MM3AppDelegate : NSObject <NSApplicationDelegate>
@end

/* The Graphics menu: render resolution (lines; 0 follows the window) and
 * anti-aliasing (MSAA samples), applied at the next frame and remembered in
 * the user defaults; an explicit RECOMP_RENDER_SCALE / RECOMP_MSAA wins at
 * launch. Texture filtering is fixed at 16x anisotropic, which costs no
 * measurable time (RECOMP_ANISO still chooses). */
extern void nv2a_metal_request_render_lines(int lines);
extern void nv2a_metal_request_msaa(int samples);
extern void nv2a_metal_save_recent_frames(void);
extern void nv2a_metal_toggle_texture_pack(void);

typedef struct { const char *title; int value; } Choice;
typedef struct {
    const char *title, *key, *env;
    int def;
    void (*apply)(int);
    const Choice *choices;
    int count;
} Setting;

static const Choice s_resolutions[] = {
    { "720p", 720 }, { "1080p", 1080 }, { "1440p", 1440 }, { "2160p (4K)", 2160 },
    { "Match Window", 0 },
};
static const Choice s_antialiasing[] = {
    { "Off", 1 }, { "2x", 2 }, { "4x", 4 },
};
#define DEFAULT_RENDER_LINES 1440
#define DEFAULT_MSAA 4
static const Setting s_settings[] = {
    { "Resolution", "RenderLines", "RECOMP_RENDER_SCALE", DEFAULT_RENDER_LINES,
      nv2a_metal_request_render_lines, s_resolutions, 5 },
    { "Anti-aliasing", "MSAA", "RECOMP_MSAA", DEFAULT_MSAA,
      nv2a_metal_request_msaa, s_antialiasing, 3 },
};
#define SETTING_COUNT ((int)(sizeof s_settings / sizeof s_settings[0]))

/* The GPU's core count (IORegistry AGXAccelerator gpu-core-count); 0 when
 * it cannot be read. */
static int gpu_cores(void)
{
    io_service_t gpu = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"));
    int n = 0;
    if (gpu) {
        CFTypeRef v = IORegistryEntryCreateCFProperty(gpu, CFSTR("gpu-core-count"), kCFAllocatorDefault, 0);
        if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &n);
        if (v) CFRelease(v);
        IOObjectRelease(gpu);
    }
    return n;
}

/* Before the player chooses: 1440p on a GPU of 16 cores or more (Pro, Max,
 * Ultra), 1080p on the base chips' 7 to 10. */
static int default_render_lines(void)
{
    int n = gpu_cores();
    return n && n < 16 ? 1080 : DEFAULT_RENDER_LINES;
}

/* 4x on the larger GPUs; BASE_CHIP_MSAA on the base chips. */
#define BASE_CHIP_MSAA 2
static int default_msaa(void)
{
    int n = gpu_cores();
    return n && n < 16 ? BASE_CHIP_MSAA : DEFAULT_MSAA;
}

static int saved_setting(const Setting *st)
{
    NSUserDefaults *u = [NSUserDefaults standardUserDefaults];
    NSString *k = [NSString stringWithUTF8String:st->key];
    if ([u objectForKey:k]) return (int)[u integerForKey:k];
    return st == &s_settings[0] ? default_render_lines() :
           st == &s_settings[1] ? default_msaa() : st->def;
}

static int saved_render_lines(void)
{
    return saved_setting(&s_settings[0]);
}

@implementation MM3AppDelegate

- (void)toggleTexturePack:(NSMenuItem *)item
{
    extern void xbox_FramebufferReleaseKeys(void);
    [item setState:[item state] == NSControlStateValueOn ? NSControlStateValueOff : NSControlStateValueOn];
    xbox_FramebufferReleaseKeys();
    nv2a_metal_toggle_texture_pack();
}

/* Debug > Keep a Log: from the next launch, what the game prints is kept in
 * ~/Library/Logs/Midtown Madness 3.log (see redirect_log). Off by default. */
- (void)toggleKeepLog:(NSMenuItem *)item
{
    BOOL on = [item state] != NSControlStateValueOn;
    [item setState:on ? NSControlStateValueOn : NSControlStateValueOff];
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:@"KeepLog"];
}

- (void)saveRecentFrames:(id)sender
{
    extern void xbox_FramebufferReleaseKeys(void);
    (void)sender;
    xbox_FramebufferReleaseKeys();
    nv2a_metal_save_recent_frames();
}

/* A Graphics menu choice: its submenu names the setting, its tag the value. */
- (void)chooseSetting:(NSMenuItem *)item
{
    const Setting *st = &s_settings[0];
    int k;
    for (k = 0; k < SETTING_COUNT; k++)
        if ([[[item menu] title] isEqualToString:[NSString stringWithUTF8String:s_settings[k].title]])
            st = &s_settings[k];
    NSMenuItem *other;
    for (other in [[item menu] itemArray])
        [other setState:other == item ? NSControlStateValueOn : NSControlStateValueOff];
    [[NSUserDefaults standardUserDefaults] setInteger:[item tag]
                                               forKey:[NSString stringWithUTF8String:st->key]];
    st->apply((int)[item tag]);
    {
        extern void xbox_FramebufferReleaseKeys(void);
        xbox_FramebufferReleaseKeys();
    }
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)app
{
    /* As the window's close button: the game's handler ends the process
     * (its guest workers do not observe a host quit). */
    extern void xbox_FramebufferRequestClose(void);
    xbox_FramebufferRequestClose();
    return NSTerminateCancel;
}

@end

/* The game data: Contents/Resources/game_files inside the app -- packaged
 * apps carry it, and the build tree's app links it there. The runtime reads
 * game_files/... relative to the working directory, and writes there too
 * (xbox_kernel.log), but nothing may change inside a signed bundle: Finder
 * then marks the app as unable to run. So the game runs in a folder of its
 * own, ~/Library/Caches/<bundle id>/run, holding a game_files link to the
 * bundle's data, renewed each launch (the app may have moved); and the DSP
 * programs the runtime would save for the next build are not saved.
 * MM3_GAME_ROOT names another folder holding game_files/; the bare
 * executable run from the repository uses the working directory. */
static int find_game_dir(void)
{
    char path[4096], run[4096], link_path[4200];
    const char *env = getenv("MM3_GAME_ROOT"), *home = getenv("HOME");
    NSString *res = [[NSBundle mainBundle] resourcePath];
    if (env && chdir(env) == 0) return 1;
    if (res && home) {
        snprintf(path, sizeof path, "%s/game_files", [res fileSystemRepresentation]);
        snprintf(link_path, sizeof link_path, "%s/default.xbe", path);
        if (access(link_path, R_OK) == 0) {
            snprintf(run, sizeof run, "%s/Library/Caches/org.mm3-port.midtown-madness-3/run", home);
            [[NSFileManager defaultManager] createDirectoryAtPath:[NSString stringWithUTF8String:run]
                                      withIntermediateDirectories:YES attributes:nil error:nil];
            snprintf(link_path, sizeof link_path, "%s/game_files", run);
            unlink(link_path);
            if (symlink(path, link_path) == 0 && chdir(run) == 0) {
                setenv("RECOMP_DSP_PROGRAM_DIR", "", 0);
                return 1;
            }
        }
    }
    return access("game_files/default.xbe", R_OK) == 0;
}

/* Opened from Finder the game's output goes nowhere, unless Debug > Keep a
 * Log is on: then to ~/Library/Logs/Midtown Madness 3.log, where Console and
 * a bug report can find it. */
static void redirect_log(void)
{
    char path[4096];
    const char *home = getenv("HOME");
    struct stat st, null_st;
    if (![[NSUserDefaults standardUserDefaults] boolForKey:@"KeepLog"]) return;
    /* LaunchServices hands an app /dev/null; a terminal, file or pipe that
     * the caller chose stays as it is. */
    if (!home || fstat(STDERR_FILENO, &st) != 0 || stat("/dev/null", &null_st) != 0 ||
        st.st_rdev != null_st.st_rdev || !S_ISCHR(st.st_mode))
        return;
    snprintf(path, sizeof path, "%s/Library/Logs/Midtown Madness 3.log", home);
    if (freopen(path, "w", stderr)) {
        setvbuf(stderr, NULL, _IOLBF, 0);
        dup2(STDERR_FILENO, STDOUT_FILENO);
    }
}

/* Mac defaults, each overridable from the environment: the picture takes
 * the window's shape (upstream fixes 16:10), and the game renders 1440 lines
 * -- 2560x1440 at 16:9 -- however large the window, the size that looks
 * right on a Retina desktop without paying for 5K. */
static void mac_defaults(void)
{
    if (!getenv("RECOMP_ASPECT")) setenv("RECOMP_ASPECT", "auto", 1);
    if (!getenv("RECOMP_RENDER_SCALE")) {
        /* The upstream profile would otherwise pin 2.0 (960 lines). */
        int lines = saved_render_lines();
        char scale[32];
        snprintf(scale, sizeof scale, "%g", (lines > 0 ? lines : DEFAULT_RENDER_LINES) / 480.0);
        setenv("RECOMP_RENDER_SCALE", scale, 1);
        if (lines == 0) nv2a_metal_request_render_lines(0);
    }
    if (!getenv("RECOMP_MSAA")) {
        char n[16];
        snprintf(n, sizeof n, "%d", saved_setting(&s_settings[1]));
        setenv("RECOMP_MSAA", n, 1);
    }
    if (!getenv("RECOMP_ANISO")) setenv("RECOMP_ANISO", "16", 1);
}

/* Whether another process holds dir/.running (a copy of the game on it). */
static int save_dir_busy(const char *dir)
{
    char path[4200];
    int fd, busy;
    snprintf(path, sizeof path, "%s/.running", dir);
    if ((fd = open(path, O_RDWR | O_CLOEXEC)) < 0) return 0;
    busy = flock(fd, LOCK_EX | LOCK_NB) != 0;
    close(fd);
    return busy;
}

/* The save drive: ~/Library/Application Support/Midtown Madness 3, unless
 * MM3_SAVE_DIR names one. Builds before 2026-10-16 used the runtime's
 * generic ".../xboxrecomp"; that folder is moved here once (a rename, so
 * instant), unless the new one exists already or a copy of an older build
 * is still playing from it. Returns 0 when such a copy is running. */
static int choose_save_dir(void)
{
    char dir[4096], old[4096];
    const char *home = getenv("HOME");
    struct stat st;
    if (getenv("MM3_SAVE_DIR") && *getenv("MM3_SAVE_DIR")) return 1;
    if (!home || !*home) home = ".";
    snprintf(dir, sizeof dir, "%s/Library/Application Support/Midtown Madness 3", home);
    snprintf(old, sizeof old, "%s/Library/Application Support/xboxrecomp", home);
    if (stat(dir, &st) != 0 && stat(old, &st) == 0 && S_ISDIR(st.st_mode)) {
        if (save_dir_busy(old)) return 0;
        if (rename(old, dir) == 0)
            fprintf(stderr, "[SAVE] moved the saves from %s to %s\n", old, dir);
        else {
            fprintf(stderr, "[SAVE] cannot move %s (%s); using it where it is\n", old, strerror(errno));
            snprintf(dir, sizeof dir, "%s", old);
        }
    }
    setenv("MM3_SAVE_DIR", dir, 1);
    return 1;
}

/* One game per save drive: two would write the same disk images and saves.
 * Held until exit (the descriptor is never closed). */
static int single_instance(void)
{
    char dir[4096], path[4200];
    const char *save = getenv("MM3_SAVE_DIR");
    int fd;
    snprintf(dir, sizeof dir, "%s", save && *save ? save : ".");
    mkdir(dir, 0755);
    snprintf(path, sizeof path, "%s/.running", dir);
    fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0644);
    if (fd < 0) return 1;                   /* cannot tell; do not block play */
    return flock(fd, LOCK_EX | LOCK_NB) == 0;
}

static void already_running_alert(void)
{
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Midtown Madness 3 is already running"];
    [alert setInformativeText:@"Only one copy can use the saved games at a time."];
    [alert addButtonWithTitle:@"Quit"];
    if (@available(macOS 14.0, *)) [NSApp activate]; else [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
}

static void no_game_alert(void)
{
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Game files not found"];
    [alert setInformativeText:
        @"Midtown Madness 3 needs the files from your own disc, which a "
        @"packaged app carries inside it; this copy has none. Building from "
        @"source: run scripts/setup.sh --iso <your disc image>, then "
        @"scripts/package.sh."];
    [alert addButtonWithTitle:@"Quit"];
    if (@available(macOS 14.0, *)) [NSApp activate]; else [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
}

static void build_menu(void)
{
    NSMenu *bar = [[NSMenu alloc] init];
    NSMenuItem *app_item = [[NSMenuItem alloc] init];
    NSMenu *app_menu = [[NSMenu alloc] init];
    [bar addItem:app_item];
    [app_menu addItemWithTitle:@"Quit Midtown Madness 3" action:@selector(terminate:) keyEquivalent:@"q"];
    [app_item setSubmenu:app_menu];
    {
        NSMenuItem *gfx_item = [[NSMenuItem alloc] init];
        NSMenu *gfx = [[NSMenu alloc] initWithTitle:@"Graphics"];
        int k;
        for (k = 0; k < SETTING_COUNT; k++) {
            const Setting *st = &s_settings[k];
            NSString *title = [NSString stringWithUTF8String:st->title];
            NSMenuItem *sub_item = [[NSMenuItem alloc] initWithTitle:title action:NULL keyEquivalent:@""];
            NSMenu *sub = [[NSMenu alloc] initWithTitle:title];
            /* Built before mac_defaults, so only the user's own setting is
             * seen; with one the menu starts unticked. */
            int current = getenv(st->env) ? -1 : saved_setting(st), i;
            for (i = 0; i < st->count; i++) {
                NSMenuItem *it = [[NSMenuItem alloc]
                    initWithTitle:[NSString stringWithUTF8String:st->choices[i].title]
                           action:@selector(chooseSetting:) keyEquivalent:@""];
                [it setTag:st->choices[i].value];
                [it setTarget:[NSApp delegate]];
                if (st->choices[i].value == current) [it setState:NSControlStateValueOn];
                [sub addItem:it];
                [it release];
            }
            [sub_item setSubmenu:sub];
            [gfx addItem:sub_item];
            [sub release]; [sub_item release];
        }
        [gfx_item setSubmenu:gfx];
        [bar addItem:gfx_item];
        [gfx release]; [gfx_item release];
    }
    {   /* Debug: diagnostics for reporting a problem. */
        NSMenuItem *dbg_item = [[NSMenuItem alloc] init];
        NSMenu *dbg = [[NSMenu alloc] initWithTitle:@"Debug"];
        NSMenuItem *save = [[NSMenuItem alloc] initWithTitle:@"Save Recent Frames"
                                                     action:@selector(saveRecentFrames:)
                                              keyEquivalent:@"s"];
        [save setKeyEquivalentModifierMask:NSEventModifierFlagCommand | NSEventModifierFlagShift];
        [save setTarget:[NSApp delegate]];
        [dbg addItem:save];
        {
            NSMenuItem *pack = [[NSMenuItem alloc] initWithTitle:@"Texture Pack"
                                                         action:@selector(toggleTexturePack:)
                                                  keyEquivalent:@"t"];
            [pack setKeyEquivalentModifierMask:NSEventModifierFlagCommand | NSEventModifierFlagShift];
            [pack setTarget:[NSApp delegate]];
            [pack setState:NSControlStateValueOn];
            [dbg addItem:pack];
            [pack release];
        }
        {
            NSMenuItem *log = [[NSMenuItem alloc] initWithTitle:@"Keep a Log (from Next Launch)"
                                                        action:@selector(toggleKeepLog:)
                                                 keyEquivalent:@""];
            [log setTarget:[NSApp delegate]];
            [log setState:[[NSUserDefaults standardUserDefaults] boolForKey:@"KeepLog"]
                          ? NSControlStateValueOn : NSControlStateValueOff];
            [dbg addItem:log];
            [log release];
        }
        [dbg_item setSubmenu:dbg];
        [bar addItem:dbg_item];
        [save release]; [dbg release]; [dbg_item release];
    }
    [NSApp setMainMenu:bar];
}

int main(int argc, char **argv)
{
    pthread_attr_t attr;
    pthread_t thread;
    (void)argc; (void)argv;
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        {   /* The bundle's icon comes from its Info.plist; the bare build-tree
             * binary has none, so it takes the same file from the source tree. */
            NSString *icon = [[NSBundle mainBundle] pathForResource:@"AppIcon" ofType:@"icns"];
            NSImage *img;
#ifdef MM3_BUILD_ROOT
            if (!icon) icon = [NSString stringWithUTF8String:MM3_BUILD_ROOT "/mac/bundle/AppIcon.icns"];
#endif
            if ((img = [[NSImage alloc] initWithContentsOfFile:icon])) {
                [NSApp setApplicationIconImage:img];
                [img release];
            }
        }
        [NSApp setDelegate:[[MM3AppDelegate alloc] init]];
        build_menu();
        redirect_log();
        /* The simulation, audio and frame pacing run on their own threads
         * and timers; App Nap would throttle them whenever the window is
         * hidden or the display sleeps, and the game falls behind real
         * time. Held for the life of the process. */
        [[[NSProcessInfo processInfo]
            beginActivityWithOptions:NSActivityUserInitiated | NSActivityLatencyCritical
                              reason:@"Game simulation and audio"] retain];
        if (!find_game_dir()) {
            no_game_alert();
            return 1;
        }
        if (!choose_save_dir() || !single_instance()) {
            fprintf(stderr, "another copy is running on this save drive\n");
            already_running_alert();
            return 1;
        }
        mac_defaults();
        pthread_attr_init(&attr);
        pthread_attr_setstacksize(&attr, GAME_STACK_BYTES);
        if (pthread_create(&thread, &attr, game_thread, NULL) != 0) {
            fprintf(stderr, "cannot start the game thread\n");
            return 1;
        }
        pthread_attr_destroy(&attr);
        [NSApp run];
    }
    return 0;
}
