#import "HUDSpawner.h"
#import <sys/types.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <unistd.h>
#import <fcntl.h>
#import <spawn.h>
#import <mach-o/dyld.h>
#import <notify.h>
#import <signal.h>
#import <pthread.h>
#import <semaphore.h>
#import <errno.h>

/**
 * HUDSpawner.mm
 *
 * Implementation of HUD spawning with SPAWN_AS_ROOT privilege escalation.
 *
 * The HUD process is spawned with persona flags that give it UID 0,
 * allowing it to use processor_set_tasks enumeration for task port acquisition.
 *
 * IPC Protocol (file-based + notifications + semaphores):
 * - Request: /tmp/h5gg_hud/request.bin (PID to look up)
 * - Response: /tmp/h5gg_hud/response.bin (task port result)
 * - Synchronization: Darwin notifications + semaphores
 *
 * Anti-Recursion:
 * - Check argv for -hud flag (don't spawn if already in HUD mode)
 * - PID file /tmp/h5gg_hud/hud.pid to detect existing HUD
 * - Mutex to prevent concurrent spawn attempts
 */

extern "C" char **environ;

// Persona management APIs for privilege escalation
extern "C" int posix_spawnattr_set_persona_np(const posix_spawnattr_t* __restrict, uid_t, uint32_t);
extern "C" int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t* __restrict, uid_t);
extern "C" int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t* __restrict, uid_t);

#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1

#define HUD_DIR "/tmp/h5gg_hud"
#define HUD_REQUEST_FILE HUD_DIR "/request.bin"
#define HUD_RESPONSE_FILE HUD_DIR "/response.bin"
#define HUD_PID_FILE HUD_DIR "/hud.pid"
#define HUD_NOTIFY_REQUEST "com.h5gg.hud.request"
#define HUD_NOTIFY_RESPONSE "com.h5gg.hud.response"

// IPC Protocol structures
typedef struct {
    pid_t targetPid;  // PID to acquire task port for
    pid_t appPid;     // Our PID (so HUD can inject port into our namespace)
} HUD_Request;

typedef struct {
    uint32_t success;  // 1 if successful, 0 if failed
    task_port_t taskPort;  // The task port (injected into our namespace)
} HUD_Response;

// Global state
static pid_t g_hud_pid = 0;
static pthread_mutex_t g_hud_mutex = PTHREAD_MUTEX_INITIALIZER;
static NSMutableDictionary<NSNumber*, NSNumber*> *g_port_cache = nil;
static pthread_mutex_t g_cache_mutex = PTHREAD_MUTEX_INITIALIZER;

// Helper: Create HUD directory with proper permissions
static void HUDSpawner_EnsureDirectory(void) {
    mkdir(HUD_DIR, 0777);
    chmod(HUD_DIR, 0777);
}

// Helper: Get current executable path
static const char* HUDSpawner_GetExecutablePath(void) {
    static char *executablePath = NULL;
    static uint32_t executablePathSize = 0;

    if (executablePath == NULL) {
        _NSGetExecutablePath(NULL, &executablePathSize);
        executablePath = (char *)calloc(1, executablePathSize);
        _NSGetExecutablePath(executablePath, &executablePathSize);
    }

    return executablePath;
}

// Helper: Write HUD PID to file
static void HUDSpawner_WritePIDFile(pid_t pid) {
    int fd = open(HUD_PID_FILE, O_WRONLY | O_CREAT | O_TRUNC, 0666);
    if (fd >= 0) {
        write(fd, &pid, sizeof(pid_t));
        close(fd);
    }
}

// Helper: Check if a process exists
// CRITICAL: This function handles privilege boundaries!
// When HUDSpawner (UID 501) checks a root HUD (UID 0), kill() returns -1 with EPERM.
// EPERM means the process EXISTS but we don't have permission to signal it (it's root).
// This is the success case - the HUD spawned as root!
static BOOL HUDSpawner_ProcessExists(pid_t pid) {
    if (kill(pid, 0) == 0) {
        // Process exists and we have permission
        return YES;
    }

    // Check errno for EPERM (Permission denied)
    if (errno == EPERM) {
        // EPERM = we can't signal the process because it's privileged (root)
        // This actually confirms the process exists and successfully escalated!
        // The HUD spawned as UID 0 and we (UID 501) cannot send signals to it.
        // This is exactly what we want!
        return YES;
    }

    // ESRCH (No such process) or other errors = process is dead
    return NO;
}

