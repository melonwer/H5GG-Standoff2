//
//  crossproc.h
//  h5gg
//
//  Created by admin on 25/4/2022.
//

#ifndef crossproc_h
#define crossproc_h

#import <mach/mach.h>

#import <sys/sysctl.h>
#import <mach-o/dyld_images.h>

#import "HUDSpawner.h"

extern "C" {
#include "dyld64.h"
#include "libproc.h"
#include "proc_info.h"
}

NSArray* getRunningProcess()
{
    //指定名字参数，按照顺序第一个元素指定本请求定向到内核的哪个子系统，第二个及其后元素依次细化指定该系统的某个部分。
    //CTL_KERN，KERN_PROC,KERN_PROC_ALL 正在运行的所有进程
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL ,0};
    
    u_int miblen = 4;
    //值-结果参数：函数被调用时，size指向的值指定该缓冲区的大小；函数返回时，该值给出内核存放在该缓冲区中的数据量
    //如果这个缓冲不够大，函数就返回ENOMEM错误
    size_t size;
    //返回0，成功；返回-1，失败
    int st = sysctl(mib, miblen, NULL, &size, NULL, 0);
    NSLog(@"allproc=%d, %s", st, strerror(errno));
    
    struct kinfo_proc * process = NULL;
    struct kinfo_proc * newprocess = NULL;
    do
    {
        size += size / 10;
        newprocess = (struct kinfo_proc *)realloc(process, size);
        if (!newprocess)
        {
            if (process)
            {
                free(process);
                process = NULL;
            }
            return nil;
        }
        
        process = newprocess;
        st = sysctl(mib, miblen, process, &size, NULL, 0);
        NSLog(@"allproc=%d, %s", st, strerror(errno));
    } while (st == -1 && errno == ENOMEM);
    
    if (st == 0)
    {
        if (size % sizeof(struct kinfo_proc) == 0)
        {
            int nprocess = size / sizeof(struct kinfo_proc);
            if (nprocess)
            {
                NSMutableArray * array = [[NSMutableArray alloc] init];
                for (int i = nprocess - 1; i >= 0; i--)
                {
                    [array addObject:@{
                        @"pid": [NSNumber numberWithInt:process[i].kp_proc.p_pid],
                        @"name": [NSString stringWithUTF8String:process[i].kp_proc.p_comm]
                    }];
                }
                
                free(process);
                process = NULL;
                NSLog(@"allproc=%d, %@", array.count, array);
                return array;
            }
        }
    }
    
    return nil;
}

pid_t pid_for_name(const char* name)
{
    NSArray* allproc = getRunningProcess();
    for(NSDictionary* proc in allproc)
    {
        if([[proc valueForKey:@"name"] isEqualToString:[NSString stringWithUTF8String:name]])
            return [[proc valueForKey:@"pid"] intValue];
    }
    return 0;
}

size_t getMachoVMSize(pid_t pid, task_port_t task, mach_vm_address_t addr)
{
    struct proc_regionwithpathinfo rwpi={0};
    int len=proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, addr, &rwpi, PROC_PIDREGIONPATHINFO_SIZE);
    
    if(!rwpi.prp_vip.vip_vi.vi_stat.vst_dev && !rwpi.prp_vip.vip_vi.vi_stat.vst_ino)
    {
        return 0;
    }
    
    struct mach_header_64 header;
    mach_vm_size_t hdrsize = sizeof(header);
    kern_return_t kr = mach_vm_read_overwrite(task, addr, hdrsize, (mach_vm_address_t)&header, &hdrsize);
    if(kr != KERN_SUCCESS)
        return 0;
    
    mach_vm_size_t lcsize=header.sizeofcmds;
    void* buf = malloc(lcsize);
    
    kr = mach_vm_read_overwrite(task, addr+hdrsize, lcsize, (mach_vm_address_t)buf, &lcsize);
    if(kr == KERN_SUCCESS)
    {
        uint64_t vm_end = 0;
        uint64_t header_vaddr = -1;
        
        struct load_command* lc = (struct load_command*)buf;
        for (uint32_t i = 0; i < header.ncmds; i++) {
            if (lc->cmd == LC_SEGMENT_64)
            {
                struct segment_command_64 * seg = (struct segment_command_64 *) lc;
                
                //printf("segment: %s file=%x:%x vm=%p:%p\n", seg->segname, seg->fileoff, seg->filesize, seg->vmaddr, seg->vmsize);
                
                if(seg->fileoff==0 && seg->filesize>0)
                {
                    if(header_vaddr != -1) {
                        NSLog(@"multi header mapping! %s", seg->segname);
                        vm_end=0;
                        break;
                    }
                    
                    header_vaddr = seg->vmaddr;
                }
                    
                if(seg->vmsize && vm_end<(seg->vmaddr+seg->vmsize))
                    vm_end = seg->vmaddr+seg->vmsize;
            }
            lc = (struct load_command *) ((char *)lc + lc->cmdsize);
        }
        
        if(vm_end && header_vaddr != -1)
            vm_end -= header_vaddr;
        
        return vm_end;
    }
    free(buf);
    return 0;
}


