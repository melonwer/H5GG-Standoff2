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
 * HUD root helper process implementation.
 *
 * This process is spawned with UID 0 (root) and runs a server loop that
 * listens for IPC requests from the main H5GG app. Each request asks for
 * a task port for a specific PID.
 *
 * The HUD uses processor_set_tasks enumeration to acquire task ports.
 * This is an undetectable method that doesn't call task_for_pid directly,
 * avoiding anti-cheat detection vectors.
 *
 * IPC Protocol:
 * - Listens for Darwin notifications at: com.h5gg.hud.request
 * - Reads request from: /tmp/h5gg_hud/request.bin
 * - Writes response to: /tmp/h5gg_hud/response.bin
 * - Posts completion notification: com.h5gg.hud.response
 */

#define HUD_DIR "/tmp/h5gg_hud"
#define HUD_REQUEST_FILE HUD_DIR "/request.bin"
#define HUD_RESPONSE_FILE HUD_DIR "/response.bin"
#define HUD_NOTIFY_REQUEST "com.h5gg.hud.request"
#define HUD_NOTIFY_RESPONSE "com.h5gg.hud.response"

// IPC Protocol structures (must match HUDSpawner.mm)
typedef struct {
    pid_t targetPid;
} HUD_Request;

typedef struct {
    uint32_t success;
    task_port_t taskPort;
} HUD_Response;

// ============================================================================
// Core task port acquisition via processor_set_tasks (undetectable)
// ============================================================================
task_port_t HUD_AcquireTaskPort(pid_t targetPid) {
    // CRITICAL DIAGNOSTIC: Check if persona flags actually worked
    uid_t actual_uid = getuid();
    uid_t actual_euid = geteuid();

    NSLog(@"[HUD] ════════════════════════════════════════════════════════");
    NSLog(@"[HUD] PRIVILEGE DIAGNOSTIC:");
    NSLog(@"[HUD]   Real UID: %d", actual_uid);
    NSLog(@"[HUD]   Effective UID: %d", actual_euid);

    if (actual_uid == 0 && actual_euid == 0) {
        NSLog(@"[HUD]   ✓✓✓ SUCCESS: Running as ROOT ✓✓✓");
    } else {
        NSLog(@"[HUD]   ✗ FAILURE: NOT running as root (expected UID 0)");
        NSLog(@"[HUD]   This means persona flags did NOT work!");
    }
    NSLog(@"[HUD] ════════════════════════════════════════════════════════");

    NSLog(@"[HUD] Attempting to acquire task port for PID %d (UID: %d)", targetPid, actual_uid);

    host_t myhost = mach_host_self();
    task_port_t psDefault = MACH_PORT_NULL;
    task_port_t psDefault_control = MACH_PORT_NULL;
    task_array_t tasks = NULL;
    mach_msg_type_number_t numTasks = 0;
    kern_return_t kr;

    // Get the default processor set
    kr = processor_set_default(myhost, &psDefault);
    if (kr != KERN_SUCCESS) {
        NSLog(@"[HUD] ✗ processor_set_default failed: %s (0x%x)", mach_error_string(kr), kr);
        return MACH_PORT_NULL;
    }

    // Get privileged access to the processor set
    // This succeeds because we're running as UID 0 (root)
    kr = host_processor_set_priv(myhost, psDefault, &psDefault_control);
    if (kr != KERN_SUCCESS) {
        NSLog(@"[HUD] ✗ host_processor_set_priv FAILED: %s (0x%x)", mach_error_string(kr), kr);
        mach_port_deallocate(mach_task_self(), psDefault);
        return MACH_PORT_NULL;
    }

    NSLog(@"[HUD] ✓ Obtained privileged processor set access (UID: %d)", getuid());

    // Enumerate all tasks in the processor set
    // This is the undetectable method - no task_for_pid call
    kr = processor_set_tasks(psDefault_control, &tasks, &numTasks);
    if (kr != KERN_SUCCESS) {
        NSLog(@"[HUD] ✗ processor_set_tasks failed: %s (0x%x)", mach_error_string(kr), kr);
        mach_port_deallocate(mach_task_self(), psDefault);
        mach_port_deallocate(mach_task_self(), psDefault_control);
        return MACH_PORT_NULL;
    }

    NSLog(@"[HUD] ✓ Got task array with %u tasks", numTasks);

    // Search for the target PID
    task_port_t targetTask = MACH_PORT_NULL;
    for (mach_msg_type_number_t i = 0; i < numTasks; i++) {
        pid_t pid = 0;
        kern_return_t pidKr = pid_for_task(tasks[i], &pid);

        if (pidKr == KERN_SUCCESS && pid == targetPid) {
            targetTask = tasks[i];
            NSLog(@"[HUD] ✓✓✓ FOUND TARGET PID %d! ✓✓✓", targetPid);

            // Deallocate all other tasks
            for (mach_msg_type_number_t j = 0; j < numTasks; j++) {
                if (j != i) {
                    mach_port_deallocate(mach_task_self(), tasks[j]);
                }
            }
            break;
        } else {
            mach_port_deallocate(mach_task_self(), tasks[i]);
        }
    }

    // Clean up
    if (tasks != NULL) {
        vm_deallocate(mach_task_self(), (vm_address_t)tasks, numTasks * sizeof(task_port_t));
    }

    mach_port_deallocate(mach_task_self(), psDefault);
    mach_port_deallocate(mach_task_self(), psDefault_control);

    if (targetTask == MACH_PORT_NULL) {
        NSLog(@"[HUD] ✗ PID %d not found in task enumeration", targetPid);
    } else {
        NSLog(@"[HUD] ✓ Successfully acquired task port for PID %d", targetPid);
    }

    return targetTask;
}

