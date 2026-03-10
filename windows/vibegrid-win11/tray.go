//go:build windows

package main

import (
	"log"
	"runtime"
	"sync"
	"syscall"
	"time"
	"unsafe"
)

// ---------------------------------------------------------------------------
// System tray (notification area) icon
// ---------------------------------------------------------------------------

var (
	shell32 = syscall.NewLazyDLL("shell32.dll")

	procShellNotifyIconW   = shell32.NewProc("Shell_NotifyIconW")
	procLoadIconW          = user32.NewProc("LoadIconW")
	procCreateIconIndirect = user32.NewProc("CreateIconIndirect")
	procCreatePopupMenu    = user32.NewProc("CreatePopupMenu")
	procInsertMenuItemW    = user32.NewProc("InsertMenuItemW")
	procTrackPopupMenu     = user32.NewProc("TrackPopupMenu")
	procDestroyMenu        = user32.NewProc("DestroyMenu")
	procGetCursorPos       = user32.NewProc("GetCursorPos")
)

const (
	nimAdd    = 0x00000000
	nimDelete = 0x00000002

	nifMessage = 0x00000001
	nifIcon    = 0x00000002
	nifTip     = 0x00000004

	wmApp      = 0x8000
	wmTrayIcon = wmApp + 1

	wmLButtonUp = 0x0202
	wmRButtonUp = 0x0205
	wmCommand   = 0x0111

	tpmBottomAlign = 0x0020
	tpmLeftAlign   = 0x0000

	menuOpenBrowser = 1
	menuQuit        = 2
)

// ICONINFO for CreateIconIndirect
type iconInfo struct {
	FIcon    uint32
	XHotspot uint32
	YHotspot uint32
	HbmMask  uintptr
	HbmColor uintptr
}

// NOTIFYICONDATAW — minimal V1 structure
type notifyIconData struct {
	CbSize           uint32
	HWnd             uintptr
	UID              uint32
	UFlags           uint32
	UCallbackMessage uint32
	HIcon            uintptr
	SzTip            [128]uint16
}

// Global tray instance pointer — accessed from wndproc callback
var (
	globalTrayInstance *trayIcon
	trayClassOnce     sync.Once
	trayClassName     *uint16
)

type trayIcon struct {
	hwnd   uintptr
	nid    notifyIconData
	hIcon  uintptr
	openFn func()
	quitFn func() // called before exit to clean up (e.g. close browser)
	logger *log.Logger
}

func newTrayIcon(openFn func(), logger *log.Logger) *trayIcon {
	return &trayIcon{openFn: openFn, logger: logger}
}

func registerTrayClass() {
	trayClassOnce.Do(func() {
		name, _ := syscall.UTF16PtrFromString("VibeGridTray")
		trayClassName = name

		type wndClassExW struct {
			CbSize        uint32
			Style         uint32
			LpfnWndProc   uintptr
			CbClsExtra    int32
			CbWndExtra    int32
			HInstance     uintptr
			HIcon         uintptr
			HCursor       uintptr
			HbrBackground uintptr
			LpszMenuName  *uint16
			LpszClassName *uint16
			HIconSm       uintptr
		}

		wndProc := syscall.NewCallback(trayWndProc)

		cls := wndClassExW{
			LpfnWndProc:   wndProc,
			LpszClassName: trayClassName,
		}
		cls.CbSize = uint32(unsafe.Sizeof(cls))
		procRegisterClassExW.Call(uintptr(unsafe.Pointer(&cls)))
	})
}

func trayWndProc(hwnd, msg, wParam, lParam uintptr) uintptr {
	t := globalTrayInstance

	switch msg {
	case wmTrayIcon:
		if t == nil {
			break
		}
		switch lParam {
		case wmLButtonUp:
			if t.openFn != nil {
				t.openFn()
			}
		case wmRButtonUp:
			t.showContextMenu()
		}
		return 0

	case wmCommand:
		if t == nil {
			break
		}
		switch int(wParam & 0xFFFF) {
		case menuOpenBrowser:
			if t.openFn != nil {
				t.openFn()
			}
		case menuQuit:
			if t.quitFn != nil {
				t.quitFn()
			}
			t.remove()
			syscall.Exit(0)
		}
		return 0
	}

	ret, _, _ := procDefWindowProcW.Call(hwnd, msg, wParam, lParam)
	return ret
}

