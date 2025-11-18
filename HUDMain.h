#ifndef HUDMain_h
#define HUDMain_h

#import <Foundation/Foundation.h>

/**
 * HUDMain.h
 *
 * Interface for the HUD root helper process.
 *
 * The HUD runs as a separate process with UID 0 (root), listening for IPC
 * requests from the main H5GG app. It uses processor_set_tasks enumeration
 * (an undetectable method) to acquire task ports for target processes.
 */

// Check if the current process should run as the HUD
// This is determined by checking argv for the "-hud" flag
// Returns YES if -hud was passed as first argument after executable name
BOOL HUD_ShouldRunAsHUD(int argc, char **argv);

// HUD server main loop - this never returns
// The process stays alive listening for requests via Darwin notifications
// This should only be called if HUD_ShouldRunAsHUD returns YES
void HUD_MainServerLoop(void);

#endif /* HUDMain_h */