BOOL HUDSpawner_Start(void) {
    pthread_mutex_lock(&g_hud_mutex);

    NSLog(@"[HUDSpawner] ════════════════════════════════════════════════════════");
    NSLog(@"[HUDSpawner] Starting HUD process with SPAWN_AS_ROOT");

    // Double-check if already running after acquiring lock
    if (g_hud_pid > 0 && HUDSpawner_ProcessExists(g_hud_pid)) {
        NSLog(@"[HUDSpawner] ✓ HUD already running with PID %d", g_hud_pid);
        NSLog(@"[HUDSpawner] ════════════════════════════════════════════════════════\n");
        pthread_mutex_unlock(&g_hud_mutex);
        return YES;
    }

    // Check PID file for previously running HUD
    HUDSpawner_EnsureDirectory();

    int pidfd = open(HUD_PID_FILE, O_RDONLY);
    if (pidfd >= 0) {
        pid_t existing_pid;
        if (read(pidfd, &existing_pid, sizeof(pid_t)) == sizeof(pid_t)) {
            if (HUDSpawner_ProcessExists(existing_pid)) {
                NSLog(@"[HUDSpawner] ✓ HUD already running (from PID file): %d", existing_pid);
                g_hud_pid = existing_pid;
                close(pidfd);
                NSLog(@"[HUDSpawner] ════════════════════════════════════════════════════════\n");
                pthread_mutex_unlock(&g_hud_mutex);
                return YES;
            }
        }
        close(pidfd);
    }

    // Setup spawn attributes
    // We spawn the HUD with persona flags to make it run as root (UID 0)
    // This is required for host_processor_set_priv() to work.
    // The HUD cannot call host_processor_set_priv from UID 501 - it must be root.

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);

    NSLog(@"[HUDSpawner] Setting up persona flags for root privilege escalation...");

    // Set SPAWN_AS_ROOT persona (UID 0)
    // CRITICAL: Must use POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE to enable persona override
    int perr = posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    if (perr != 0) {
        NSLog(@"[HUDSpawner] ✗ posix_spawnattr_set_persona_np failed: %d", perr);
        posix_spawnattr_destroy(&attr);
        NSLog(@"[HUDSpawner] ════════════════════════════════════════════════════════\n");
        pthread_mutex_unlock(&g_hud_mutex);
        return NO;
    }

    perr = posix_spawnattr_set_persona_uid_np(&attr, 0);
    if (perr != 0) {
        NSLog(@"[HUDSpawner] ✗ posix_spawnattr_set_persona_uid_np failed: %d", perr);
        posix_spawnattr_destroy(&attr);
        NSLog(@"[HUDSpawner] ════════════════════════════════════════════════════════\n");
        pthread_mutex_unlock(&g_hud_mutex);
        return NO;
    }

    perr = posix_spawnattr_set_persona_gid_np(&attr, 0);
    if (perr != 0) {
        NSLog(@"[HUDSpawner] ✗ posix_spawnattr_set_persona_gid_np failed: %d", perr);
        posix_spawnattr_destroy(&attr);
        NSLog(@"[HUDSpawner] ════════════════════════════════════════════════════════\n");
        pthread_mutex_unlock(&g_hud_mutex);
        return NO;
    }

    NSLog(@"[HUDSpawner] ✓ Persona flags set: HUD will spawn as UID 0 (root)");

    // Detach from parent's process group
    posix_spawnattr_setpgroup(&attr, 0);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);

    // Spawn process with -hud argument
    const char *execPath = HUDSpawner_GetExecutablePath();
    const char *args[] = { execPath, "-hud", NULL };

    NSLog(@"[HUDSpawner] Spawning: %s -hud", execPath);
    int spawnErr = posix_spawn(&g_hud_pid, execPath, NULL, &attr, (char **)args, environ);
    posix_spawnattr_destroy(&attr);

    if (spawnErr != 0) {
        NSLog(@"[HUDSpawner] ✗ posix_spawn failed: %s (error %d)", strerror(spawnErr), spawnErr);
        g_hud_pid = 0;
        NSLog(@"[HUDSpawner] ════════════════════════════════════════════════════════\n");
        pthread_mutex_unlock(&g_hud_mutex);
        return NO;
    }

    NSLog(@"[HUDSpawner] ✓ HUD spawned successfully with PID %d", g_hud_pid);

    // Write PID to file
    HUDSpawner_WritePIDFile(g_hud_pid);

    // Wait for HUD to initialize
    // Note: The HUD is running as root (UID 0), while we're running as mobile (UID 501)
    // When we check HUDSpawner_ProcessExists(), kill(pid, 0) will fail with EPERM
    // because we can't send signals to a root process. That's OK - EPERM means it exists!
    NSLog(@"[HUDSpawner] Waiting for HUD to initialize (running as root, we are mobile)...");

    BOOL hudAlive = NO;
    for (int i = 0; i < 50; i++) {  // 5 second timeout
        if (HUDSpawner_ProcessExists(g_hud_pid)) {
            // Process is alive (either we have permission, or EPERM means it's running as root)
            hudAlive = YES;
            break;
        }
        usleep(100000);  // 100ms
    }

    if (!hudAlive) {
        NSLog(@"[HUDSpawner] ✗ HUD process died during initialization (no response to process check)");
        g_hud_pid = 0;
        NSLog(@"[HUDSpawner] ════════════════════════════════════════════════════════\n");
        pthread_mutex_unlock(&g_hud_mutex);
        return NO;
    }

    NSLog(@"[HUDSpawner] ✓ HUD is alive and running (likely as UID 0 based on EPERM)");
    NSLog(@"[HUDSpawner] ✓ HUD initialized - standing by for IPC requests");
    NSLog(@"[HUDSpawner] ════════════════════════════════════════════════════════\n");
    pthread_mutex_unlock(&g_hud_mutex);
    return YES;
}

