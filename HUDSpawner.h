#ifndef HUDSpawner_h
#define HUDSpawner_h

#import <Foundation/Foundation.h>
#import <mach/mach.h>

/**
 * HUDSpawner.h
 *
 * Public API for spawning and communicating with the HUD root helper process.
 *
 * The HUD is spawned with SPAWN_AS_ROOT privilege escalation, allowing it to
 * use processor_set_tasks enumeration to acquire task ports undetectably.
 *
 * This module handles:
 * - Spawning the HUD process (once, with anti-recursion checks)
 * - File-based IPC with Darwin notifications
 * - Task port request/response synchronization (via semaphores)
 * - Task port caching for efficiency
 */

// Start the HUD process if not already running
// Returns YES if HUD is now running, NO if failed
BOOL HUDSpawner_Start(void);

// Check if HUD process is currently running
// Returns YES if running, NO otherwise
BOOL HUDSpawner_IsRunning(void);

// Stop the HUD process gracefully
// Sends SIGTERM, waits for exit, force kills if needed
// Returns YES if stopped successfully, NO otherwise
BOOL HUDSpawner_Stop(void);

// Request a task port for the given PID from the HUD
// Automatically starts HUD if not running
// Uses cached ports when available
// Returns the task port if successful, MACH_PORT_NULL if failed
// Timeout: 5 seconds
task_port_t HUDSpawner_GetTaskPort(pid_t targetPid);

// Clear the task port cache (useful if processes are terminated/restarted)
void HUDSpawner_ClearCache(void);

#endif /* HUDSpawner_h */