// start creates the tray icon on a dedicated thread with its own message loop.
// If the message loop exits unexpectedly (e.g. Explorer restart), it will
// automatically recreate the tray icon after a short delay.
func (t *trayIcon) start() {
	globalTrayInstance = t
	ready := make(chan struct{})
	readyClosed := false

	go func() {
		runtime.LockOSThread()

		for attempt := 0; ; attempt++ {
			if attempt > 0 {
				t.logger.Printf("tray: restarting message loop (attempt %d) after 2s delay", attempt+1)
				time.Sleep(2 * time.Second)
			}

			func() {
				defer func() {
					if r := recover(); r != nil {
						buf := make([]byte, 4096)
						n := runtime.Stack(buf, false)
						t.logger.Printf("FATAL: tray thread panicked: %v\n%s", r, buf[:n])
					}
				}()

				registerTrayClass()

				// Create a hidden window to receive tray messages.
				// Must NOT be HWND_MESSAGE — those can't own popup menus.
				hwnd, _, _ := procCreateWindowExW.Call(
					0,
					uintptr(unsafe.Pointer(trayClassName)),
					0,
					0,          // style: not visible
					0, 0, 0, 0, // x, y, w, h
					0, 0, 0, 0,
				)
				t.hwnd = hwnd
				if hwnd == 0 {
					t.logger.Printf("tray: CreateWindowExW failed, will retry")
					if !readyClosed {
						readyClosed = true
						close(ready)
					}
					return
				}

				// Generate the VibeGrid V icon, fall back to system icon
				t.hIcon = createVibeGridIcon()
				if t.hIcon == 0 {
					t.hIcon, _, _ = procLoadIconW.Call(0, uintptr(32512)) // IDI_APPLICATION
				}

				// Set up NOTIFYICONDATA
				t.nid = notifyIconData{
					HWnd:             hwnd,
					UID:              1,
					UFlags:           nifMessage | nifIcon | nifTip,
					UCallbackMessage: wmTrayIcon,
					HIcon:            t.hIcon,
				}
				t.nid.CbSize = uint32(unsafe.Sizeof(t.nid))

				tip, _ := syscall.UTF16FromString("VibeGrid Window Manager")
				copy(t.nid.SzTip[:], tip)

				ret, _, _ := procShellNotifyIconW.Call(nimAdd, uintptr(unsafe.Pointer(&t.nid)))
				if ret == 0 {
					t.logger.Printf("tray: Shell_NotifyIconW(NIM_ADD) failed, will retry")
				} else {
					t.logger.Printf("tray: icon added successfully (attempt %d)", attempt+1)
				}

				if !readyClosed {
					readyClosed = true
					close(ready)
				}

				// Standard Win32 message loop — dispatches to trayWndProc
				type msgStruct struct {
					hwnd    uintptr
					message uint32
					wParam  uintptr
					lParam  uintptr
					time    uint32
					ptX     int32
					ptY     int32
				}
				var m msgStruct
				for {
					ret, _, err := procGetMessageW.Call(uintptr(unsafe.Pointer(&m)), 0, 0, 0)
					threadHealth.tray.Store(time.Now().UnixMilli())
					if ret == 0 {
						t.logger.Printf("tray: GetMessageW returned WM_QUIT")
						return
					}
					if int32(ret) == -1 {
						t.logger.Printf("tray: GetMessageW error: %v — will restart loop", err)
						return
					}
					procDispatchMessageW.Call(uintptr(unsafe.Pointer(&m)))
				}
			}()

			// Clean up old icon before retrying
			t.remove()
			t.hwnd = 0
		}
	}()

	<-ready
}

func (t *trayIcon) remove() {
	if t.hwnd != 0 {
		procShellNotifyIconW.Call(nimDelete, uintptr(unsafe.Pointer(&t.nid)))
	}
}

func (t *trayIcon) showContextMenu() {
	hMenu, _, _ := procCreatePopupMenu.Call()
	if hMenu == 0 {
		return
	}

	appendMenuItem(hMenu, menuOpenBrowser, "Open VibeGrid")
	appendMenuItem(hMenu, menuQuit, "Quit")

	type pointStruct struct{ X, Y int32 }
	var pt pointStruct
	procGetCursorPos.Call(uintptr(unsafe.Pointer(&pt)))

	// Required: set foreground so menu dismisses on click-away
	procSetForegroundWindow.Call(t.hwnd)

	procTrackPopupMenu.Call(
		hMenu,
		tpmBottomAlign|tpmLeftAlign,
		uintptr(pt.X), uintptr(pt.Y),
		0, t.hwnd, 0,
	)
	// TrackPopupMenu posts WM_COMMAND to t.hwnd, handled by trayWndProc

	procDestroyMenu.Call(hMenu)

	// Per MSDN: post a benign message after TrackPopupMenu so the window
	// processes it and can dismiss properly.
	procPostMessageW.Call(t.hwnd, 0, 0, 0) // WM_NULL
}

func appendMenuItem(hMenu uintptr, id int, text string) {
	type menuItemInfo struct {
		CbSize        uint32
		FMask         uint32
		FType         uint32
		FState        uint32
		WID           uint32
		HSubMenu      uintptr
		HbmpChecked   uintptr
		HbmpUnchecked uintptr
		DwItemData    uintptr
		DwTypeData    *uint16
		Cch           uint32
		HbmpItem      uintptr
	}

	const miimString = 0x00000040
	const miimID = 0x00000002

	textW, _ := syscall.UTF16PtrFromString(text)
	mii := menuItemInfo{
		FMask:      miimString | miimID,
		WID:        uint32(id),
		DwTypeData: textW,
		Cch:        uint32(len(text)),
	}
	mii.CbSize = uint32(unsafe.Sizeof(mii))

	procInsertMenuItemW.Call(hMenu, 0xFFFFFFFF, 1, uintptr(unsafe.Pointer(&mii)))
}