// ============================================================================
// HUD Server Main Loop
// ============================================================================
void HUD_MainServerLoop(void) {
    NSLog(@"╔═════════════════════════════════════════════════════════════════╗");
    NSLog(@"║           HUD Root Helper Process Started                       ║");
    NSLog(@"╚═════════════════════════════════════════════════════════════════╝");
    NSLog(@"[HUD] PID: %d, UID: %d, EUID: %d", getpid(), getuid(), geteuid());

    // Ensure directory exists
    mkdir(HUD_DIR, 0777);
    chmod(HUD_DIR, 0777);

    // Register for request notifications
    int notifyToken;
    int regErr = notify_register_dispatch(HUD_NOTIFY_REQUEST, &notifyToken, dispatch_get_main_queue(), ^(int token) {
        NSLog(@"[HUD] ───────────────────────────────────────────────────────────");
        NSLog(@"[HUD] Received request notification");

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

        NSLog(@"[HUD] REQUEST: Get task port for PID %d", req.targetPid);

        // Prepare response
        HUD_Response resp = {0};

        // Acquire the task port
        task_port_t port = HUD_AcquireTaskPort(req.targetPid);
        if (port != MACH_PORT_NULL) {
            resp.success = 1;
            resp.taskPort = port;
            NSLog(@"[HUD] RESPONSE: success=1, taskPort=%u", port);
        } else {
            resp.success = 0;
            resp.taskPort = MACH_PORT_NULL;
            NSLog(@"[HUD] RESPONSE: success=0, failed to acquire port");
        }

        // Write response
        fd = open(HUD_RESPONSE_FILE, O_WRONLY | O_CREAT | O_TRUNC, 0666);
        if (fd >= 0) {
            ssize_t written = write(fd, &resp, sizeof(resp));
            close(fd);

            if (written == sizeof(resp)) {
                NSLog(@"[HUD] ✓ Response written successfully");
            } else {
                NSLog(@"[HUD] ✗ Failed to write full response (%zd bytes)", written);
            }
        } else {
            NSLog(@"[HUD] ✗ Cannot open response file: %s", strerror(errno));
        }

        // Notify client that response is ready
        notify_post(HUD_NOTIFY_RESPONSE);
        NSLog(@"[HUD] ✓ Request processed");
        NSLog(@"[HUD] ───────────────────────────────────────────────────────────");
    });

    if (regErr != NOTIFY_STATUS_OK) {
        NSLog(@"[HUD] ✗ Failed to register for notifications: %d", regErr);
        exit(1);
    }

    NSLog(@"[HUD] ✓ Server running and listening for requests");
    NSLog(@"[HUD] Listening on notification: %s", HUD_NOTIFY_REQUEST);
    NSLog(@"[HUD] ════════════════════════════════════════════════════════════\n");

    // Keep the server alive
    // The dispatch queue will handle notifications as they arrive
    [[NSRunLoop currentRunLoop] run];

    // Never reaches here unless NSRunLoop stops (which shouldn't happen)
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
