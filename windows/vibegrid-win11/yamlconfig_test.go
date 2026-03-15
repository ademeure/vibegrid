//go:build windows

package main

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

// fixtureDir returns the path to the shared test fixtures.
// The fixtures live at ../../Tests/VibeGridTests/Fixtures/ relative to this file.
func fixtureDir(t *testing.T) string {
	t.Helper()
	_, thisFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("unable to determine test file path")
	}
	dir := filepath.Join(filepath.Dir(thisFile), "..", "..", "Tests", "VibeGridTests", "Fixtures")
	if _, err := os.Stat(dir); os.IsNotExist(err) {
		t.Skipf("fixture directory not found: %s", dir)
	}
	return dir
}

func loadFixture(t *testing.T, name string) string {
	t.Helper()
	path := filepath.Join(fixtureDir(t), name)
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("failed to read fixture %s: %v", name, err)
	}
	return string(data)
}

// assertParityConfig verifies the parsed config matches the expected values
// from the shared parity fixtures. Both parity_2space.yaml and parity_4space.yaml
// encode the same config, so these assertions apply to both.
func assertParityConfig(t *testing.T, cfg map[string]any) {
	t.Helper()

	settings, ok := cfg["settings"].(map[string]any)
	if !ok {
		t.Fatal("missing settings")
	}

	assertFloat(t, settings, "defaultGridColumns", 12)
	assertFloat(t, settings, "defaultGridRows", 8)
	assertFloat(t, settings, "gap", 4)
	assertBool(t, settings, "defaultCycleDisplaysOnWrap", true)
	assertFloat(t, settings, "animationDuration", 0.5)
	assertFloat(t, settings, "controlCenterScale", 1.25)
	assertBool(t, settings, "largerFonts", true)
	assertString(t, settings, "themeMode", "dark")
	assertString(t, settings, "moveEverythingMoveOnSelection", "always")
	assertFloat(t, settings, "moveEverythingCenterWidthPercent", 50)
	assertFloat(t, settings, "moveEverythingCenterHeightPercent", 80)
	assertString(t, settings, "moveEverythingOverlayMode", "timed")
	assertFloat(t, settings, "moveEverythingOverlayDuration", 3)
	assertBool(t, settings, "moveEverythingStartAlwaysOnTop", true)
	assertBool(t, settings, "moveEverythingStartMoveToBottom", true)
	assertBool(t, settings, "moveEverythingAdvancedControlCenterHover", false)
	assertBool(t, settings, "moveEverythingStickyHoverStealFocus", true)
	assertBool(t, settings, "moveEverythingCloseHideHotkeysOutsideMode", true)
	assertFloat(t, settings, "moveEverythingITermRecentActivityTimeout", 7)
	assertString(t, settings, "moveEverythingITermRecentActivityActiveText", "[LIVE]")
	assertString(t, settings, "moveEverythingITermRecentActivityIdleText", "[idle]")
	assertBool(t, settings, "moveEverythingITermRecentActivityBadgeEnabled", true)
	assertBool(t, settings, "moveEverythingITermRecentActivityColorize", true)
	assertString(t, settings, "moveEverythingITermRecentActivityActiveColor", "#228844")
	assertString(t, settings, "moveEverythingITermRecentActivityIdleColor", "#AA3333")

	// Hotkey settings are decoded from strings into {key, modifiers} maps
	assertHotkey(t, settings, "moveEverythingCloseWindowHotkey", "w", []string{"cmd", "shift"})
	assertHotkey(t, settings, "moveEverythingHideWindowHotkey", "h", []string{"alt", "cmd"})

	shortcuts, ok := cfg["shortcuts"].([]any)
	if !ok {
		t.Fatal("missing shortcuts")
	}
	if len(shortcuts) != 2 {
		t.Fatalf("expected 2 shortcuts, got %d", len(shortcuts))
	}

	left := shortcuts[0].(map[string]any)
	assertString(t, left, "name", "Left Half")
	assertBool(t, left, "enabled", true)
	assertBool(t, left, "cycleDisplaysOnWrap", false)
	assertBool(t, left, "controlCenterOnly", false)

	leftHK := left["hotkey"].(map[string]any)
	assertString(t, leftHK, "key", "left")

	leftPlacements := left["placements"].([]any)
	if len(leftPlacements) != 1 {
		t.Fatalf("expected 1 placement for left shortcut, got %d", len(leftPlacements))
	}
	lp := leftPlacements[0].(map[string]any)
	assertString(t, lp, "mode", "grid")
	assertString(t, lp, "display", "active")
	grid := lp["grid"].(map[string]any)
	assertFloat(t, grid, "columns", 12)
	assertFloat(t, grid, "rows", 8)
	assertFloat(t, grid, "width", 6)
	assertFloat(t, grid, "height", 8)

	center := shortcuts[1].(map[string]any)
	assertString(t, center, "name", "Center Float")
	assertBool(t, center, "cycleDisplaysOnWrap", true)
	assertBool(t, center, "controlCenterOnly", true)

	centerPlacements := center["placements"].([]any)
	if len(centerPlacements) != 2 {
		t.Fatalf("expected 2 placements for center shortcut, got %d", len(centerPlacements))
	}

	big := centerPlacements[0].(map[string]any)
	assertString(t, big, "title", "Big")
	assertString(t, big, "mode", "freeform")
	assertString(t, big, "display", "main")
	bigRect := big["rect"].(map[string]any)
	assertFloat(t, bigRect, "x", 0.1)
	assertFloat(t, bigRect, "y", 0.15)
	assertFloat(t, bigRect, "width", 0.8)
	assertFloat(t, bigRect, "height", 0.7)

	small := centerPlacements[1].(map[string]any)
	assertString(t, small, "title", "Small")
	assertString(t, small, "mode", "freeform")
	smallRect := small["rect"].(map[string]any)
	assertFloat(t, smallRect, "x", 0.25)
	assertFloat(t, smallRect, "width", 0.5)
}