BOOL HUDSpawner_IsRunning(void) {
    if (g_hud_pid <= 0) {
        return NO;
    }

    // Check if process still exists
    if (!HUDSpawner_ProcessExists(g_hud_pid)) {
        NSLog(@"[HUDSpawner] HUD process %d no longer exists", g_hud_pid);
        g_hud_pid = 0;
        return NO;
    }

    return YES;
}

BOOL HUDSpawner_Stop(void) {
    NSLog(@"[HUDSpawner] Stopping HUD process");

    if (g_hud_pid <= 0) {
        NSLog(@"[HUDSpawner] No HUD process to stop");
        return YES;
    }

    // Send SIGTERM to HUD
    kill(g_hud_pid, SIGTERM);

    // Wait for process to exit (with timeout)
    for (int i = 0; i < 10; i++) {
        int status;
        pid_t ret = waitpid(g_hud_pid, &status, WNOHANG);

        if (ret == g_hud_pid) {
            NSLog(@"[HUDSpawner] ✓ HUD process exited gracefully");
            g_hud_pid = 0;
            return YES;
        }

        usleep(100000);  // 100ms
    }

    // Force kill if still running
    NSLog(@"[HUDSpawner] Forcing HUD process termination");
    kill(g_hud_pid, SIGKILL);
    waitpid(g_hud_pid, NULL, 0);
    g_hud_pid = 0;

    return YES;
}

