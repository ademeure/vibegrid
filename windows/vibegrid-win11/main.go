//go:build windows

package main

import (
	"crypto/rand"
	"embed"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"math"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"
)

//go:embed web/*
var webFS embed.FS

// ---------------------------------------------------------------------------
// Win32 DLL bindings
// ---------------------------------------------------------------------------

var (
	user32   = syscall.NewLazyDLL("user32.dll")
	kernel32 = syscall.NewLazyDLL("kernel32.dll")
	psapi    = syscall.NewLazyDLL("psapi.dll")

	procEnumWindows              = user32.NewProc("EnumWindows")
	procIsWindowVisible          = user32.NewProc("IsWindowVisible")
	procGetWindowTextW           = user32.NewProc("GetWindowTextW")
	procGetWindowTextLengthW     = user32.NewProc("GetWindowTextLengthW")
	procGetWindowThreadProcessId = user32.NewProc("GetWindowThreadProcessId")
	procShowWindow               = user32.NewProc("ShowWindow")
	procSetForegroundWindow      = user32.NewProc("SetForegroundWindow")
	procGetWindowRect            = user32.NewProc("GetWindowRect")
	procMoveWindow               = user32.NewProc("MoveWindow")
	procPostMessageW             = user32.NewProc("PostMessageW")
	procSystemParametersInfoW    = user32.NewProc("SystemParametersInfoW")
	procSetWindowPos             = user32.NewProc("SetWindowPos")
	procGetWindowLongW           = user32.NewProc("GetWindowLongW")
	procGetClassNameW            = user32.NewProc("GetClassNameW")
	procGetWindow                = user32.NewProc("GetWindow")

	procOpenProcess = kernel32.NewProc("OpenProcess")
	procCloseHandle = kernel32.NewProc("CloseHandle")

	procGetModuleBaseNameW = psapi.NewProc("GetModuleBaseNameW")

	advapi32            = syscall.NewLazyDLL("advapi32.dll")
	procRegSetValueExW  = advapi32.NewProc("RegSetValueExW")
	procRegDeleteValueW = advapi32.NewProc("RegDeleteValueW")
)

const (
	swHide           = 0
	swMaximize       = 3
	swRestore        = 9
	wmClose          = 0x0010
	processQueryInfo = 0x0400
	processVMRead    = 0x0010
	spiGetWorkArea   = 0x0030
	swpNoSize        = 0x0001
	swpNoMove        = 0x0002

	gwlExStyle uintptr = ^uintptr(19) // -20
	gwlStyle   uintptr = ^uintptr(15) // -16
	gwOwner            = 4            // GetWindow(hwnd, GW_OWNER)

	wsExAppWindow   = 0x00040000
	wsExNoActivate2 = 0x08000000
	wsChild         = 0x40000000
)

type rect struct {
	Left, Top, Right, Bottom int32
}

// ---------------------------------------------------------------------------
// Win32 thread — all Win32 calls must happen on one locked OS thread
// ---------------------------------------------------------------------------

type win32Request struct {
	fn   func()
	done chan struct{}
}

var win32Chan = make(chan win32Request, 16)

// threadHealth tracks whether critical goroutines are alive.
var threadHealth struct {
	win32   atomic.Int64
	hotkey  atomic.Int64
	tray    atomic.Int64
	overlay atomic.Int64
	refresh atomic.Int64
}

func initWin32Thread(logger *log.Logger) {
	go func() {
		defer func() {
			if r := recover(); r != nil {
				buf := make([]byte, 4096)
				n := runtime.Stack(buf, false)
				logger.Printf("FATAL: win32 thread panicked: %v\n%s", r, buf[:n])
			}
			logger.Printf("FATAL: win32 thread exited unexpectedly")
		}()
		runtime.LockOSThread()
		logger.Printf("win32 thread started")
		for req := range win32Chan {
			req.fn()
			close(req.done)
			threadHealth.win32.Store(time.Now().UnixMilli())
		}
	}()
}

func win32Do(fn func()) {
	done := make(chan struct{})
	win32Chan <- win32Request{fn: fn, done: done}
	<-done
}

// ---------------------------------------------------------------------------
// Win32 helpers
// ---------------------------------------------------------------------------

func getWindowText(hwnd uintptr) string {
	length, _, _ := procGetWindowTextLengthW.Call(hwnd)
	if length == 0 {
		return ""
	}
	buf := make([]uint16, length+1)
	procGetWindowTextW.Call(hwnd, uintptr(unsafe.Pointer(&buf[0])), uintptr(length+1))
	return syscall.UTF16ToString(buf)
}

func getProcessName(hwnd uintptr) string {
	var pid uint32
	procGetWindowThreadProcessId.Call(hwnd, uintptr(unsafe.Pointer(&pid)))
	if pid == 0 {
		return ""
	}
	handle, _, _ := procOpenProcess.Call(processQueryInfo|processVMRead, 0, uintptr(pid))
	if handle == 0 {
		return ""
	}
	defer procCloseHandle.Call(handle)

	buf := make([]uint16, 260)
	n, _, _ := procGetModuleBaseNameW.Call(handle, 0, uintptr(unsafe.Pointer(&buf[0])), 260)
	if n == 0 {
		return ""
	}
	name := syscall.UTF16ToString(buf[:n])
	name = strings.TrimSuffix(name, ".exe")
	return name
}

func getWorkArea() rect {
	var r rect
	ret, _, _ := procSystemParametersInfoW.Call(spiGetWorkArea, 0, uintptr(unsafe.Pointer(&r)), 0)
	if ret == 0 || (r.Right-r.Left) <= 0 || (r.Bottom-r.Top) <= 0 {
		// Fallback: assume a reasonable 1920x1080 work area
		return rect{Left: 0, Top: 0, Right: 1920, Bottom: 1040}
	}
	return r
}

// moveWindowCompensated calls MoveWindow with the target rect expanded to
// account for the invisible window frame that Windows 10/11 adds for the
// drop shadow. The border size is read from the "frameBorderCompensation"
// setting (default 7). Set to 0 to disable compensation.
func moveWindowCompensated(hwnd uintptr, x, y, w, h, border int32) {
	procMoveWindow.Call(hwnd,
		uintptr(x-border), uintptr(y),
		uintptr(w+border*2), uintptr(h+border),
		1)
}

// ---------------------------------------------------------------------------
// Global hotkeys — RegisterHotKey + message loop on a dedicated thread
// ---------------------------------------------------------------------------

var (
	procRegisterHotKey      = user32.NewProc("RegisterHotKey")
	procUnregisterHotKey    = user32.NewProc("UnregisterHotKey")
	procGetMessageW         = user32.NewProc("GetMessageW")
	procGetForegroundWindow = user32.NewProc("GetForegroundWindow")
	procPostThreadMessageW  = user32.NewProc("PostThreadMessageW")
	procGetCurrentThreadId  = kernel32.NewProc("GetCurrentThreadId")
)

const wmHotkey = 0x0312
const wmUser = 0x0400

// Win32 modifier flags for RegisterHotKey
const (
	modAlt   = 0x0001
	modCtrl  = 0x0002
	modShift = 0x0004
	modWin   = 0x0008
)

type registeredHotkey struct {
	id         int
	shortcutID string // shortcut ID for placement hotkeys
	meAction   string // "close" or "hide" for Move Everything hotkeys
}

type hotkeyManager struct {
	logger        *log.Logger
	appState      *AppState
	overlays      *OverlayManager
	registered    []registeredHotkey
	cycleIndex    map[string]int // shortcutID -> current step index
	lastShortcut  string
	lastPress     time.Time
	hoveredWindow uintptr // hwnd of window hovered in Window List (0 = none)
	threadID      uint32  // Win32 thread ID for PostThreadMessage
	capturing     bool    // true while UI is recording a hotkey — all hotkeys unregistered
	mu            sync.Mutex
}

func newHotkeyManager(logger *log.Logger, appState *AppState, overlays *OverlayManager) *hotkeyManager {
	return &hotkeyManager{
		logger:     logger,
		appState:   appState,
		overlays:   overlays,
		cycleIndex: make(map[string]int),
	}
}

