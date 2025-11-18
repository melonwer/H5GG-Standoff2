#import "HUDMain.h"
#import <mach/mach.h>
#import <mach/processor_set.h>
#import <notify.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <string.h>

/**
 * HUDMain.mm
 *
 * HUD root helper process implementation with PORT INJECTION.
 *
 * This process is spawned with UID 0 (root) and runs a server loop that
 * listens for IPC requests from the main H5GG app. Each request asks for
 * a task port for a specific PID.
 *
 * CRITICAL: The HUD acquires TWO task ports (target + app) and uses
 * mach_port_insert_right() to inject the target port into the app's
 * namespace. This is necessary because port numbers are namespace-local!
 *
 * IPC Protocol:
 * - Request contains: targetPid (game) + appPid (H5GG)
 * - HUD finds both tasks
 * - HUD injects target port into app's namespace using mach_port_insert_right
 * - HUD returns the injected port name (valid in app's namespace)
 */

#define HUD_DIR "/tmp/h5gg_hud"
#define HUD_REQUEST_FILE HUD_DIR "/request.bin"
#define HUD_RESPONSE_FILE HUD_DIR "/response.bin"
#define HUD_NOTIFY_REQUEST "com.h5gg.hud.request"
#define HUD_NOTIFY_RESPONSE "com.h5gg.hud.response"

// IPC Protocol structures (UPDATED with appPid)
typedef struct {
    pid_t targetPid;  // PID of game to acquire port for
    pid_t appPid;     // PID of H5GG app (for port namespace injection)
} HUD_Request;

typedef struct {
    uint32_t success;  // 1 = success, 0 = failure
    task_port_t taskPort;  // Port name (injected into app's namespace)
} HUD_Response;

// ============================================================================
// Helper: Find task port for any PID using processor_set enumeration
// ============================================================================
task_port_t HUD_FindTaskForPID(pid_t targetPid) {
    NSLog(@"[HUD] Finding task port for PID %d", targetPid);

    host_t myhost = mach_host_self();
    task_port_t psDefault = MACH_PORT_NULL;
    task_port_t psDefault_control = MACH_PORT_NULL;
    task_array_t tasks = NULL;
    mach_msg_type_number_t numTasks = 0;
    kern_return_t kr;
    task_port_t foundTask = MACH_PORT_NULL;

    // Get default processor set
    kr = processor_set_default(myhost, &psDefault);
    if (kr != KERN_SUCCESS) {
        NSLog(@"[HUD]   ✗ processor_set_default failed: %s", mach_error_string(kr));
        return MACH_PORT_NULL;
    }

    // Get privileged access to processor set (works because we're root)
    kr = host_processor_set_priv(myhost, psDefault, &psDefault_control);
    if (kr != KERN_SUCCESS) {
        NSLog(@"[HUD]   ✗ host_processor_set_priv failed: %s", mach_error_string(kr));
        mach_port_deallocate(mach_task_self(), psDefault);
        return MACH_PORT_NULL;
    }

    // Enumerate all tasks
    kr = processor_set_tasks(psDefault_control, &tasks, &numTasks);
    if (kr != KERN_SUCCESS) {
        NSLog(@"[HUD]   ✗ processor_set_tasks failed: %s", mach_error_string(kr));
        mach_port_deallocate(mach_task_self(), psDefault);
        mach_port_deallocate(mach_task_self(), psDefault_control);
        return MACH_PORT_NULL;
    }

    NSLog(@"[HUD]   Enumerated %u tasks, searching for PID %d", numTasks, targetPid);

    // Find the target PID
    for (mach_msg_type_number_t i = 0; i < numTasks; i++) {
        pid_t pid = 0;
        kern_return_t pidKr = pid_for_task(tasks[i], &pid);

        if (pidKr == KERN_SUCCESS && pid == targetPid) {
            foundTask = tasks[i];  // Keep this one
            NSLog(@"[HUD]   ✓ Found PID %d at task index %u", targetPid, i);
        } else {
            mach_port_deallocate(mach_task_self(), tasks[i]);  // Release others
        }
    }

    // Cleanup
    if (tasks != NULL) {
        vm_deallocate(mach_task_self(), (vm_address_t)tasks, numTasks * sizeof(task_port_t));
    }

    mach_port_deallocate(mach_task_self(), psDefault);
    mach_port_deallocate(mach_task_self(), psDefault_control);

    if (foundTask == MACH_PORT_NULL) {
        NSLog(@"[HUD]   ✗ PID %d not found", targetPid);
    }

    return foundTask;
}