task_port_t HUDSpawner_GetTaskPort(pid_t targetPid) {
    NSLog(@"[HUDSpawner_GetTaskPort] Requesting task port for PID %d", targetPid);

    // Check cache
    pthread_mutex_lock(&g_cache_mutex);
    if (g_port_cache) {
        NSNumber *pidKey = @(targetPid);
        NSNumber *cachedPort = g_port_cache[pidKey];
        if (cachedPort) {
            task_port_t port = (task_port_t)[cachedPort unsignedIntValue];
            // Verify port is still valid in OUR namespace
            mach_port_type_t type;
            if (mach_port_type(mach_task_self(), port, &type) == KERN_SUCCESS) {
                NSLog(@"[HUDSpawner_GetTaskPort] ✓ Using cached task port %d", port);
                pthread_mutex_unlock(&g_cache_mutex);
                return port;
            }
            [g_port_cache removeObjectForKey:pidKey];
        }
    }
    pthread_mutex_unlock(&g_cache_mutex);

    if (!HUDSpawner_IsRunning()) {
        if (!HUDSpawner_Start()) return MACH_PORT_NULL;
    }

    HUDSpawner_EnsureDirectory();

    HUD_Request req;
    req.targetPid = targetPid;
    req.appPid = getpid();

    // Clean up old response
    unlink(HUD_RESPONSE_FILE);

    int fd = open(HUD_REQUEST_FILE, O_WRONLY | O_CREAT | O_TRUNC, 0666);
    if (fd < 0) return MACH_PORT_NULL;
    write(fd, &req, sizeof(req));
    close(fd);

    // --- FIX: RETRY LOOP ---
    // Don't just notify once. The HUD might still be starting up.
    // We loop for 5 seconds, checking for the file AND re-sending the notification.

    BOOL responseReceived = NO;
    for (int i = 0; i < 25; i++) { // 25 * 200ms = 5 seconds

        // 1. Signal HUD (Repeat this!)
        notify_post(HUD_NOTIFY_REQUEST);

        // 2. Wait a bit
        usleep(200000); // 200ms

        // 3. Check for response
        struct stat st;
        if (stat(HUD_RESPONSE_FILE, &st) == 0 && st.st_size > 0) {
            responseReceived = YES;
            break;
        }
    }

    if (!responseReceived) {
        NSLog(@"[HUDSpawner] ✗ Timeout waiting for HUD response");
        return MACH_PORT_NULL;
    }

    fd = open(HUD_RESPONSE_FILE, O_RDONLY);
    if (fd < 0) return MACH_PORT_NULL;
    HUD_Response resp = {0};
    read(fd, &resp, sizeof(resp));
    close(fd);

    if (!resp.success) {
        NSLog(@"[HUDSpawner] ✗ HUD reported failure");
        return MACH_PORT_NULL;
    }

    // --- RETRIEVE STASHED PORT ---
    task_port_t port = MACH_PORT_NULL;
    mach_port_array_t ports = NULL;
    mach_msg_type_number_t portsCount = 0;

    // Lookup the ports the HUD registered for us
    kern_return_t kr = mach_ports_lookup(mach_task_self(), &ports, &portsCount);

    if (kr == KERN_SUCCESS && portsCount > 0) {
        port = ports[0]; // The HUD put the target task at index 0
        NSLog(@"[HUDSpawner] ✓ Retrieved stashed port: %u", port);

        // Optional: Clear the stash to be clean (not strictly necessary)
        // mach_ports_register(mach_task_self(), NULL, 0);

        // Free the array memory (not the ports themselves)
        vm_deallocate(mach_task_self(), (vm_address_t)ports, portsCount * sizeof(mach_port_t));
    } else {
        NSLog(@"[HUDSpawner] ✗ Failed to lookup stashed ports: 0x%x (Count: %d)", kr, portsCount);
        return MACH_PORT_NULL;
    }

    // Validation
    mach_port_type_t type = 0;
    kr = mach_port_type(mach_task_self(), port, &type);
    if (kr != KERN_SUCCESS) {
        NSLog(@"[HUDSpawner] ✗ CRITICAL: Port %u is invalid (0x%x)", port, kr);
        return MACH_PORT_NULL;
    }

    pthread_mutex_lock(&g_cache_mutex);
    if (!g_port_cache) g_port_cache = [NSMutableDictionary new];
    g_port_cache[@(targetPid)] = @(port);
    pthread_mutex_unlock(&g_cache_mutex);

    return port;
}

void HUDSpawner_ClearCache(void) {
    pthread_mutex_lock(&g_cache_mutex);
    [g_port_cache removeAllObjects];
    pthread_mutex_unlock(&g_cache_mutex);
    NSLog(@"[HUDSpawner] Port cache cleared");
}