// ---------------------------------------------------------------------------
// Programmatic V icon
// ---------------------------------------------------------------------------

// createVibeGridIcon generates a 16x16 tray icon matching the app branding:
// green gradient background with a white "V".
func createVibeGridIcon() uintptr {
	const n = 16
	pixels := make([][4]byte, n*n) // BGRA, top-down

	// Gradient colors matching .brand-badge: #1c7f57 → #2db07b
	type rgb struct{ r, g, b byte }
	topLeft := rgb{0x1c, 0x7f, 0x57}
	botRight := rgb{0x2d, 0xb0, 0x7b}

	lerp := func(a, b byte, t float64) byte {
		return byte(float64(a)*(1-t) + float64(b)*t)
	}

	// Draw rounded gradient background (radius 3)
	for y := 0; y < n; y++ {
		for x := 0; x < n; x++ {
			if pointInRoundedRect(x, y, n, n, 3) {
				t := (float64(x) + float64(y)) / float64(2*(n-1)) // diagonal gradient
				r := lerp(topLeft.r, botRight.r, t)
				g := lerp(topLeft.g, botRight.g, t)
				b := lerp(topLeft.b, botRight.b, t)
				pixels[y*n+x] = [4]byte{b, g, r, 255}
			}
		}
	}

	// White V — two diagonal strokes meeting at bottom center
	type px struct {
		x, y int
		a    byte
	}
	vPixels := []px{
		// Left stroke (top-left to bottom-center)
		{2, 3, 255}, {3, 3, 120},
		{3, 4, 255}, {2, 4, 120}, {4, 4, 80},
		{3, 5, 200}, {4, 5, 255}, {5, 5, 80},
		{4, 6, 200}, {5, 6, 255}, {6, 6, 80},
		{5, 7, 200}, {6, 7, 255},
		{6, 8, 200}, {7, 8, 255},
		{7, 9, 255}, {6, 9, 80},
		{7, 10, 255}, {8, 10, 200},
		{7, 11, 200}, {8, 11, 255},
		{8, 12, 255},

		// Right stroke (top-right to bottom-center)
		{13, 3, 255}, {12, 3, 120},
		{12, 4, 255}, {13, 4, 120}, {11, 4, 80},
		{12, 5, 200}, {11, 5, 255}, {10, 5, 80},
		{11, 6, 200}, {10, 6, 255}, {9, 6, 80},
		{10, 7, 200}, {9, 7, 255},
		{9, 8, 200}, {8, 8, 255},
		{8, 9, 255}, {9, 9, 80},
		{8, 10, 200},
		{8, 11, 200},
	}

	// Blend white V onto gradient background
	for _, p := range vPixels {
		if p.x >= 0 && p.x < n && p.y >= 0 && p.y < n {
			idx := p.y*n + p.x
			a := float64(p.a) / 255.0
			dst := pixels[idx]
			// White (#f4fff9) over opaque background — simple alpha blend
			pixels[idx] = [4]byte{
				byte(float64(0xf9)*a + float64(dst[0])*(1-a)),
				byte(float64(0xff)*a + float64(dst[1])*(1-a)),
				byte(float64(0xf4)*a + float64(dst[2])*(1-a)),
				255,
			}
		}
	}

	// Premultiply alpha for Win32
	for i := range pixels {
		a := float64(pixels[i][3]) / 255.0
		pixels[i][0] = byte(float64(pixels[i][0]) * a)
		pixels[i][1] = byte(float64(pixels[i][1]) * a)
		pixels[i][2] = byte(float64(pixels[i][2]) * a)
	}

	// Create color bitmap (32bpp top-down DIB)
	bi := bitmapInfo{
		BmiHeader: bitmapInfoHeader{
			BiWidth:       n,
			BiHeight:      -n, // top-down
			BiPlanes:      1,
			BiBitCount:    32,
			BiCompression: biRGB,
		},
	}
	bi.BmiHeader.BiSize = uint32(unsafe.Sizeof(bi.BmiHeader))

	var colorBits unsafe.Pointer
	hColor, _, _ := procCreateDIBSection.Call(
		0, uintptr(unsafe.Pointer(&bi)), dibRGBColors,
		uintptr(unsafe.Pointer(&colorBits)), 0, 0,
	)
	if hColor == 0 {
		return 0
	}
	copy(unsafe.Slice((*[4]byte)(colorBits), n*n), pixels)

	// Mask bitmap (all zeros — alpha channel handles transparency)
	biMask := bi
	var maskBits unsafe.Pointer
	hMask, _, _ := procCreateDIBSection.Call(
		0, uintptr(unsafe.Pointer(&biMask)), dibRGBColors,
		uintptr(unsafe.Pointer(&maskBits)), 0, 0,
	)
	if hMask == 0 {
		procDeleteObject.Call(hColor)
		return 0
	}

	ii := iconInfo{
		FIcon:    1,
		HbmMask:  hMask,
		HbmColor: hColor,
	}
	hIcon, _, _ := procCreateIconIndirect.Call(uintptr(unsafe.Pointer(&ii)))

	procDeleteObject.Call(hColor)
	procDeleteObject.Call(hMask)
	return hIcon
}
