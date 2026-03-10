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
// Win32 overlay windows — transparent, click-through, always-on-top
// ---------------------------------------------------------------------------

var (
	gdi32 = syscall.NewLazyDLL("gdi32.dll")

	procRegisterClassExW    = user32.NewProc("RegisterClassExW")
	procCreateWindowExW     = user32.NewProc("CreateWindowExW")
	procDestroyWindow       = user32.NewProc("DestroyWindow")
	procUpdateLayeredWindow = user32.NewProc("UpdateLayeredWindow")
	procDefWindowProcW      = user32.NewProc("DefWindowProcW")

	procCreateCompatibleDC   = gdi32.NewProc("CreateCompatibleDC")
	procDeleteDC             = gdi32.NewProc("DeleteDC")
	procSelectObject         = gdi32.NewProc("SelectObject")
	procDeleteObject         = gdi32.NewProc("DeleteObject")
	procCreateDIBSection     = gdi32.NewProc("CreateDIBSection")
)

const (
	wsExLayered      = 0x00080000
	wsExTransparent  = 0x00000020
	wsExTopmost      = 0x00000008
	wsExToolWindow   = 0x00000080
	wsExNoActivate   = 0x08000000
	wsPopup          = 0x80000000

	swpNoActivate   = 0x0010
	swpShowWindow   = 0x0040
	swpHideWindow   = 0x0080
	hwndTopmost     = ^uintptr(0) // -1

	ulwAlpha = 0x02

	biRGB     = 0
	dibRGBColors = 0
)

type bitmapInfoHeader struct {
	BiSize          uint32
	BiWidth         int32
	BiHeight        int32
	BiPlanes        uint16
	BiBitCount      uint16
	BiCompression   uint32
	BiSizeImage     uint32
	BiXPelsPerMeter int32
	BiYPelsPerMeter int32
	BiClrUsed       uint32
	BiClrImportant  uint32
}

type bitmapInfo struct {
	BmiHeader bitmapInfoHeader
}

type blendFunction struct {
	BlendOp             byte
	BlendFlags          byte
	SourceConstantAlpha byte
	AlphaFormat         byte
}

type point struct {
	X, Y int32
}

type size struct {
	CX, CY int32
}

// OverlayStyle defines the visual appearance of an overlay
type OverlayStyle struct {
	BorderR, BorderG, BorderB byte
	BorderA                   byte
	FillR, FillG, FillB       byte
	FillA                     byte
}

var (
	// Matches macOS PlacementPreviewOverlayController styles.
	// macOS uses NSColor.systemGreen/systemPurple/systemBlue which are
	// highly saturated. Fill alphas are bumped slightly vs macOS values
	// because Win32 UpdateLayeredWindow premultiplied compositing renders
	// low-alpha fills less visibly than macOS Core Animation layers.
	StylePreview = OverlayStyle{
		BorderR: 40, BorderG: 205, BorderB: 65, BorderA: 153, // systemGreen @ 60%
		FillR: 40, FillG: 205, FillB: 65, FillA: 26, // systemGreen @ ~10%
	}
	StyleMoveEverythingHover = OverlayStyle{
		BorderR: 175, BorderG: 82, BorderB: 222, BorderA: 71, // systemPurple @ 28%
		FillR: 175, FillG: 82, FillB: 222, FillA: 18, // systemPurple @ ~7%
	}
	StyleMoveEverythingSelection = OverlayStyle{
		BorderR: 40, BorderG: 205, BorderB: 65, BorderA: 115, // systemGreen @ 45%
		FillR: 40, FillG: 205, FillB: 65, FillA: 23, // systemGreen @ ~9%
	}
	StyleMoveEverythingHoverSelectionBlend = OverlayStyle{
		BorderR: 32, BorderG: 130, BorderB: 255, BorderA: 97, // systemBlue @ 38%
		FillR: 32, FillG: 130, FillB: 255, FillA: 23, // systemBlue @ ~9%
	}
)

// Overlay represents a single transparent overlay window
type Overlay struct {
	hwnd    uintptr
	visible bool
	x, y    int32
	w, h    int32
	style   OverlayStyle
}