// keyNameToVK maps VibeGrid key names to Windows virtual key codes
var keyNameToVK = map[string]uint32{
	"a": 0x41, "b": 0x42, "c": 0x43, "d": 0x44, "e": 0x45, "f": 0x46,
	"g": 0x47, "h": 0x48, "i": 0x49, "j": 0x4A, "k": 0x4B, "l": 0x4C,
	"m": 0x4D, "n": 0x4E, "o": 0x4F, "p": 0x50, "q": 0x51, "r": 0x52,
	"s": 0x53, "t": 0x54, "u": 0x55, "v": 0x56, "w": 0x57, "x": 0x58,
	"y": 0x59, "z": 0x5A,
	"0": 0x30, "1": 0x31, "2": 0x32, "3": 0x33, "4": 0x34,
	"5": 0x35, "6": 0x36, "7": 0x37, "8": 0x38, "9": 0x39,
	"f1": 0x70, "f2": 0x71, "f3": 0x72, "f4": 0x73, "f5": 0x74,
	"f6": 0x75, "f7": 0x76, "f8": 0x77, "f9": 0x78, "f10": 0x79,
	"f11": 0x7A, "f12": 0x7B, "f13": 0x7C, "f14": 0x7D, "f15": 0x7E,
	"f16": 0x7F, "f17": 0x80, "f18": 0x81, "f19": 0x82, "f20": 0x83,
	"left": 0x25, "up": 0x26, "right": 0x27, "down": 0x28,
	"return": 0x0D, "enter": 0x0D, "space": 0x20, "tab": 0x09,
	"escape": 0x1B, "esc": 0x1B, "delete": 0x08, "backspace": 0x08,
	"forwarddelete": 0x2E,
	"home":          0x24, "end": 0x23, "pageup": 0x21, "pagedown": 0x22,
	"grave": 0xC0, "`": 0xC0,
	"-": 0xBD, "=": 0xBB, "[": 0xDB, "]": 0xDD, "\\": 0xDC,
	";": 0xBA, "'": 0xDE, ",": 0xBC, ".": 0xBE, "/": 0xBF,
	// Keypad — support both underscored and collapsed forms
	"keypad0": 0x60, "keypad1": 0x61, "keypad2": 0x62, "keypad3": 0x63,
	"keypad4": 0x64, "keypad5": 0x65, "keypad6": 0x66, "keypad7": 0x67,
	"keypad8": 0x68, "keypad9": 0x69,
	"keypadmultiply": 0x6A, "keypadasterisk": 0x6A, "keypadplus": 0x6B, "keypadminus": 0x6D,
	"keypaddecimal": 0x6E, "keypaddivide": 0x6F, "keypadslash": 0x6F,
	"keypadenter": 0x0D, "keypadequals": 0xBB, "keypadclear": 0x0C,
	// Volume / media
	"volumeup": 0xAF, "volumedown": 0xAE, "mute": 0xAD,
	// Capslock
	"capslock": 0x14,
}

// raiseWithoutActivating brings a window to the top of the Z-order
// without giving it focus or activating it. Uses the TOPMOST→NOTOPMOST trick
// to bypass Windows' foreground lock restrictions.
func raiseWithoutActivating(hwnd uintptr) {
	const hwndNoTopmost = ^uintptr(1) // -2
	procSetWindowPos.Call(hwnd, hwndTopmost, 0, 0, 0, 0,
		swpNoMove|swpNoSize|swpNoActivate)
	procSetWindowPos.Call(hwnd, hwndNoTopmost, 0, 0, 0, 0,
		swpNoMove|swpNoSize|swpNoActivate)
}

// bringToFront brings a window to the front and activates it.
func bringToFront(hwnd uintptr) {
	const hwndNoTopmost = ^uintptr(1) // -2
	procSetWindowPos.Call(hwnd, hwndTopmost, 0, 0, 0, 0,
		swpNoMove|swpNoSize|swpShowWindow)
	procSetWindowPos.Call(hwnd, hwndNoTopmost, 0, 0, 0, 0,
		swpNoMove|swpNoSize)
	procSetForegroundWindow.Call(hwnd)
}

// collapseKeyName normalizes a key name by lowercasing and stripping
// whitespace, underscores, and hyphens — matches macOS collapseKeyName.
func collapseKeyName(key string) string {
	key = strings.ToLower(strings.TrimSpace(key))
	key = strings.NewReplacer("_", "", "-", "", " ", "").Replace(key)
	return key
}

func modifiersToWin32(mods []string) uint32 {
	var flags uint32
	for _, m := range mods {
		switch strings.ToLower(m) {
		case "alt", "option":
			flags |= modAlt
		case "ctrl", "control":
			flags |= modCtrl
		case "shift":
			flags |= modShift
		case "cmd", "command", "win", "super":
			flags |= modWin
		}
	}
	return flags
}

// startHotkeyLoop runs on its own locked OS thread with a Win32 message loop.
// It registers hotkeys and dispatches placement actions when they fire.
func (hm *hotkeyManager) startHotkeyLoop() {
	ready := make(chan struct{})
	readyClosed := false
	go func() {
		runtime.LockOSThread()

		for attempt := 0; ; attempt++ {
			if attempt > 0 {
				hm.logger.Printf("hotkey: restarting message loop (attempt %d) after 2s delay", attempt+1)
				time.Sleep(2 * time.Second)
			}

			func() {
				defer func() {
					if r := recover(); r != nil {
						buf := make([]byte, 4096)
						n := runtime.Stack(buf, false)
						hm.logger.Printf("FATAL: hotkey thread panicked: %v\n%s", r, buf[:n])
					}
				}()

				tid, _, _ := procGetCurrentThreadId.Call()
				hm.threadID = uint32(tid)
				hm.logger.Printf("hotkey thread started (tid=%d, attempt %d)", hm.threadID, attempt+1)
				if !readyClosed {
					readyClosed = true
					close(ready)
				}

				hm.registerAll()

				type msgStruct struct {
					hwnd    uintptr
					message uint32
					wParam  uintptr
					lParam  uintptr
					time    uint32
					ptX     int32
					ptY     int32
				}
				var msg msgStruct

				for {
					ret, _, err := procGetMessageW.Call(
						uintptr(unsafe.Pointer(&msg)), 0, 0, 0,
					)
					threadHealth.hotkey.Store(time.Now().UnixMilli())
					if ret == 0 {
						hm.logger.Printf("hotkey thread: GetMessageW returned WM_QUIT — will restart")
						return
					}
					if int32(ret) == -1 {
						hm.logger.Printf("hotkey thread: GetMessageW error: %v — will restart", err)
						return
					}
					if msg.message == wmHotkey {
						hm.onHotkey(int(msg.wParam))
					} else if msg.message == wmUser {
						// Re-register hotkeys (triggered by config save)
						hm.registerAll()
					} else if msg.message == wmUserCapture {
						if msg.wParam == 1 {
							// Begin capture: unregister all hotkeys
							for _, rh := range hm.registered {
								procUnregisterHotKey.Call(0, uintptr(rh.id))
							}
							hm.logger.Printf("hotkey: all hotkeys unregistered for capture")
						} else {
							// End capture: re-register
							hm.registerAll()
							hm.logger.Printf("hotkey: hotkeys re-registered after capture")
						}
					}
				}
			}()
		}
	}()
	<-ready
}

func (hm *hotkeyManager) registerAll() {
	// Unregister any existing hotkeys
	for _, rh := range hm.registered {
		procUnregisterHotKey.Call(0, uintptr(rh.id))
	}
	hm.registered = nil

	cfg := hm.appState.getConfig()
	shortcuts, ok := cfg["shortcuts"].([]any)
	if !ok {
		return
	}

	id := 1
	for _, s := range shortcuts {
		sc, ok := s.(map[string]any)
		if !ok {
			continue
		}
		if enabled, ok := sc["enabled"].(bool); ok && !enabled {
			continue
		}
		hotkey, ok := sc["hotkey"].(map[string]any)
		if !ok {
			continue
		}
		keyName, _ := hotkey["key"].(string)
		keyName = collapseKeyName(keyName)
		vk, found := keyNameToVK[keyName]
		if !found {
			hm.logger.Printf("hotkey: unknown key %q, skipping", keyName)
			continue
		}

		var mods []string
		if modList, ok := hotkey["modifiers"].([]any); ok {
			for _, m := range modList {
				if ms, ok := m.(string); ok {
					mods = append(mods, ms)
				}
			}
		}
		winMods := modifiersToWin32(mods)

		shortcutID, _ := sc["id"].(string)
		ret, _, err := procRegisterHotKey.Call(0, uintptr(id), uintptr(winMods), uintptr(vk))
		if ret == 0 {
			hm.logger.Printf("hotkey: failed to register %s+%s (id=%s): %v", mods, keyName, shortcutID, err)
			continue
		}

		hm.registered = append(hm.registered, registeredHotkey{id: id, shortcutID: shortcutID})
		hm.logger.Printf("hotkey: registered id=%d %v+%s -> %s", id, mods, keyName, shortcutID)
		id++
	}

	// Register Move Everything close/hide window hotkeys
	settings, _ := cfg["settings"].(map[string]any)
	meHotkeys := []struct {
		field    string
		meAction string
	}{
		{"moveEverythingCloseWindowHotkey", "close"},
		{"moveEverythingHideWindowHotkey", "hide"},
	}
	for _, mh := range meHotkeys {
		hotkey, ok := settings[mh.field].(map[string]any)
		if !ok {
			continue
		}
		keyName, _ := hotkey["key"].(string)
		keyName = collapseKeyName(keyName)
		vk, found := keyNameToVK[keyName]
		if !found {
			hm.logger.Printf("hotkey: unknown key %q for %s, skipping", keyName, mh.field)
			continue
		}
		var mods []string
		if modList, ok := hotkey["modifiers"].([]any); ok {
			for _, m := range modList {
				if ms, ok := m.(string); ok {
					mods = append(mods, ms)
				}
			}
		}
		winMods := modifiersToWin32(mods)
		ret, _, err := procRegisterHotKey.Call(0, uintptr(id), uintptr(winMods), uintptr(vk))
		if ret == 0 {
			hm.logger.Printf("hotkey: failed to register %s+%s (%s): %v", mods, keyName, mh.field, err)
			continue
		}
		hm.registered = append(hm.registered, registeredHotkey{id: id, meAction: mh.meAction})
		hm.logger.Printf("hotkey: registered id=%d %v+%s -> ME %s", id, mods, keyName, mh.meAction)
		id++
	}
}

