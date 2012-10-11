#import "include/cef_application_mac.h"
#import "native/atom_cef_client.h"
#import "native/atom_application.h"
#import "native/atom_window_controller.h"
#import "native/atom_cef_app.h"
#import <getopt.h>

@implementation AtomApplication

@synthesize arguments=_arguments;

+ (AtomApplication *)sharedApplication {
  return (AtomApplication *)[super sharedApplication];
}

+ (id)applicationWithArguments:(char **)argv count:(int)argc {
  AtomApplication *application = [self sharedApplication];
  CefInitialize(CefMainArgs(argc, argv), [self createCefSettings], new AtomCefApp);
  application.arguments = [self parseArguments:argv count:argc];
  
  return application;
}

+ (NSDictionary *)parseArguments:(char **)argv count:(int)argc {
  NSMutableDictionary *arguments = [[NSMutableDictionary alloc] init];
  
  #ifdef RESOURCE_PATH
    [arguments setObject:[NSString stringWithUTF8String:RESOURCE_PATH] forKey:@"resource-path"];
  #endif
  
  // Remove non-posix (i.e. -long_argument_with_one_leading_hyphen) added by OS X from the command line
  size_t argvSize = argc * sizeof(char *);
  char **cleanArgv = (char **)alloca(argvSize);
  memcpy(cleanArgv, argv, argvSize);
  char noop[] = "--noop";
  for (int i=0; i < argc; i++) {
    if (strcmp(cleanArgv[i], "-NSDocumentRevisionsDebugMode") == 0) { // Xcode inserts useless command-line args by default: http://trac.wxwidgets.org/ticket/13732
        cleanArgv[i] = noop;
        cleanArgv[++i] = noop;
    }
    else if (strncmp(cleanArgv[i], "-psn_", 5) == 0) { // OS X inserts a -psn_[PID] argument.
      cleanArgv[i] = noop;
    }
  }

  int opt;
  int longindex;

  static struct option longopts[] = {
    { "executed-from",      optional_argument,      NULL,  'K'  },
    { "resource-path",      optional_argument,      NULL,  'r'  },
    { "benchmark",          optional_argument,      NULL,  'b'  },
    { "test",               optional_argument,      NULL,  't'  },
    { "noop",               optional_argument,      NULL,  NULL },
    { NULL,                 0,                      NULL,  0 }
  };

  while ((opt = getopt_long(argc, cleanArgv, "r:K:bth?", longopts, &longindex)) != -1) {
    NSString *key, *value;
    switch (opt) {
      case 'K':
      case 'r':
      case 'b':
      case 't':
        key = [NSString stringWithUTF8String:longopts[longindex].name];
        value = optarg ? [NSString stringWithUTF8String:optarg] : @"YES";
        [arguments setObject:value forKey:key];
        break;
      case 0:
        break;
      default:
        NSLog(@"usage: atom [--resource-path=<path>] [<path>]");
    }
  }
  
  argc -= optind;
  argv += optind;
  
  if (argc > 0) {
    NSString *path = [NSString stringWithUTF8String:argv[0]];
    NSString *executedFromPath =[arguments objectForKey:@"executed-from"];
    if (![path isAbsolutePath] && executedFromPath) {
      path = [executedFromPath stringByAppendingPathComponent:path];
    }
    path = [path stringByStandardizingPath];
    [arguments setObject:path forKey:@"path"];
  }
  
  
  return arguments;
}

+ (NSString *)supportDirectory {
  NSString *cachePath = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) objectAtIndex:0];
  NSString *executableName = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleExecutable"];
  NSString *supportDirectory = [cachePath stringByAppendingPathComponent:executableName];

  NSFileManager *fs = [NSFileManager defaultManager];
  NSError *error;
  BOOL success = [fs createDirectoryAtPath:supportDirectory withIntermediateDirectories:YES attributes:nil error:&error];
  if (!success) {
    NSLog(@"Warning: Can't create support directory '%@' because %@", supportDirectory, [error localizedDescription]);
    supportDirectory = @"";
  }

  return supportDirectory;
}
  
+ (CefSettings)createCefSettings {
  CefSettings settings;

  CefString(&settings.cache_path) = [[self supportDirectory] UTF8String];
  CefString(&settings.user_agent) = "";
  CefString(&settings.log_file) = "";
  CefString(&settings.javascript_flags) = "";
  settings.remote_debugging_port = 9090;
  settings.log_severity = LOGSEVERITY_ERROR;
  return settings;
}

- (void)dealloc {
  [_backgroundWindowController release];
  [_arguments release];
  [super dealloc];
}

- (void)open:(NSString *)path {
  [[AtomWindowController alloc] initWithPath:path];
}

- (IBAction)runSpecs:(id)sender {
  [self runSpecsThenExit:NO];
}

- (void)runSpecsThenExit:(BOOL)exitWhenDone {
  [[AtomWindowController alloc] initSpecsThenExit:exitWhenDone];
}

- (IBAction)runBenchmarks:(id)sender {
  [self runBenchmarksThenExit:NO];
}

- (void)runBenchmarksThenExit:(BOOL)exitWhenDone {
  [[AtomWindowController alloc] initBenchmarksThenExit:exitWhenDone];
}

# pragma mark NSApplicationDelegate

- (void)applicationWillFinishLaunching:(NSNotification *)notification {
  _backgroundWindowController = [[AtomWindowController alloc] initInBackground];
  
  if ([self.arguments objectForKey:@"benchmark"]) {
    [self runBenchmarksThenExit:true];
  }
  else if ([self.arguments objectForKey:@"test"]) {
    [self runSpecsThenExit:true];
  }
  else {
    NSString *path = [self.arguments objectForKey:@"path"];

    // Just a hack to open the Atom src by default when we run from xcode
    #ifdef RESOURCE_PATH
    if (!path) path = [NSString stringWithUTF8String:RESOURCE_PATH];
    #endif

    [self open:path];
  }
}

- (void)applicationWillTerminate:(NSNotification *)notification {
  NSInteger windowCount = [[self windows] count];
  for(int i = 0; i < windowCount; i++) {
    NSWindow *window = [[self windows] objectAtIndex:i];
    [window performClose:0];
  }
  CefShutdown();
}

# pragma mark CefAppProtocol

- (BOOL)isHandlingSendEvent {
  return handlingSendEvent_;
}

- (void)setHandlingSendEvent:(BOOL)handlingSendEvent {
  handlingSendEvent_ = handlingSendEvent;
}

- (void)sendEvent:(NSEvent*)event {
  CefScopedSendingEvent sendingEventScoper;
  if ([[self mainMenu] performKeyEquivalent:event]) return;

  if (_backgroundWindowController && ![self keyWindow] && [event type] == NSKeyDown) {
    [_backgroundWindowController.window makeKeyWindow];
    [_backgroundWindowController.window sendEvent:event];
  }
  else {
    [super sendEvent:event];
  }
}

@end