func TestYAMLParityTwoSpace(t *testing.T) {
	text := loadFixture(t, "parity_2space.yaml")
	cfg, err := yamlToConfig(text)
	if err != nil {
		t.Fatalf("failed to parse 2-space fixture: %v", err)
	}
	assertParityConfig(t, cfg)
}

func TestYAMLParityFourSpace(t *testing.T) {
	text := loadFixture(t, "parity_4space.yaml")
	cfg, err := yamlToConfig(text)
	if err != nil {
		t.Fatalf("failed to parse 4-space fixture: %v", err)
	}
	assertParityConfig(t, cfg)
}

func TestYAMLRoundTrip(t *testing.T) {
	text := loadFixture(t, "parity_2space.yaml")
	cfg, err := yamlToConfig(text)
	if err != nil {
		t.Fatalf("failed to parse: %v", err)
	}

	encoded, err := configToYAML(cfg)
	if err != nil {
		t.Fatalf("failed to encode: %v", err)
	}

	reparsed, err := yamlToConfig(encoded)
	if err != nil {
		t.Fatalf("failed to reparse: %v", err)
	}

	settings1 := cfg["settings"].(map[string]any)
	settings2 := reparsed["settings"].(map[string]any)
	assertFloat(t, settings1, "gap", settings2["gap"].(float64))
	assertString(t, settings1, "themeMode", settings2["themeMode"].(string))

	shortcuts1 := cfg["shortcuts"].([]any)
	shortcuts2 := reparsed["shortcuts"].([]any)
	if len(shortcuts1) != len(shortcuts2) {
		t.Fatalf("shortcut count mismatch: %d vs %d", len(shortcuts1), len(shortcuts2))
	}
}

