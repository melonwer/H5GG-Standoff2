#import "HUDMain.h"
#import <mach/mach.h>
#import <mach/processor_set.h>
#import <notify.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <string.h>
#import <dispatch/dispatch.h>

#define HUD_DIR "/tmp/h5gg_hud"
#define HUD_REQUEST_FILE HUD_DIR "/request.bin"
#define HUD_RESPONSE_FILE HUD_DIR "/response.bin"
#define HUD_NOTIFY_REQUEST "com.h5gg.hud.request"
#define HUD_NOTIFY_RESPONSE "com.h5gg.hud.response"

typedef struct {
    pid_t targetPid;
    pid_t appPid;
} HUD_Request;

typedef struct {
    uint32_t success;
    task_port_t taskPort;
} HUD_Response;

task_port_t HUD_FindTaskForPID(pid_t targetPid) {
    host_t myhost = mach_host_self();
    task_port_t psDefault = MACH_PORT_NULL;
    task_port_t psDefault_control = MACH_PORT_NULL;
    task_array_t tasks = NULL;
    mach_msg_type_number_t numTasks = 0;
    kern_return_t kr;
    task_port_t foundTask = MACH_PORT_NULL;

    kr = processor_set_default(myhost, &psDefault);
    if (kr != KERN_SUCCESS) return MACH_PORT_NULL;

    kr = host_processor_set_priv(myhost, psDefault, &psDefault_control);
    if (kr != KERN_SUCCESS) {
        NSLog(@"[HUD] ✗ host_processor_set_priv failed: 0x%x", kr);
        mach_port_deallocate(mach_task_self(), psDefault);
        return MACH_PORT_NULL;
    }

    kr = processor_set_tasks(psDefault_control, &tasks, &numTasks);
    if (kr != KERN_SUCCESS) {
        NSLog(@"[HUD] ✗ processor_set_tasks failed: 0x%x", kr);
        mach_port_deallocate(mach_task_self(), psDefault);
        mach_port_deallocate(mach_task_self(), psDefault_control);
        return MACH_PORT_NULL;
    }

    for (mach_msg_type_number_t i = 0; i < numTasks; i++) {
        pid_t pid = 0;
        if (foundTask == MACH_PORT_NULL && pid_for_task(tasks[i], &pid) == KERN_SUCCESS && pid == targetPid) {
            foundTask = tasks[i];
        } else {
            mach_port_deallocate(mach_task_self(), tasks[i]);
        }
    }

    if (tasks) vm_deallocate(mach_task_self(), (vm_address_t)tasks, numTasks * sizeof(task_port_t));
    mach_port_deallocate(mach_task_self(), psDefault);
    mach_port_deallocate(mach_task_self(), psDefault_control);

    return foundTask;
}

void HUD_MainServerLoop(void) {
    NSLog(@"[HUD] Server Started. UID: %d", getuid());
    mkdir(HUD_DIR, 0777);
    chmod(HUD_DIR, 0777);

    int notifyToken;
    notify_register_dispatch(HUD_NOTIFY_REQUEST, &notifyToken, dispatch_get_main_queue(), ^(int token) {
        NSLog(@"[HUD] Processing Request...");

        int fd = open(HUD_REQUEST_FILE, O_RDONLY);
        if (fd < 0) return;
        HUD_Request req = {0};
        read(fd, &req, sizeof(req));
        close(fd);

        NSLog(@"[HUD] Target=%d, App=%d", req.targetPid, req.appPid);

        HUD_Response resp = {0};
        resp.success = 0;

        task_port_t targetTask = HUD_FindTaskForPID(req.targetPid);
        task_port_t appTask = HUD_FindTaskForPID(req.appPid);

        if (targetTask != MACH_PORT_NULL && appTask != MACH_PORT_NULL) {

            // --- NEW INJECTION METHOD: mach_ports_register ---
            // We stash the target port into the App's "Registered Ports" array.
            // This bypasses the need to allocate a specific name or use insert_right.

            mach_port_array_t ports = (mach_port_array_t)malloc(sizeof(mach_port_t) * 1);
            ports[0] = targetTask;

            kern_return_t kr = mach_ports_register(appTask, ports, 1);
            free(ports);

            if (kr == KERN_SUCCESS) {
                NSLog(@"[HUD] ✓ Stashed port via mach_ports_register");
                resp.success = 1;
                // We don't send the port number back, the App must lookup its own registered ports
                resp.taskPort = 0;
            } else {
                NSLog(@"[HUD] ✗ mach_ports_register failed: 0x%x", kr);
            }
        } else {
            NSLog(@"[HUD] ✗ Tasks not found");
        }

        // Cleanup
        if (targetTask != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), targetTask);
        if (appTask != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), appTask);

        fd = open(HUD_RESPONSE_FILE, O_WRONLY | O_CREAT | O_TRUNC, 0666);
        if (fd >= 0) {
            write(fd, &resp, sizeof(resp));
            close(fd);
            chmod(HUD_RESPONSE_FILE, 0666);
        }
        notify_post(HUD_NOTIFY_RESPONSE);
    });

    dispatch_main();
}

// Argument parsing
BOOL HUD_ShouldRunAsHUD(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-hud") == 0) {
            return YES;
        }
    }
    return NO;
}