func (hm *hotkeyManager) onHotkey(hotkeyID int) {
	// Hold the lock only long enough to read/update cycle state and hoveredWindow.
	// Release BEFORE applyPlacement which does blocking win32Do calls — holding the
	// lock across those would block the HTTP hover handler and cause the UI to freeze.
	hm.mu.Lock()

	var shortcutID string
	var meAction string
	for _, rh := range hm.registered {
		if rh.id == hotkeyID {
			shortcutID = rh.shortcutID
			meAction = rh.meAction
			break
		}
	}

	// Handle Move Everything close/hide window hotkeys
	if meAction != "" {
		targetHwnd := hm.hoveredWindow
		hm.mu.Unlock()
		hm.handleMoveEverythingAction(meAction, targetHwnd)
		return
	}

	if shortcutID == "" {
		hm.mu.Unlock()
		return
	}

	hm.logger.Printf("hotkey fired: shortcutID=%s", shortcutID)

	// Find the shortcut config
	cfg := hm.appState.getConfig()
	shortcuts, _ := cfg["shortcuts"].([]any)
	var placements []any
	for _, s := range shortcuts {
		sc, ok := s.(map[string]any)
		if !ok {
			continue
		}
		if sid, _ := sc["id"].(string); sid == shortcutID {
			placements, _ = sc["placements"].([]any)
			break
		}
	}

	if len(placements) == 0 {
		hm.logger.Printf("hotkey: no placements for %s", shortcutID)
		hm.mu.Unlock()
		return
	}

	// Cycle logic: reset if different shortcut or >10s since last press
	now := time.Now()
	if shortcutID != hm.lastShortcut || now.Sub(hm.lastPress) > 10*time.Second {
		hm.cycleIndex[shortcutID] = 0
	}
	hm.lastShortcut = shortcutID
	hm.lastPress = now

	idx := hm.cycleIndex[shortcutID] % len(placements)
	hm.cycleIndex[shortcutID] = idx + 1

	placement, ok := placements[idx].(map[string]any)
	if !ok {
		hm.mu.Unlock()
		return
	}

	// Snapshot hoveredWindow while still under lock
	targetHwnd := hm.hoveredWindow
	hm.mu.Unlock()
	hm.applyPlacement(placement, cfg, targetHwnd)
}

func (hm *hotkeyManager) applyPlacement(placement map[string]any, cfg map[string]any, targetHwnd uintptr) {
	mode, _ := placement["mode"].(string)

	wa := getWorkArea()
	waW := float64(wa.Right - wa.Left)
	waH := float64(wa.Bottom - wa.Top)
	waX := float64(wa.Left)
	waY := float64(wa.Top)

	var nx, ny, nw, nh float64 // normalized 0..1

	switch mode {
	case "freeform":
		r, ok := placement["rect"].(map[string]any)
		if !ok {
			return
		}
		nx = toFloat(r["x"])
		ny = toFloat(r["y"])
		nw = toFloat(r["width"])
		nh = toFloat(r["height"])

	case "grid":
		g, ok := placement["grid"].(map[string]any)
		if !ok {
			return
		}
		settings, _ := cfg["settings"].(map[string]any)
		cols := toFloat(g["columns"])
		rows := toFloat(g["rows"])
		if cols <= 0 {
			cols = toFloat(settings["defaultGridColumns"])
		}
		if rows <= 0 {
			rows = toFloat(settings["defaultGridRows"])
		}
		if cols <= 0 {
			cols = 12
		}
		if rows <= 0 {
			rows = 8
		}
		nx = toFloat(g["x"]) / cols
		ny = toFloat(g["y"]) / rows
		nw = toFloat(g["width"]) / cols
		nh = toFloat(g["height"]) / rows

	default:
		hm.logger.Printf("hotkey: unknown placement mode %q", mode)
		return
	}

	// Apply gap and frame border compensation from settings
	settings, _ := cfg["settings"].(map[string]any)
	gap := toFloat(settings["gap"])
	borderComp := toFloat(settings["frameBorderCompensation"])
	if _, exists := settings["frameBorderCompensation"]; !exists {
		borderComp = 7 // Windows 10/11 default invisible frame size
	}

	x := int32(waX + nx*waW + gap)
	y := int32(waY + ny*waH + gap)
	w := int32(nw*waW - 2*gap)
	h := int32(nh*waH - 2*gap)

	hm.logger.Printf("hotkey: placing window at x=%d y=%d w=%d h=%d (gap=%.0f border=%.0f)", x, y, w, h, gap, borderComp)

	// Move the hovered window (Window List) if set, otherwise the foreground window
	isHoveredTarget := targetHwnd != 0
	var movedHwnd uintptr
	// Single win32Do call to move + raise — reduces channel contention
	win32Do(func() {
		hwnd := targetHwnd
		var browserHwnd uintptr
		if isHoveredTarget {
			browserHwnd, _, _ = procGetForegroundWindow.Call()
		}
		if hwnd == 0 {
			hwnd, _, _ = procGetForegroundWindow.Call()
		}
		if hwnd == 0 {
			hm.logger.Printf("hotkey: no target window")
			return
		}
		procShowWindow.Call(hwnd, swRestore)
		moveWindowCompensated(hwnd, x, y, w, h, int32(borderComp))
		movedHwnd = hwnd

		if isHoveredTarget {
			raiseWithoutActivating(hwnd)
			if browserHwnd != 0 {
				raiseWithoutActivating(browserHwnd)
			}
		} else {
			bringToFront(hwnd)
		}
	})
	if movedHwnd != 0 && isHoveredTarget {
		hm.overlays.ShowHoverOverlay(movedHwnd, StyleMoveEverythingHover)
	}
}

func (hm *hotkeyManager) handleMoveEverythingAction(action string, targetHwnd uintptr) {
	// If a window is hovered in Window List, use it; otherwise use foreground window
	var hwnd uintptr
	if targetHwnd != 0 {
		hwnd = targetHwnd
	} else {
		win32Do(func() {
			hwnd, _, _ = procGetForegroundWindow.Call()
		})
	}
	if hwnd == 0 {
		hm.logger.Printf("ME hotkey %s: no target window", action)
		return
	}

	hm.logger.Printf("ME hotkey %s on hwnd=%d", action, hwnd)
	win32Do(func() {
		switch action {
		case "close":
			procPostMessageW.Call(hwnd, wmClose, 0, 0)
		case "hide":
			procShowWindow.Call(hwnd, swHide)
		}
	})
}

func toFloat(v any) float64 {
	switch n := v.(type) {
	case float64:
		return n
	case int:
		return float64(n)
	case json.Number:
		f, _ := n.Float64()
		return f
	}
	return 0
}

// findAppModeBrowser returns the path to a Chromium-based browser that supports --app mode.
// Prefers Edge > Chromium > Chrome > Brave.
func findAppModeBrowser(logger *log.Logger) string {
	localApp := os.Getenv("LOCALAPPDATA")
	progFiles := os.Getenv("PROGRAMFILES")
	progFiles86 := os.Getenv("PROGRAMFILES(X86)")

	candidates := []struct {
		name  string
		paths []string
	}{
		{"Edge", []string{
			filepath.Join(progFiles, "Microsoft", "Edge", "Application", "msedge.exe"),
			filepath.Join(progFiles86, "Microsoft", "Edge", "Application", "msedge.exe"),
		}},
		{"Chromium", []string{
			filepath.Join(progFiles, "Chromium", "Application", "chrome.exe"),
			filepath.Join(localApp, "Chromium", "Application", "chrome.exe"),
		}},
		{"Chrome", []string{
			filepath.Join(progFiles, "Google", "Chrome", "Application", "chrome.exe"),
			filepath.Join(progFiles86, "Google", "Chrome", "Application", "chrome.exe"),
			filepath.Join(localApp, "Google", "Chrome", "Application", "chrome.exe"),
		}},
		{"Brave", []string{
			filepath.Join(progFiles, "BraveSoftware", "Brave-Browser", "Application", "brave.exe"),
			filepath.Join(progFiles86, "BraveSoftware", "Brave-Browser", "Application", "brave.exe"),
			filepath.Join(localApp, "BraveSoftware", "Brave-Browser", "Application", "brave.exe"),
		}},
	}

	for _, c := range candidates {
		for _, p := range c.paths {
			if _, err := os.Stat(p); err == nil {
				logger.Printf("app-mode browser: %s (%s)", c.name, p)
				return p
			}
		}
	}

	logger.Printf("app-mode browser: none found, will use default browser")
	return ""
}

func parseHwnd(key string) uintptr {
	if !strings.HasPrefix(key, "hwnd:") {
		return 0
	}
	val, err := strconv.ParseUint(strings.TrimPrefix(key, "hwnd:"), 10, 64)
	if err != nil {
		return 0
	}
	return uintptr(val)
}