// ============================================================================
// HUD Server Main Loop with PORT INJECTION
// ============================================================================
void HUD_MainServerLoop(void) {
    NSLog(@"\n╔═════════════════════════════════════════════════════════════════╗");
    NSLog(@"║           HUD Root Helper Process Started (UID: %d)               ║", getuid());
    NSLog(@"╚═════════════════════════════════════════════════════════════════╝\n");

    // Ensure directory exists
    mkdir(HUD_DIR, 0777);
    chmod(HUD_DIR, 0777);

    // Register for request notifications
    int notifyToken;
    int regErr = notify_register_dispatch(HUD_NOTIFY_REQUEST, &notifyToken, dispatch_get_main_queue(), ^(int token) {
        NSLog(@"[HUD] ───────────────────────────────────────────────────────────");
        NSLog(@"[HUD] Processing request notification");

        // Read request
        int fd = open(HUD_REQUEST_FILE, O_RDONLY);
        if (fd < 0) {
            NSLog(@"[HUD] ✗ Cannot open request file: %s", strerror(errno));
            return;
        }

        HUD_Request req = {0};
        ssize_t bytesRead = read(fd, &req, sizeof(req));
        close(fd);

        if (bytesRead != sizeof(req)) {
            NSLog(@"[HUD] ✗ Invalid request (read %zd bytes, expected %zu)", bytesRead, sizeof(req));
            return;
        }

        NSLog(@"[HUD] REQUEST: targetPid=%d, appPid=%d", req.targetPid, req.appPid);

        // Verify privilege level
        NSLog(@"[HUD] Privilege check: UID=%d, EUID=%d", getuid(), geteuid());
        if (getuid() != 0 || geteuid() != 0) {
            NSLog(@"[HUD] ✗ ERROR: Not running as root!");
            NSLog(@"[HUD] ───────────────────────────────────────────────────────────");
            return;
        }

        HUD_Response resp = {0};
        resp.success = 0;

        // Declare variables at top to avoid goto issues
        task_port_t targetTask = MACH_PORT_NULL;
        task_port_t appTask = MACH_PORT_NULL;
        mach_port_name_t nameInApp = MACH_PORT_NULL;
        kern_return_t kr;

        // STEP 1: Find target task (the game)
        NSLog(@"[HUD] STEP 1: Finding target task (game PID %d)...", req.targetPid);
        targetTask = HUD_FindTaskForPID(req.targetPid);

        if (targetTask == MACH_PORT_NULL) {
            NSLog(@"[HUD] ✗ Failed to find target task");
            NSLog(@"[HUD] ───────────────────────────────────────────────────────────");
            goto respond;
        }

        NSLog(@"[HUD] ✓ Found target task: %u", targetTask);

        // STEP 2: Find app task (H5GG)
        NSLog(@"[HUD] STEP 2: Finding app task (H5GG PID %d)...", req.appPid);
        appTask = HUD_FindTaskForPID(req.appPid);

        if (appTask == MACH_PORT_NULL) {
            NSLog(@"[HUD] ✗ Failed to find app task");
            mach_port_deallocate(mach_task_self(), targetTask);
            NSLog(@"[HUD] ───────────────────────────────────────────────────────────");
            goto respond;
        }

        NSLog(@"[HUD] ✓ Found app task: %u", appTask);

        // STEP 3: Inject target port into app's namespace
        NSLog(@"[HUD] STEP 3: Injecting target port into app namespace...");

        // Allocate a name in the app's port space
        kr = mach_port_allocate(appTask, MACH_PORT_RIGHT_DEAD_NAME, &nameInApp);

        if (kr != KERN_SUCCESS) {
            NSLog(@"[HUD] ✗ mach_port_allocate failed in app: %s", mach_error_string(kr));
            mach_port_deallocate(mach_task_self(), targetTask);
            mach_port_deallocate(mach_task_self(), appTask);
            NSLog(@"[HUD] ───────────────────────────────────────────────────────────");
            goto respond;
        }

        NSLog(@"[HUD]   ✓ Allocated port name in app: %u", nameInApp);

        // Insert a send right to targetTask into the app's namespace at nameInApp
        kr = mach_port_insert_right(appTask, nameInApp, targetTask, MACH_MSG_TYPE_COPY_SEND);

        if (kr != KERN_SUCCESS) {
            NSLog(@"[HUD] ✗ mach_port_insert_right failed: %s", mach_error_string(kr));
            mach_port_deallocate(appTask, nameInApp);  // Cleanup
            mach_port_deallocate(mach_task_self(), targetTask);
            mach_port_deallocate(mach_task_self(), appTask);
            NSLog(@"[HUD] ───────────────────────────────────────────────────────────");
            goto respond;
        }

        NSLog(@"[HUD] ✓✓✓ SUCCESS: Port injected into app's namespace!");
        NSLog(@"[HUD]   Target port %u is now accessible as %u in app's namespace",
              targetTask, nameInApp);

        resp.success = 1;
        resp.taskPort = nameInApp;  // This name is VALID in the app's namespace!

        // Cleanup local references in HUD
        mach_port_deallocate(mach_task_self(), targetTask);
        mach_port_deallocate(mach_task_self(), appTask);

respond:
        // Write response
        int fd2 = open(HUD_RESPONSE_FILE, O_WRONLY | O_CREAT | O_TRUNC, 0666);
        if (fd2 >= 0) {
            ssize_t written = write(fd2, &resp, sizeof(resp));
            close(fd2);

            if (written == sizeof(resp)) {
                NSLog(@"[HUD] ✓ Response written: success=%d, port=%u",
                      resp.success, resp.taskPort);
            } else {
                NSLog(@"[HUD] ✗ Failed to write full response (%zd bytes)", written);
            }
        } else {
            NSLog(@"[HUD] ✗ Cannot open response file: %s", strerror(errno));
        }

        // Notify client that response is ready
        notify_post(HUD_NOTIFY_RESPONSE);
        NSLog(@"[HUD] ───────────────────────────────────────────────────────────\n");
    });

    if (regErr != NOTIFY_STATUS_OK) {
        NSLog(@"[HUD] ✗ Failed to register for notifications: %d", regErr);
        exit(1);
    }

    NSLog(@"[HUD] ✓ Server running, listening for requests");
    NSLog(@"[HUD] ════════════════════════════════════════════════════════════\n");

    // Keep the server alive
    [[NSRunLoop currentRunLoop] run];

    // Never reaches here
    NSLog(@"[HUD] Server exiting unexpectedly");
    exit(0);
}

// ============================================================================
// Argument parsing
// ============================================================================
BOOL HUD_ShouldRunAsHUD(int argc, char **argv) {
    // Check for -hud argument
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-hud") == 0) {
            return YES;
        }
    }
    return NO;
}