var (
	overlayClassName *uint16
	overlayClassOnce sync.Once
)

func registerOverlayClass() {
	overlayClassOnce.Do(func() {
		name, _ := syscall.UTF16PtrFromString("VibeGridOverlay")
		overlayClassName = name

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
			HIconSm      uintptr
		}

		wndProc := syscall.NewCallback(func(hwnd, msg, wParam, lParam uintptr) uintptr {
			ret, _, _ := procDefWindowProcW.Call(hwnd, msg, wParam, lParam)
			return ret
		})

		cls := wndClassExW{
			LpfnWndProc:   wndProc,
			LpszClassName: overlayClassName,
		}
		cls.CbSize = uint32(unsafe.Sizeof(cls))

		procRegisterClassExW.Call(uintptr(unsafe.Pointer(&cls)))
	})
}

func newOverlay() *Overlay {
	return &Overlay{}
}

// ensureWindow creates the overlay HWND if it doesn't exist.
// Must be called from the overlay thread.
func (o *Overlay) ensureWindow() {
	if o.hwnd != 0 {
		return
	}
	registerOverlayClass()

	exStyle := uintptr(wsExLayered | wsExTransparent | wsExTopmost | wsExToolWindow | wsExNoActivate)
	style := uintptr(wsPopup)

	hwnd, _, _ := procCreateWindowExW.Call(
		exStyle,
		uintptr(unsafe.Pointer(overlayClassName)),
		0, // no title
		style,
		0, 0, 1, 1, // initial pos/size
		0, 0, 0, 0,
	)
	o.hwnd = hwnd
}

// Show positions and shows the overlay with the given style.
// Must be called from the overlay thread.
func (o *Overlay) Show(x, y, w, h int32, style OverlayStyle) {
	if w <= 0 || h <= 0 {
		o.Hide()
		return
	}

	o.ensureWindow()
	if o.hwnd == 0 {
		return
	}

	needsRedraw := o.w != w || o.h != h || o.style != style
	o.x = x
	o.y = y
	o.w = w
	o.h = h
	o.style = style

	if needsRedraw {
		o.paint()
	}

	// Position the window
	procSetWindowPos.Call(
		o.hwnd, hwndTopmost,
		uintptr(x), uintptr(y), uintptr(w), uintptr(h),
		swpNoActivate|swpShowWindow,
	)
	o.visible = true
}

// Hide removes the overlay from screen
func (o *Overlay) Hide() {
	if o.hwnd == 0 || !o.visible {
		return
	}
	procSetWindowPos.Call(
		o.hwnd, 0,
		0, 0, 0, 0,
		swpNoMove|swpNoSize|swpNoActivate|swpHideWindow,
	)
	o.visible = false
}

// Destroy cleans up the overlay window
func (o *Overlay) Destroy() {
	if o.hwnd != 0 {
		procDestroyWindow.Call(o.hwnd)
		o.hwnd = 0
	}
}

// paint renders the rounded rectangle into a DIB and calls UpdateLayeredWindow
func (o *Overlay) paint() {
	if o.hwnd == 0 || o.w <= 0 || o.h <= 0 {
		return
	}

	w := int(o.w)
	h := int(o.h)

	// Create DC and DIB section
	screenDC := uintptr(0) // screen DC
	memDC, _, _ := procCreateCompatibleDC.Call(screenDC)
	if memDC == 0 {
		return
	}
	defer procDeleteDC.Call(memDC)

	bi := bitmapInfo{
		BmiHeader: bitmapInfoHeader{
			BiWidth:       int32(w),
			BiHeight:      -int32(h), // top-down
			BiPlanes:      1,
			BiBitCount:    32,
			BiCompression: biRGB,
		},
	}
	bi.BmiHeader.BiSize = uint32(unsafe.Sizeof(bi.BmiHeader))

	var bits unsafe.Pointer
	hBitmap, _, _ := procCreateDIBSection.Call(
		memDC,
		uintptr(unsafe.Pointer(&bi)),
		dibRGBColors,
		uintptr(unsafe.Pointer(&bits)),
		0, 0,
	)
	if hBitmap == 0 {
		return
	}
	defer procDeleteObject.Call(hBitmap)

	oldBmp, _, _ := procSelectObject.Call(memDC, hBitmap)
	defer procSelectObject.Call(memDC, oldBmp)

	// Draw into pixel buffer
	pixels := unsafe.Slice((*[4]byte)(bits), w*h)
	drawRoundedRect(pixels, w, h, 10, 2, o.style)

	// UpdateLayeredWindow
	ptSrc := point{0, 0}
	ptDst := point{o.x, o.y}
	sz := size{int32(w), int32(h)}
	bf := blendFunction{
		BlendOp:             0, // AC_SRC_OVER
		SourceConstantAlpha: 255,
		AlphaFormat:         1, // AC_SRC_ALPHA
	}

	procUpdateLayeredWindow.Call(
		o.hwnd,
		screenDC,
		uintptr(unsafe.Pointer(&ptDst)),
		uintptr(unsafe.Pointer(&sz)),
		memDC,
		uintptr(unsafe.Pointer(&ptSrc)),
		0,
		uintptr(unsafe.Pointer(&bf)),
		ulwAlpha,
	)
}