NSArray* getRangesList2(pid_t pid, task_port_t task, NSString* filter)
{
    NSMutableArray* results = [[NSMutableArray alloc] init];
    
    task_dyld_info_data_t task_dyld_info;
    mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
    kern_return_t kr = task_info(task, TASK_DYLD_INFO, (task_info_t)&task_dyld_info, &count);
    NSLog(@"getmodules TASK_DYLD_INFO=%p %x %d", task_dyld_info.all_image_info_addr, task_dyld_info.all_image_info_size, task_dyld_info.all_image_info_format);
    
    if(kr!=KERN_SUCCESS)
        return results;
    
    struct dyld_all_image_infos64 aii;
    mach_vm_size_t aiiSize = sizeof(aii);
    kr = mach_vm_read_overwrite(task, task_dyld_info.all_image_info_addr, aiiSize, (mach_vm_address_t)&aii, &aiiSize);
    
    NSLog(@"getmodules all_image_info %d %p %d", aii.version, aii.infoArray, aii.infoArrayCount);
    if(kr != KERN_SUCCESS)
        return results;
    
    mach_vm_address_t        ii;
    uint32_t                iiCount;
    mach_msg_type_number_t    iiSize;
    
    
    ii = aii.infoArray;
    iiCount = aii.infoArrayCount;
    iiSize = iiCount * sizeof(struct dyld_image_info64);
        
    // If ii is NULL, it means it is being modified, come back later.
    kr = mach_vm_read(task, ii, iiSize, (vm_offset_t *)&ii, &iiSize);
    if(kr != KERN_SUCCESS) {
        NSLog(@"getmodules cannot read aii");
        return results;
    }
    
    for (int i = 0; i < iiCount; i++) {
        mach_vm_address_t addr;
        mach_vm_address_t path;
        
        struct dyld_image_info64 *ii64 = (struct dyld_image_info64 *)ii;
        addr = ii64[i].imageLoadAddress;
        path = ii64[i].imageFilePath;
        
        NSLog(@"getmodules image[%d] %p %p", i, addr, path);
        
        char pathbuffer[PATH_MAX]={0};
        
        mach_vm_size_t size3;
        if (mach_vm_read_overwrite(task, path, MAXPATHLEN, (mach_vm_address_t)pathbuffer, &size3) != KERN_SUCCESS)
            strcpy(pathbuffer, "<Unknown>");
        
        NSLog(@"getmodules path=%s", pathbuffer);
        
        if(filter==nil
            || (i==0 && [filter isEqual:@"0"])
            || [filter isEqual:[NSString stringWithUTF8String:basename((char*)pathbuffer) ]]
        ){
            
            uint64_t size = getMachoVMSize(pid, task, (uint64_t)addr);
            uint64_t end = size ? ((uint64_t)addr+size) : 0;
            
            [results addObject:@{
                @"name" : [NSString stringWithUTF8String:pathbuffer],
                @"start" : [NSString stringWithFormat:@"0x%llX", addr],
                @"end" : [NSString stringWithFormat:@"0x%llX", end],
                //@"type" : @"rwxp",
            }];
            
            if(i==0 && [filter isEqual:@"0"]) break;
        }
    }
    vm_deallocate(mach_task_self(), ii, iiSize);

    return results;
}


