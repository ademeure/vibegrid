//go:build windows

package main

import (
	"encoding/json"
	"fmt"
	"strings"

	"gopkg.in/yaml.v3"
)

// ---------------------------------------------------------------------------
// YAML ↔ JSON config conversion
// ---------------------------------------------------------------------------

// configToYAML converts the internal JSON config (map[string]any) to YAML text
// matching the macOS VibeGrid YAML format.
func configToYAML(cfg map[string]any) (string, error) {
	// Build an ordered structure matching the macOS YAML output
	ordered := yaml.Node{Kind: yaml.MappingNode}

	// version
	addMapping(&ordered, "version", scalarNode(cfg["version"]))

	// settings
	if settings, ok := cfg["settings"].(map[string]any); ok {
		settingsNode := settingsToYAML(settings)
		addMapping(&ordered, "settings", settingsNode)
	}

	// shortcuts
	if shortcuts, ok := cfg["shortcuts"].([]any); ok {
		shortcutsNode := shortcutsToYAML(shortcuts)
		addMapping(&ordered, "shortcuts", shortcutsNode)
	}

	data, err := yaml.Marshal(&ordered)
	if err != nil {
		return "", err
	}
	return string(data), nil
}

func settingsToYAML(s map[string]any) *yaml.Node {
	node := &yaml.Node{Kind: yaml.MappingNode}
	// Output settings in a stable order matching macOS
	keys := []string{
		"defaultGridColumns", "defaultGridRows", "gap",
		"defaultCycleDisplaysOnWrap", "animationDuration", "controlCenterScale",
		"largerFonts", "themeMode", "moveEverythingMoveOnSelection",
		"moveEverythingCenterWidthPercent", "moveEverythingCenterHeightPercent",
		"moveEverythingOverlayMode", "moveEverythingOverlayDuration",
		"moveEverythingStartAlwaysOnTop", "moveEverythingStartMoveToBottom",
		"moveEverythingAdvancedControlCenterHover",
		"moveEverythingStickyHoverStealFocus",
		"moveEverythingCloseHideHotkeysOutsideMode",
		"moveEverythingExcludeControlCenter",
		"moveEverythingMiniRetileWidthPercent",
		"moveEverythingBackgroundRefreshInterval",
		"moveEverythingITermRecentActivityTimeout",
		"moveEverythingITermRecentActivityActiveText",
		"moveEverythingITermRecentActivityIdleText",
		"moveEverythingITermRecentActivityBadgeEnabled",
		"moveEverythingITermRecentActivityColorize",
		"moveEverythingActiveWindowHighlightColorize",
		"moveEverythingActiveWindowHighlightColor",
		"moveEverythingITermRecentActivityActiveColor",
		"moveEverythingITermRecentActivityIdleColor",
		"moveEverythingCloseWindowHotkey", "moveEverythingHideWindowHotkey",
	}
	for _, k := range keys {
		v, ok := s[k]
		if !ok {
			continue
		}
		// Encode hotkey objects as "mod1+mod2+key" strings
		if hk, ok := v.(map[string]any); ok {
			addMapping(node, k, scalarNode(encodeHotkeyString(hk)))
			continue
		}
		addMapping(node, k, scalarNode(v))
	}
	return node
}

func shortcutsToYAML(shortcuts []any) *yaml.Node {
	seq := &yaml.Node{Kind: yaml.SequenceNode}
	for _, s := range shortcuts {
		sc, ok := s.(map[string]any)
		if !ok {
			continue
		}
		entry := &yaml.Node{Kind: yaml.MappingNode}

		addMapping(entry, "id", scalarNode(sc["id"]))
		addMapping(entry, "name", scalarNode(sc["name"]))
		addMapping(entry, "enabled", scalarNode(sc["enabled"]))
		addMapping(entry, "cycleDisplaysOnWrap", scalarNode(sc["cycleDisplaysOnWrap"]))
		addMapping(entry, "controlCenterOnly", scalarNode(sc["controlCenterOnly"]))

		// hotkey
		if hk, ok := sc["hotkey"].(map[string]any); ok {
			hkNode := &yaml.Node{Kind: yaml.MappingNode}
			addMapping(hkNode, "key", scalarNode(hk["key"]))
			if mods, ok := hk["modifiers"].([]any); ok {
				modSeq := &yaml.Node{Kind: yaml.SequenceNode}
				for _, m := range mods {
					modSeq.Content = append(modSeq.Content, scalarNode(m))
				}
				addMapping(hkNode, "modifiers", modSeq)
			}
			addMapping(entry, "hotkey", hkNode)
		}

		// placements
		if placements, ok := sc["placements"].([]any); ok {
			plSeq := &yaml.Node{Kind: yaml.SequenceNode}
			for _, p := range placements {
				pl, ok := p.(map[string]any)
				if !ok {
					continue
				}
				plNode := &yaml.Node{Kind: yaml.MappingNode}
				addMapping(plNode, "id", scalarNode(pl["id"]))
				addMapping(plNode, "title", scalarNode(pl["title"]))
				addMapping(plNode, "mode", scalarNode(pl["mode"]))
				addMapping(plNode, "display", scalarNode(pl["display"]))

				mode, _ := pl["mode"].(string)
				if mode == "grid" {
					if g, ok := pl["grid"].(map[string]any); ok {
						gNode := &yaml.Node{Kind: yaml.MappingNode}
						for _, gk := range []string{"columns", "rows", "x", "y", "width", "height"} {
							addMapping(gNode, gk, scalarNode(g[gk]))
						}
						addMapping(plNode, "grid", gNode)
					}
				} else if mode == "freeform" {
					if r, ok := pl["rect"].(map[string]any); ok {
						rNode := &yaml.Node{Kind: yaml.MappingNode}
						for _, rk := range []string{"x", "y", "width", "height"} {
							addMapping(rNode, rk, scalarNode(r[rk]))
						}
						addMapping(plNode, "rect", rNode)
					}
				}
				plSeq.Content = append(plSeq.Content, plNode)
			}
			addMapping(entry, "placements", plSeq)
		}

		seq.Content = append(seq.Content, entry)
	}
	return seq
}