// placementToScreenRect converts a placement step payload to absolute screen coordinates
func placementToScreenRect(placement map[string]any, cfg map[string]any, wa rect) (x, y, w, h int32) {
	mode, _ := placement["mode"].(string)
	settings, _ := cfg["settings"].(map[string]any)

	waW := float64(wa.Right - wa.Left)
	waH := float64(wa.Bottom - wa.Top)
	waX := float64(wa.Left)
	waY := float64(wa.Top)

	var nx, ny, nw, nh float64

	switch mode {
	case "freeform":
		r, ok := placement["rect"].(map[string]any)
		if !ok {
			return
		}
		nx = toFloat(r["x"])
		ny = toFloat(r["y"])
		nw = toFloat(r["width"])
		nh = toFloat(r["height"])
	case "grid":
		g, ok := placement["grid"].(map[string]any)
		if !ok {
			return
		}
		cols := toFloat(g["columns"])
		rows := toFloat(g["rows"])
		if cols <= 0 {
			cols = toFloat(settings["defaultGridColumns"])
		}
		if rows <= 0 {
			rows = toFloat(settings["defaultGridRows"])
		}
		if cols <= 0 {
			cols = 12
		}
		if rows <= 0 {
			rows = 8
		}
		nx = toFloat(g["x"]) / cols
		ny = toFloat(g["y"]) / rows
		nw = toFloat(g["width"]) / cols
		nh = toFloat(g["height"]) / rows
	default:
		return
	}

	gap := toFloat(settings["gap"])
	x = int32(waX + nx*waW + gap)
	y = int32(waY + ny*waH + gap)
	w = int32(nw*waW - 2*gap)
	h = int32(nh*waH - 2*gap)
	return
}

// reloadHotkeys re-registers all hotkeys (called after config save).
// Posts WM_USER to the hotkey thread since RegisterHotKey must be called
// on the same thread that runs the GetMessage loop.
func (hm *hotkeyManager) reloadHotkeys() {
	if hm.threadID != 0 {
		procPostThreadMessageW.Call(uintptr(hm.threadID), wmUser, 0, 0)
	}
}

const wmUserCapture = wmUser + 1 // begin/end hotkey capture

// beginCapture unregisters all hotkeys so the browser can capture key combos.
func (hm *hotkeyManager) beginCapture() {
	hm.mu.Lock()
	hm.capturing = true
	hm.mu.Unlock()
	if hm.threadID != 0 {
		procPostThreadMessageW.Call(uintptr(hm.threadID), wmUserCapture, 1, 0)
	}
}

// endCapture re-registers all hotkeys after recording is done.
func (hm *hotkeyManager) endCapture() {
	hm.mu.Lock()
	hm.capturing = false
	hm.mu.Unlock()
	if hm.threadID != 0 {
		procPostThreadMessageW.Call(uintptr(hm.threadID), wmUserCapture, 0, 0)
	}
}

// ---------------------------------------------------------------------------
// Window inventory (matches macOS MoveEverything format)
// ---------------------------------------------------------------------------

type MoveEverythingWindow struct {
	Key         string `json:"key"`
	Title       string `json:"title"`
	AppName     string `json:"appName"`
	IsVisible   bool   `json:"isVisible"`
	CanRestore  bool   `json:"canRestore"`
	IconDataURL string `json:"iconDataURL,omitempty"`
}

// isRealWindow checks if a window is a real user-visible window (taskbar-like filter).
// This mirrors the algorithm Windows uses to decide what appears on the taskbar.
func isRealWindow(hwnd uintptr) bool {
	// Skip child windows
	style, _, _ := procGetWindowLongW.Call(hwnd, gwlStyle)
	if style&wsChild != 0 {
		return false
	}

	exStyle, _, _ := procGetWindowLongW.Call(hwnd, gwlExStyle)

	// WS_EX_APPWINDOW forces taskbar presence — always include
	if exStyle&wsExAppWindow != 0 {
		return true
	}

	// WS_EX_TOOLWINDOW hides from taskbar — exclude
	if exStyle&wsExToolWindow != 0 {
		return false
	}

	// WS_EX_NOACTIVATE windows are usually not real — exclude
	if exStyle&wsExNoActivate2 != 0 {
		return false
	}

	// Owned windows (have an owner) are typically secondary — exclude
	owner, _, _ := procGetWindow.Call(hwnd, gwOwner)
	if owner != 0 {
		return false
	}

	// Filter known system/junk window classes
	clsBuf := make([]uint16, 256)
	n, _, _ := procGetClassNameW.Call(hwnd, uintptr(unsafe.Pointer(&clsBuf[0])), 256)
	if n > 0 {
		cls := syscall.UTF16ToString(clsBuf[:n])
		switch cls {
		case "DesktopWindowXamlSource", "Windows.UI.Core.CoreWindow",
			"ForegroundStaging", "ApplicationFrameWindow",
			"Shell_TrayWnd", "Shell_SecondaryTrayWnd",
			"Progman", "WorkerW", "tooltips_class32",
			"NotifyIconOverflowWindow", "TopLevelWindowForOverflowXamlIsland":
			return false
		}
	}

	// Skip windows with zero size
	var r rect
	procGetWindowRect.Call(hwnd, uintptr(unsafe.Pointer(&r)))
	if r.Right <= r.Left || r.Bottom <= r.Top {
		return false
	}

	return true
}

func listMoveEverythingWindows(logger *log.Logger, icons *iconCache) map[string]any {
	var visible []MoveEverythingWindow
	var hidden []MoveEverythingWindow

	win32Do(func() {
		cb := syscall.NewCallback(func(hwnd uintptr, _ uintptr) uintptr {
			title := getWindowText(hwnd)
			if title == "" {
				return 1
			}
			if !isRealWindow(hwnd) {
				return 1
			}

			// Get process name and exe path for icon extraction
			var pid uint32
			procGetWindowThreadProcessId.Call(hwnd, uintptr(unsafe.Pointer(&pid)))
			appName := getProcessName(hwnd)
			if appName == "" {
				appName = "(unknown)"
			}
			if pid != 0 && icons != nil {
				if exePath := getProcessPath(pid); exePath != "" {
					icons.registerPath(appName, exePath)
				}
				icons.ensureExtracted(appName)
			}

			isVisible, _, _ := procIsWindowVisible.Call(hwnd)

			// Determine if a hidden window can be meaningfully restored.
			// Windows without WS_MINIMIZEBOX or WS_THICKFRAME, or with zero-size
			// rects, are typically dummy/menu-bar/system windows that can't be shown.
			style, _, _ := procGetWindowLongW.Call(hwnd, gwlStyle)
			const wsMinimizeBox = 0x00020000
			const wsThickFrame = 0x00040000
			const wsCaption = 0x00C00000
			canRestore := true
			if isVisible == 0 {
				var r rect
				procGetWindowRect.Call(hwnd, uintptr(unsafe.Pointer(&r)))
				hasCaption := style&wsCaption == wsCaption
				hasSizeOrMin := style&(wsMinimizeBox|wsThickFrame) != 0
				hasSize := (r.Right-r.Left) > 1 && (r.Bottom-r.Top) > 1
				canRestore = hasCaption && hasSizeOrMin && hasSize
			}

			w := MoveEverythingWindow{
				Key:        fmt.Sprintf("hwnd:%d", hwnd),
				Title:      title,
				AppName:    appName,
				IsVisible:  isVisible != 0,
				CanRestore: canRestore,
			}
			if icons != nil {
				w.IconDataURL = icons.getDataURL(appName)
			}
			if isVisible != 0 {
				visible = append(visible, w)
			} else {
				hidden = append(hidden, w)
			}
			return 1
		})
		procEnumWindows.Call(cb, 0)
	})

	if visible == nil {
		visible = []MoveEverythingWindow{}
	}
	if hidden == nil {
		hidden = []MoveEverythingWindow{}
	}

	return map[string]any{"visible": visible, "hidden": hidden}
}

// ---------------------------------------------------------------------------
// Window actions
// ---------------------------------------------------------------------------

func doWindowAction(key, action string, logger *log.Logger) error {
	if !strings.HasPrefix(key, "hwnd:") {
		return fmt.Errorf("invalid window key")
	}
	hwndVal, err := strconv.ParseUint(strings.TrimPrefix(key, "hwnd:"), 10, 64)
	if err != nil {
		return fmt.Errorf("invalid hwnd in key")
	}
	hwnd := uintptr(hwndVal)

	logger.Printf("executing action=%q key=%q", action, key)

	var actionErr error
	win32Do(func() {
		switch action {
		case "focus":
			procShowWindow.Call(hwnd, swRestore)
			bringToFront(hwnd)
		case "hide":
			procShowWindow.Call(hwnd, swHide)
		case "show":
			procShowWindow.Call(hwnd, swRestore)
		case "close":
			procPostMessageW.Call(hwnd, wmClose, 0, 0)
		case "maximize":
			procShowWindow.Call(hwnd, swMaximize)
		case "center":
			var r rect
			procGetWindowRect.Call(hwnd, uintptr(unsafe.Pointer(&r)))
			wa := getWorkArea()
			w := r.Right - r.Left
			h := r.Bottom - r.Top
			screenW := wa.Right - wa.Left
			screenH := wa.Bottom - wa.Top
			x := wa.Left + (screenW-w)/2
			y := wa.Top + (screenH-h)/2
			procMoveWindow.Call(hwnd, uintptr(x), uintptr(y), uintptr(w), uintptr(h), 1)
		default:
			actionErr = fmt.Errorf("unsupported action: %s", action)
		}
	})
	return actionErr
}