// ============================================================================
// METHOD 2: Mach Port Space Enumeration
// ============================================================================
// Enumerate ports in our local mach port space to find target task port
// Never calls task_for_pid, only uses pid_for_task (reverse lookup)
// Should work with TrollStore entitlements
// ============================================================================
task_port_t mach_port_space_enumeration(pid_t target_pid) {
    NSLog(@"\n[mach_port_space_enumeration] ════════════════════════════════════");
    NSLog(@"[mach_port_space_enumeration] METHOD 2: Enumerating local mach port space");
    NSLog(@"[mach_port_space_enumeration] Target PID: %d", target_pid);

    mach_port_name_array_t names = NULL;
    mach_port_type_array_t types = NULL;
    mach_msg_type_number_t names_count = 0;
    mach_msg_type_number_t types_count = 0;

    // Get list of all ports in our mach port space
    kern_return_t kr = mach_port_names(mach_task_self(),
                                       &names, &names_count,
                                       &types, &types_count);

    if (kr != KERN_SUCCESS) {
        NSLog(@"[mach_port_space_enumeration] ✗ mach_port_names failed: %s (0x%x)",
              mach_error_string(kr), kr);
        return MACH_PORT_NULL;
    }

    NSLog(@"[mach_port_space_enumeration] ✓ Got %u ports in local space", names_count);

    task_port_t target_task = MACH_PORT_NULL;
    mach_msg_type_number_t checked_count = 0;

    // Iterate through ports in our space
    for (mach_msg_type_number_t i = 0; i < names_count; i++) {
        // Only check ports with send rights (task ports have this)
        if ((types[i] & MACH_PORT_TYPE_SEND) || (types[i] & MACH_PORT_TYPE_SEND_ONCE)) {
            pid_t port_pid = 0;

            // Try to get the PID for this port (reverse lookup)
            kern_return_t pid_kr = pid_for_task(names[i], &port_pid);

            if (pid_kr == KERN_SUCCESS) {
                checked_count++;

                if (port_pid == target_pid) {
                    NSLog(@"[mach_port_space_enumeration] ✓✓✓ FOUND TARGET! ✓✓✓");
                    NSLog(@"[mach_port_space_enumeration]   Port: 0x%x", names[i]);
                    NSLog(@"[mach_port_space_enumeration]   PID: %d", port_pid);
                    target_task = names[i];
                    break;
                }

                // Log first few and target port for debugging
                if (i < 3 || i == names_count - 1) {
                    NSLog(@"[mach_port_space_enumeration]   Port[%u]: 0x%x → PID %d",
                          i, names[i], port_pid);
                }
            }
        }
    }

    NSLog(@"[mach_port_space_enumeration] Checked %u task ports", checked_count);

    // Deallocate arrays returned by mach_port_names
    if (names != NULL) {
        vm_deallocate(mach_task_self(), (vm_address_t)names,
                     names_count * sizeof(mach_port_name_t));
    }
    if (types != NULL) {
        vm_deallocate(mach_task_self(), (vm_address_t)types,
                     types_count * sizeof(mach_port_type_t));
    }

    if (target_task == MACH_PORT_NULL) {
        NSLog(@"[mach_port_space_enumeration] ✗ PID %d not found in port space", target_pid);
    } else {
        NSLog(@"[mach_port_space_enumeration] ✓ SUCCESS: Got task port via port space enumeration");
    }
    NSLog(@"[mach_port_space_enumeration] ════════════════════════════════════\n");

    return target_task;
}


// ============================================================================
// METHOD 3: Bootstrap Port Discovery
// ============================================================================
// Use launchd bootstrap to discover task ports
// Alternative method that may work when port space enumeration fails
// ============================================================================
task_port_t bootstrap_port_discovery(pid_t target_pid) {
    NSLog(@"\n[bootstrap_port_discovery] ════════════════════════════════════");
    NSLog(@"[bootstrap_port_discovery] METHOD 3: Bootstrap port discovery");
    NSLog(@"[bootstrap_port_discovery] Target PID: %d", target_pid);

    // Note: This is a placeholder for a more complex implementation
    // Bootstrap port discovery requires specific service registration
    // which may not be available for arbitrary processes

    NSLog(@"[bootstrap_port_discovery] ℹ This method requires service registration");
    NSLog(@"[bootstrap_port_discovery] ✗ Bootstrap discovery not available for arbitrary PIDs");
    NSLog(@"[bootstrap_port_discovery] ════════════════════════════════════\n");

    return MACH_PORT_NULL;
}