func addMapping(node *yaml.Node, key string, value *yaml.Node) {
	node.Content = append(node.Content,
		&yaml.Node{Kind: yaml.ScalarNode, Value: key},
		value,
	)
}

func scalarNode(v any) *yaml.Node {
	switch val := v.(type) {
	case nil:
		return &yaml.Node{Kind: yaml.ScalarNode, Value: "", Tag: "!!null"}
	case string:
		return &yaml.Node{Kind: yaml.ScalarNode, Value: val}
	case bool:
		s := "false"
		if val {
			s = "true"
		}
		return &yaml.Node{Kind: yaml.ScalarNode, Value: s}
	case float64:
		if val == float64(int64(val)) {
			return &yaml.Node{Kind: yaml.ScalarNode, Value: fmt.Sprintf("%d", int64(val))}
		}
		return &yaml.Node{Kind: yaml.ScalarNode, Value: fmt.Sprintf("%g", val)}
	case json.Number:
		return &yaml.Node{Kind: yaml.ScalarNode, Value: val.String()}
	case int:
		return &yaml.Node{Kind: yaml.ScalarNode, Value: fmt.Sprintf("%d", val)}
	default:
		return &yaml.Node{Kind: yaml.ScalarNode, Value: fmt.Sprintf("%v", val)}
	}
}

func encodeHotkeyString(hk map[string]any) string {
	key, _ := hk["key"].(string)
	key = strings.TrimSpace(strings.ToLower(key))
	if key == "" {
		return ""
	}
	var mods []string
	if modList, ok := hk["modifiers"].([]any); ok {
		for _, m := range modList {
			if ms, ok := m.(string); ok {
				mods = append(mods, strings.ToLower(ms))
			}
		}
	}
	parts := append(mods, key)
	return strings.Join(parts, "+")
}

// yamlToConfig converts YAML text to the internal JSON config (map[string]any).
func yamlToConfig(text string) (map[string]any, error) {
	var raw map[string]any
	if err := yaml.Unmarshal([]byte(text), &raw); err != nil {
		return nil, fmt.Errorf("YAML parse error: %w", err)
	}

	// yaml.v3 uses map[string]any with proper Go types, but we need to
	// normalize types to match what encoding/json would produce (float64 for numbers).
	result := normalizeYAMLTypes(raw).(map[string]any)

	// Decode inline hotkey strings in settings (e.g. "ctrl+alt+f4" -> {key, modifiers})
	if settings, ok := result["settings"].(map[string]any); ok {
		hotkeyKeys := []string{
			"moveEverythingCloseWindowHotkey",
			"moveEverythingHideWindowHotkey",
		}
		for _, k := range hotkeyKeys {
			if s, ok := settings[k].(string); ok {
				settings[k] = decodeHotkeyString(s)
			}
		}
	}

	return result, nil
}

// normalizeYAMLTypes recursively converts yaml.v3 types to JSON-compatible types.
func normalizeYAMLTypes(v any) any {
	switch val := v.(type) {
	case map[string]any:
		out := make(map[string]any, len(val))
		for k, v2 := range val {
			out[k] = normalizeYAMLTypes(v2)
		}
		return out
	case []any:
		out := make([]any, len(val))
		for i, v2 := range val {
			out[i] = normalizeYAMLTypes(v2)
		}
		return out
	case int:
		return float64(val)
	case int64:
		return float64(val)
	default:
		return val
	}
}

func decodeHotkeyString(s string) any {
	s = strings.TrimSpace(strings.ToLower(s))
	if s == "" || s == "none" || s == "null" {
		return nil
	}
	parts := strings.Split(s, "+")
	if len(parts) == 0 {
		return nil
	}
	key := parts[len(parts)-1]
	mods := parts[:len(parts)-1]
	modsAny := make([]any, len(mods))
	for i, m := range mods {
		modsAny[i] = m
	}
	return map[string]any{
		"key":       key,
		"modifiers": modsAny,
	}
}