// drawRoundedRect renders a rounded rectangle with border and fill into a BGRA pixel buffer
func drawRoundedRect(pixels [][4]byte, w, h, radius, borderWidth int, style OverlayStyle) {
	if radius > w/2 {
		radius = w / 2
	}
	if radius > h/2 {
		radius = h / 2
	}

	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			if !pointInRoundedRect(x, y, w, h, radius) {
				pixels[y*w+x] = [4]byte{0, 0, 0, 0}
				continue
			}

			// Border test: point is in border if it's NOT inside the shrunk inner rect
			innerInside := pointInRoundedRect(
				x-borderWidth, y-borderWidth,
				w-2*borderWidth, h-2*borderWidth,
				max(0, radius-borderWidth),
			)

			var r, g, b, a byte
			if !innerInside {
				r, g, b, a = style.BorderR, style.BorderG, style.BorderB, style.BorderA
			} else {
				r, g, b, a = style.FillR, style.FillG, style.FillB, style.FillA
			}

			// Premultiply alpha (required by UpdateLayeredWindow with AC_SRC_ALPHA)
			fa := float64(a) / 255.0
			pixels[y*w+x] = [4]byte{
				byte(float64(b) * fa), // B
				byte(float64(g) * fa), // G
				byte(float64(r) * fa), // R
				a,                     // A
			}
		}
	}
}

// pointInRoundedRect tests whether (px,py) lies inside a w×h rounded rectangle.
func pointInRoundedRect(px, py, w, h, radius int) bool {
	if px < 0 || py < 0 || px >= w || py >= h {
		return false
	}
	if radius <= 0 {
		return true
	}
	r2 := radius * radius
	// Top-left corner
	if px < radius && py < radius {
		dx := radius - px - 1
		dy := radius - py - 1
		return dx*dx+dy*dy <= r2
	}
	// Top-right corner
	if px >= w-radius && py < radius {
		dx := px - (w - radius)
		dy := radius - py - 1
		return dx*dx+dy*dy <= r2
	}
	// Bottom-left corner
	if px < radius && py >= h-radius {
		dx := radius - px - 1
		dy := py - (h - radius)
		return dx*dx+dy*dy <= r2
	}
	// Bottom-right corner
	if px >= w-radius && py >= h-radius {
		dx := px - (w - radius)
		dy := py - (h - radius)
		return dx*dx+dy*dy <= r2
	}
	return true
}

// ---------------------------------------------------------------------------
// OverlayManager — manages overlay windows on a dedicated thread
// ---------------------------------------------------------------------------

type overlayCmd struct {
	fn   func()
	done chan struct{}
}

type OverlayManager struct {
	cmdChan       chan overlayCmd
	hoverOverlay  *Overlay
	previewOverlay *Overlay
}

func newOverlayManager() *OverlayManager {
	return &OverlayManager{
		cmdChan:       make(chan overlayCmd, 32),
		hoverOverlay:  newOverlay(),
		previewOverlay: newOverlay(),
	}
}