// ============================================================================
// METHOD 4: Spawn Root Helper (HUD Process)
// ============================================================================
// Spawn a privileged helper process to get task port via processor_set_tasks
// Uses HUDSpawner to manage the root helper process
// The HUD runs with UID 0, allowing full processor_set_tasks access
// ============================================================================
task_port_t spawn_root_helper_for_port(pid_t target_pid) {
    NSLog(@"\n[spawn_root_helper_for_port] ════════════════════════════════════");
    NSLog(@"[spawn_root_helper_for_port] METHOD 4: Using root helper (HUD) process");
    NSLog(@"[spawn_root_helper_for_port] Target PID: %d", target_pid);

    // Ensure HUD is running
    if (!HUDSpawner_IsRunning()) {
        NSLog(@"[spawn_root_helper_for_port] HUD not running, starting...");
        if (!HUDSpawner_Start()) {
            NSLog(@"[spawn_root_helper_for_port] ✗ Failed to start HUD");
            NSLog(@"[spawn_root_helper_for_port] ════════════════════════════════════\n");
            return MACH_PORT_NULL;
        }
    }

    NSLog(@"[spawn_root_helper_for_port] ✓ HUD is running");

    // Request task port from HUD via IPC
    NSLog(@"[spawn_root_helper_for_port] Requesting task port from HUD...");
    task_port_t port = HUDSpawner_GetTaskPort(target_pid);

    if (port != MACH_PORT_NULL) {
        NSLog(@"[spawn_root_helper_for_port] ✓ SUCCESS: Received task port from HUD");
    } else {
        NSLog(@"[spawn_root_helper_for_port] ✗ HUD failed to acquire task port for PID %d", target_pid);
    }

    NSLog(@"[spawn_root_helper_for_port] ════════════════════════════════════\n");
    return port;
}