func TestDecodeHotkeyString(t *testing.T) {
	tests := []struct {
		input    string
		wantKey  string
		wantMods []string
	}{
		{"cmd+shift+w", "w", []string{"cmd", "shift"}},
		{"ctrl+alt+t", "t", []string{"ctrl", "alt"}},
		{"alt+cmd+h", "h", []string{"alt", "cmd"}},
		{"f4", "f4", nil},
	}

	for _, tt := range tests {
		result := decodeHotkeyString(tt.input)
		if result == nil {
			t.Errorf("decodeHotkeyString(%q) returned nil", tt.input)
			continue
		}
		hk := result.(map[string]any)
		key := hk["key"].(string)
		if key != tt.wantKey {
			t.Errorf("decodeHotkeyString(%q) key = %q, want %q", tt.input, key, tt.wantKey)
		}
	}
}

func TestDecodeHotkeyStringNil(t *testing.T) {
	for _, input := range []string{"", "none", "null"} {
		result := decodeHotkeyString(input)
		if result != nil {
			t.Errorf("decodeHotkeyString(%q) = %v, want nil", input, result)
		}
	}
}

func TestEncodeHotkeyString(t *testing.T) {
	hk := map[string]any{
		"key":       "w",
		"modifiers": []any{"cmd", "shift"},
	}
	result := encodeHotkeyString(hk)
	if result != "cmd+shift+w" {
		t.Errorf("encodeHotkeyString = %q, want %q", result, "cmd+shift+w")
	}
}

func TestEncodeHotkeyStringEmpty(t *testing.T) {
	hk := map[string]any{
		"key":       "",
		"modifiers": []any{},
	}
	result := encodeHotkeyString(hk)
	if result != "" {
		t.Errorf("encodeHotkeyString(empty) = %q, want empty", result)
	}
}

// Helpers

func assertFloat(t *testing.T, m map[string]any, key string, want float64) {
	t.Helper()
	v, ok := m[key]
	if !ok {
		t.Errorf("missing key %q", key)
		return
	}
	got, ok := v.(float64)
	if !ok {
		t.Errorf("key %q: expected float64, got %T", key, v)
		return
	}
	if got != want {
		t.Errorf("key %q: got %v, want %v", key, got, want)
	}
}

func assertString(t *testing.T, m map[string]any, key, want string) {
	t.Helper()
	v, ok := m[key]
	if !ok {
		t.Errorf("missing key %q", key)
		return
	}
	got, ok := v.(string)
	if !ok {
		t.Errorf("key %q: expected string, got %T", key, v)
		return
	}
	if got != want {
		t.Errorf("key %q: got %q, want %q", key, got, want)
	}
}

func assertBool(t *testing.T, m map[string]any, key string, want bool) {
	t.Helper()
	v, ok := m[key]
	if !ok {
		t.Errorf("missing key %q", key)
		return
	}
	got, ok := v.(bool)
	if !ok {
		t.Errorf("key %q: expected bool, got %T", key, v)
		return
	}
	if got != want {
		t.Errorf("key %q: got %v, want %v", key, got, want)
	}
}

func assertHotkey(t *testing.T, m map[string]any, key, wantKey string, wantMods []string) {
	t.Helper()
	v, ok := m[key]
	if !ok {
		t.Errorf("missing hotkey %q", key)
		return
	}
	hk, ok := v.(map[string]any)
	if !ok {
		t.Errorf("hotkey %q: expected map, got %T", key, v)
		return
	}
	gotKey, _ := hk["key"].(string)
	if gotKey != wantKey {
		t.Errorf("hotkey %q key: got %q, want %q", key, gotKey, wantKey)
	}
	mods, _ := hk["modifiers"].([]any)
	if len(mods) != len(wantMods) {
		t.Errorf("hotkey %q modifiers: got %d, want %d", key, len(mods), len(wantMods))
		return
	}
	for i, wm := range wantMods {
		if got, _ := mods[i].(string); got != wm {
			t.Errorf("hotkey %q modifier[%d]: got %q, want %q", key, i, got, wm)
		}
	}
}