func retileVisibleWindows(as *AppState, logger *log.Logger, widthFraction float64, aspectRatio float64) error {
	type retileWindow struct {
		hwnd    uintptr
		title   string
		appName string
	}

	type tileCandidate struct {
		rows, cols   int
		tileW, tileH float64
		aspectDelta  float64
		usedArea     float64
	}

	wa := getWorkArea()
	availableX := float64(wa.Left)
	availableY := float64(wa.Top)
	availableW := float64(wa.Right - wa.Left)
	availableH := float64(wa.Bottom - wa.Top)
	if availableW <= 0 || availableH <= 0 {
		return fmt.Errorf("invalid work area")
	}

	cfgGap := 0.0
	borderComp := 7.0
	settings, _ := as.getConfig()["settings"].(map[string]any)
	if settings != nil {
		cfgGap = toFloat(settings["gap"])
		if _, exists := settings["frameBorderCompensation"]; exists {
			borderComp = toFloat(settings["frameBorderCompensation"])
		}
	}
	if cfgGap < 0 {
		cfgGap = 0
	}
	var windows []retileWindow
	var ccMidX float64 = -1
	win32Do(func() {
		cb := syscall.NewCallback(func(hwnd uintptr, _ uintptr) uintptr {
			title := getWindowText(hwnd)
			if title == "" || !isRealWindow(hwnd) {
				return 1
			}
			if strings.EqualFold(strings.TrimSpace(title), "VibeGrid Control Center") {
				var r rect
				procGetWindowRect.Call(hwnd, uintptr(unsafe.Pointer(&r)))
				ccMidX = float64(r.Left+r.Right) / 2
				return 1
			}
			isVisible, _, _ := procIsWindowVisible.Call(hwnd)
			if isVisible == 0 {
				return 1
			}
			windows = append(windows, retileWindow{
				hwnd:    hwnd,
				title:   strings.TrimSpace(title),
				appName: strings.TrimSpace(getProcessName(hwnd)),
			})
			return 1
		})
		procEnumWindows.Call(cb, 0)
	})

	if widthFraction > 0 && widthFraction < 1 {
		sliceW := math.Max(math.Floor(availableW*widthFraction), 1)
		screenMidX := availableX + availableW/2
		if ccMidX >= 0 && ccMidX <= screenMidX {
			// Control center is on the left half; move windows to the right
			availableX = availableX + availableW - sliceW
		}
		availableW = sliceW
	}

	if len(windows) == 0 {
		return fmt.Errorf("no visible windows were found")
	}
	sort.SliceStable(windows, func(i, j int) bool {
		leftAppFold := strings.ToLower(windows[i].appName)
		rightAppFold := strings.ToLower(windows[j].appName)
		if leftAppFold != rightAppFold {
			return leftAppFold < rightAppFold
		}
		leftTitleFold := strings.ToLower(windows[i].title)
		rightTitleFold := strings.ToLower(windows[j].title)
		if leftTitleFold != rightTitleFold {
			return leftTitleFold < rightTitleFold
		}
		return windows[i].hwnd < windows[j].hwnd
	})

	var best *tileCandidate
	for rows := 1; rows <= len(windows); rows++ {
		cols := (len(windows) + rows - 1) / rows
		usableW := availableW - cfgGap*float64(maxInt(cols-1, 0))
		usableH := availableH - cfgGap*float64(maxInt(rows-1, 0))
		if usableW <= 0 || usableH <= 0 {
			continue
		}

		tileW := usableW / float64(cols)
		tileH := usableH / float64(rows)
		if tileW < 80 || tileH < 60 {
			continue
		}

		actualAspect := tileW / tileH
		aspectDelta := math.Abs(math.Log(actualAspect / aspectRatio))
		usedArea := tileW * tileH * float64(len(windows))
		if best != nil {
			isBetterAspect := aspectDelta < best.aspectDelta-0.001
			isSimilarAspect := math.Abs(aspectDelta-best.aspectDelta) <= 0.001
			if !isBetterAspect && !(isSimilarAspect && usedArea > best.usedArea) {
				continue
			}
		}
		best = &tileCandidate{rows: rows, cols: cols, tileW: tileW, tileH: tileH, aspectDelta: aspectDelta, usedArea: usedArea}
	}

	if best == nil {
		return fmt.Errorf("unable to compute a valid tile layout")
	}

	win32Do(func() {
		for index, window := range windows {
			row := index / best.cols
			col := index % best.cols
			x := int32(availableX + float64(col)*(best.tileW+cfgGap))
			y := int32(availableY + float64(row)*(best.tileH+cfgGap))
			w := int32(best.tileW)
			h := int32(best.tileH)

			procShowWindow.Call(window.hwnd, swRestore)
			moveWindowCompensated(window.hwnd, x, y, w, h, int32(borderComp))
			raiseWithoutActivating(window.hwnd)
		}
	})

	return nil
}

func minFloat(a, b float64) float64 {
	if a < b {
		return a
	}
	return b
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}

// ---------------------------------------------------------------------------
// Config persistence
// ---------------------------------------------------------------------------

type AppState struct {
	mu               sync.RWMutex
	config           map[string]any
	configPath       string
	legacyConfigPath string
	logger           *log.Logger
}

func newAppState(logger *log.Logger) *AppState {
	configDir := filepath.Join(os.Getenv("APPDATA"), "VibeGrid")
	configPath := filepath.Join(configDir, "config.yaml")
	legacyConfigPath := filepath.Join(configDir, "config.json")

	as := &AppState{
		configPath:       configPath,
		legacyConfigPath: legacyConfigPath,
		logger:           logger,
	}

	data, err := os.ReadFile(configPath)
	if err == nil {
		cfg, parseErr := yamlToConfig(string(data))
		if parseErr == nil {
			as.config = cfg
			logger.Printf("loaded config from %s", configPath)
			return as
		}
		logger.Printf("failed to parse YAML config at %s: %v", configPath, parseErr)
	}

	data, err = os.ReadFile(legacyConfigPath)
	if err == nil {
		var cfg map[string]any
		if json.Unmarshal(data, &cfg) == nil {
			as.config = cfg
			if saveErr := as.saveConfig(cfg); saveErr != nil {
				logger.Printf("failed to migrate legacy JSON config from %s to %s: %v", legacyConfigPath, configPath, saveErr)
			} else {
				logger.Printf("migrated legacy config from %s to %s", legacyConfigPath, configPath)
			}
			return as
		}
		logger.Printf("failed to parse legacy JSON config at %s", legacyConfigPath)
	}

	as.config = defaultConfig()
	logger.Printf("using default config (path=%s)", configPath)
	return as
}

func defaultConfig() map[string]any {
	return map[string]any{
		"version": 1,
		"settings": map[string]any{
			"defaultGridColumns":                            12,
			"defaultGridRows":                               8,
			"gap":                                           0,
			"frameBorderCompensation":                       7,
			"defaultCycleDisplaysOnWrap":                    false,
			"animationDuration":                             0,
			"controlCenterScale":                            1,
			"themeMode":                                     "system",
			"moveEverythingMoveOnSelection":                 "miniControlCenterOnTop",
			"moveEverythingCenterWidthPercent":              33,
			"moveEverythingCenterHeightPercent":             70,
			"moveEverythingStartAlwaysOnTop":                false,
			"moveEverythingStartMoveToBottom":               false,
			"moveEverythingAdvancedControlCenterHover":      true,
			"moveEverythingStickyHoverStealFocus":           false,
			"moveEverythingCloseHideHotkeysOutsideMode":     false,
			"moveEverythingExcludeControlCenter":            false,
			"moveEverythingMiniRetileWidthPercent":          25,
			"moveEverythingBackgroundRefreshInterval":       5,
			"moveEverythingITermRecentActivityTimeout":      10,
			"moveEverythingITermRecentActivityActiveText":   "[ACTIVE]",
			"moveEverythingITermRecentActivityIdleText":     "",
			"moveEverythingITermRecentActivityBadgeEnabled": true,
			"moveEverythingITermRecentActivityColorize":     true,
			"moveEverythingActiveWindowHighlightColorize":   true,
			"moveEverythingActiveWindowHighlightColor":      "#4D88D4",
			"moveEverythingITermRecentActivityActiveColor":  "#2F8F4E",
			"moveEverythingITermRecentActivityIdleColor":    "#BA4D4D",
			"moveEverythingOverlayMode":                     "persistent",
			"moveEverythingOverlayDuration":                 2,
			"moveEverythingCloseWindowHotkey":               nil,
			"moveEverythingHideWindowHotkey":                nil,
			"largerFonts":                                   true,
		},
		"shortcuts": defaultShortcuts(),
	}
}