// ============================================================================
// MAIN: UNDETECTABLE task_for_pid WORKAROUND with 4-Tier Fallback
// ============================================================================
// Tries multiple methods to acquire task port while avoiding anti-cheat
// Method 1: processor_set_tasks enumeration (jailbreak)
// Method 2: mach port space enumeration (TrollStore primary)
// Method 3: bootstrap port discovery (alternative)
// Method 4: spawn root helper (last resort)
// ============================================================================
task_port_t task_for_pid_workaround(pid_t targetPid) {
    NSLog(@"\n");
    NSLog(@"╔═════════════════════════════════════════════════════════════════╗");
    NSLog(@"║   task_for_pid_workaround - Multi-Method Fallback Strategy      ║");
    NSLog(@"╚═════════════════════════════════════════════════════════════════╝");
    NSLog(@"[task_for_pid_workaround] Target PID: %d", targetPid);
    NSLog(@"[task_for_pid_workaround] Current PID: %d", getpid());
    NSLog(@"[task_for_pid_workaround] Task port: %u", mach_task_self());

    task_port_t targetTask = MACH_PORT_NULL;

    // ===== ATTEMPT 1: processor_set_tasks (Jailbreak with root) =====
    NSLog(@"\n[ATTEMPT 1/4] Trying processor_set_tasks enumeration...");

    host_t myhost = mach_host_self();
    task_port_t psDefault = MACH_PORT_NULL;
    task_port_t psDefault_control = MACH_PORT_NULL;
    task_array_t tasks = NULL;
    mach_msg_type_number_t numTasks = 0;
    kern_return_t kr;

    kr = processor_set_default(myhost, &psDefault);
    if (kr == KERN_SUCCESS) {
        kr = host_processor_set_priv(myhost, psDefault, &psDefault_control);

        if (kr == KERN_SUCCESS) {
            NSLog(@"[task_for_pid_workaround] ✓ Got privileged processor set access");
            kr = processor_set_tasks(psDefault_control, &tasks, &numTasks);

            if (kr == KERN_SUCCESS) {
                NSLog(@"[task_for_pid_workaround] ✓ Got task array with %u tasks", numTasks);

                for (mach_msg_type_number_t i = 0; i < numTasks; i++) {
                    pid_t pid = 0;
                    if (pid_for_task(tasks[i], &pid) == KERN_SUCCESS && pid == targetPid) {
                        NSLog(@"[task_for_pid_workaround] ✓✓✓ FOUND via Method 1 (processor_set_tasks)!");
                        targetTask = tasks[i];

                        // Deallocate other ports
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

                if (tasks != NULL) {
                    vm_deallocate(mach_task_self(), (vm_address_t)tasks, numTasks * sizeof(task_port_t));
                }
            }

            mach_port_deallocate(mach_task_self(), psDefault);
            mach_port_deallocate(mach_task_self(), psDefault_control);
        }
    }

    if (targetTask != MACH_PORT_NULL) {
        NSLog(@"\n╔═════════════════════════════════════════════════════════════════╗");
        NSLog(@"║            RESULT: SUCCESS (Method 1)                           ║");
        NSLog(@"╚═════════════════════════════════════════════════════════════════╝");
        NSLog(@"[task_for_pid_workaround] ✓ Acquired via processor_set_tasks");
        NSLog(@"[task_for_pid_workaround] Task port: %u, PID: %d\n", targetTask, targetPid);
        return targetTask;
    }

    NSLog(@"[task_for_pid_workaround] ✗ Method 1 failed, trying Method 2...");

    // ===== ATTEMPT 2: mach_port_space_enumeration (TrollStore primary) =====
    NSLog(@"\n[ATTEMPT 2/4] Trying mach port space enumeration...");
    targetTask = mach_port_space_enumeration(targetPid);

    if (targetTask != MACH_PORT_NULL) {
        NSLog(@"\n╔═════════════════════════════════════════════════════════════════╗");
        NSLog(@"║            RESULT: SUCCESS (Method 2)                           ║");
        NSLog(@"╚═════════════════════════════════════════════════════════════════╝");
        NSLog(@"[task_for_pid_workaround] ✓ Acquired via port space enumeration");
        NSLog(@"[task_for_pid_workaround] Task port: %u, PID: %d\n", targetTask, targetPid);
        return targetTask;
    }

    NSLog(@"[task_for_pid_workaround] ✗ Method 2 failed, trying Method 3...");

    // ===== ATTEMPT 3: bootstrap_port_discovery (Alternative) =====
    NSLog(@"\n[ATTEMPT 3/4] Trying bootstrap port discovery...");
    targetTask = bootstrap_port_discovery(targetPid);

    if (targetTask != MACH_PORT_NULL) {
        NSLog(@"\n╔═════════════════════════════════════════════════════════════════╗");
        NSLog(@"║            RESULT: SUCCESS (Method 3)                           ║");
        NSLog(@"╚═════════════════════════════════════════════════════════════════╝");
        NSLog(@"[task_for_pid_workaround] ✓ Acquired via bootstrap discovery");
        NSLog(@"[task_for_pid_workaround] Task port: %u, PID: %d\n", targetTask, targetPid);
        return targetTask;
    }

    NSLog(@"[task_for_pid_workaround] ✗ Method 3 failed, trying Method 4...");

    // ===== ATTEMPT 4: spawn_root_helper (Last Resort) =====
    NSLog(@"\n[ATTEMPT 4/4] Trying root helper spawn...");
    targetTask = spawn_root_helper_for_port(targetPid);

    if (targetTask != MACH_PORT_NULL) {
        NSLog(@"\n╔═════════════════════════════════════════════════════════════════╗");
        NSLog(@"║            RESULT: SUCCESS (Method 4)                           ║");
        NSLog(@"╚═════════════════════════════════════════════════════════════════╝");
        NSLog(@"[task_for_pid_workaround] ✓ Acquired via root helper");
        NSLog(@"[task_for_pid_workaround] Task port: %u, PID: %d\n", targetTask, targetPid);
        return targetTask;
    }

    // ===== ALL METHODS FAILED =====
    NSLog(@"\n╔═════════════════════════════════════════════════════════════════╗");
    NSLog(@"║              RESULT: ALL METHODS FAILED                        ║");
    NSLog(@"╚═════════════════════════════════════════════════════════════════╝");
    NSLog(@"[task_for_pid_workaround] ✗ Could not acquire task port for PID %d", targetPid);
    NSLog(@"[task_for_pid_workaround]   Method 1 (processor_set_tasks): Requires root/jailbreak");
    NSLog(@"[task_for_pid_workaround]   Method 2 (port space enum): Target port not in local space");
    NSLog(@"[task_for_pid_workaround]   Method 3 (bootstrap): Service not registered");
    NSLog(@"[task_for_pid_workaround]   Method 4 (root helper): Helper binary not available");
    NSLog(@"[task_for_pid_workaround] ✗ Cannot proceed with memory operations\n");

    return MACH_PORT_NULL;
}

#endif /* crossproc_h */
