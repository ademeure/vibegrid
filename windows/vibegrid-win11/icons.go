//go:build windows

package main

import (
	"bytes"
	"encoding/base64"
	"image"
	"image/png"
	"runtime"
	"sync"
	"syscall"
	"unsafe"
)

// ---------------------------------------------------------------------------
// App icon extraction and caching
// ---------------------------------------------------------------------------

var (
	procExtractIconExW             = shell32.NewProc("ExtractIconExW")
	procGetIconInfo                = user32.NewProc("GetIconInfo")
	procDestroyIcon                = user32.NewProc("DestroyIcon")
	procDrawIconEx                 = user32.NewProc("DrawIconEx")
	procGetDC                      = user32.NewProc("GetDC")
	procReleaseDC                  = user32.NewProc("ReleaseDC")
	procQueryFullProcessImageNameW = kernel32.NewProc("QueryFullProcessImageNameW")
)

type iconCache struct {
	mu    sync.RWMutex
	icons map[string]string // processName -> data:image/png;base64,... (empty string = failed)
	paths map[string]string // processName -> exe path
}

func newIconCache() *iconCache {
	return &iconCache{
		icons: make(map[string]string),
		paths: make(map[string]string),
	}
}

// registerPath records the exe path for a process name.
// Called during window enumeration so icon extraction can find the exe later.
func (ic *iconCache) registerPath(processName, exePath string) {
	if processName == "" || exePath == "" {
		return
	}
	ic.mu.Lock()
	ic.paths[processName] = exePath
	ic.mu.Unlock()
}

// getDataURL returns the cached data URL for a process icon.
// Returns "" if not yet extracted. Call ensureExtracted to trigger extraction.
func (ic *iconCache) getDataURL(processName string) string {
	ic.mu.RLock()
	url, ok := ic.icons[processName]
	ic.mu.RUnlock()
	if ok {
		return url
	}
	return ""
}

// ensureExtracted triggers background icon extraction for a process name
// if not already cached or in progress. Non-blocking.
func (ic *iconCache) ensureExtracted(processName string) {
	ic.mu.RLock()
	_, cached := ic.icons[processName]
	ic.mu.RUnlock()
	if cached {
		return
	}

	ic.mu.Lock()
	// Double-check after write lock
	if _, cached := ic.icons[processName]; cached {
		ic.mu.Unlock()
		return
	}
	exePath := ic.paths[processName]
	if exePath == "" {
		ic.mu.Unlock()
		return
	}
	// Mark as in-progress with empty string to prevent duplicate extractions
	ic.icons[processName] = ""
	ic.mu.Unlock()

	go func() {
		dataURL := extractIconDataURL(exePath)
		ic.mu.Lock()
		ic.icons[processName] = dataURL
		ic.mu.Unlock()
	}()
}

// getProcessPath returns the full exe path for a process given its PID.
func getProcessPath(pid uint32) string {
	handle, _, _ := procOpenProcess.Call(processQueryInfo, 0, uintptr(pid))
	if handle == 0 {
		return ""
	}
	defer procCloseHandle.Call(handle)

	buf := make([]uint16, 260)
	size := uint32(260)
	ret, _, _ := procQueryFullProcessImageNameW.Call(
		handle, 0,
		uintptr(unsafe.Pointer(&buf[0])),
		uintptr(unsafe.Pointer(&size)),
	)
	if ret == 0 {
		return ""
	}
	return syscall.UTF16ToString(buf[:size])
}

// extractIconDataURL extracts the app icon from an exe and returns a
// data:image/png;base64,... URL. Returns "" on failure.
func extractIconDataURL(exePath string) string {
	pngData := extractIconPNG(exePath)
	if pngData == nil {
		return ""
	}
	return "data:image/png;base64," + base64.StdEncoding.EncodeToString(pngData)
}

// extractIconPNG extracts a 32x32 icon from an exe and returns PNG bytes.
func extractIconPNG(exePath string) []byte {
	// Lock OS thread for GDI calls
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	pathW, err := syscall.UTF16PtrFromString(exePath)
	if err != nil {
		return nil
	}

	var hIconLarge, hIconSmall uintptr
	ret, _, _ := procExtractIconExW.Call(
		uintptr(unsafe.Pointer(pathW)),
		0,
		uintptr(unsafe.Pointer(&hIconLarge)),
		uintptr(unsafe.Pointer(&hIconSmall)),
		1,
	)
	if ret == 0 {
		return nil
	}
	defer func() {
		if hIconLarge != 0 {
			procDestroyIcon.Call(hIconLarge)
		}
		if hIconSmall != 0 {
			procDestroyIcon.Call(hIconSmall)
		}
	}()

	// Prefer large (32x32), fall back to small (16x16)
	hIcon := hIconLarge
	if hIcon == 0 {
		hIcon = hIconSmall
	}
	if hIcon == 0 {
		return nil
	}

	return hiconToPNG(hIcon, 32)
}

// hiconToPNG renders an HICON into a PNG byte slice.
func hiconToPNG(hIcon uintptr, size int) []byte {
	hDC, _, _ := procGetDC.Call(0)
	if hDC == 0 {
		return nil
	}
	defer procReleaseDC.Call(0, hDC)

	memDC, _, _ := procCreateCompatibleDC.Call(hDC)
	if memDC == 0 {
		return nil
	}
	defer procDeleteDC.Call(memDC)

	bi := bitmapInfo{
		BmiHeader: bitmapInfoHeader{
			BiWidth:       int32(size),
			BiHeight:      -int32(size), // top-down
			BiPlanes:      1,
			BiBitCount:    32,
			BiCompression: biRGB,
		},
	}
	bi.BmiHeader.BiSize = uint32(unsafe.Sizeof(bi.BmiHeader))

	var bits unsafe.Pointer
	hBitmap, _, _ := procCreateDIBSection.Call(
		memDC, uintptr(unsafe.Pointer(&bi)), dibRGBColors,
		uintptr(unsafe.Pointer(&bits)), 0, 0,
	)
	if hBitmap == 0 {
		return nil
	}
	defer procDeleteObject.Call(hBitmap)

	oldBmp, _, _ := procSelectObject.Call(memDC, hBitmap)
	defer procSelectObject.Call(memDC, oldBmp)

	// Draw icon onto the DIB (DI_NORMAL = 3)
	procDrawIconEx.Call(memDC, 0, 0, hIcon, uintptr(size), uintptr(size), 0, 0, 3)

	// Read BGRA pixels and convert to RGBA for PNG encoding
	pixels := unsafe.Slice((*[4]byte)(bits), size*size)
	img := image.NewNRGBA(image.Rect(0, 0, size, size))
	for i := 0; i < size*size; i++ {
		px := pixels[i]
		// BGRA (premultiplied) -> NRGBA
		a := px[3]
		if a == 0 {
			continue // leave as transparent zero
		}
		if a == 255 {
			img.Pix[i*4+0] = px[2] // R
			img.Pix[i*4+1] = px[1] // G
			img.Pix[i*4+2] = px[0] // B
			img.Pix[i*4+3] = 255
		} else {
			// Un-premultiply
			fa := float64(a)
			img.Pix[i*4+0] = byte(float64(px[2]) * 255.0 / fa)
			img.Pix[i*4+1] = byte(float64(px[1]) * 255.0 / fa)
			img.Pix[i*4+2] = byte(float64(px[0]) * 255.0 / fa)
			img.Pix[i*4+3] = a
		}
	}

	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		return nil
	}
	return buf.Bytes()
}