func defaultShortcuts() []any {
	g := func(x, y, w, h int) map[string]any {
		return map[string]any{
			"columns": 6, "rows": 6,
			"x": x, "y": y, "width": w, "height": h,
		}
	}
	p := func(id string, grid map[string]any) map[string]any {
		return map[string]any{
			"id": id, "title": "", "mode": "grid",
			"display": "active", "grid": grid,
		}
	}
	s := func(id, name, key string, placements ...map[string]any) map[string]any {
		return map[string]any{
			"id":   id,
			"name": name,
			"hotkey": map[string]any{
				"key":       key,
				"modifiers": []any{"ctrl"},
			},
			"placements": placements,
		}
	}
	return []any{
		s("cycle-left", "Left", "keypad4",
			p("left-half", g(0, 0, 3, 6)),
			p("left-third", g(0, 0, 2, 6))),
		s("cycle-right", "Right", "keypad6",
			p("right-half", g(3, 0, 3, 6)),
			p("right-third", g(4, 0, 2, 6))),
		s("cycle-center", "Center", "keypad5",
			p("full-screen", g(0, 0, 6, 6)),
			p("center-third", g(2, 0, 2, 6))),
		s("cycle-top", "Top", "keypad8",
			p("top-full", g(0, 0, 6, 3)),
			p("top-center", g(2, 0, 2, 3))),
		s("cycle-bottom", "Bottom", "keypad2",
			p("bottom-full", g(0, 3, 6, 3)),
			p("bottom-center", g(2, 3, 2, 3))),
		s("cycle-top-left", "Top Left", "keypad7",
			p("top-left-half", g(0, 0, 3, 3)),
			p("top-left-third", g(0, 0, 2, 3))),
		s("cycle-top-right", "Top Right", "keypad9",
			p("top-right-half", g(3, 0, 3, 3)),
			p("top-right-third", g(4, 0, 2, 3))),
		s("cycle-bottom-left", "Bottom Left", "keypad1",
			p("bottom-left-half", g(0, 3, 3, 3)),
			p("bottom-left-third", g(0, 3, 2, 3))),
		s("cycle-bottom-right", "Bottom Right", "keypad3",
			p("bottom-right-half", g(3, 3, 3, 3)),
			p("bottom-right-third", g(4, 3, 2, 3))),
	}
}

func (as *AppState) getConfig() map[string]any {
	as.mu.RLock()
	defer as.mu.RUnlock()
	return as.config
}

func (as *AppState) saveConfig(cfg map[string]any) error {
	as.mu.Lock()
	as.config = cfg
	as.mu.Unlock()

	dir := filepath.Dir(as.configPath)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	yamlText, err := configToYAML(cfg)
	if err != nil {
		return err
	}
	if err := os.WriteFile(as.configPath, []byte(yamlText), 0o644); err != nil {
		return err
	}
	as.logger.Printf("config saved to %s", as.configPath)
	return nil
}

// ---------------------------------------------------------------------------
// State push (polled by bridge.js)
// ---------------------------------------------------------------------------

type statePush struct {
	Version int64 `json:"version"`
	Message any   `json:"message,omitempty"`
}

var (
	stateVersion atomic.Int64
	stateMu      sync.RWMutex
	stateMsg     any
	globalTray   *trayIcon // cleaned up on exit

	// Track browser processes launched by openBrowser so we can close them
	browserProcsMu sync.Mutex
	browserProcs   []*os.Process
)

func pushState(msg any) {
	stateMu.Lock()
	stateMsg = msg
	stateMu.Unlock()
	stateVersion.Add(1)
}

func getStatePush() statePush {
	stateMu.RLock()
	msg := stateMsg
	stateMu.RUnlock()
	return statePush{
		Version: stateVersion.Load(),
		Message: msg,
	}
}

// closeBrowserWindows kills all tracked browser processes (closes the client UI).
func closeBrowserWindows(logger *log.Logger) {
	browserProcsMu.Lock()
	procs := browserProcs
	browserProcs = nil
	browserProcsMu.Unlock()

	for _, p := range procs {
		if p != nil {
			logger.Printf("closing browser process pid=%d", p.Pid)
			p.Kill()
		}
	}
}

func buildFullState(as *AppState, logger *log.Logger, icons *iconCache) map[string]any {
	windows := listMoveEverythingWindows(logger, icons)
	return map[string]any{
		"type": "state",
		"payload": map[string]any{
			"config":                             as.getConfig(),
			"hotKeyIssues":                       []any{},
			"configPath":                         as.configPath,
			"permissions":                        map[string]any{"accessibility": true},
			"runtime":                            map[string]any{"sandboxed": false, "message": ""},
			"launchAtLogin":                      map[string]any{"supported": true, "enabled": isLaunchAtStartupEnabled(), "requiresApproval": false, "message": ""},
			"moveEverythingActive":               true,
			"moveEverythingWindows":              windows,
			"controlCenterFocused":               true,
			"moveEverythingControlCenterFocused": true,
			"moveEverythingAlwaysOnTop":          false,
			"moveEverythingMoveToBottom":         false,
			"moveEverythingDontMoveVibeGrid":     false,
			"moveEverythingShowOverlays":         false,
			"yaml":                               "",
		},
	}
}

// ---------------------------------------------------------------------------
// Bridge message handler
// ---------------------------------------------------------------------------

func handleBridgeMessage(msg map[string]any, as *AppState, overlays *OverlayManager, hkMgr *hotkeyManager, icons *iconCache, logger *log.Logger) any {
	msgType, _ := msg["type"].(string)
	payload, _ := msg["payload"].(map[string]any)

	switch msgType {
	case "ready", "requestState":
		state := buildFullState(as, logger, icons)
		pushState(state)
		return state

	case "saveConfig":
		cfgPayload := payload
		if cfgPayload != nil {
			if inner, ok := cfgPayload["config"].(map[string]any); ok {
				cfgPayload = inner
			}
		}
		if cfgPayload == nil {
			return map[string]any{"type": "notice", "payload": map[string]any{"level": "error", "message": "No config payload"}}
		}
		if err := as.saveConfig(cfgPayload); err != nil {
			return map[string]any{"type": "notice", "payload": map[string]any{"level": "error", "message": err.Error()}}
		}
		hkMgr.reloadHotkeys()
		pushState(buildFullState(as, logger, icons))
		return map[string]any{"type": "notice", "payload": map[string]any{"level": "success", "message": "Configuration saved"}}

	case "toggleMoveEverythingMode", "ensureMoveEverythingMode":
		state := buildFullState(as, logger, icons)
		pushState(state)
		return state

	case "moveEverythingFocusWindow":
		key, _ := payload["key"].(string)
		if key != "" {
			doWindowAction(key, "focus", logger)
		}
		pushState(buildFullState(as, logger, icons))
		return map[string]any{"type": "ok"}

	case "moveEverythingCloseWindow":
		key, _ := payload["key"].(string)
		if key != "" {
			doWindowAction(key, "close", logger)
			time.Sleep(100 * time.Millisecond)
		}
		state := buildFullState(as, logger, icons)
		pushState(state)
		return state

	case "moveEverythingHideWindow":
		key, _ := payload["key"].(string)
		if key != "" {
			doWindowAction(key, "hide", logger)
		}
		state := buildFullState(as, logger, icons)
		pushState(state)
		return state

	case "moveEverythingShowWindow":
		key, _ := payload["key"].(string)
		if key != "" {
			doWindowAction(key, "show", logger)
		}
		state := buildFullState(as, logger, icons)
		pushState(state)
		return state

	case "moveEverythingCenterWindow":
		key, _ := payload["key"].(string)
		if key != "" {
			doWindowAction(key, "center", logger)
		}
		state := buildFullState(as, logger, icons)
		pushState(state)
		return state

	case "moveEverythingMaximizeWindow":
		key, _ := payload["key"].(string)
		if key != "" {
			doWindowAction(key, "maximize", logger)
		}
		state := buildFullState(as, logger, icons)
		pushState(state)
		return state

	case "moveEverythingRetileVisibleWindows":
		if err := retileVisibleWindows(as, logger, 1, 3.0/2.0); err != nil {
			return map[string]any{"type": "notice", "payload": map[string]any{"level": "error", "message": err.Error()}}
		}
		state := buildFullState(as, logger, icons)
		pushState(state)
		return state

	case "moveEverythingMiniRetileVisibleWindows":
		if err := retileVisibleWindows(as, logger, 0.25, 1); err != nil {
			return map[string]any{"type": "notice", "payload": map[string]any{"level": "error", "message": err.Error()}}
		}
		state := buildFullState(as, logger, icons)
		pushState(state)
		return state

	case "jsLog":
		level, _ := payload["level"].(string)
		message, _ := payload["message"].(string)
		logger.Printf("JS [%s]: %s", level, message)
		return map[string]any{"type": "ok"}

	case "reloadConfig":
		pushState(buildFullState(as, logger, icons))
		return map[string]any{"type": "notice", "payload": map[string]any{"level": "info", "message": "Reloaded config"}}

	case "moveEverythingHoverWindow":
		key, _ := payload["key"].(string)
		key = strings.TrimSpace(key)
		if key == "" {
			overlays.HideHoverOverlay()
			hkMgr.mu.Lock()
			hkMgr.hoveredWindow = 0
			hkMgr.mu.Unlock()
		} else {
			hwnd := parseHwnd(key)
			if hwnd != 0 {
				overlays.ShowHoverOverlay(hwnd, StyleMoveEverythingHover)
				hkMgr.mu.Lock()
				hkMgr.hoveredWindow = hwnd
				hkMgr.mu.Unlock()
			}
		}
		return map[string]any{"type": "ok"}

	case "previewPlacement":
		if payload == nil {
			overlays.HidePreviewOverlay()
			return map[string]any{"type": "ok"}
		}
		cfg := as.getConfig()
		wa := getWorkArea()
		x, y, w, h := placementToScreenRect(payload, cfg, wa)
		if w > 0 && h > 0 {
			overlays.ShowPreviewOverlay(x, y, w, h, StylePreview)
		} else {
			overlays.HidePreviewOverlay()
		}
		return map[string]any{"type": "ok"}

	case "hidePlacementPreview":
		overlays.HidePreviewOverlay()
		return map[string]any{"type": "ok"}

	case "requestAccessibility":
		return map[string]any{
			"type": "permission",
			"payload": map[string]any{
				"accessibility": true,
			},
		}

	case "openConfigFile":
		go exec.Command("rundll32", "url.dll,FileProtocolHandler", as.configPath).Start()
		return map[string]any{"type": "ok"}

	case "saveAsYaml", "loadFromYaml":
		// Handled by bridge.js via /api/yaml/export and /api/yaml/import
		return map[string]any{"type": "ok"}

	case "setLaunchAtLogin":
		enabled, _ := payload["enabled"].(bool)
		if err := setLaunchAtStartup(enabled); err != nil {
			logger.Printf("setLaunchAtStartup(%v): %v", enabled, err)
			return map[string]any{"type": "notice", "payload": map[string]any{"level": "error", "message": fmt.Sprintf("Failed to update startup setting: %v", err)}}
		}
		logger.Printf("launch at startup: %v", enabled)
		return map[string]any{"type": "ok"}

	case "openLoginItemsSettings":
		go exec.Command("cmd", "/c", "start", "ms-settings:startupapps").Start()
		return map[string]any{"type": "ok"}

	case "setMoveEverythingAlwaysOnTop",
		"setMoveEverythingShowOverlays",
		"setMoveEverythingMoveToBottom",
		"setMoveEverythingDontMoveVibeGrid",
		"setMoveEverythingNarrowMode",
		"openSettings":
		return map[string]any{"type": "ok"}

	case "beginHotkeyCapture":
		hkMgr.beginCapture()
		return map[string]any{"type": "ok"}

	case "endHotkeyCapture":
		hkMgr.endCapture()
		return map[string]any{"type": "ok"}

	case "hideControlCenter":
		closeBrowserWindows(logger)
		return map[string]any{"type": "ok"}

	case "exitApp":
		logger.Printf("exit requested from UI")
		go func() {
			closeBrowserWindows(logger)
			time.Sleep(300 * time.Millisecond)
			if globalTray != nil {
				globalTray.remove()
			}
			os.Exit(0)
		}()
		return map[string]any{"type": "exitApp"}

	default:
		logger.Printf("unhandled bridge message: %s", msgType)
		return map[string]any{"type": "ok"}
	}
}

