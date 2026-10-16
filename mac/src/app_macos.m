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

/* The Graphics menu: render resolution (lines; 0 follows the window),
 * applied at the next frame and remembered in the user defaults; an explicit
 * RECOMP_RENDER_SCALE wins at launch. Anti-aliasing and texture filtering
 * are fixed at 4x MSAA and 16x anisotropic: on these GPUs neither costs a
 * measurable frame and lower settings looked no different, so they are not
 * worth a menu (RECOMP_MSAA / RECOMP_ANISO still choose). */
extern void nv2a_metal_request_render_lines(int lines);
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
#define DEFAULT_RENDER_LINES 1440
static const Setting s_settings[] = {
    { "Resolution", "RenderLines", "RECOMP_RENDER_SCALE", DEFAULT_RENDER_LINES,
      nv2a_metal_request_render_lines, s_resolutions, 5 },
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

static int saved_setting(const Setting *st)
{
    NSUserDefaults *u = [NSUserDefaults standardUserDefaults];
    NSString *k = [NSString stringWithUTF8String:st->key];
    if ([u objectForKey:k]) return (int)[u integerForKey:k];
    return st == &s_settings[0] ? default_render_lines() : st->def;
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

/* Started from the build tree or a bundle: run where game_files/ is --
 * MM3_GAME_ROOT, the current directory, a directory above the executable,
 * or the tree the app was built from. Returns 0 when there is none. */
static int find_game_dir(void)
{
    char path[4096];
    const char *env = getenv("MM3_GAME_ROOT");
    if (env && chdir(env) == 0) return 1;
    if (access("game_files/default.xbe", R_OK) == 0) return 1;
    {
        NSString *exe = [[NSBundle mainBundle] executablePath];
        NSString *dir = [exe stringByDeletingLastPathComponent];
        while ([dir length] > 1) {
            snprintf(path, sizeof path, "%s/game_files/default.xbe", [dir fileSystemRepresentation]);
            if (access(path, R_OK) == 0) return chdir([dir fileSystemRepresentation]) == 0;
            dir = [dir stringByDeletingLastPathComponent];
        }
    }
#ifdef MM3_BUILD_ROOT
    snprintf(path, sizeof path, "%s/game_files/default.xbe", MM3_BUILD_ROOT);
    if (access(path, R_OK) == 0) return chdir(MM3_BUILD_ROOT) == 0;
#endif
    return 0;
}

/* Opened from Finder there is no terminal: keep the log where Console and a
 * bug report can find it, ~/Library/Logs/Midtown Madness 3.log. */
static void redirect_log(void)
{
    char path[4096];
    const char *home = getenv("HOME");
    struct stat st, null_st;
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
    if (!getenv("RECOMP_MSAA")) setenv("RECOMP_MSAA", "4", 1);
    if (!getenv("RECOMP_ANISO")) setenv("RECOMP_ANISO", "16", 1);
}

/* One game per save drive: two would write the same disk images and saves.
 * Held until exit (the descriptor is never closed). */
static int single_instance(void)
{
    char dir[4096], path[4200];
    const char *save = getenv("MM3_SAVE_DIR"), *home = getenv("HOME");
    int fd;
    if (save && *save) snprintf(dir, sizeof dir, "%s", save);
    else snprintf(dir, sizeof dir, "%s/Library/Application Support/xboxrecomp", home ? home : ".");
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
        @"Midtown Madness 3 needs the files from your own disc. Run "
        @"scripts/setup.sh --iso <your disc image> in the mm3-port folder, "
        @"or set MM3_GAME_ROOT to the folder that contains game_files/."];
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
        if (!single_instance()) {
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