var (
	procPeekMessageW    = user32.NewProc("PeekMessageW")
	procTranslateMessage = user32.NewProc("TranslateMessage")
	procDispatchMessageW = user32.NewProc("DispatchMessageW")
)

// start runs the overlay thread — must be called once.
// It processes both overlay commands and Win32 messages for overlay windows.
func (om *OverlayManager) start(logger *log.Logger) {
	go func() {
		defer func() {
			if r := recover(); r != nil {
				buf := make([]byte, 4096)
				n := runtime.Stack(buf, false)
				logger.Printf("FATAL: overlay thread panicked: %v\n%s", r, buf[:n])
			}
			logger.Printf("FATAL: overlay thread exited unexpectedly")
		}()
		runtime.LockOSThread()
		logger.Printf("overlay thread started")

		type msgStruct struct {
			hwnd    uintptr
			message uint32
			wParam  uintptr
			lParam  uintptr
			time    uint32
			ptX     int32
			ptY     int32
		}

		ticker := time.NewTicker(16 * time.Millisecond) // ~60fps
		defer ticker.Stop()

		for {
			threadHealth.overlay.Store(time.Now().UnixMilli())

			// Drain any pending Win32 messages (PM_REMOVE = 1)
			var msg msgStruct
			for {
				ret, _, _ := procPeekMessageW.Call(
					uintptr(unsafe.Pointer(&msg)), 0, 0, 0, 1,
				)
				if ret == 0 {
					break
				}
				procTranslateMessage.Call(uintptr(unsafe.Pointer(&msg)))
				procDispatchMessageW.Call(uintptr(unsafe.Pointer(&msg)))
			}

			// Process overlay commands (non-blocking check first, then short block)
			select {
			case cmd, ok := <-om.cmdChan:
				if !ok {
					return
				}
				cmd.fn()
				if cmd.done != nil {
					close(cmd.done)
				}
			default:
				select {
				case cmd, ok := <-om.cmdChan:
					if !ok {
						return
					}
					cmd.fn()
					if cmd.done != nil {
						close(cmd.done)
					}
				case <-ticker.C:
				}
			}
		}
	}()
}

func (om *OverlayManager) do(fn func()) {
	done := make(chan struct{})
	om.cmdChan <- overlayCmd{fn: fn, done: done}
	<-done
}

func (om *OverlayManager) doAsync(fn func()) {
	select {
	case om.cmdChan <- overlayCmd{fn: fn}:
	default:
		// Channel full — drop this command to avoid blocking the caller.
		// The next hover/preview update will correct the state.
	}
}

// ShowHoverOverlay highlights a window by its HWND
func (om *OverlayManager) ShowHoverOverlay(hwnd uintptr, style OverlayStyle) {
	om.doAsync(func() {
		if hwnd == 0 {
			om.hoverOverlay.Hide()
			return
		}
		var r rect
		procGetWindowRect.Call(hwnd, uintptr(unsafe.Pointer(&r)))
		if r.Right <= r.Left || r.Bottom <= r.Top {
			om.hoverOverlay.Hide()
			return
		}
		om.hoverOverlay.Show(r.Left, r.Top, r.Right-r.Left, r.Bottom-r.Top, style)
	})
}

// HideHoverOverlay hides the hover overlay
func (om *OverlayManager) HideHoverOverlay() {
	om.doAsync(func() {
		om.hoverOverlay.Hide()
	})
}

// ShowPreviewOverlay shows a placement preview at an absolute screen position
func (om *OverlayManager) ShowPreviewOverlay(x, y, w, h int32, style OverlayStyle) {
	om.doAsync(func() {
		om.previewOverlay.Show(x, y, w, h, style)
	})
}

// HidePreviewOverlay hides the preview overlay
func (om *OverlayManager) HidePreviewOverlay() {
	om.doAsync(func() {
		om.previewOverlay.Hide()
	})
}

// HideAll hides all overlays
func (om *OverlayManager) HideAll() {
	om.doAsync(func() {
		om.hoverOverlay.Hide()
		om.previewOverlay.Hide()
	})
}