// ---------------------------------------------------------------------------
// Launch at startup (registry-based)
// ---------------------------------------------------------------------------

const startupRegistryKey = `Software\Microsoft\Windows\CurrentVersion\Run`
const startupRegistryValueName = "VibeGrid"

func isLaunchAtStartupEnabled() bool {
	var h syscall.Handle
	keyPath, _ := syscall.UTF16PtrFromString(startupRegistryKey)
	err := syscall.RegOpenKeyEx(syscall.HKEY_CURRENT_USER, keyPath, 0, syscall.KEY_READ, &h)
	if err != nil {
		return false
	}
	defer syscall.RegCloseKey(h)

	valName, _ := syscall.UTF16PtrFromString(startupRegistryValueName)
	var typ uint32
	var bufLen uint32
	err = syscall.RegQueryValueEx(h, valName, nil, &typ, nil, &bufLen)
	return err == nil
}

func setLaunchAtStartup(enabled bool) error {
	var h syscall.Handle
	keyPath, _ := syscall.UTF16PtrFromString(startupRegistryKey)
	access := uint32(syscall.KEY_SET_VALUE)
	err := syscall.RegOpenKeyEx(syscall.HKEY_CURRENT_USER, keyPath, 0, access, &h)
	if err != nil {
		return fmt.Errorf("RegOpenKeyEx: %w", err)
	}
	defer syscall.RegCloseKey(h)

	valName, _ := syscall.UTF16PtrFromString(startupRegistryValueName)
	if !enabled {
		procRegDeleteValueW.Call(uintptr(h), uintptr(unsafe.Pointer(valName)))
		return nil
	}

	exePath, err := os.Executable()
	if err != nil {
		return fmt.Errorf("os.Executable: %w", err)
	}
	exePath, _ = filepath.Abs(exePath)
	val, _ := syscall.UTF16FromString(`"` + exePath + `"`)
	byteLen := uint32(len(val) * 2)
	ret, _, callErr := procRegSetValueExW.Call(
		uintptr(h),
		uintptr(unsafe.Pointer(valName)),
		0,
		uintptr(syscall.REG_SZ),
		uintptr(unsafe.Pointer(&val[0])),
		uintptr(byteLen),
	)
	if ret != 0 {
		return fmt.Errorf("RegSetValueExW: %w", callErr)
	}
	return nil
}

// ---------------------------------------------------------------------------
// HTTP server
// ---------------------------------------------------------------------------

// serverState holds the port, token, and PID of a running instance.
type serverState struct {
	Port  int    `json:"port"`
	Token string `json:"token"`
	PID   int    `json:"pid"`
}

func serverStatePath() string {
	return filepath.Join(os.Getenv("APPDATA"), "VibeGrid", "server.json")
}

func generateSessionToken() string {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic("crypto/rand failed: " + err.Error())
	}
	return hex.EncodeToString(b)
}

func readServerState() (*serverState, error) {
	data, err := os.ReadFile(serverStatePath())
	if err != nil {
		return nil, err
	}
	var s serverState
	if err := json.Unmarshal(data, &s); err != nil {
		return nil, err
	}
	return &s, nil
}

func writeServerState(s *serverState) error {
	data, err := json.Marshal(s)
	if err != nil {
		return err
	}
	path := serverStatePath()
	os.MkdirAll(filepath.Dir(path), 0700)
	return os.WriteFile(path, data, 0600)
}

// securityMiddleware adds per-session token authentication and security headers.
// API endpoints (except /api/health) require a random session token in the
// X-VibeGrid-Token header, preventing cross-origin and local spoofing attacks.
func securityMiddleware(next http.Handler, token string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Content-Security-Policy",
			"default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'")

		if strings.HasPrefix(r.URL.Path, "/api/") && r.URL.Path != "/api/health" {
			if r.Header.Get("X-VibeGrid-Token") != token {
				http.Error(w, "forbidden", http.StatusForbidden)
				return
			}
		}

		next.ServeHTTP(w, r)
	})
}

func init() {
	// Set per-monitor DPI awareness before any Win32 calls so that
	// GetWindowRect and SystemParametersInfo use the same coordinate space.
	// DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = -4
	if proc, err := syscall.LoadDLL("user32.dll"); err == nil {
		if fn, err := proc.FindProc("SetProcessDpiAwarenessContext"); err == nil {
			fn.Call(^uintptr(3)) // -4 as uintptr
		}
	}
}

func main() {
	sessionToken := generateSessionToken()

	// If an existing instance is running, ask it to show its control center and exit.
	if old, err := readServerState(); err == nil {
		oldAddr := fmt.Sprintf("127.0.0.1:%d", old.Port)
		client := &http.Client{Timeout: 2 * time.Second}
		if resp, err := client.Get("http://" + oldAddr + "/api/health"); err == nil {
			resp.Body.Close()
			// Tell existing instance to show the control center
			if showReq, err := http.NewRequest(http.MethodPost, "http://"+oldAddr+"/api/show", nil); err == nil {
				showReq.Header.Set("X-VibeGrid-Token", old.Token)
				if sr, se := client.Do(showReq); se == nil {
					sr.Body.Close()
					os.Exit(0) // Existing instance will show the UI; we can exit
				}
			}
			// If /api/show failed, fall through to quit the old instance and start fresh
			if quitReq, err := http.NewRequest(http.MethodPost, "http://"+oldAddr+"/api/quit", nil); err == nil {
				quitReq.Header.Set("X-VibeGrid-Token", old.Token)
				if qr, qe := client.Do(quitReq); qe == nil {
					qr.Body.Close()
				}
			}
			for i := 0; i < 30; i++ {
				time.Sleep(100 * time.Millisecond)
				if _, err := client.Get("http://" + oldAddr + "/api/health"); err != nil {
					break
				}
			}
		}
	}

	// Bind an ephemeral port — the address is no longer predictable.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		log.Fatalf("failed to bind listener: %v", err)
	}
	addr := ln.Addr().String()
	_, portStr, _ := net.SplitHostPort(addr)
	port, _ := strconv.Atoi(portStr)
	writeServerState(&serverState{Port: port, Token: sessionToken, PID: os.Getpid()})

	// Log to file so we have diagnostics even when running without a console
	logWriter := os.Stdout
	if logFile, err := os.OpenFile(
		filepath.Join(os.TempDir(), "vibegrid-win11.log"),
		os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644,
	); err == nil {
		logWriter = logFile
		defer logFile.Close()
	}
	logger := log.New(logWriter, "[vibegrid-win11] ", log.LstdFlags|log.Lmicroseconds)
	logger.Printf("=== VibeGrid starting (pid=%d) ===", os.Getpid())
	initWin32Thread(logger)

	appState := newAppState(logger)
	appIcons := newIconCache()
	overlays := newOverlayManager()
	overlays.start(logger)

	hkManager := newHotkeyManager(logger, appState, overlays)
	hkManager.startHotkeyLoop()

	mux := http.NewServeMux()

	mux.HandleFunc("/api/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"ok": true})
	})

	mux.HandleFunc("/api/quit", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		logger.Printf("quit requested via /api/quit")
		w.WriteHeader(http.StatusOK)
		go func() {
			time.Sleep(50 * time.Millisecond)
			if globalTray != nil {
				globalTray.remove()
			}
			os.Exit(0)
		}()
	})

	mux.HandleFunc("/api/bridge", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		r.Body = http.MaxBytesReader(w, r.Body, 10<<20) // 10 MB limit
		var msg map[string]any
		if err := json.NewDecoder(r.Body).Decode(&msg); err != nil {
			http.Error(w, "invalid json", http.StatusBadRequest)
			return
		}

		reply := handleBridgeMessage(msg, appState, overlays, hkManager, appIcons, logger)

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(reply)
	})

	mux.HandleFunc("/api/state", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(getStatePush())
	})

	mux.HandleFunc("/api/yaml/export", func(w http.ResponseWriter, r *http.Request) {
		yamlText, err := configToYAML(appState.getConfig())
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "text/yaml; charset=utf-8")
		w.Write([]byte(yamlText))
	})

	mux.HandleFunc("/api/yaml/import", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, 10<<20) // 10 MB limit
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, "failed to read body", http.StatusBadRequest)
			return
		}
		cfg, err := yamlToConfig(string(body))
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		if err := appState.saveConfig(cfg); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		hkManager.reloadHotkeys()
		pushState(buildFullState(appState, logger, appIcons))
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"type":    "notice",
			"payload": map[string]any{"level": "success", "message": "YAML config loaded successfully"},
		})
	})

	// Keep old endpoints for backwards compat
	mux.HandleFunc("/api/windows", func(w http.ResponseWriter, r *http.Request) {
		windows := listMoveEverythingWindows(logger, appIcons)
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(windows)
	})

	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path
		if path == "/" {
			path = "index.html"
		} else {
			path = strings.TrimPrefix(path, "/")
		}
		data, err := webFS.ReadFile("web/" + path)
		if err != nil {
			http.NotFound(w, r)
			return
		}
		switch {
		case strings.HasSuffix(path, ".html"):
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
		case strings.HasSuffix(path, ".js"):
			w.Header().Set("Content-Type", "application/javascript; charset=utf-8")
		case strings.HasSuffix(path, ".css"):
			w.Header().Set("Content-Type", "text/css; charset=utf-8")
		case strings.HasSuffix(path, ".svg"):
			w.Header().Set("Content-Type", "image/svg+xml")
		}
		// index.html is shared with macOS. Inject Windows-only additions:
		// favicon link and bridge.js (HTTP polling bridge, loaded before app.js).
		if path == "index.html" {
			html := string(data)
			html = strings.Replace(html,
				"<link rel=\"stylesheet\" href=\"styles.css\" />",
				"<link rel=\"icon\" type=\"image/svg+xml\" href=\"favicon.svg\" />\n    <link rel=\"stylesheet\" href=\"styles.css\" />",
				1)
			html = strings.Replace(html,
				"<script src=\"app.js\"></script>",
				"<script src=\"bridge.js\"></script>\n    <script src=\"app.js\"></script>",
				1)
			html = strings.Replace(html,
				"<meta charset=\"UTF-8\" />",
				"<meta charset=\"UTF-8\" />\n    <meta name=\"vibegrid-token\" content=\""+sessionToken+"\">",
				1)
			w.Write([]byte(html))
			return
		}
		w.Write(data)
	})

	// Periodically refresh the window list so new/closed windows appear
	go func() {
		defer func() {
			if r := recover(); r != nil {
				buf := make([]byte, 4096)
				n := runtime.Stack(buf, false)
				logger.Printf("FATAL: refresh goroutine panicked: %v\n%s", r, buf[:n])
			}
			logger.Printf("FATAL: refresh goroutine exited unexpectedly")
		}()
		ticker := time.NewTicker(2 * time.Second)
		defer ticker.Stop()
		for range ticker.C {
			threadHealth.refresh.Store(time.Now().UnixMilli())
			pushState(buildFullState(appState, logger, appIcons))
		}
	}()

	// Watchdog: log warnings when threads appear stuck
	go func() {
		ticker := time.NewTicker(30 * time.Second)
		defer ticker.Stop()
		for range ticker.C {
			now := time.Now().UnixMilli()
			staleThreshold := int64(60_000) // 60 seconds
			type threadInfo struct {
				name   string
				health *atomic.Int64
			}
			threads := []threadInfo{
				{"win32", &threadHealth.win32},
				{"hotkey", &threadHealth.hotkey},
				{"tray", &threadHealth.tray},
				{"overlay", &threadHealth.overlay},
				{"refresh", &threadHealth.refresh},
			}
			for _, t := range threads {
				last := t.health.Load()
				if last > 0 && now-last > staleThreshold {
					logger.Printf("WARNING: %s thread appears stuck (last heartbeat %ds ago)", t.name, (now-last)/1000)
				}
			}
		}
	}()

	appURL := "http://" + addr
	browserPath := findAppModeBrowser(logger)

	openBrowser := func() {
		if browserPath != "" {
			// Use a dedicated user-data-dir so Edge/Chrome doesn't restore
			// a stale saved window position from a previous session.
			dataDir := filepath.Join(os.Getenv("APPDATA"), "VibeGrid", "browser-data")
			wa := getWorkArea()
			waW := int(wa.Right - wa.Left)
			waH := int(wa.Bottom - wa.Top)
			winW := waW * 45 / 100
			winH := waH
			winX := int(wa.Left) + (waW-winW)/2
			winY := int(wa.Top) + (waH-winH)/2
			args := []string{
				"--app=" + appURL,
				fmt.Sprintf("--window-position=%d,%d", winX, winY),
				fmt.Sprintf("--window-size=%d,%d", winW, winH),
				"--user-data-dir=" + dataDir,
			}
			cmd := exec.Command(browserPath, args...)
			if err := cmd.Start(); err != nil {
				logger.Printf("app-mode launch failed (%s), falling back to default browser: %v", browserPath, err)
				cmd2 := exec.Command("rundll32", "url.dll,FileProtocolHandler", appURL)
				cmd2.Start()
				if cmd2.Process != nil {
					browserProcsMu.Lock()
					browserProcs = append(browserProcs, cmd2.Process)
					browserProcsMu.Unlock()
				}
			} else if cmd.Process != nil {
				browserProcsMu.Lock()
				browserProcs = append(browserProcs, cmd.Process)
				browserProcsMu.Unlock()
			}
		} else {
			cmd := exec.Command("rundll32", "url.dll,FileProtocolHandler", appURL)
			cmd.Start()
			if cmd.Process != nil {
				browserProcsMu.Lock()
				browserProcs = append(browserProcs, cmd.Process)
				browserProcsMu.Unlock()
			}
		}
	}

	// Endpoint to show the control center from a second instance launch
	mux.HandleFunc("/api/show", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		logger.Printf("show requested via /api/show — opening browser")
		go openBrowser()
		w.WriteHeader(http.StatusOK)
	})

	// System tray icon
	tray := newTrayIcon(openBrowser, logger)
	tray.quitFn = func() {
		closeBrowserWindows(logger)
	}
	globalTray = tray
	tray.start()

	// Auto-open browser unless --no-browser is passed
	noBrowser := false
	for _, arg := range os.Args[1:] {
		if arg == "--no-browser" {
			noBrowser = true
		}
	}
	if !noBrowser {
		go func() {
			time.Sleep(300 * time.Millisecond)
			openBrowser()
		}()
	}

	logger.Printf("VibeGrid Windows 11 host listening on http://%s", addr)
	if err := http.Serve(ln, securityMiddleware(mux, sessionToken)); err != nil {
		logger.Printf("FATAL: HTTP server crashed: %v", err)
		// Keep process alive for tray icon / hotkeys even if HTTP fails
		select {}
	}
}
