// ---------------------------------------------------------------------------
// Pub/sub: lightweight topic-based event system for targeted re-renders.
//
// Topics:
//   'config'         - shortcut/placement data changed (add/remove/edit/reorder)
//   'selection'      - selected or hovered shortcut/placement changed
//   'moveEverything' - move-everything workspace, windows, or modal state changed
//   'theme'          - theme mode changed
//   'hotkeys'        - hotkey issues or recording state changed
//   'settings'       - settings changed (grid defaults, gap, scale, launch-at-login, etc.)
//   'undoRedo'       - undo/redo stack changed
//   'runtime'        - runtime banner state changed
//
// Each render function subscribes to the topics it depends on.
// renderAll() publishes every topic (de-duped) as a fallback for bulk updates.
// ---------------------------------------------------------------------------
const pubsub = {
  _subs: {},
  subscribe(topic, fn) {
    (this._subs[topic] ||= []).push(fn);
  },
  publish(topic) {
    (this._subs[topic] || []).forEach(fn => fn());
  },
  publishAll(topics) {
    const fns = new Set();
    for (const t of topics) {
      for (const fn of (this._subs[t] || [])) fns.add(fn);
    }
    fns.forEach(fn => fn());
  }
};

const pubsubAllTopics = [
  'config', 'selection', 'moveEverything', 'theme',
  'hotkeys', 'settings', 'undoRedo', 'runtime',
];

const state = {
  config: createDefaultConfig(),
  hotKeyIssues: [],
  selectedShortcutId: null,
  selectedPlacementId: null,
  hoveredShortcutId: null,
  hoveredPlacementId: null,
  history: [],
  future: [],
  recordingShortcutId: null,
  massRecordingOrder: null,
  massRecordingIndex: -1,
  settingsModalOpen: false,
  settingsActiveTab: "general",
  moveEverythingModalOpen: false,
  moveEverythingWindowEditor: null,
  recordingMoveEverythingField: null,
  didLogFirstState: false,
  gridDrag: null,
  freeDrag: null,
  listReorderDrag: null,
  listReorderClickSuppressUntil: 0,
  lastHoveredListKind: null,
  previewRequestFrame: null,
  pendingPreviewPlacement: null,
  confirmDialog: null,
  permissions: {
    accessibility: false,
  },
  runtime: {
    sandboxed: false,
    message: "",
  },
  configPath: "",
  launchAtLogin: {
    supported: false,
    enabled: false,
    requiresApproval: false,
    message: "",
  },
  settingControlCenterScaleDraft: null,
  moveEverythingActive: false,
  controlCenterFocused: false,
  moveEverythingControlCenterFocused: false,
  moveEverythingAlwaysOnTop: false,
  moveEverythingMoveToBottom: false,
  moveEverythingDontMoveVibeGrid: false,
  moveEverythingPinnedWindowKeys: new Set(),
  moveEverythingPinMode: false,
  moveEverythingRuntimeTogglePending: {
    alwaysOnTop: null,
    moveToBottom: null,
    dontMoveVibeGrid: null,
  },
  moveEverythingWindows: {
    visible: [],
    hidden: [],
    undoRetileAvailable: false,
    savedPositionsPreviousAvailable: false,
    savedPositionsNextAvailable: false,
  },
  moveEverythingHoveredWindowKey: null,
  moveEverythingFocusedWindowKey: null,
  moveEverythingEnsureRequestedAt: 0,
  moveEverythingNarrowMode: null,
  narrowPreviewMode: "windows",  // "windows" or "sequences"
  moveEverythingActionButtonsCompact: null,
  moveEverythingHoverLastSentAt: 0,
  moveEverythingHoverPendingKey: null,
  moveEverythingHoverSendTimer: null,
  moveEverythingActionRefreshTimers: [],
  moveEverythingCustomWindowTitlesByKey: {},
  moveEverythingCustomITermWindowTitlesByKey: {},
  moveEverythingCustomITermWindowBadgeTextByKey: {},
  moveEverythingCustomITermWindowBadgeColorByKey: {},
  moveEverythingCustomITermWindowBadgeOpacityByKey: {},
  moveEverythingCustomTitleStaleSince: {},
  moveEverythingLastButtonActionToken: null,
  moveEverythingLastButtonActionAt: 0,
};

const ids = {
  permissionBadge: document.getElementById("permissionBadge"),
  hotkeyIssueBanner: document.getElementById("hotkeyIssueBanner"),
  runtimeBanner: document.getElementById("runtimeBanner"),
  shortcutList: document.getElementById("shortcutList"),
  placementList: document.getElementById("placementList"),
  editorPanel: document.querySelector(".editor-panel"),
  emptyState: document.getElementById("emptyState"),
  editorContent: document.getElementById("editorContent"),
  placementEditor: document.getElementById("placementEditor"),
  placementEditorEmpty: document.getElementById("placementEditorEmpty"),
  shortcutName: document.getElementById("shortcutName"),
  hotkeyCaptureBtn: document.getElementById("hotkeyCaptureBtn"),
  massHotkeyCaptureBtn: document.getElementById("massHotkeyCaptureBtn"),
  hotkeyPreview: document.getElementById("hotkeyPreview"),
  toggleShortcutEnabledBtn: document.getElementById("toggleShortcutEnabledBtn"),
  cycleDisplaysOnWrap: document.getElementById("cycleDisplaysOnWrap"),
  controlCenterOnly: document.getElementById("controlCenterOnly"),
  ignoreExcludePinnedWindows: document.getElementById("ignoreExcludePinnedWindows"),
  placementTitle: document.getElementById("placementTitle"),
  displayTarget: document.getElementById("displayTarget"),
  removePlacementBtn: document.getElementById("removePlacementBtn"),
  settingGridCols: document.getElementById("settingGridCols"),
  settingGridRows: document.getElementById("settingGridRows"),
  settingGap: document.getElementById("settingGap"),
  settingDefaultCycleDisplaysOnWrap: document.getElementById("settingDefaultCycleDisplaysOnWrap"),
  settingThemeMode: document.getElementById("settingThemeMode"),
  settingControlCenterScale: document.getElementById("settingControlCenterScale"),
  applyControlCenterScaleBtn: document.getElementById("applyControlCenterScaleBtn"),
  settingLargerFonts: document.getElementById("settingLargerFonts"),
  settingLaunchAtLogin: document.getElementById("settingLaunchAtLogin"),
  openLoginItemsSettingsBtn: document.getElementById("openLoginItemsSettingsBtn"),
  settingsConfigPath: document.getElementById("settingsConfigPath"),
  revealConfigBtn: document.getElementById("revealConfigBtn"),
  openConfigBtn: document.getElementById("openConfigBtn"),
  copyConfigPathBtn: document.getElementById("copyConfigPathBtn"),
  modeGridBtn: document.getElementById("modeGridBtn"),
  modeFreeBtn: document.getElementById("modeFreeBtn"),
  gridEditor: document.getElementById("gridEditor"),
  freeEditor: document.getElementById("freeEditor"),
  gridCols: document.getElementById("gridCols"),
  gridRows: document.getElementById("gridRows"),
  gridCanvas: document.getElementById("gridCanvas"),
  freeX: document.getElementById("freeX"),
  freeY: document.getElementById("freeY"),
  freeW: document.getElementById("freeW"),
  freeH: document.getElementById("freeH"),
  freeXLabel: document.getElementById("freeXLabel"),
  freeYLabel: document.getElementById("freeYLabel"),
  freeWLabel: document.getElementById("freeWLabel"),
  freeHLabel: document.getElementById("freeHLabel"),
  freeCanvas: document.getElementById("freeCanvas"),
  freeRect: document.getElementById("freeRect"),
  yamlPreview: document.getElementById("yamlPreview"),
  toastStack: document.getElementById("toastStack"),
  exitBtn: document.getElementById("exitBtn"),
  moveEverythingBtn: document.getElementById("moveEverythingBtn"),
  moveEverythingWorkspace: document.getElementById("moveEverythingWorkspace"),
  moveEverythingStickyControls: document.getElementById("moveEverythingStickyControls"),
  moveEverythingNativeOnlyControls: document.getElementById("moveEverythingNativeOnlyControls"),
  moveEverythingWindowList: document.getElementById("moveEverythingWindowList"),
  moveEverythingRetileBtn: document.getElementById("moveEverythingRetileBtn"),
  moveEverythingMiniRetileBtn: document.getElementById("moveEverythingMiniRetileBtn"),
  moveEverythingHybridRetileBtn: document.getElementById("moveEverythingHybridRetileBtn"),
  moveEverythingITermRetileBtn: document.getElementById("moveEverythingITermRetileBtn"),
  moveEverythingNonITermRetileBtn: document.getElementById("moveEverythingNonITermRetileBtn"),
  moveEverythingUndoRetileBtn: document.getElementById("moveEverythingUndoRetileBtn"),
  moveEverythingAlwaysOnTop: document.getElementById("moveEverythingAlwaysOnTop"),
  moveEverythingAlwaysOnTopLabel: document.getElementById("moveEverythingAlwaysOnTopLabel"),
  moveEverythingMoveToBottom: document.getElementById("moveEverythingMoveToBottom"),
  moveEverythingMoveToBottomLabel: document.getElementById("moveEverythingMoveToBottomLabel"),
  moveEverythingDontMoveVibeGrid: document.getElementById("moveEverythingDontMoveVibeGrid"),
  moveEverythingPinModeBtn: document.getElementById("moveEverythingPinModeBtn"),
  settingsBtn: document.getElementById("settingsBtn"),
  hideBtn: document.getElementById("hideBtn"),
  confirmModal: document.getElementById("confirmModal"),
  confirmTitle: document.getElementById("confirmTitle"),
  confirmMessage: document.getElementById("confirmMessage"),
  confirmCancelBtn: document.getElementById("confirmCancelBtn"),
  confirmOkBtn: document.getElementById("confirmOkBtn"),
  settingsModal: document.getElementById("settingsModal"),
  colorsModal: document.getElementById("colorsModal"),
  colorsBtn: document.getElementById("colorsBtn"),
  colorsCloseBtn: document.getElementById("colorsCloseBtn"),
  settingsExitBtn: document.getElementById("settingsExitBtn"),
  settingsRestoreDefaultsBtn: document.getElementById("settingsRestoreDefaultsBtn"),
  settingsCloseBtn: document.getElementById("settingsCloseBtn"),
  openMoveEverythingSettingsBtn: document.getElementById("openMoveEverythingSettingsBtn"),
  moveEverythingModal: document.getElementById("moveEverythingModal"),
  moveEverythingCloseBtn: document.getElementById("moveEverythingCloseBtn"),
  moveEverythingRequirementsHint: document.getElementById("moveEverythingRequirementsHint"),
  moveEverythingStartAlwaysOnTopSetting: document.getElementById("moveEverythingStartAlwaysOnTopSetting"),
  moveEverythingStickyHoverStealFocusSetting: document.getElementById("moveEverythingStickyHoverStealFocusSetting"),
  moveEverythingCloseMuxKillSetting: document.getElementById("moveEverythingCloseMuxKillSetting"),
  moveEverythingExcludePinnedWindowsSetting: document.getElementById("moveEverythingExcludePinnedWindowsSetting"),
  moveEverythingMiniRetileWidthPercentSetting: document.getElementById("moveEverythingMiniRetileWidthPercentSetting"),
  moveEverythingBackgroundRefreshIntervalSetting: document.getElementById("moveEverythingBackgroundRefreshIntervalSetting"),
  moveEverythingRetileOrderSetting: document.getElementById("moveEverythingRetileOrderSetting"),
  moveEverythingQuickViewVerticalModeSetting: document.getElementById("moveEverythingQuickViewVerticalModeSetting"),
  moveEverythingITermGroupByRepositorySetting: document.getElementById("moveEverythingITermGroupByRepositorySetting"),
  moveEverythingITermRecentActivityTimeoutSetting: document.getElementById("moveEverythingITermRecentActivityTimeoutSetting"),
  moveEverythingITermRecentActivityBufferSetting: document.getElementById("moveEverythingITermRecentActivityBufferSetting"),
  moveEverythingITermRecentActivityActiveTextSetting: document.getElementById("moveEverythingITermRecentActivityActiveTextSetting"),
  moveEverythingITermRecentActivityIdleTextSetting: document.getElementById("moveEverythingITermRecentActivityIdleTextSetting"),
  moveEverythingITermRecentActivityBadgeEnabledSetting: document.getElementById("moveEverythingITermRecentActivityBadgeEnabledSetting"),
  moveEverythingITermBadgeFromTitleSetting: document.getElementById("moveEverythingITermBadgeFromTitleSetting"),
  moveEverythingITermTitleFromBadgeSetting: document.getElementById("moveEverythingITermTitleFromBadgeSetting"),
  moveEverythingITermTitleAllCapsSetting: document.getElementById("moveEverythingITermTitleAllCapsSetting"),
  moveEverythingITermRecentActivityColorizeSetting: document.getElementById("moveEverythingITermRecentActivityColorizeSetting"),
  moveEverythingITermRecentActivityColorizeNamedOnlySetting: document.getElementById("moveEverythingITermRecentActivityColorizeNamedOnlySetting"),
  narrowModeToggle: document.getElementById("narrowModeToggle"),
  narrowModeWindowsBtn: document.getElementById("narrowModeWindowsBtn"),
  narrowModeSequencesBtn: document.getElementById("narrowModeSequencesBtn"),
  moveEverythingITermActivityTintIntensitySetting: document.getElementById("moveEverythingITermActivityTintIntensitySetting"),
  moveEverythingITermActivityHoldSecondsSetting: document.getElementById("moveEverythingITermActivityHoldSecondsSetting"),
  moveEverythingITermActivityOverlayOpacitySetting: document.getElementById("moveEverythingITermActivityOverlayOpacitySetting"),
  moveEverythingITermActivityBackgroundTintEnabledSetting: document.getElementById("moveEverythingITermActivityBackgroundTintEnabledSetting"),
  moveEverythingITermActivityTabColorEnabledSetting: document.getElementById("moveEverythingITermActivityTabColorEnabledSetting"),
  moveEverythingITermRecentActivityActiveColorSetting: document.getElementById("moveEverythingITermRecentActivityActiveColorSetting"),
  moveEverythingITermRecentActivityIdleColorSetting: document.getElementById("moveEverythingITermRecentActivityIdleColorSetting"),
  moveEverythingITermRecentActivityActiveColorLightSetting: document.getElementById("moveEverythingITermRecentActivityActiveColorLightSetting"),
  moveEverythingITermRecentActivityIdleColorLightSetting: document.getElementById("moveEverythingITermRecentActivityIdleColorLightSetting"),
  moveEverythingITermBadgeTopMarginSetting: document.getElementById("moveEverythingITermBadgeTopMarginSetting"),
  moveEverythingITermBadgeRightMarginSetting: document.getElementById("moveEverythingITermBadgeRightMarginSetting"),
  moveEverythingActiveWindowHighlightColorizeSetting: document.getElementById("moveEverythingActiveWindowHighlightColorizeSetting"),
  moveEverythingActiveWindowHighlightColorSetting: document.getElementById("moveEverythingActiveWindowHighlightColorSetting"),
  moveEverythingITermRecentActivityHint: document.getElementById("moveEverythingITermRecentActivityHint"),
  moveEverythingCloseWindowPreview: document.getElementById("moveEverythingCloseWindowPreview"),
  moveEverythingHideWindowPreview: document.getElementById("moveEverythingHideWindowPreview"),
  moveEverythingNameWindowPreview: document.getElementById("moveEverythingNameWindowPreview"),
  moveEverythingQuickViewPreview: document.getElementById("moveEverythingQuickViewPreview"),
  moveEverythingUndoWindowMovementPreview: document.getElementById("moveEverythingUndoWindowMovementPreview"),
  moveEverythingRedoWindowMovementPreview: document.getElementById("moveEverythingRedoWindowMovementPreview"),
  moveEverythingCloseHideOutsideMode: document.getElementById("moveEverythingCloseHideOutsideMode"),
  moveEverythingWindowEditorModal: document.getElementById("moveEverythingWindowEditorModal"),
  moveEverythingWindowEditorTitle: document.getElementById("moveEverythingWindowEditorTitle"),
  moveEverythingWindowEditorHint: document.getElementById("moveEverythingWindowEditorHint"),
  moveEverythingWindowEditorForm: document.getElementById("moveEverythingWindowEditorForm"),
  moveEverythingWindowEditorTitleField: document.getElementById("moveEverythingWindowEditorTitleField"),
  moveEverythingWindowEditorTitleInput: document.getElementById("moveEverythingWindowEditorTitleInput"),
  moveEverythingWindowEditorTitleMeta: document.getElementById("moveEverythingWindowEditorTitleMeta"),
  moveEverythingWindowEditorBadgeTextField: document.getElementById("moveEverythingWindowEditorBadgeTextField"),
  moveEverythingWindowEditorBadgeTextInput: document.getElementById("moveEverythingWindowEditorBadgeTextInput"),
  moveEverythingWindowEditorBadgeTextMeta: document.getElementById("moveEverythingWindowEditorBadgeTextMeta"),
  moveEverythingWindowEditorBadgeColorField: document.getElementById("moveEverythingWindowEditorBadgeColorField"),
  moveEverythingWindowEditorBadgeColorSwatches: document.getElementById("moveEverythingWindowEditorBadgeColorSwatches"),
  moveEverythingWindowEditorBadgeColorInput: document.getElementById("moveEverythingWindowEditorBadgeColorInput"),
  moveEverythingWindowEditorBadgeOpacityInput: document.getElementById("moveEverythingWindowEditorBadgeOpacityInput"),
  moveEverythingWindowEditorBadgeOpacityLabel: document.getElementById("moveEverythingWindowEditorBadgeOpacityLabel"),
  moveEverythingSaveDefaultsBtn: document.getElementById("moveEverythingSaveDefaultsBtn"),
  moveEverythingResetDefaultsBtn: document.getElementById("moveEverythingResetDefaultsBtn"),
  moveEverythingWindowEditorResetBtn: document.getElementById("moveEverythingWindowEditorResetBtn"),
  moveEverythingWindowEditorCancelBtn: document.getElementById("moveEverythingWindowEditorCancelBtn"),
  moveEverythingWindowEditorSaveBtn: document.getElementById("moveEverythingWindowEditorSaveBtn"),
  flipHorizontalBtn: document.getElementById("flipHorizontalBtn"),
  flipVerticalBtn: document.getElementById("flipVerticalBtn"),
  flipAllSteps: document.getElementById("flipAllSteps"),
  undoBtn: document.getElementById("undoBtn"),
  redoBtn: document.getElementById("redoBtn"),
};

const modifierOrder = ["cmd", "ctrl", "alt", "shift", "fn"];
const maxUndoChanges = 100;
const autosaveDelayMs = 0;
const listReorderHoldDelayMs = 110;
const listReorderMoveTolerancePx = 8;
const listReorderClickSuppressMs = 250;
const listReorderAutoScrollEdgePx = 36;
const listReorderAutoScrollSpeedPx = 16;
const themeModes = ["system", "light", "dark"];
const themeModeLookup = new Set(themeModes);
const systemThemeMediaQuery = window.matchMedia?.("(prefers-color-scheme: dark)") || null;
const supportsControlCenterZoom = "zoom" in document.documentElement.style;
const minControlCenterScale = 0.5;
const maxControlCenterScale = 2;
const defaultControlCenterScale = 1;
const minControlCenterScalePercent = Math.round(minControlCenterScale * 100);
const maxControlCenterScalePercent = Math.round(maxControlCenterScale * 100);
const defaultControlCenterScalePercent = Math.round(defaultControlCenterScale * 100);
const minMoveEverythingPercent = 10;
const maxMoveEverythingPercent = 100;
const defaultMoveEverythingMoveOnSelectionMode = "miniControlCenterOnTop";
const defaultMoveEverythingWidthPercent = 33;
const defaultMoveEverythingHeightPercent = 70;
const moveEverythingOverlayModes = ["persistent", "timed"];
const moveEverythingOverlayModeLookup = new Set(moveEverythingOverlayModes);
const defaultMoveEverythingOverlayMode = "persistent";
const minMoveEverythingOverlayDuration = 0.2;
const maxMoveEverythingOverlayDuration = 8;
const defaultMoveEverythingOverlayDuration = 2;
const moveEverythingRuntimeTogglePendingMs = 700;
const moveEverythingHoverSendThrottleMs = 40;
const moveEverythingPerfLogThresholdMs = 28;
const moveEverythingTitleTruncatePaddingPx = 8;
const moveEverythingTitleEllipsis = "...";
const narrowModeWidthThresholdPx = 960;
const moveEverythingActionCompactWidthThresholdPx = 1140;
const defaultMoveEverythingITermRecentActivityActiveColor = "#2F8F4E";
const defaultMoveEverythingITermRecentActivityIdleColor = "#BA4D4D";
const defaultMoveEverythingITermRecentActivityActiveColorLight = "#1A7535";
const defaultMoveEverythingITermRecentActivityIdleColorLight = "#A03030";
const defaultMoveEverythingActiveWindowHighlightColor = "#4D88D4";
const defaultMoveEverythingITermBadgeTopMargin = 6;
const defaultMoveEverythingITermBadgeRightMargin = 8;
const defaultMoveEverythingITermBadgeCustomColor = "#4A90D9";
const defaultMoveEverythingITermBadgeOpacity = 60;
const moveEverythingHotkeyFieldOrder = [
  "moveEverythingCloseWindowHotkey",
  "moveEverythingHideWindowHotkey",
  "moveEverythingNameWindowHotkey",
  "moveEverythingQuickViewHotkey",
  "moveEverythingUndoWindowMovementHotkey",
  "moveEverythingRedoWindowMovementHotkey",
];
const moveEverythingHotkeyPreviewByField = {
  moveEverythingCloseWindowHotkey: ids.moveEverythingCloseWindowPreview,
  moveEverythingHideWindowHotkey: ids.moveEverythingHideWindowPreview,
  moveEverythingNameWindowHotkey: ids.moveEverythingNameWindowPreview,
  moveEverythingQuickViewHotkey: ids.moveEverythingQuickViewPreview,
  moveEverythingUndoWindowMovementHotkey: ids.moveEverythingUndoWindowMovementPreview,
  moveEverythingRedoWindowMovementHotkey: ids.moveEverythingRedoWindowMovementPreview,
};
let permissionPollTimer = null;
let autosaveTimer = null;
let configSaveGuardUntil = 0;
let moveEverythingTitleMeasureCanvas = null;

function sendJsLog(level, message, details = "") {
  if (window.webkit?.messageHandlers?.vibeGridBridge) {
    window.webkit.messageHandlers.vibeGridBridge.postMessage({
      type: "jsLog",
      payload: {
        level,
        message,
        details: details ? String(details) : "",
      },
    });
    return;
  }
  console[level === "error" ? "error" : "log"](`[VibeGrid JS ${level}] ${message}`, details || "");
}

function sendToNative(type, payload = {}) {
  if (window.webkit?.messageHandlers?.vibeGridBridge) {
    window.webkit.messageHandlers.vibeGridBridge.postMessage({ type, payload });
    return;
  }

  // Non-WebKit bridge (e.g. Windows Go backend via bridge.js HTTP polling)
  if (typeof window.vibeGridBridgePostMessage === "function") {
    window.vibeGridBridgePostMessage({ type, payload });
    return;
  }

  if (type === "ready") {
    const fallback = createDefaultConfig();
    receiveState({
      config: fallback,
      permissions: { accessibility: false },
      configPath: "~/Library/Application Support/VibeGrid/config.yaml",
      yaml: "# Running in browser fallback mode",
    });
  }
}

window.addEventListener("error", (event) => {
  const message = event?.message || "Unknown JS error";
  const source = event?.filename || "";
  const line = Number.isFinite(event?.lineno) ? `:${event.lineno}` : "";
  const column = Number.isFinite(event?.colno) ? `:${event.colno}` : "";
  const stack = event?.error?.stack || "";
  sendJsLog("error", "window.error", `${message} @ ${source}${line}${column} ${stack}`.trim());
});

window.addEventListener("unhandledrejection", (event) => {
  const reason = event?.reason;
  let details = "";
  if (reason && typeof reason === "object" && reason.stack) {
    details = String(reason.stack);
  } else {
    details = String(reason ?? "unknown");
  }
  sendJsLog("error", "unhandledrejection", details);
});

window.vibeGridReceive = (message) => {
  if (!message || typeof message !== "object") {
    return;
  }

  const { type, payload } = message;

  if (type === "state") {
    receiveState(payload);
    return;
  }

  if (type === "yaml") {
    if (ids.yamlPreview) {
      ids.yamlPreview.textContent = payload?.text ?? "";
    }
    return;
  }

  if (type === "permission") {
    updateAccessibilityState(Boolean(payload?.accessibility));
    return;
  }

  if (type === "saveMeta") {
    state.hotKeyIssues = Array.isArray(payload?.hotKeyIssues) ? payload.hotKeyIssues : [];
    if (ids.yamlPreview && typeof payload?.yaml === "string") {
      ids.yamlPreview.textContent = payload.yaml;
    }
    renderHotKeyIssues();
    renderShortcutList();
    return;
  }

  if (type === "openWindowEditor") {
    const key = payload?.key;
    if (key) {
      openMoveEverythingWindowEditor(key);
    }
    return;
  }

  if (type === "notice") {
    showToast(payload?.message ?? "", payload?.level ?? "info");
  }
};

function receiveState(payload) {
  // If there are unsaved local config changes (pending autosave), don't overwrite
  // the config from the server — only update non-config fields like the window list.
  state.hotKeyIssues = Array.isArray(payload?.hotKeyIssues) ? payload.hotKeyIssues : [];

  // If there are unsaved local edits (pending autosave), flush them to the
  // server immediately but skip this payload's config — it's stale (predates
  // our edits). The flush triggers a saveConfig which will cause the server
  // to push back the correct config on the next cycle.
  if (autosaveTimer !== null) {
    flushAutosave();
    // Config wasn't updated from payload; record current signature for fast-path diffing.
    if (state._currentConfigSig === undefined) {
      state._currentConfigSig = configSignature(state.config);
    }
  } else if (performance.now() < configSaveGuardUntil) {
    // Skip config overwrite — a save was just flushed and the server
    // may not have processed it yet. The next push will have the correct config.
    if (state._currentConfigSig === undefined) {
      state._currentConfigSig = configSignature(state.config);
    }
  } else {
    const previousSignature = state.config ? configSignature(state.config) : null;
    state.config = payload?.config || createDefaultConfig();
    if (!Array.isArray(state.config.shortcuts)) {
      state.config.shortcuts = [];
    }
    state.config.settings = normalizeSettings(state.config.settings);
    state.config.shortcuts = state.config.shortcuts.map((shortcut) => ({
      ...shortcut,
      enabled: shortcut.enabled !== false,
      cycleDisplaysOnWrap:
        shortcut.cycleDisplaysOnWrap === undefined || shortcut.cycleDisplaysOnWrap === null
          ? Boolean(state.config.settings.defaultCycleDisplaysOnWrap)
          : Boolean(shortcut.cycleDisplaysOnWrap),
      controlCenterOnly: Boolean(shortcut.controlCenterOnly),
      useForRetiling: shortcut.useForRetiling || "no",
    }));

    const nextSignature = configSignature(state.config);
    state._currentConfigSig = nextSignature;
    if (!state.history.length || previousSignature === null) {
      resetHistoryFromCurrentConfig();
    } else if (previousSignature !== nextSignature) {
      // Config changed externally (e.g. file edited outside app).
      // Preserve undo history but add the new state as a checkpoint.
      pushCurrentConfigToHistory();
    }
  }
  state.permissions.accessibility = Boolean(payload?.permissions?.accessibility);
  state.runtime.sandboxed = Boolean(payload?.runtime?.sandboxed);
  state.runtime.message = typeof payload?.runtime?.message === "string" ? payload.runtime.message : "";
  state.configPath = typeof payload?.configPath === "string" ? payload.configPath : "";
  state.configParseError = typeof payload?.configParseError === "string" ? payload.configParseError : "";
  state.launchAtLogin = normalizeLaunchAtLoginState(payload?.launchAtLogin);
  state.moveEverythingActive = Boolean(payload?.moveEverythingActive);
  if (!state.moveEverythingActive && state.moveEverythingPinMode) {
    state.moveEverythingPinMode = false;
  }
  state.controlCenterFocused = Boolean(payload?.controlCenterFocused);
  state.moveEverythingControlCenterFocused = Boolean(payload?.moveEverythingControlCenterFocused);
  state.moveEverythingAlwaysOnTop = resolveMoveEverythingRuntimeToggleValue(
    "alwaysOnTop",
    Boolean(payload?.moveEverythingAlwaysOnTop)
  );
  state.moveEverythingMoveToBottom = resolveMoveEverythingRuntimeToggleValue(
    "moveToBottom",
    Boolean(payload?.moveEverythingMoveToBottom)
  );
  state.moveEverythingDontMoveVibeGrid = resolveMoveEverythingRuntimeToggleValue(
    "dontMoveVibeGrid",
    Boolean(payload?.moveEverythingDontMoveVibeGrid)
  );
  state.moveEverythingPinnedWindowKeys = new Set(
    Array.isArray(payload?.moveEverythingPinnedWindowKeys) ? payload.moveEverythingPinnedWindowKeys : []
  );
  state.moveEverythingWindows = normalizeMoveEverythingWindowInventory(payload?.moveEverythingWindows);
  state.moveEverythingFocusedWindowKey = String(payload?.moveEverythingFocusedWindowKey || "").trim() || null;
  applyTheme();
  applyLargerFonts();

  enforceSelection();

  // Skip full re-render while a drag-reorder is in progress — re-rendering
  // the list mid-drag causes item duplication. The render will happen when
  // the drag ends and the next state poll arrives.
  if (!state.listReorderDrag && !state.gridDrag && !state.freeDrag) {
    // Fast path: if only the move-everything window inventory or focus/hover
    // state changed, publish just that topic to avoid re-rendering the
    // shortcut list, placement editor, grid, etc.
    if (state._lastReceivedConfigSig !== undefined &&
        state._lastReceivedConfigSig === state._currentConfigSig &&
        state._lastMoveEverythingActive === state.moveEverythingActive) {
      syncNarrowModeLayout();
      pubsub.publish('moveEverything');
    } else {
      renderAll();
    }
  }
  state._lastReceivedConfigSig = state._currentConfigSig;
  state._lastMoveEverythingActive = state.moveEverythingActive;

  updateAccessibilityState(state.permissions.accessibility);
  if (ids.yamlPreview) {
    ids.yamlPreview.textContent = payload?.yaml ?? "";
  }

  if (!state.didLogFirstState) {
    state.didLogFirstState = true;
    sendJsLog(
      "info",
      "state.received",
      `shortcuts=${state.config.shortcuts.length} moveEverythingActive=${state.moveEverythingActive}`
    );
  }
}

function enforceSelection() {
  const shortcuts = state.config.shortcuts;

  if (!shortcuts.length) {
    state.selectedShortcutId = null;
    state.selectedPlacementId = null;
    return;
  }

  if (!shortcuts.find((item) => item.id === state.selectedShortcutId)) {
    state.selectedShortcutId = shortcuts[0].id;
  }

  const shortcut = selectedShortcut();
  if (!shortcut || !shortcut.placements.length) {
    state.selectedPlacementId = null;
    return;
  }

  if (state.selectedPlacementId &&
      !shortcut.placements.find((item) => item.id === state.selectedPlacementId)) {
    state.selectedPlacementId = null;
  }
}

function moveEverythingWorkspaceVisible() {
  return displayPlacementContext().placement === null;
}

function maybeEnsureMoveEverythingMode(force = false) {
  if (!force && state.moveEverythingActive) {
    return;
  }
  const now = Date.now();
  if (!force && now - state.moveEverythingEnsureRequestedAt < 1200) {
    return;
  }
  state.moveEverythingEnsureRequestedAt = now;
  sendToNative("ensureMoveEverythingMode");
}

// ---------------------------------------------------------------------------
// Pub/sub subscriptions: each render function subscribes to its topics.
// ---------------------------------------------------------------------------

// 'theme' - re-apply CSS theme when theme mode changes
pubsub.subscribe('theme', applyTheme);

// 'settings' - re-apply control-center zoom scale and font boost when settings change
pubsub.subscribe('settings', applyControlCenterScale);
pubsub.subscribe('settings', applyLargerFonts);

// 'undoRedo' - enable/disable undo & redo buttons
pubsub.subscribe('undoRedo', renderUndoRedoButtons);

// 'hotkeys', 'config' - hotkey issue banner depends on issues list + shortcut names
pubsub.subscribe('hotkeys', renderHotKeyIssues);
pubsub.subscribe('config', renderHotKeyIssues);

// 'runtime' - runtime banner (sandbox warning, etc.)
pubsub.subscribe('runtime', renderRuntimeBanner);

// 'moveEverything', 'selection' - button label depends on whether workspace is visible
pubsub.subscribe('moveEverything', renderMoveEverythingButton);
pubsub.subscribe('selection', renderMoveEverythingButton);

// 'config', 'selection', 'hotkeys' - shortcut list shows names, hotkeys, selection, issues
pubsub.subscribe('config', renderShortcutList);
pubsub.subscribe('selection', renderShortcutList);
pubsub.subscribe('hotkeys', renderShortcutList);

// 'config', 'selection', 'hotkeys' - shortcut editor shows selected shortcut details, recording state
pubsub.subscribe('config', renderShortcutEditor);
pubsub.subscribe('selection', renderShortcutEditor);
pubsub.subscribe('hotkeys', renderShortcutEditor);

// 'config', 'selection' - placement list shows placements for selected/hovered shortcut
pubsub.subscribe('config', renderPlacementList);
pubsub.subscribe('selection', renderPlacementList);

// 'config', 'selection' - placement editor shows selected placement details
pubsub.subscribe('config', renderPlacementEditor);
pubsub.subscribe('selection', renderPlacementEditor);

// 'moveEverything', 'selection' - workspace depends on window list + whether a placement is selected
pubsub.subscribe('moveEverything', renderMoveEverythingWorkspace);
pubsub.subscribe('selection', renderMoveEverythingWorkspace);
pubsub.subscribe('theme', renderMoveEverythingWorkspace);

// 'settings', 'moveEverything' - settings modal shows settings + launch-at-login state
pubsub.subscribe('settings', renderSettingsModal);

// 'moveEverything' - move-everything modal shows hotkey previews, recording state, settings
pubsub.subscribe('moveEverything', renderMoveEverythingModal);

// ---------------------------------------------------------------------------
// renderAll: publishes all topics (de-duped), used for initial load, config
// reload, undo/redo, and anywhere the exact trigger is unclear.
// ---------------------------------------------------------------------------
function renderAll() {
  syncNarrowModeLayout();
  pubsub.publishAll(pubsubAllTopics);
}

function narrowModeActive() {
  return state.moveEverythingNarrowMode === true || document.body.classList.contains("narrow-mode");
}

function moveEverythingActionCompactModeActive() {
  return narrowModeActive() || window.innerWidth <= moveEverythingActionCompactWidthThresholdPx;
}

function syncNarrowModeLayout() {
  const isNarrow = window.innerWidth <= narrowModeWidthThresholdPx;
  let didMutate = false;
  if (isNarrow && state.narrowPreviewMode !== "sequences") {
    if (state.selectedPlacementId !== null) {
      clearSelectedPlacement({ render: false });
      didMutate = true;
    }
    if (clearPlacementHoverState()) {
      didMutate = true;
    }
    if (state.lastHoveredListKind !== null) {
      state.lastHoveredListKind = null;
      didMutate = true;
    }
  }
  const wasNarrow = document.body.classList.contains("narrow-mode");
  document.body.classList.toggle("narrow-mode", isNarrow);
  syncMoveEverythingMoveToBottomLabels(isNarrow);
  if (state.moveEverythingNarrowMode !== isNarrow) {
    state.moveEverythingNarrowMode = isNarrow;
    sendToNative("setMoveEverythingNarrowMode", { enabled: isNarrow });
    didMutate = true;
  }
  // Show/hide narrow mode toggle and apply sequences class
  syncNarrowPreviewMode();
  return didMutate || wasNarrow !== isNarrow;
}

function syncNarrowPreviewMode() {
  const isNarrow = state.moveEverythingNarrowMode === true;
  if (ids.narrowModeToggle) {
    ids.narrowModeToggle.classList.toggle("hidden", !isNarrow);
  }
  if (ids.narrowModeWindowsBtn) {
    ids.narrowModeWindowsBtn.classList.toggle("active", state.narrowPreviewMode === "windows");
  }
  if (ids.narrowModeSequencesBtn) {
    ids.narrowModeSequencesBtn.classList.toggle("active", state.narrowPreviewMode === "sequences");
  }
  document.body.classList.toggle("narrow-sequences", isNarrow && state.narrowPreviewMode === "sequences");
}

function setNarrowPreviewMode(mode) {
  state.narrowPreviewMode = mode;
  if (mode === "sequences" && !state.selectedPlacementId) {
    const shortcut = selectedShortcut();
    if (shortcut?.placements?.length) {
      state.selectedPlacementId = shortcut.placements[0].id;
    }
  }
  syncNarrowPreviewMode();
  pubsub.publish("selection");
  pubsub.publish("moveEverything");
}

function normalizeHexColor(value, fallback) {
  const trimmed = String(value ?? "").trim();
  if (!trimmed.startsWith("#")) {
    return fallback;
  }
  const raw = trimmed.slice(1);
  if (/^[0-9a-fA-F]{3}$/.test(raw)) {
    return `#${raw[0]}${raw[0]}${raw[1]}${raw[1]}${raw[2]}${raw[2]}`.toUpperCase();
  }
  if (/^[0-9a-fA-F]{6}$/.test(raw)) {
    return `#${raw.toUpperCase()}`;
  }
  return fallback;
}

function parseHexColor(value) {
  const normalized = normalizeHexColor(value, "");
  if (!normalized) {
    return null;
  }
  const raw = normalized.slice(1);
  const red = Number.parseInt(raw.slice(0, 2), 16);
  const green = Number.parseInt(raw.slice(2, 4), 16);
  const blue = Number.parseInt(raw.slice(4, 6), 16);
  if (!Number.isFinite(red) || !Number.isFinite(green) || !Number.isFinite(blue)) {
    return null;
  }
  return { red, green, blue };
}

function blendColor(base, target, ratio) {
  const clamped = clampNumber(Number(ratio), 0, 1);
  return {
    red: Math.round(base.red * (1 - clamped) + target.red * clamped),
    green: Math.round(base.green * (1 - clamped) + target.green * clamped),
    blue: Math.round(base.blue * (1 - clamped) + target.blue * clamped),
  };
}

function colorToCss(color, alpha = null) {
  if (!color) {
    return "";
  }
  if (alpha === null) {
    return `rgb(${color.red} ${color.green} ${color.blue})`;
  }
  return `rgb(${color.red} ${color.green} ${color.blue} / ${clampNumber(Number(alpha), 0, 1)})`;
}

function moveEverythingThemeIsDark() {
  return document.documentElement.getAttribute("data-theme") === "dark";
}

function resolveMoveEverythingWindowActivityColorPair(baseHex) {
  const parsed = parseHexColor(baseHex);
  if (!parsed) {
    return null;
  }
  const darkTheme = moveEverythingThemeIsDark();
  if (darkTheme) {
    const darkSurface = { red: 13, green: 19, blue: 23 };
    return {
      border: colorToCss(blendColor(parsed, darkSurface, 0.46)),
      background: colorToCss(blendColor(parsed, darkSurface, 0.77), 0.92),
    };
  }
  const lightSurface = { red: 255, green: 255, blue: 255 };
  return {
    border: colorToCss(blendColor(parsed, lightSurface, 0.1)),
    background: colorToCss(blendColor(parsed, lightSurface, 0.84), 0.95),
  };
}

function syncMoveEverythingMoveToBottomLabels(isNarrow) {
  const alwaysOnTopLabel = isNarrow ? "On Top" : "Always On Top";
  if (ids.moveEverythingAlwaysOnTopLabel) {
    ids.moveEverythingAlwaysOnTopLabel.textContent = alwaysOnTopLabel;
  }
  const moveToBottomLabel = isNarrow ? "Move To Side" : "Move To Bottom";
  if (ids.moveEverythingMoveToBottomLabel) {
    ids.moveEverythingMoveToBottomLabel.textContent = moveToBottomLabel;
  }
}

function effectiveHotKeyIssues() {
  const backendIssues = (state.hotKeyIssues || []).filter(
    (issue) => issue?.kind !== "duplicateInConfig"
  );

  return [...backendIssues, ...deriveLocalDuplicateHotKeyIssues()];
}

function deriveLocalDuplicateHotKeyIssues() {
  if (!Array.isArray(state.config?.shortcuts)) {
    return [];
  }

  const seenBySignature = new Map();
  const issues = [];

  for (const shortcut of state.config.shortcuts) {
    if (shortcut.enabled === false) {
      continue;
    }

    const signature = hotkeySignature(shortcut.hotkey);
    if (!signature) {
      continue;
    }

    const existing = seenBySignature.get(signature);
    if (existing) {
      const existingName = existing.name || existing.id || "another shortcut";
      issues.push({
        shortcutID: shortcut.id,
        kind: "duplicateInConfig",
        message: `Duplicate of '${existingName}' (${formatHotkey(shortcut.hotkey)})`,
      });
      continue;
    }

    seenBySignature.set(signature, shortcut);
  }

  return issues;
}

function renderUndoRedoButtons() {
  const canUndo = state.history.length > 1;
  const canRedo = state.future.length > 0;
  ids.undoBtn.disabled = !canUndo;
  ids.redoBtn.disabled = !canRedo;
}

function renderHotKeyIssues() {
  const issues = effectiveHotKeyIssues();
  ids.hotkeyIssueBanner.innerHTML = "";
  ids.hotkeyIssueBanner.classList.toggle("hidden", issues.length === 0);
  if (!issues.length) {
    return;
  }

  const fragment = document.createDocumentFragment();
  issues.forEach((issue) => {
    const row = document.createElement("div");
    row.className = "issue-row";
    const shortcut = state.config.shortcuts.find((item) => item.id === issue.shortcutID);
    const name = shortcut?.name || issue.shortcutID;
    row.textContent = `Shortcut "${name}": ${issue.message}`;
    fragment.appendChild(row);
  });
  ids.hotkeyIssueBanner.appendChild(fragment);
}

function renderRuntimeBanner() {
  const parseError = state.configParseError || "";
  const runtimeMessage = state.runtime?.message || "";
  const message = parseError || runtimeMessage;
  const isWarning = Boolean(parseError) || Boolean(state.runtime?.sandboxed);
  ids.runtimeBanner.textContent = message;
  ids.runtimeBanner.classList.toggle("hidden", !message);
  ids.runtimeBanner.classList.toggle("warning", isWarning);
  ids.runtimeBanner.classList.toggle("info", !isWarning && Boolean(message));
}

function moveEverythingRequirementText(settings = state.config?.settings) {
  void settings;
  return "Optional: set Close/Hide hotkeys for keyboard actions.";
}

function renderMoveEverythingButton() {
  if (!ids.moveEverythingBtn) {
    return;
  }

  const workspaceVisible = moveEverythingWorkspaceVisible();
  ids.moveEverythingBtn.classList.toggle("active", workspaceVisible);
  ids.moveEverythingBtn.textContent = "Window List";
  ids.moveEverythingBtn.title = workspaceVisible
    ? "Open Window List settings"
    : "Show Window List panel";
}

function openMoveEverythingModal() {
  state.moveEverythingModalOpen = true;
  renderMoveEverythingModal();
}

function closeMoveEverythingModal() {
  if (state.recordingMoveEverythingField) {
    stopMoveEverythingHotkeyRecording({ silent: true });
  }
  state.moveEverythingModalOpen = false;
  renderMoveEverythingModal();
}

function renderMoveEverythingModal() {
  // Window List settings are now rendered inside the Settings modal tabs.
  // Still render the standalone modal if it exists (backward compat).
  if (ids.moveEverythingModal) {
    ids.moveEverythingModal.classList.toggle("hidden", !state.moveEverythingModalOpen);
  }

  // Render content if the standalone modal is open OR the settings modal is
  // on the windowList/colors tab.
  const settingsTabActive = state.settingsModalOpen &&
    (state.settingsActiveTab === "windowList" || state.settingsActiveTab === "colors");
  if (!state.moveEverythingModalOpen && !settingsTabActive) {
    return;
  }

  syncMoveEverythingMoveToBottomLabels(document.body.classList.contains("narrow-mode"));

  const settings = state.config.settings;
  if (
    !ids.moveEverythingCloseHideOutsideMode ||
    !ids.moveEverythingStartAlwaysOnTopSetting ||
    !ids.moveEverythingStickyHoverStealFocusSetting ||
    !ids.moveEverythingRequirementsHint
  ) {
    return;
  }
  if (window.vibeGridPlatform && window.vibeGridPlatform.noNativeFeatures) {
    // Hide native-only settings on non-native hosts (e.g. Windows Go backend)
    if (ids.moveEverythingStartAlwaysOnTopSetting && ids.moveEverythingStartAlwaysOnTopSetting.parentElement) {
      ids.moveEverythingStartAlwaysOnTopSetting.parentElement.style.display = "none";
    }
    if (ids.moveEverythingStickyHoverStealFocusSetting && ids.moveEverythingStickyHoverStealFocusSetting.parentElement) {
      ids.moveEverythingStickyHoverStealFocusSetting.parentElement.style.display = "none";
    }
    if (ids.moveEverythingCloseMuxKillSetting && ids.moveEverythingCloseMuxKillSetting.parentElement) {
      ids.moveEverythingCloseMuxKillSetting.parentElement.style.display = "none";
    }
    if (ids.moveEverythingExcludePinnedWindowsSetting && ids.moveEverythingExcludePinnedWindowsSetting.parentElement) {
      ids.moveEverythingExcludePinnedWindowsSetting.parentElement.style.display = "none";
    }
    if (ids.moveEverythingITermRecentActivityTimeoutSetting && ids.moveEverythingITermRecentActivityTimeoutSetting.parentElement) {
      ids.moveEverythingITermRecentActivityTimeoutSetting.parentElement.style.display = "none";
    }
    if (ids.moveEverythingITermRecentActivityBufferSetting && ids.moveEverythingITermRecentActivityBufferSetting.parentElement) {
      ids.moveEverythingITermRecentActivityBufferSetting.parentElement.style.display = "none";
    }
    if (ids.moveEverythingITermRecentActivityActiveTextSetting && ids.moveEverythingITermRecentActivityActiveTextSetting.parentElement) {
      ids.moveEverythingITermRecentActivityActiveTextSetting.parentElement.style.display = "none";
    }
    if (ids.moveEverythingITermRecentActivityIdleTextSetting && ids.moveEverythingITermRecentActivityIdleTextSetting.parentElement) {
      ids.moveEverythingITermRecentActivityIdleTextSetting.parentElement.style.display = "none";
    }
    if (ids.moveEverythingITermRecentActivityBadgeEnabledSetting && ids.moveEverythingITermRecentActivityBadgeEnabledSetting.parentElement) {
      ids.moveEverythingITermRecentActivityBadgeEnabledSetting.parentElement.style.display = "none";
    }
    if (ids.moveEverythingITermBadgeFromTitleSetting && ids.moveEverythingITermBadgeFromTitleSetting.parentElement) {
      ids.moveEverythingITermBadgeFromTitleSetting.parentElement.style.display = "none";
    }
    if (ids.moveEverythingITermTitleFromBadgeSetting && ids.moveEverythingITermTitleFromBadgeSetting.parentElement) {
      ids.moveEverythingITermTitleFromBadgeSetting.parentElement.style.display = "none";
    }
    if (ids.moveEverythingITermBadgeTopMarginSetting && ids.moveEverythingITermBadgeTopMarginSetting.parentElement) {
      ids.moveEverythingITermBadgeTopMarginSetting.parentElement.style.display = "none";
    }
    if (ids.moveEverythingITermBadgeRightMarginSetting && ids.moveEverythingITermBadgeRightMarginSetting.parentElement) {
      ids.moveEverythingITermBadgeRightMarginSetting.parentElement.style.display = "none";
    }
  } else {
    ids.moveEverythingStartAlwaysOnTopSetting.checked = Boolean(
      settings.moveEverythingStartAlwaysOnTop
    );
    ids.moveEverythingStickyHoverStealFocusSetting.checked = Boolean(
      settings.moveEverythingStickyHoverStealFocus
    );
    if (ids.moveEverythingCloseMuxKillSetting) {
      ids.moveEverythingCloseMuxKillSetting.checked = Boolean(
        settings.moveEverythingCloseMuxKill ?? true
      );
    }
    if (ids.moveEverythingExcludePinnedWindowsSetting) {
      ids.moveEverythingExcludePinnedWindowsSetting.checked = Boolean(
        settings.moveEverythingExcludePinnedWindows
      );
    }
    if (ids.moveEverythingITermRecentActivityTimeoutSetting && ids.moveEverythingITermRecentActivityTimeoutSetting.parentElement) {
      ids.moveEverythingITermRecentActivityTimeoutSetting.parentElement.style.display = "none";
    }
    if (ids.moveEverythingITermRecentActivityBufferSetting && ids.moveEverythingITermRecentActivityBufferSetting.parentElement) {
      ids.moveEverythingITermRecentActivityBufferSetting.parentElement.style.display = "none";
    }
    if (ids.moveEverythingITermRecentActivityActiveTextSetting && ids.moveEverythingITermRecentActivityActiveTextSetting.parentElement) {
      ids.moveEverythingITermRecentActivityActiveTextSetting.parentElement.style.display = "";
    }
    if (ids.moveEverythingITermRecentActivityIdleTextSetting && ids.moveEverythingITermRecentActivityIdleTextSetting.parentElement) {
      ids.moveEverythingITermRecentActivityIdleTextSetting.parentElement.style.display = "";
    }
    if (ids.moveEverythingITermRecentActivityBadgeEnabledSetting && ids.moveEverythingITermRecentActivityBadgeEnabledSetting.parentElement) {
      ids.moveEverythingITermRecentActivityBadgeEnabledSetting.parentElement.style.display = "";
    }
    if (ids.moveEverythingITermBadgeFromTitleSetting && ids.moveEverythingITermBadgeFromTitleSetting.parentElement) {
      ids.moveEverythingITermBadgeFromTitleSetting.parentElement.style.display = "";
    }
    if (ids.moveEverythingITermTitleFromBadgeSetting && ids.moveEverythingITermTitleFromBadgeSetting.parentElement) {
      ids.moveEverythingITermTitleFromBadgeSetting.parentElement.style.display = "";
    }
    if (ids.moveEverythingITermRecentActivityColorizeSetting && ids.moveEverythingITermRecentActivityColorizeSetting.parentElement) {
      ids.moveEverythingITermRecentActivityColorizeSetting.parentElement.style.display = "";
    }
    if (ids.moveEverythingITermRecentActivityColorizeNamedOnlySetting && ids.moveEverythingITermRecentActivityColorizeNamedOnlySetting.parentElement) {
      ids.moveEverythingITermRecentActivityColorizeNamedOnlySetting.parentElement.style.display = "";
    }
    if (ids.moveEverythingITermBadgeTopMarginSetting && ids.moveEverythingITermBadgeTopMarginSetting.parentElement) {
      ids.moveEverythingITermBadgeTopMarginSetting.parentElement.style.display = "";
    }
    if (ids.moveEverythingITermBadgeRightMarginSetting && ids.moveEverythingITermBadgeRightMarginSetting.parentElement) {
      ids.moveEverythingITermBadgeRightMarginSetting.parentElement.style.display = "";
    }
  }
  ids.moveEverythingCloseHideOutsideMode.checked = Boolean(
    settings.moveEverythingCloseHideHotkeysOutsideMode
  );
  if (ids.moveEverythingMiniRetileWidthPercentSetting) {
    ids.moveEverythingMiniRetileWidthPercentSetting.value = clampInt(
      Math.round(Number(settings.moveEverythingMiniRetileWidthPercent ?? 25)),
      5,
      100
    );
  }
  if (ids.moveEverythingBackgroundRefreshIntervalSetting) {
    ids.moveEverythingBackgroundRefreshIntervalSetting.value = clampNumber(
      Number(settings.moveEverythingBackgroundRefreshInterval ?? 5),
      0.5,
      30
    );
  }
  if (ids.moveEverythingRetileOrderSetting) {
    ids.moveEverythingRetileOrderSetting.value = settings.moveEverythingRetileOrder || "leftToRight";
  }
  if (ids.moveEverythingQuickViewVerticalModeSetting) {
    ids.moveEverythingQuickViewVerticalModeSetting.value = settings.moveEverythingQuickViewVerticalMode || "fromCursor";
  }
  if (ids.moveEverythingITermGroupByRepositorySetting) {
    ids.moveEverythingITermGroupByRepositorySetting.checked = settings.moveEverythingITermGroupByRepository !== false;
  }
  if (ids.moveEverythingITermRecentActivityTimeoutSetting) {
    ids.moveEverythingITermRecentActivityTimeoutSetting.value = clampNumber(
      Number(settings.moveEverythingITermRecentActivityTimeout ?? 1),
      0,
      300
    );
  }
  if (ids.moveEverythingITermRecentActivityBufferSetting) {
    ids.moveEverythingITermRecentActivityBufferSetting.value = clampNumber(
      Number(settings.moveEverythingITermRecentActivityBuffer ?? 4),
      0,
      300
    );
  }
  if (ids.moveEverythingITermRecentActivityActiveTextSetting) {
    ids.moveEverythingITermRecentActivityActiveTextSetting.value = String(
      settings.moveEverythingITermRecentActivityActiveText ?? "[ACTIVE]"
    );
  }
  if (ids.moveEverythingITermRecentActivityIdleTextSetting) {
    ids.moveEverythingITermRecentActivityIdleTextSetting.value = String(
      settings.moveEverythingITermRecentActivityIdleText ?? ""
    );
  }
  if (ids.moveEverythingITermRecentActivityBadgeEnabledSetting) {
    ids.moveEverythingITermRecentActivityBadgeEnabledSetting.checked = Boolean(
      settings.moveEverythingITermRecentActivityBadgeEnabled
    );
  }
  if (ids.moveEverythingITermBadgeFromTitleSetting) {
    ids.moveEverythingITermBadgeFromTitleSetting.checked = Boolean(
      settings.moveEverythingITermBadgeFromTitle
    );
  }
  if (ids.moveEverythingITermTitleAllCapsSetting) {
    ids.moveEverythingITermTitleAllCapsSetting.checked = Boolean(
      settings.moveEverythingITermTitleAllCaps
    );
  }
  if (ids.moveEverythingITermTitleFromBadgeSetting) {
    ids.moveEverythingITermTitleFromBadgeSetting.checked = Boolean(
      settings.moveEverythingITermTitleFromBadge
    );
  }
  if (ids.moveEverythingITermRecentActivityColorizeSetting) {
    ids.moveEverythingITermRecentActivityColorizeSetting.checked = Boolean(
      settings.moveEverythingITermRecentActivityColorize
    );
  }
  if (ids.moveEverythingITermRecentActivityColorizeNamedOnlySetting) {
    ids.moveEverythingITermRecentActivityColorizeNamedOnlySetting.checked = Boolean(
      settings.moveEverythingITermRecentActivityColorizeNamedOnly
    );
  }
  if (ids.moveEverythingITermActivityTintIntensitySetting) {
    ids.moveEverythingITermActivityTintIntensitySetting.value = clampNumber(
      Number(settings.moveEverythingITermActivityTintIntensity ?? 0.25),
      0.05, 1
    );
  }
  if (ids.moveEverythingITermActivityHoldSecondsSetting) {
    ids.moveEverythingITermActivityHoldSecondsSetting.value = clampNumber(
      Number(settings.moveEverythingITermActivityHoldSeconds ?? 7),
      1, 60
    );
  }
  if (ids.moveEverythingITermActivityOverlayOpacitySetting) {
    ids.moveEverythingITermActivityOverlayOpacitySetting.value = clampNumber(
      Number(settings.moveEverythingITermActivityOverlayOpacity ?? 0.14),
      0, 1
    );
  }
  if (ids.moveEverythingITermActivityBackgroundTintEnabledSetting) {
    ids.moveEverythingITermActivityBackgroundTintEnabledSetting.checked = Boolean(
      settings.moveEverythingITermActivityBackgroundTintEnabled
    );
  }
  if (ids.moveEverythingITermActivityTabColorEnabledSetting) {
    ids.moveEverythingITermActivityTabColorEnabledSetting.checked = Boolean(
      settings.moveEverythingITermActivityTabColorEnabled
    );
  }
  if (ids.moveEverythingActiveWindowHighlightColorizeSetting) {
    ids.moveEverythingActiveWindowHighlightColorizeSetting.checked = Boolean(
      settings.moveEverythingActiveWindowHighlightColorize
    );
  }
  if (ids.moveEverythingActiveWindowHighlightColorSetting) {
    ids.moveEverythingActiveWindowHighlightColorSetting.value = normalizeHexColor(
      settings.moveEverythingActiveWindowHighlightColor,
      defaultMoveEverythingActiveWindowHighlightColor
    );
  }
  if (ids.moveEverythingITermRecentActivityActiveColorSetting) {
    ids.moveEverythingITermRecentActivityActiveColorSetting.value = normalizeHexColor(
      settings.moveEverythingITermRecentActivityActiveColor,
      defaultMoveEverythingITermRecentActivityActiveColor
    );
  }
  if (ids.moveEverythingITermRecentActivityIdleColorSetting) {
    ids.moveEverythingITermRecentActivityIdleColorSetting.value = normalizeHexColor(
      settings.moveEverythingITermRecentActivityIdleColor,
      defaultMoveEverythingITermRecentActivityIdleColor
    );
  }
  if (ids.moveEverythingITermRecentActivityActiveColorLightSetting) {
    ids.moveEverythingITermRecentActivityActiveColorLightSetting.value = normalizeHexColor(
      settings.moveEverythingITermRecentActivityActiveColorLight,
      defaultMoveEverythingITermRecentActivityActiveColorLight
    );
  }
  if (ids.moveEverythingITermRecentActivityIdleColorLightSetting) {
    ids.moveEverythingITermRecentActivityIdleColorLightSetting.value = normalizeHexColor(
      settings.moveEverythingITermRecentActivityIdleColorLight,
      defaultMoveEverythingITermRecentActivityIdleColorLight
    );
  }
  if (ids.moveEverythingITermBadgeTopMarginSetting) {
    ids.moveEverythingITermBadgeTopMarginSetting.value = clampInt(
      Number(settings.moveEverythingITermBadgeTopMargin ?? defaultMoveEverythingITermBadgeTopMargin),
      0,
      200
    );
  }
  if (ids.moveEverythingITermBadgeRightMarginSetting) {
    ids.moveEverythingITermBadgeRightMarginSetting.value = clampInt(
      Number(settings.moveEverythingITermBadgeRightMargin ?? defaultMoveEverythingITermBadgeRightMargin),
      0,
      200
    );
  }
  for (const field of moveEverythingHotkeyFieldOrder) {
    const preview = moveEverythingHotkeyPreviewByField[field];
    if (!preview) {
      continue;
    }
    preview.textContent = formatHotkey(settings[field]);
  }

  ids.moveEverythingRequirementsHint.classList.toggle("warning", false);
  ids.moveEverythingRequirementsHint.textContent = moveEverythingRequirementText(settings);

  const hotkeyContainer = ids.moveEverythingModal || ids.settingsModal;
  const recordButtons = hotkeyContainer ? hotkeyContainer.querySelectorAll("button[data-me-record]") : [];
  const clearButtons = hotkeyContainer ? hotkeyContainer.querySelectorAll("button[data-me-clear]") : [];
  recordButtons.forEach((button) => {
    const field = button.dataset.meRecord;
    const recording = state.recordingMoveEverythingField === field;
    button.classList.toggle("recording", recording);
    button.textContent = recording ? "Press Keys..." : "Record";
    button.disabled = Boolean(state.recordingShortcutId) && !recording;
  });
  clearButtons.forEach((button) => {
    const field = button.dataset.meClear;
    button.disabled = !Boolean(settings[field]?.key);
  });
}

function toggleMoveEverythingFromButton() {
  if (moveEverythingWorkspaceVisible()) {
    openSettingsModal("windowList");
    return;
  }
  state.selectedPlacementId = null;
  hidePlacementPreview();
  maybeEnsureMoveEverythingMode(true);
  pubsub.publish('selection');
}

function applyOptimisticMoveEverythingWindowAction(action, key) {
  if (!action || !key) {
    return false;
  }

  const inventory = state.moveEverythingWindows || { visible: [], hidden: [] };
  const visible = Array.isArray(inventory.visible) ? [...inventory.visible] : [];
  const hidden = Array.isArray(inventory.hidden) ? [...inventory.hidden] : [];
  const visibleIndex = visible.findIndex((item) => item.key === key);
  const hiddenIndex = hidden.findIndex((item) => item.key === key);

  let didMutate = false;
  if (action === "close") {
    if (visibleIndex >= 0) {
      visible.splice(visibleIndex, 1);
      didMutate = true;
    }
    if (hiddenIndex >= 0) {
      hidden.splice(hiddenIndex, 1);
      didMutate = true;
    }
    delete state.moveEverythingCustomWindowTitlesByKey[String(key)];
    delete state.moveEverythingCustomITermWindowTitlesByKey[String(key)];
    delete state.moveEverythingCustomITermWindowBadgeTextByKey[String(key)];
    delete state.moveEverythingCustomTitleStaleSince[String(key)];
  } else if (action === "hide") {
    if (visibleIndex >= 0) {
      const [windowItem] = visible.splice(visibleIndex, 1);
      if (hiddenIndex < 0) {
        hidden.unshift({
          ...windowItem,
          isCoreGraphicsFallback: true,
        });
      }
      didMutate = true;
    }
  } else if (action === "show" || action === "max" || action === "center") {
    if (hiddenIndex >= 0) {
      const [windowItem] = hidden.splice(hiddenIndex, 1);
      if (visibleIndex < 0) {
        visible.push(windowItem);
      }
      didMutate = true;
    }
  }

  if (!didMutate) {
    return false;
  }

  state.moveEverythingWindows = {
    visible,
    hidden,
    undoRetileAvailable: Boolean(inventory.undoRetileAvailable),
    savedPositionsPreviousAvailable: Boolean(inventory.savedPositionsPreviousAvailable),
    savedPositionsNextAvailable: Boolean(inventory.savedPositionsNextAvailable),
  };
  if (state.moveEverythingHoveredWindowKey === key) {
    setMoveEverythingHoveredWindow(null, { render: false, immediate: true });
  }
  return true;
}

function applyOptimisticShowAllMoveEverythingWindows() {
  const inventory = state.moveEverythingWindows || { visible: [], hidden: [] };
  const visible = Array.isArray(inventory.visible) ? [...inventory.visible] : [];
  const hidden = Array.isArray(inventory.hidden) ? [...inventory.hidden] : [];
  if (!hidden.length) {
    return false;
  }

  const visibleKeys = new Set(visible.map((item) => item.key));
  hidden.forEach((windowItem) => {
    if (!visibleKeys.has(windowItem.key)) {
      visible.push(windowItem);
      visibleKeys.add(windowItem.key);
    }
  });
  state.moveEverythingWindows = {
    visible,
    hidden: [],
    undoRetileAvailable: Boolean(inventory.undoRetileAvailable),
    savedPositionsPreviousAvailable: Boolean(inventory.savedPositionsPreviousAvailable),
    savedPositionsNextAvailable: Boolean(inventory.savedPositionsNextAvailable),
  };
  return true;
}

function performMoveEverythingWindowAction(action, key, options = {}) {
  const { render = true } = options;
  if (!action || !key) {
    return;
  }

  const didOptimisticUpdate = applyOptimisticMoveEverythingWindowAction(action, key);
  if (didOptimisticUpdate && render && moveEverythingWorkspaceVisible()) {
    renderMoveEverythingWorkspace();
  }

  if (action === "close") {
    sendToNative("moveEverythingCloseWindow", { key });
    scheduleMoveEverythingWindowActionRefresh(action);
    return;
  }

  if (action === "hide") {
    sendToNative("moveEverythingHideWindow", { key });
    scheduleMoveEverythingWindowActionRefresh(action);
    return;
  }

  if (action === "show") {
    sendToNative("moveEverythingShowWindow", { key });
    scheduleMoveEverythingWindowActionRefresh(action);
    return;
  }

  if (action === "center") {
    sendToNative("moveEverythingCenterWindow", { key });
    return;
  }

  if (action === "max") {
    sendToNative("moveEverythingMaximizeWindow", { key });
    return;
  }

  if (action === "pin") {
    pinMoveEverythingWindow(key);
    return;
  }

  if (action === "unpin") {
    unpinMoveEverythingWindow(key);
    return;
  }
}

function cancelMoveEverythingWindowActionRefreshTimers() {
  if (!Array.isArray(state.moveEverythingActionRefreshTimers)) {
    state.moveEverythingActionRefreshTimers = [];
    return;
  }
  state.moveEverythingActionRefreshTimers.forEach((timerId) => window.clearTimeout(timerId));
  state.moveEverythingActionRefreshTimers = [];
}

function scheduleMoveEverythingWindowActionRefresh(action) {
  if (!["hide", "show", "close"].includes(action)) {
    return;
  }

  cancelMoveEverythingWindowActionRefreshTimers();
  const delays = [60, 180];
  state.moveEverythingActionRefreshTimers = delays.map((delayMs) =>
    window.setTimeout(() => {
      sendToNative("requestState", { forceMoveEverythingWindowRefresh: true });
    }, delayMs)
  );
}

function scheduleMoveEverythingSavedPositionsRefresh() {
  cancelMoveEverythingWindowActionRefreshTimers();
  const delays = [180, 520];
  state.moveEverythingActionRefreshTimers = delays.map((delayMs) =>
    window.setTimeout(() => {
      sendToNative("requestState", { forceMoveEverythingWindowRefresh: true });
    }, delayMs)
  );
}

function showAllMoveEverythingWindows(options = {}) {
  const { render = true } = options;
  const didOptimisticUpdate = applyOptimisticShowAllMoveEverythingWindows();
  if (didOptimisticUpdate && render && moveEverythingWorkspaceVisible()) {
    renderMoveEverythingWorkspace();
  }
  sendToNative("moveEverythingShowAllWindows");
  scheduleMoveEverythingWindowActionRefresh("show");
}

function saveMoveEverythingWindowPositions() {
  sendToNative("moveEverythingSavePositions");
  scheduleMoveEverythingSavedPositionsRefresh();
}

function restorePreviousMoveEverythingWindowPositions() {
  sendToNative("moveEverythingRestorePreviousPositions");
  scheduleMoveEverythingSavedPositionsRefresh();
}

function restoreNextMoveEverythingWindowPositions() {
  sendToNative("moveEverythingRestoreNextPositions");
  scheduleMoveEverythingSavedPositionsRefresh();
}

function rememberMoveEverythingButtonAction(token) {
  state.moveEverythingLastButtonActionToken = token;
  state.moveEverythingLastButtonActionAt = performance.now();
}

function isDuplicateMoveEverythingButtonClick(token) {
  return state.moveEverythingLastButtonActionToken === token &&
    (performance.now() - state.moveEverythingLastButtonActionAt) < 1000;
}

function handleMoveEverythingWindowListButtonEvent(event, source) {
  const target = event.target instanceof Element ? event.target : null;
  if (!target) {
    return false;
  }

  const bulkActionButton = target.closest("button[data-me-window-bulk-action]");
  if (bulkActionButton) {
    const action = String(bulkActionButton.dataset.meWindowBulkAction || "").trim();
    const token = `bulk:${action}`;
    if (!action) {
      return true;
    }
    if (source === "click" && isDuplicateMoveEverythingButtonClick(token)) {
      event.preventDefault();
      event.stopPropagation();
      return true;
    }
    rememberMoveEverythingButtonAction(token);
    event.preventDefault();
    event.stopPropagation();
    if (action === "showAll") {
      sendJsLog("info", "moveEverythingWindowButton.bulk", `source=${source} action=${action}`);
      showAllMoveEverythingWindows();
    } else if (action === "savePositions") {
      sendJsLog("info", "moveEverythingWindowButton.bulk", `source=${source} action=${action}`);
      saveMoveEverythingWindowPositions();
    } else if (action === "restorePreviousPositions") {
      sendJsLog("info", "moveEverythingWindowButton.bulk", `source=${source} action=${action}`);
      restorePreviousMoveEverythingWindowPositions();
    } else if (action === "restoreNextPositions") {
      sendJsLog("info", "moveEverythingWindowButton.bulk", `source=${source} action=${action}`);
      restoreNextMoveEverythingWindowPositions();
    }
    return true;
  }

  const renameButton = target.closest("button[data-me-rename-window]");
  if (renameButton) {
    const key = String(renameButton.dataset.meWindowKey || "").trim();
    const token = `rename:${key}`;
    if (!key) {
      return true;
    }
    if (source === "click" && isDuplicateMoveEverythingButtonClick(token)) {
      event.preventDefault();
      event.stopPropagation();
      return true;
    }
    rememberMoveEverythingButtonAction(token);
    event.preventDefault();
    event.stopPropagation();
    sendJsLog("info", "moveEverythingWindowButton.rename", `source=${source} key=${key}`);
    renameMoveEverythingWindow(key);
    return true;
  }

  const actionButton = target.closest("button[data-me-window-action]");
  if (actionButton) {
    const action = String(actionButton.dataset.meWindowAction || "").trim();
    const key = String(actionButton.dataset.meWindowKey || "").trim();
    const token = `${action}:${key}`;
    if (!action || !key) {
      return true;
    }
    if (source === "click" && isDuplicateMoveEverythingButtonClick(token)) {
      event.preventDefault();
      event.stopPropagation();
      return true;
    }
    rememberMoveEverythingButtonAction(token);
    event.preventDefault();
    event.stopPropagation();
    sendJsLog("info", "moveEverythingWindowButton.action", `source=${source} action=${action} key=${key}`);
    performMoveEverythingWindowAction(action, key);
    return true;
  }

  return false;
}

function handleMoveEverythingWindowListRowClick(event) {
  const target = event.target instanceof Element ? event.target : null;
  if (!target || isInteractiveElement(target)) {
    return false;
  }

  const row = target.closest(".move-window-row[data-me-window-key]");
  if (!row ||
      !ids.moveEverythingWindowList.contains(row) ||
      row.dataset.meControlCenter === "1") {
    return false;
  }

  if (!row.classList.contains("hidden-window")) {
    return false;
  }

  const key = String(row.dataset.meWindowKey || "").trim();
  if (!key) {
    return false;
  }

  event.preventDefault();
  performMoveEverythingWindowAction("show", key);
  return true;
}

function updateMoveEverythingAlwaysOnTop(enabled) {
  setMoveEverythingRuntimeTogglePending("alwaysOnTop", Boolean(enabled));
  sendToNative("setMoveEverythingAlwaysOnTop", { enabled: Boolean(enabled) });
  state.moveEverythingAlwaysOnTop = Boolean(enabled);
  if (ids.moveEverythingAlwaysOnTop) {
    ids.moveEverythingAlwaysOnTop.checked = Boolean(enabled);
  }
}

function updateMoveEverythingMoveToBottom(enabled) {
  setMoveEverythingRuntimeTogglePending("moveToBottom", Boolean(enabled));
  sendToNative("setMoveEverythingMoveToBottom", { enabled: Boolean(enabled) });
  state.moveEverythingMoveToBottom = Boolean(enabled);
  if (ids.moveEverythingMoveToBottom) {
    ids.moveEverythingMoveToBottom.checked = Boolean(enabled);
  }
}

function updateMoveEverythingDontMoveVibeGrid(enabled) {
  setMoveEverythingRuntimeTogglePending("dontMoveVibeGrid", Boolean(enabled));
  sendToNative("setMoveEverythingDontMoveVibeGrid", { enabled: Boolean(enabled) });
  state.moveEverythingDontMoveVibeGrid = Boolean(enabled);
  if (ids.moveEverythingDontMoveVibeGrid) {
    ids.moveEverythingDontMoveVibeGrid.checked = Boolean(enabled);
  }
}

function toggleMoveEverythingPinMode() {
  state.moveEverythingPinMode = !state.moveEverythingPinMode;
  sendToNative("setMoveEverythingPinMode", { enabled: state.moveEverythingPinMode });
  syncMoveEverythingPinModeButton();
  pubsub.publish("moveEverything");
}

function syncMoveEverythingPinModeButton() {
  if (ids.moveEverythingPinModeBtn) {
    ids.moveEverythingPinModeBtn.classList.toggle("active", state.moveEverythingPinMode);
  }
  const pinCCToggle = document.querySelector(".move-everything-pin-cc-toggle");
  if (pinCCToggle) {
    pinCCToggle.classList.toggle("pin-mode-visible", state.moveEverythingPinMode);
  }
}

function pinMoveEverythingWindow(key) {
  if (!key) return;
  state.moveEverythingPinnedWindowKeys.add(key);
  sendToNative("pinMoveEverythingWindow", { key });
  pubsub.publish("moveEverything");
}

function unpinMoveEverythingWindow(key) {
  if (!key) return;
  state.moveEverythingPinnedWindowKeys.delete(key);
  sendToNative("unpinMoveEverythingWindow", { key });
  pubsub.publish("moveEverything");
}

function saveCurrentMoveEverythingAsDefaults() {
  sendToNative("saveControlCenterDefaults");
}

function resetMoveEverythingDefaults() {
  sendToNative("resetControlCenterDefaults");
}

function retileVisibleMoveEverythingWindows() {
  sendToNative("moveEverythingRetileVisibleWindows");
}

function miniRetileVisibleMoveEverythingWindows() {
  sendToNative("moveEverythingMiniRetileVisibleWindows");
}

function hybridRetileVisibleMoveEverythingWindows() {
  sendToNative("moveEverythingHybridRetileVisibleWindows");
}

function iTermRetileVisibleMoveEverythingWindows() {
  sendToNative("moveEverythingITermRetileVisibleWindows");
}

function nonITermRetileVisibleMoveEverythingWindows() {
  sendToNative("moveEverythingNonITermRetileVisibleWindows");
}

function undoLastMoveEverythingRetile() {
  sendToNative("moveEverythingUndoRetile");
}

function setMoveEverythingHoveredWindow(key, options = {}) {
  const { render = true, immediate = false } = options;
  const normalized = key ? String(key).trim() : "";
  const nextKey = normalized.length ? normalized : null;
  const previousKey = state.moveEverythingHoveredWindowKey;
  if (previousKey === nextKey) {
    return;
  }
  state.moveEverythingHoveredWindowKey = nextKey;
  queueMoveEverythingHoverSend(nextKey, immediate);
  if (render && moveEverythingWorkspaceVisible()) {
    const didPatchHoverRows = patchMoveEverythingHoveredRows(previousKey, nextKey);
    if (!didPatchHoverRows) {
      renderMoveEverythingWorkspace();
    }
  }
}

function moveEverythingRowByWindowKey(key) {
  if (!key || !ids.moveEverythingWindowList) {
    return null;
  }

  // Use CSS attribute selector for direct lookup instead of iterating all rows.
  const escaped = CSS.escape(key);
  return ids.moveEverythingWindowList.querySelector(`.move-window-row[data-me-window-key="${escaped}"]`);
}

function patchMoveEverythingHoveredRows(previousKey, nextKey) {
  if (!ids.moveEverythingWindowList) {
    return false;
  }

  let didPatch = false;
  const previousRow = moveEverythingRowByWindowKey(previousKey);
  if (previousRow) {
    previousRow.classList.remove("hovered");
    didPatch = true;
  }

  const nextRow = moveEverythingRowByWindowKey(nextKey);
  if (nextRow &&
      nextRow.dataset.meControlCenter !== "1") {
    nextRow.classList.add("hovered");
    didPatch = true;
  }

  return didPatch;
}

function cancelMoveEverythingHoverSendTimer() {
  if (state.moveEverythingHoverSendTimer !== null) {
    window.clearTimeout(state.moveEverythingHoverSendTimer);
    state.moveEverythingHoverSendTimer = null;
  }
}

function flushMoveEverythingHoverSend() {
  cancelMoveEverythingHoverSendTimer();
  const pendingKey = state.moveEverythingHoverPendingKey;
  state.moveEverythingHoverPendingKey = null;
  state.moveEverythingHoverLastSentAt = performance.now();
  sendToNative("moveEverythingHoverWindow", { key: pendingKey || "" });
}

function queueMoveEverythingHoverSend(nextKey, immediate) {
  state.moveEverythingHoverPendingKey = nextKey;
  if (immediate) {
    flushMoveEverythingHoverSend();
    return;
  }

  const now = performance.now();
  const elapsed = now - (state.moveEverythingHoverLastSentAt || 0);
  if (!state.moveEverythingHoverLastSentAt || elapsed >= moveEverythingHoverSendThrottleMs) {
    flushMoveEverythingHoverSend();
    return;
  }

  if (state.moveEverythingHoverSendTimer !== null) {
    return;
  }

  const wait = Math.max(0, moveEverythingHoverSendThrottleMs - elapsed);
  state.moveEverythingHoverSendTimer = window.setTimeout(() => {
    flushMoveEverythingHoverSend();
  }, wait);
}

function resolveMoveEverythingHoverKeyFromTarget(target, pointerClientY = null) {
  const list = ids.moveEverythingWindowList;
  if (!list) {
    return null;
  }
  const row = target?.closest?.(".move-window-row");
  if (row && list.contains(row)) {
    if (row.dataset.meControlCenter === "1") {
      return null;
    }
    const key = String(row.dataset.meWindowKey || "").trim();
    return key.length ? key : null;
  }
  // Pointer is inside the list but not on a row (rounded-corner gap, section
  // header, etc.). Return undefined to tell the caller to keep the current
  // hover — pointerleave handles clearing when the pointer actually leaves.
  if (list.contains(target)) {
    return undefined;
  }
  return null;
}

function resolveListHoverIDFromTarget(
  list,
  itemSelector,
  datasetKey,
  target,
  pointerClientY = null
) {
  if (!list) {
    return null;
  }

  const row = target?.closest?.(itemSelector);
  if (row && list.contains(row)) {
    const key = String(row.dataset?.[datasetKey] || "").trim();
    return key.length ? key : null;
  }

  if (!Number.isFinite(pointerClientY)) {
    return null;
  }

  const rows = [...list.querySelectorAll(itemSelector)];
  if (!rows.length) {
    return null;
  }

  const rects = rows.map((candidateRow) => candidateRow.getBoundingClientRect());
  for (let i = 0; i < rows.length; i += 1) {
    const rect = rects[i];
    const previousRect = i > 0 ? rects[i - 1] : null;
    const nextRect = i + 1 < rows.length ? rects[i + 1] : null;
    const topBoundary = previousRect ? (previousRect.bottom + rect.top) / 2 : rect.top;
    const bottomBoundary = nextRect ? (rect.bottom + nextRect.top) / 2 : rect.bottom;
    if (pointerClientY >= topBoundary && pointerClientY < bottomBoundary) {
      const key = String(rows[i].dataset?.[datasetKey] || "").trim();
      return key.length ? key : null;
    }
  }

  // Only snap to the first item if the pointer is above it (between the
  // list top and the first row). Below the last row, return null so that
  // the window list / empty state is shown instead of locking to the
  // bottom item.
  const firstRow = rows[0];
  const firstKey = String(firstRow?.dataset?.[datasetKey] || "").trim();
  if (pointerClientY < rects[0].top) {
    return firstKey.length ? firstKey : null;
  }

  return null;
}

function resolveShortcutHoverIDFromTarget(target, pointerClientY = null) {
  if (narrowModeActive()) {
    return null;
  }
  return resolveListHoverIDFromTarget(
    ids.shortcutList,
    ".shortcut-item",
    "shortcutId",
    target,
    pointerClientY
  );
}

function resolvePlacementHoverIDFromTarget(target, pointerClientY = null) {
  if (narrowModeActive()) {
    return null;
  }
  return resolveListHoverIDFromTarget(
    ids.placementList,
    ".placement-item",
    "placementId",
    target,
    pointerClientY
  );
}

function setMoveEverythingRuntimeTogglePending(key, value) {
  if (!state.moveEverythingRuntimeTogglePending || !(key in state.moveEverythingRuntimeTogglePending)) {
    return;
  }
  state.moveEverythingRuntimeTogglePending[key] = {
    value: Boolean(value),
    expiresAt: Date.now() + moveEverythingRuntimeTogglePendingMs,
  };
}

function resolveMoveEverythingRuntimeToggleValue(key, incomingValue) {
  const pending = state.moveEverythingRuntimeTogglePending?.[key];
  const incoming = Boolean(incomingValue);
  if (!pending) {
    return incoming;
  }

  if (Date.now() > pending.expiresAt) {
    state.moveEverythingRuntimeTogglePending[key] = null;
    return incoming;
  }

  if (incoming === pending.value) {
    state.moveEverythingRuntimeTogglePending[key] = null;
    return incoming;
  }

  return pending.value;
}

function updateMoveEverythingSettings() {
  if (
    !ids.moveEverythingCloseHideOutsideMode ||
    !ids.moveEverythingStartAlwaysOnTopSetting ||
    !ids.moveEverythingStickyHoverStealFocusSetting
  ) {
    return;
  }

  const settings = state.config.settings;
  settings.moveEverythingStartAlwaysOnTop = Boolean(
    ids.moveEverythingStartAlwaysOnTopSetting.checked
  );
  settings.moveEverythingStickyHoverStealFocus = Boolean(
    ids.moveEverythingStickyHoverStealFocusSetting.checked
  );
  settings.moveEverythingCloseHideHotkeysOutsideMode = Boolean(
    ids.moveEverythingCloseHideOutsideMode.checked
  );
  if (ids.moveEverythingCloseMuxKillSetting) {
    settings.moveEverythingCloseMuxKill = Boolean(
      ids.moveEverythingCloseMuxKillSetting.checked
    );
  }
  if (ids.moveEverythingExcludePinnedWindowsSetting) {
    settings.moveEverythingExcludePinnedWindows = Boolean(
      ids.moveEverythingExcludePinnedWindowsSetting.checked
    );
  }
  if (ids.moveEverythingMiniRetileWidthPercentSetting) {
    settings.moveEverythingMiniRetileWidthPercent = clampInt(
      Number(ids.moveEverythingMiniRetileWidthPercentSetting.value),
      5,
      100
    );
  }
  if (ids.moveEverythingBackgroundRefreshIntervalSetting) {
    settings.moveEverythingBackgroundRefreshInterval = clampNumber(
      Number(ids.moveEverythingBackgroundRefreshIntervalSetting.value),
      0.5,
      30
    );
  }
  if (ids.moveEverythingRetileOrderSetting) {
    settings.moveEverythingRetileOrder = ids.moveEverythingRetileOrderSetting.value || "leftToRight";
  }
  if (ids.moveEverythingQuickViewVerticalModeSetting) {
    settings.moveEverythingQuickViewVerticalMode = ids.moveEverythingQuickViewVerticalModeSetting.value || "fromCursor";
  }
  if (ids.moveEverythingITermGroupByRepositorySetting) {
    settings.moveEverythingITermGroupByRepository = Boolean(ids.moveEverythingITermGroupByRepositorySetting.checked);
  }
  if (ids.moveEverythingITermRecentActivityTimeoutSetting) {
    settings.moveEverythingITermRecentActivityTimeout = clampNumber(
      Number(ids.moveEverythingITermRecentActivityTimeoutSetting.value),
      0,
      300
    );
  }
  if (ids.moveEverythingITermRecentActivityBufferSetting) {
    settings.moveEverythingITermRecentActivityBuffer = clampNumber(
      Number(ids.moveEverythingITermRecentActivityBufferSetting.value),
      0,
      300
    );
  }
  if (ids.moveEverythingITermRecentActivityActiveTextSetting) {
    settings.moveEverythingITermRecentActivityActiveText = String(
      ids.moveEverythingITermRecentActivityActiveTextSetting.value || ""
    );
  }
  if (ids.moveEverythingITermRecentActivityIdleTextSetting) {
    settings.moveEverythingITermRecentActivityIdleText = String(
      ids.moveEverythingITermRecentActivityIdleTextSetting.value || ""
    );
  }
  if (ids.moveEverythingITermRecentActivityBadgeEnabledSetting) {
    settings.moveEverythingITermRecentActivityBadgeEnabled = Boolean(
      ids.moveEverythingITermRecentActivityBadgeEnabledSetting.checked
    );
  }
  if (ids.moveEverythingITermBadgeFromTitleSetting) {
    settings.moveEverythingITermBadgeFromTitle = Boolean(
      ids.moveEverythingITermBadgeFromTitleSetting.checked
    );
  }
  if (ids.moveEverythingITermTitleAllCapsSetting) {
    settings.moveEverythingITermTitleAllCaps = Boolean(
      ids.moveEverythingITermTitleAllCapsSetting.checked
    );
  }
  if (ids.moveEverythingITermTitleFromBadgeSetting) {
    settings.moveEverythingITermTitleFromBadge = Boolean(
      ids.moveEverythingITermTitleFromBadgeSetting.checked
    );
  }
  if (ids.moveEverythingITermRecentActivityColorizeSetting) {
    settings.moveEverythingITermRecentActivityColorize = Boolean(
      ids.moveEverythingITermRecentActivityColorizeSetting.checked
    );
  }
  if (ids.moveEverythingITermRecentActivityColorizeNamedOnlySetting) {
    settings.moveEverythingITermRecentActivityColorizeNamedOnly = Boolean(
      ids.moveEverythingITermRecentActivityColorizeNamedOnlySetting.checked
    );
  }
  if (ids.moveEverythingITermActivityTintIntensitySetting) {
    settings.moveEverythingITermActivityTintIntensity = clampNumber(
      Number(ids.moveEverythingITermActivityTintIntensitySetting.value),
      0.05, 1
    );
  }
  if (ids.moveEverythingITermActivityHoldSecondsSetting) {
    settings.moveEverythingITermActivityHoldSeconds = clampNumber(
      Number(ids.moveEverythingITermActivityHoldSecondsSetting.value),
      1, 60
    );
  }
  if (ids.moveEverythingITermActivityOverlayOpacitySetting) {
    settings.moveEverythingITermActivityOverlayOpacity = clampNumber(
      Number(ids.moveEverythingITermActivityOverlayOpacitySetting.value),
      0, 1
    );
  }
  if (ids.moveEverythingITermActivityBackgroundTintEnabledSetting) {
    settings.moveEverythingITermActivityBackgroundTintEnabled = Boolean(
      ids.moveEverythingITermActivityBackgroundTintEnabledSetting.checked
    );
  }
  if (ids.moveEverythingITermActivityTabColorEnabledSetting) {
    settings.moveEverythingITermActivityTabColorEnabled = Boolean(
      ids.moveEverythingITermActivityTabColorEnabledSetting.checked
    );
  }
  if (ids.moveEverythingActiveWindowHighlightColorizeSetting) {
    settings.moveEverythingActiveWindowHighlightColorize = Boolean(
      ids.moveEverythingActiveWindowHighlightColorizeSetting.checked
    );
  }
  if (ids.moveEverythingActiveWindowHighlightColorSetting) {
    settings.moveEverythingActiveWindowHighlightColor = normalizeHexColor(
      ids.moveEverythingActiveWindowHighlightColorSetting.value,
      defaultMoveEverythingActiveWindowHighlightColor
    );
  }
  if (ids.moveEverythingITermRecentActivityActiveColorSetting) {
    settings.moveEverythingITermRecentActivityActiveColor = normalizeHexColor(
      ids.moveEverythingITermRecentActivityActiveColorSetting.value,
      defaultMoveEverythingITermRecentActivityActiveColor
    );
  }
  if (ids.moveEverythingITermRecentActivityIdleColorSetting) {
    settings.moveEverythingITermRecentActivityIdleColor = normalizeHexColor(
      ids.moveEverythingITermRecentActivityIdleColorSetting.value,
      defaultMoveEverythingITermRecentActivityIdleColor
    );
  }
  if (ids.moveEverythingITermRecentActivityActiveColorLightSetting) {
    settings.moveEverythingITermRecentActivityActiveColorLight = normalizeHexColor(
      ids.moveEverythingITermRecentActivityActiveColorLightSetting.value,
      defaultMoveEverythingITermRecentActivityActiveColorLight
    );
  }
  if (ids.moveEverythingITermRecentActivityIdleColorLightSetting) {
    settings.moveEverythingITermRecentActivityIdleColorLight = normalizeHexColor(
      ids.moveEverythingITermRecentActivityIdleColorLightSetting.value,
      defaultMoveEverythingITermRecentActivityIdleColorLight
    );
  }
  if (ids.moveEverythingITermBadgeTopMarginSetting) {
    settings.moveEverythingITermBadgeTopMargin = clampInt(
      Number(ids.moveEverythingITermBadgeTopMarginSetting.value),
      0,
      200
    );
  }
  if (ids.moveEverythingITermBadgeRightMarginSetting) {
    settings.moveEverythingITermBadgeRightMargin = clampInt(
      Number(ids.moveEverythingITermBadgeRightMarginSetting.value),
      0,
      200
    );
  }
  state.config.settings = normalizeSettings(settings);
  markDirty();
  renderMoveEverythingButton();
  renderMoveEverythingModal();
  renderMoveEverythingWorkspace();
}

function renderShortcutList() {
  // Skip re-render during drag-reorder — rebuilding the list would duplicate
  // the dragged item (which lives on document.body while its list slot has a placeholder).
  if (state.listReorderDrag && state.listReorderDrag.active) {
    return;
  }
  ids.shortcutList.innerHTML = "";
  const issues = effectiveHotKeyIssues();

  if (!state.config.shortcuts.length) {
    ids.shortcutList.innerHTML = '<p class="empty-list">No shortcuts yet.</p>';
    return;
  }

  const fragment = document.createDocumentFragment();

  state.config.shortcuts.forEach((shortcut) => {
    const item = document.createElement("div");
    const isSelected = shortcut.id === state.selectedShortcutId;
    const isHovered = shortcut.id === state.hoveredShortcutId;
    item.className = `shortcut-item ${isSelected ? "active" : ""} ${isHovered ? "hovered" : ""} ${shortcut.enabled ? "" : "disabled"}`;
    item.dataset.shortcutId = shortcut.id;

    const left = document.createElement("div");
    left.className = "placement-meta-text";

    const title = document.createElement("h4");
    title.textContent = shortcut.name || "Untitled";
    const subtitle = document.createElement("p");
    const stateLabel = shortcut.enabled ? "" : " • Disabled";
    const shortcutScopeLabel = shortcut.controlCenterOnly
      ? "control center only"
      : `${shortcut.placements.length} step${shortcut.placements.length === 1 ? "" : "s"}`;
    const retileLabel = shortcut.useForRetiling && shortcut.useForRetiling !== "no"
      ? ` • retile: ${shortcut.useForRetiling}`
      : "";
    subtitle.textContent = `${formatHotkey(shortcut.hotkey)} • ${shortcutScopeLabel}${retileLabel}${stateLabel}`;

    left.appendChild(title);
    left.appendChild(subtitle);

    const right = document.createElement("div");
    right.className = "shortcut-row-actions";

    const hasIssue = issues.some((issue) => issue.shortcutID === shortcut.id);
    if (hasIssue) {
      const dot = document.createElement("span");
      dot.className = "shortcut-issue-dot";
      dot.title = "Shortcut has registration issue";
      right.appendChild(dot);
    }

    const index = state.config.shortcuts.findIndex((entry) => entry.id === shortcut.id);
    const up = iconActionButton("▲", "move-shortcut-up", shortcut.id, index === 0);
    const down = iconActionButton("▼", "move-shortcut-down", shortcut.id, index === state.config.shortcuts.length - 1);
    right.appendChild(up);
    right.appendChild(down);

    item.appendChild(left);
    item.appendChild(right);
    fragment.appendChild(item);
  });

  ids.shortcutList.appendChild(fragment);
}

function renderShortcutEditor() {
  const shortcut = selectedShortcut();
  const hasShortcut = Boolean(shortcut);
  const massRecording = isMassRecordingActive();

  ids.emptyState.classList.toggle("hidden", hasShortcut);
  ids.editorContent.classList.toggle("hidden", !hasShortcut);

  if (!shortcut) {
    if (ids.massHotkeyCaptureBtn) {
      ids.massHotkeyCaptureBtn.textContent = "Record All Hotkeys";
      ids.massHotkeyCaptureBtn.classList.remove("recording");
      ids.massHotkeyCaptureBtn.disabled = state.config.shortcuts.length === 0;
    }
    return;
  }

  ids.shortcutName.value = shortcut.name || "";
  ids.hotkeyPreview.textContent = formatHotkey(shortcut.hotkey);
  ids.toggleShortcutEnabledBtn.textContent = shortcut.enabled ? "Disable" : "Enable";
  ids.toggleShortcutEnabledBtn.classList.toggle("danger", !shortcut.enabled);
  ids.toggleShortcutEnabledBtn.classList.toggle("ghost", shortcut.enabled);
  ids.cycleDisplaysOnWrap.checked = Boolean(shortcut.cycleDisplaysOnWrap);
  ids.controlCenterOnly.checked = Boolean(shortcut.controlCenterOnly);
  const excludePinnedEnabled = Boolean(state.config.settings.moveEverythingExcludePinnedWindows);
  ids.ignoreExcludePinnedWindows.checked = Boolean(shortcut.ignoreExcludePinnedWindows);
  ids.ignoreExcludePinnedWindows.disabled = !excludePinnedEnabled;
  ids.ignoreExcludePinnedWindows.closest("label").classList.toggle("disabled", !excludePinnedEnabled);
  const useForRetilingSelect = document.getElementById("useForRetiling");
  if (useForRetilingSelect) {
    useForRetilingSelect.value = shortcut.useForRetiling || "no";
  }
  renderUseForRetilingError();
  ids.settingGridCols.value = clampInt(state.config.settings.defaultGridColumns, 1, 24);
  ids.settingGridRows.value = clampInt(state.config.settings.defaultGridRows, 1, 20);
  ids.settingGap.value = clampInt(state.config.settings.gap, 0, 80);
  ids.settingDefaultCycleDisplaysOnWrap.checked = Boolean(
    state.config.settings.defaultCycleDisplaysOnWrap
  );
  syncThemeModeSelect(state.config.settings.themeMode);
  renderControlCenterScaleInput();

  const recording = state.recordingShortcutId === shortcut.id;
  ids.hotkeyCaptureBtn.classList.toggle("recording", recording);
  ids.hotkeyCaptureBtn.disabled = massRecording && !recording;
  ids.hotkeyCaptureBtn.textContent = recording ? "Press Keys..." : "Record";

  if (ids.massHotkeyCaptureBtn) {
    if (massRecording) {
      const progress = Math.min(
        state.massRecordingOrder.length,
        Math.max(0, state.massRecordingIndex + 1)
      );
      ids.massHotkeyCaptureBtn.textContent = `Stop (${progress}/${state.massRecordingOrder.length})`;
    } else {
      ids.massHotkeyCaptureBtn.textContent = "Record All Hotkeys";
    }
    ids.massHotkeyCaptureBtn.classList.toggle("recording", massRecording);
    ids.massHotkeyCaptureBtn.disabled = state.config.shortcuts.length === 0;
  }
}

function renderPlacementList() {
  if (state.listReorderDrag && state.listReorderDrag.active) {
    return;
  }
  ids.placementList.innerHTML = "";

  const shortcut = displayShortcut();
  if (!shortcut) {
    return;
  }

  const fragment = document.createDocumentFragment();

  shortcut.placements.forEach((placement, index) => {
    const item = document.createElement("div");
    const isActive = placement.id === state.selectedPlacementId && state.selectedShortcutId === shortcut.id;
    const isHovered = placement.id === state.hoveredPlacementId;
    item.className = `placement-item ${isActive ? "active" : ""} ${isHovered ? "hovered" : ""}`;
    item.dataset.placementId = placement.id;

    const left = document.createElement("div");
    left.className = "placement-meta-text";

    const title = document.createElement("strong");
    title.textContent = `${index + 1}. ${placementDisplayTitle(placement)}`;

    const detail = document.createElement("small");
    detail.textContent = `${placement.display} target`;

    left.appendChild(title);
    left.appendChild(detail);

    const right = document.createElement("div");
    right.className = "placement-row-actions";

    const badge = document.createElement("span");
    badge.className = "placement-mode";
    badge.textContent = placement.mode;

    const up = iconActionButton("▲", "move-up", placement.id, index === 0);
    const down = iconActionButton("▼", "move-down", placement.id, index === shortcut.placements.length - 1);

    right.appendChild(badge);
    right.appendChild(up);
    right.appendChild(down);

    item.appendChild(left);
    item.appendChild(right);

    fragment.appendChild(item);
  });

  ids.placementList.appendChild(fragment);
}

function renderPlacementEditor() {
  const { placement, readOnly } = displayPlacementContext();

  ids.placementEditor.classList.toggle("hidden", !placement);
  ids.placementEditorEmpty.classList.add("hidden");

  if (!placement) {
    hidePlacementPreview();
    return;
  }

  ids.placementEditor.classList.toggle("preview-only", readOnly);
  ids.placementTitle.value = placement.title || "";
  ids.displayTarget.value = placement.display || "active";
  ids.placementTitle.disabled = readOnly;
  ids.displayTarget.disabled = readOnly;

  ids.modeGridBtn.classList.toggle("active", placement.mode === "grid");
  ids.modeFreeBtn.classList.toggle("active", placement.mode === "freeform");
  ids.modeGridBtn.disabled = readOnly;
  ids.modeFreeBtn.disabled = readOnly;
  if (ids.removePlacementBtn) {
    ids.removePlacementBtn.disabled = readOnly;
  }

  ids.gridEditor.classList.toggle("hidden", placement.mode !== "grid");
  ids.freeEditor.classList.toggle("hidden", placement.mode !== "freeform");

  if (placement.mode === "grid") {
    const grid = ensureGrid(placement);
    ids.gridCols.value = grid.columns;
    ids.gridRows.value = grid.rows;
    ids.gridCols.disabled = readOnly;
    ids.gridRows.disabled = readOnly;
    ids.gridCanvas.style.pointerEvents = readOnly ? "none" : "";
    renderGridCanvas(placement);
  } else {
    const rect = ensureRect(placement);
    ids.freeX.value = rect.x;
    ids.freeY.value = rect.y;
    ids.freeW.value = rect.width;
    ids.freeH.value = rect.height;
    ids.freeX.disabled = readOnly;
    ids.freeY.disabled = readOnly;
    ids.freeW.disabled = readOnly;
    ids.freeH.disabled = readOnly;
    ids.freeCanvas.style.pointerEvents = readOnly ? "none" : "";
    syncFreeLabels(rect);
    syncFreeCanvas(rect);
  }
}

function renderMoveEverythingWorkspace() {
  if (!ids.moveEverythingWorkspace || !ids.moveEverythingWindowList) {
    return;
  }
  const renderStartedAt = performance.now();

  // In narrow mode, hide workspace when editing a placement (needs full width).
  // In wide mode, always show — the window list coexists with the shortcut editor.
  const narrowMode = state.moveEverythingNarrowMode === true;
  const showWorkspace = narrowMode ? moveEverythingWorkspaceVisible() : true;
  ids.moveEverythingWorkspace.classList.toggle("hidden", !showWorkspace);
  if (!showWorkspace) {
    if (state.moveEverythingHoveredWindowKey) {
      setMoveEverythingHoveredWindow(null, { render: false, immediate: true });
    }
    return;
  }

  // Ensure move-everything mode is active so Swift populates the window inventory.
  // Not forced — the rate limiter prevents re-sending within 1.2s.
  maybeEnsureMoveEverythingMode();

  if (window.vibeGridPlatform && window.vibeGridPlatform.noNativeFeatures) {
    if (ids.moveEverythingNativeOnlyControls) ids.moveEverythingNativeOnlyControls.style.display = "none";
  } else {
    if (ids.moveEverythingNativeOnlyControls) ids.moveEverythingNativeOnlyControls.style.display = "";
    if (ids.moveEverythingAlwaysOnTop) {
      ids.moveEverythingAlwaysOnTop.checked = Boolean(state.moveEverythingAlwaysOnTop);
    }
    if (ids.moveEverythingMoveToBottom) {
      ids.moveEverythingMoveToBottom.checked = Boolean(state.moveEverythingMoveToBottom);
    }
    if (ids.moveEverythingDontMoveVibeGrid) {
      ids.moveEverythingDontMoveVibeGrid.checked = Boolean(state.moveEverythingDontMoveVibeGrid);
    }
    syncMoveEverythingPinModeButton();
  }

  const inventory = state.moveEverythingWindows || { visible: [], hidden: [] };
  if (ids.moveEverythingUndoRetileBtn) {
    ids.moveEverythingUndoRetileBtn.disabled = !Boolean(inventory.undoRetileAvailable);
  }
  state.moveEverythingActionButtonsCompact = moveEverythingActionCompactModeActive();
  const allVisible = Array.isArray(inventory.visible)
    ? [...inventory.visible].sort(compareMoveEverythingVisibleWindowsByAppThenTitle)
    : [];
  const allHidden = Array.isArray(inventory.hidden)
    ? inventory.hidden.filter((w) => w.canRestore !== false)
    : [];
  pruneMoveEverythingCustomWindowTitles(allVisible, allHidden);

  const namedVisibleWindows = allVisible.filter((w) => hasMoveEverythingCustomWindowTitle(w));
  const namedHiddenWindows = allHidden.filter((w) => hasMoveEverythingCustomWindowTitle(w));
  const visibleWindows = allVisible.filter((w) => !hasMoveEverythingCustomWindowTitle(w));
  const hiddenWindows = allHidden.filter((w) => !hasMoveEverythingCustomWindowTitle(w));
  const namedITermVisibleWindows = namedVisibleWindows.filter((w) => isLikelyITermWindow(w));
  const namedITermHiddenWindows = namedHiddenWindows.filter((w) => isLikelyITermWindow(w));
  const iTermVisibleWindows = visibleWindows.filter((w) => isLikelyITermWindow(w));
  const iTermHiddenWindows = hiddenWindows.filter((w) => isLikelyITermWindow(w));
  const namedOtherVisibleWindows = namedVisibleWindows.filter((w) => !isLikelyITermWindow(w));
  const namedOtherHiddenWindows = namedHiddenWindows.filter((w) => !isLikelyITermWindow(w));
  const otherVisibleWindows = visibleWindows.filter((w) => !isLikelyITermWindow(w));
  const otherHiddenWindows = hiddenWindows.filter((w) => !isLikelyITermWindow(w));
  const namedCount = namedVisibleWindows.length + namedHiddenWindows.length;
  const namedITermCount = namedITermVisibleWindows.length + namedITermHiddenWindows.length;
  const iTermCount = iTermVisibleWindows.length + iTermHiddenWindows.length;

  if (state.moveEverythingHoveredWindowKey &&
      !allVisible.some((windowItem) => windowItem.key === state.moveEverythingHoveredWindowKey) &&
      !allHidden.some((windowItem) => windowItem.key === state.moveEverythingHoveredWindowKey)) {
    setMoveEverythingHoveredWindow(null, { render: false, immediate: true });
  }
  ids.moveEverythingWindowList.innerHTML = "";

  const fragment = document.createDocumentFragment();

  function appendMoveEverythingSection(titleText, visibleItems, hiddenItems, emptyText) {
    const totalCount = visibleItems.length + hiddenItems.length;
    if (!totalCount && !emptyText) {
      return;
    }
    const section = document.createElement("section");
    section.className = "move-window-section";
    const title = document.createElement("h4");
    title.textContent = `${titleText} (${totalCount})`;
    section.appendChild(title);
    if (!totalCount) {
      const empty = document.createElement("p");
      empty.className = "move-window-empty";
      empty.textContent = emptyText;
      section.appendChild(empty);
      fragment.appendChild(section);
      return;
    }
    visibleItems.forEach((windowItem) => {
      const rowHovered = !windowItem.isControlCenter &&
        state.moveEverythingHoveredWindowKey === windowItem.key;
      const rowFocused = !windowItem.isControlCenter &&
        state.moveEverythingFocusedWindowKey === windowItem.key;
      section.appendChild(
        buildMoveEverythingWindowRow(windowItem, {
          hovered: rowHovered,
          focused: rowFocused,
          hidden: false,
        })
      );
    });
    hiddenItems.forEach((windowItem) => {
      const rowHovered = !windowItem.isControlCenter &&
        state.moveEverythingHoveredWindowKey === windowItem.key;
      section.appendChild(
        buildMoveEverythingWindowRow(windowItem, {
          hovered: rowHovered,
          hidden: true,
        })
      );
    });
    fragment.appendChild(section);
  }

  if (namedITermCount > 0) {
    appendMoveEverythingSection(
      "Named iTerm",
      namedITermVisibleWindows,
      namedITermHiddenWindows
    );
  }

  if (iTermCount > 0) {
    appendMoveEverythingSection(
      "iTerm",
      iTermVisibleWindows,
      iTermHiddenWindows
    );
  }

  if (namedCount - namedITermCount > 0) {
    appendMoveEverythingSection(
      "Named Windows",
      namedOtherVisibleWindows,
      namedOtherHiddenWindows
    );
  }

  appendMoveEverythingSection(
    "Visible Windows",
    otherVisibleWindows,
    [],
    "No visible windows."
  );

  appendMoveEverythingSection(
    "Hidden Windows",
    [],
    otherHiddenWindows,
    "No hidden windows."
  );

  if (allHidden.length > 0) {
    const bulkActions = document.createElement("div");
    bulkActions.className = "move-window-bulk-actions";
    const showAllBtn = document.createElement("button");
    showAllBtn.type = "button";
    showAllBtn.className = "btn primary move-everything-bulk-btn";
    showAllBtn.textContent = "Show All";
    showAllBtn.dataset.meWindowBulkAction = "showAll";
    bulkActions.appendChild(showAllBtn);
    fragment.appendChild(bulkActions);
  }

  const savedPositionsActions = document.createElement("div");
  savedPositionsActions.className = "move-window-bulk-actions";

  const previousBtn = document.createElement("button");
  previousBtn.type = "button";
  previousBtn.className = "btn move-everything-bulk-btn";
  previousBtn.textContent = "Previous";
  previousBtn.dataset.meWindowBulkAction = "restorePreviousPositions";
  previousBtn.disabled = !state.moveEverythingWindows?.savedPositionsPreviousAvailable;
  savedPositionsActions.appendChild(previousBtn);

  const nextBtn = document.createElement("button");
  nextBtn.type = "button";
  nextBtn.className = "btn move-everything-bulk-btn";
  nextBtn.textContent = "Next";
  nextBtn.dataset.meWindowBulkAction = "restoreNextPositions";
  nextBtn.disabled = !state.moveEverythingWindows?.savedPositionsNextAvailable;
  savedPositionsActions.appendChild(nextBtn);

  const saveBtn = document.createElement("button");
  saveBtn.type = "button";
  saveBtn.className = "btn primary move-everything-bulk-btn";
  saveBtn.textContent = "Save";
  saveBtn.dataset.meWindowBulkAction = "savePositions";
  saveBtn.disabled = visibleWindows.length === 0;
  savedPositionsActions.appendChild(saveBtn);

  fragment.appendChild(savedPositionsActions);

  ids.moveEverythingWindowList.appendChild(fragment);
  applyMoveEverythingTitleSizing();

  const elapsed = performance.now() - renderStartedAt;
  if (elapsed >= moveEverythingPerfLogThresholdMs) {
    sendJsLog(
      "info",
      "perf.renderMoveEverythingWorkspace",
      `ms=${elapsed.toFixed(1)} named=${namedCount} visible=${visibleWindows.length} hidden=${hiddenWindows.length}`
    );
  }
}

function applyMoveEverythingTitleSizing() {
  if (!ids.moveEverythingWindowList) {
    return;
  }

  const startedAt = performance.now();
  _titleFontCacheByClass = {}; // Reset so the first element of each class re-samples getComputedStyle
  const titleElements = ids.moveEverythingWindowList.querySelectorAll(".move-window-copy strong");

  // Phase 1: Batch-read all layout measurements to avoid read/write thrashing.
  // Reset text content and read widths before any truncation writes.
  const entries = [];
  for (const element of titleElements) {
    if (!(element instanceof HTMLElement)) {
      continue;
    }
    const fullTitle = String(
      element.dataset.fullTitle ||
      element.textContent ||
      ""
    );
    element.textContent = fullTitle;
    element.classList.remove("title-short", "title-long", "title-truncated");
    if (!fullTitle) {
      continue;
    }
    const textLength = fullTitle.trim().length;
    if (textLength <= 22) {
      element.classList.add("title-short");
    } else if (textLength >= 52) {
      element.classList.add("title-long");
    }
    const copyElement = element.closest(".move-window-copy");
    const referenceWidth = Math.max(
      (copyElement instanceof HTMLElement ? copyElement.clientWidth : element.clientWidth),
      1
    );
    entries.push({ element, fullTitle, referenceWidth });
  }

  // Phase 2: Batch-write truncation results (no more layout reads).
  for (const { element, fullTitle, referenceWidth } of entries) {
    const availableWidth = Math.max(
      0,
      referenceWidth - moveEverythingTitleTruncatePaddingPx
    );
    if (availableWidth <= 0) {
      element.textContent = moveEverythingTitleEllipsis;
      element.classList.add("title-truncated");
      element.title = fullTitle;
      continue;
    }

    const truncated = truncateMoveEverythingTitleByPixels(fullTitle, availableWidth, element);
    if (truncated !== fullTitle) {
      element.textContent = truncated;
      element.classList.add("title-truncated");
      element.title = fullTitle;
    } else {
      element.title = "";
    }
  }

  const elapsed = performance.now() - startedAt;
  if (elapsed >= moveEverythingPerfLogThresholdMs) {
    sendJsLog("info", "perf.applyMoveEverythingTitleSizing", `ms=${elapsed.toFixed(1)}`);
  }
}

function titleMeasureContext() {
  if (!moveEverythingTitleMeasureCanvas) {
    moveEverythingTitleMeasureCanvas = document.createElement("canvas");
  }
  return moveEverythingTitleMeasureCanvas.getContext("2d");
}

// Cache for computed font styles to avoid repeated getComputedStyle calls
// during a single title sizing pass. Keyed by font-size class since
// title-short (14px) and title-long (11px) have different sizes.
let _titleFontCacheByClass = {};

function measureTitleTextWidth(text, element) {
  const context = titleMeasureContext();
  if (!context) {
    return Number.MAX_SAFE_INTEGER;
  }
  const sizeClass = element.classList.contains("title-long") ? "long"
    : element.classList.contains("title-short") ? "short" : "default";
  let cached = _titleFontCacheByClass[sizeClass];
  if (!cached) {
    const style = window.getComputedStyle(element);
    cached = { font: style.font, letterSpacing: style.letterSpacing };
    _titleFontCacheByClass[sizeClass] = cached;
  }
  context.font = cached.font;
  context.letterSpacing = cached.letterSpacing;
  return context.measureText(text).width;
}

function truncateMoveEverythingTitleByPixels(fullTitle, maxWidthPx, element) {
  if (!fullTitle) {
    return "";
  }
  const fullWidth = measureTitleTextWidth(fullTitle, element);
  if (fullWidth <= maxWidthPx) {
    return fullTitle;
  }

  const ellipsisWidth = measureTitleTextWidth(moveEverythingTitleEllipsis, element);
  if (ellipsisWidth >= maxWidthPx) {
    return moveEverythingTitleEllipsis;
  }

  let low = 0;
  let high = fullTitle.length;
  let best = "";
  while (low <= high) {
    const mid = Math.floor((low + high) / 2);
    const candidateBase = fullTitle.slice(0, mid).trimEnd();
    const candidate = `${candidateBase}${moveEverythingTitleEllipsis}`;
    const candidateWidth = measureTitleTextWidth(candidate, element);
    if (candidateWidth <= maxWidthPx) {
      best = candidate;
      low = mid + 1;
    } else {
      high = mid - 1;
    }
  }

  return best || moveEverythingTitleEllipsis;
}

function titleContainsStatusMarker(rawTitle, markerText) {
  const marker = String(markerText ?? "").trim();
  if (!marker.length) {
    return false;
  }
  const title = String(rawTitle || "").trim();
  if (!title.length) {
    return false;
  }
  const normalizedTitle = title.toLowerCase();
  const normalizedMarker = marker.toLowerCase();
  return normalizedTitle === normalizedMarker || normalizedTitle.includes(normalizedMarker);
}

function isLikelyITermWindow(windowItem) {
  const appName = String(windowItem?.appName || "").trim().toLowerCase();
  return appName === "iterm2" || appName === "iterm";
}

function stripLeadingMarkerToken(title, marker) {
  const markerText = String(marker ?? "").trim();
  if (!markerText.length) {
    return title;
  }

  const normalizedTitle = String(title || "");
  if (!normalizedTitle.length) {
    return normalizedTitle;
  }

  const lowerTitle = normalizedTitle.toLowerCase();
  const lowerMarker = markerText.toLowerCase();
  if (!lowerTitle.startsWith(lowerMarker)) {
    return normalizedTitle;
  }

  const suffix = normalizedTitle.slice(markerText.length).replace(/^[\s\-:|•]+/u, "");
  return suffix.trimStart();
}

function stripMoveEverythingStatusMarkersForDisplay(rawTitle, windowItem) {
  const title = String(rawTitle || "").trim();
  if (!title.length || !isLikelyITermWindow(windowItem)) {
    return title;
  }

  const settings = state.config?.settings || {};
  const knownMarkers = [
    settings.moveEverythingITermRecentActivityActiveText,
    settings.moveEverythingITermRecentActivityIdleText,
    "[ACTIVE]",
    "[IDLE]",
  ]
    .map((item) => String(item || "").trim())
    .filter((item) => item.length > 0);

  let current = title;
  for (let i = 0; i < 8; i += 1) {
    let stripped = false;

    for (const marker of knownMarkers) {
      const next = stripLeadingMarkerToken(current, marker);
      if (next !== current) {
        current = next;
        stripped = true;
        break;
      }
    }

    if (!stripped) {
      // Unwrap one level of outer brackets when nesting is present.
      // e.g. [[mux] move focus] → [mux] move focus
      // Do NOT strip arbitrary [brackets] — only known markers above.
      const trimmed = current.trimStart();
      if (trimmed.startsWith("[")) {
        let depth = 0;
        let end = -1;
        let hasNested = false;
        for (let j = 0; j < trimmed.length && j < 64; j++) {
          if (trimmed[j] === "[") {
            depth++;
            if (depth > 1) hasNested = true;
          } else if (trimmed[j] === "]") {
            depth--;
            if (depth === 0) { end = j; break; }
          }
        }
        if (end > 0 && hasNested) {
          current = (trimmed.slice(1, end) + trimmed.slice(end + 1)).trimStart();
        }
      }
      break; // no known marker matched — stop stripping
    }

    if (!stripped) {
      break;
    }
  }

  return current.trim().length ? current.trim() : "Untitled Window";
}


function resolveMoveEverythingWindowActivityStatus(windowItem) {
  const settings = state.config?.settings || {};
  const activeText = String(settings.moveEverythingITermRecentActivityActiveText || "").trim();
  const idleText = String(settings.moveEverythingITermRecentActivityIdleText || "").trim();
  const rawTitle = String(windowItem?.title || "").trim();

  if (!rawTitle.length) {
    return "unknown";
  }
  // For iTerm windows: prefer the enriched activity status from the Swift
  // layer. Fall through to raw-title markers only when the enriched status
  // is unavailable.
  if (isLikelyITermWindow(windowItem)) {
    const status = windowItem.iTermActivityStatus;
    if (status === "active" || status === "idle") {
      return status;
    }
  }
  // Explicit title markers as fallback
  if (titleContainsStatusMarker(rawTitle, activeText)) {
    return "active";
  }
  if (titleContainsStatusMarker(rawTitle, idleText)) {
    return "idle";
  }
  if (titleContainsStatusMarker(rawTitle, "[ACTIVE]")) {
    return "active";
  }
  if (titleContainsStatusMarker(rawTitle, "[IDLE]")) {
    return "idle";
  }
  if (isLikelyITermWindow(windowItem)) {
    return "unknown";
  }
  return "unknown";
}


function resolveMoveEverythingDisplayedWindowTitle(windowItem) {
  const key = String(windowItem?.key || "").trim();
  const renamed = isLikelyITermWindow(windowItem)
    ? (key ? state.moveEverythingCustomITermWindowTitlesByKey[key] : "")
    : (key ? state.moveEverythingCustomWindowTitlesByKey[key] : "");
  if (typeof renamed === "string" && renamed.trim().length) {
    return renamed.trim();
  }
  // Use badge text as title for iTerm windows when the setting is enabled
  if (isLikelyITermWindow(windowItem) && state.config?.settings?.moveEverythingITermTitleFromBadge) {
    const badge = String(windowItem?.iTermBadgeText || "").trim();
    if (badge.length) {
      return badge;
    }
  }
  // Prefer the stripped raw AX title — it contains the full context
  // (e.g. "[global] window overlay") rather than just the bare session name.
  const rawTitle = String(windowItem?.title || "");
  const strippedTitle = stripMoveEverythingStatusMarkersForDisplay(rawTitle, windowItem);
  if (strippedTitle.length && strippedTitle !== "Untitled Window") {
    return strippedTitle;
  }
  // Fall back to session/tmux name or iTerm API window name
  const sessionName = String(windowItem?.iTermSessionName || "").trim();
  if (sessionName.length) {
    return sessionName;
  }
  const iTermName = String(windowItem?.iTermWindowName || "").trim();
  if (iTermName.length) {
    return iTermName;
  }
  return strippedTitle;
}

function resolveMoveEverythingWindowSubtitle(windowItem) {
  const isCoreGraphicsFallback = Boolean(windowItem?.isCoreGraphicsFallback);
  if (isCoreGraphicsFallback) {
    const key = String(windowItem?.key || "");
    const match = key.match(/(?:-cg-|-)(\d+)$/);
    const fallbackLabel = (!match || !match[1]) ? "Window" : `Window ${match[1]}`;
    return `${fallbackLabel} • ${key} • CG fallback`;
  }

  const appName = String(windowItem?.appName || "App").trim() || "App";
  if (isLikelyITermWindow(windowItem)) {
    const profileID = String(windowItem?.iTermProfileID || "").trim().toLowerCase();
    const baseProfile = profileID.split("+")[0];
    if (baseProfile === "claude-code") {
      return "Claude Code";
    }
    if (baseProfile === "codex") {
      return "Codex";
    }
    const displayedTitle = resolveMoveEverythingDisplayedWindowTitle(windowItem);
    const lowerTitle = displayedTitle.toLowerCase();
    const paneCommand = String(windowItem?.iTermPaneCommand || "").trim();
    const panePath = String(windowItem?.iTermPanePath || "").trim();
    const shortPath = panePath.startsWith("/Users/") ? "~" + panePath.slice(panePath.indexOf("/", 7)) : panePath;
    const isShell = !paneCommand || ["zsh", "-zsh", "bash", "-bash", "fish", "login"].includes(paneCommand);
    if (!isShell && shortPath) {
      return `${paneCommand} · ${shortPath}`;
    }
    if (!isShell) {
      return paneCommand;
    }
    if (shortPath) {
      return shortPath;
    }
    // Fallback: show something complementary to the title, not a repeat of it
    const candidates = [
      String(windowItem?.iTermSessionName || "").trim(),
      String(windowItem?.iTermWindowName || "").trim(),
      stripMoveEverythingStatusMarkersForDisplay(
        String(windowItem?.title || ""), windowItem
      ),
    ];
    for (const candidate of candidates) {
      if (candidate.length && candidate !== displayedTitle && candidate !== "Untitled Window"
          && !lowerTitle.includes(candidate.toLowerCase())
          && !candidate.toLowerCase().includes(lowerTitle)) {
        return candidate;
      }
    }
    return "";
  }

  return `${appName} • ${String(windowItem?.key || "")}`;
}

function pruneMoveEverythingCustomWindowTitles(visibleWindows, hiddenWindows) {
  const allWindows = [...(visibleWindows || []), ...(hiddenWindows || [])];
  const liveKeys = new Set();
  for (const windowItem of allWindows) {
    if (windowItem?.key) {
      liveKeys.add(String(windowItem.key));
    }
  }

  // Clear stale tracking for keys that are live again
  for (const key of liveKeys) {
    delete state.moveEverythingCustomTitleStaleSince[key];
  }

  const GRACE_PERIOD_MS = 30_000;
  const now = Date.now();

  // Collect all custom-title maps that should be pruned together
  const customMaps = [
    state.moveEverythingCustomWindowTitlesByKey,
    state.moveEverythingCustomITermWindowTitlesByKey,
    state.moveEverythingCustomITermWindowBadgeTextByKey,
    state.moveEverythingCustomITermWindowBadgeColorByKey,
    state.moveEverythingCustomITermWindowBadgeOpacityByKey,
  ];

  // Find all stale keys (present in any custom map but not live)
  const staleKeys = new Set();
  for (const map of customMaps) {
    for (const key of Object.keys(map || {})) {
      if (!liveKeys.has(key)) {
        staleKeys.add(key);
      }
    }
  }

  for (const staleKey of staleKeys) {
    // Apply grace period before deleting — window keys can change transiently
    // during renames (e.g. AXWindowNumber temporarily unavailable), so we keep
    // custom titles around for a while before pruning.
    if (!state.moveEverythingCustomTitleStaleSince[staleKey]) {
      state.moveEverythingCustomTitleStaleSince[staleKey] = now;
      continue;
    }
    if (now - state.moveEverythingCustomTitleStaleSince[staleKey] < GRACE_PERIOD_MS) {
      continue;
    }

    // Grace period expired — delete
    for (const map of customMaps) {
      if (map) delete map[staleKey];
    }
    delete state.moveEverythingCustomTitleStaleSince[staleKey];
  }
}

function findMoveEverythingWindowByKey(key) {
  const normalizedKey = String(key || "").trim();
  if (!normalizedKey) {
    return null;
  }
  const inventory = state.moveEverythingWindows || { visible: [], hidden: [] };
  const visible = Array.isArray(inventory.visible) ? inventory.visible : [];
  const hidden = Array.isArray(inventory.hidden) ? inventory.hidden : [];
  return [...visible, ...hidden].find((item) => item?.key === normalizedKey) || null;
}

function syncMoveEverythingWindowEditorBadgeColorVisibility() {
  syncMoveEverythingWindowEditorBadgeColorSwatchSelection();
}

function syncMoveEverythingWindowEditorBadgeColorSwatchSelection() {
  const container = ids.moveEverythingWindowEditorBadgeColorSwatches;
  if (!container) {
    return;
  }
  const currentValue = normalizeHexColor(
    ids.moveEverythingWindowEditorBadgeColorInput?.value,
    ""
  );
  for (const swatch of container.querySelectorAll(".badge-color-swatch")) {
    const swatchColor = normalizeHexColor(swatch.dataset.color, "");
    swatch.classList.toggle("selected", swatchColor === currentValue && currentValue !== "");
  }
}

function renderMoveEverythingWindowEditorModal() {
  if (!ids.moveEverythingWindowEditorModal) {
    return;
  }

  const editor = state.moveEverythingWindowEditor;
  ids.moveEverythingWindowEditorModal.classList.toggle("hidden", !editor);
  if (!editor) {
    return;
  }

  const isITerm = editor.isITermWindow;
  const currentTitle = editor.displayedTitle || editor.sourceTitle || "Untitled Window";
  if (ids.moveEverythingWindowEditorTitle) {
    ids.moveEverythingWindowEditorTitle.textContent = isITerm
      ? "Edit iTerm2 Window"
      : "Rename Window";
  }
  if (ids.moveEverythingWindowEditorHint) {
    ids.moveEverythingWindowEditorHint.textContent = isITerm
      ? `${editor.appName || "iTerm2"} Window List label and badge for this window.`
      : `${editor.appName || "Window"} title override for this VibeGrid session.`;
  }
  if (ids.moveEverythingWindowEditorTitleField) {
    ids.moveEverythingWindowEditorTitleField.classList.toggle("hidden", false);
  }
  if (ids.moveEverythingWindowEditorBadgeTextField) {
    ids.moveEverythingWindowEditorBadgeTextField.classList.toggle("hidden", !isITerm);
  }
  if (ids.moveEverythingWindowEditorBadgeColorField) {
    ids.moveEverythingWindowEditorBadgeColorField.classList.toggle("hidden", !isITerm);
  }
  if (ids.moveEverythingWindowEditorTitleInput) {
    ids.moveEverythingWindowEditorTitleInput.value = String(editor.titleValue || "");
  }
  if (ids.moveEverythingWindowEditorTitleMeta) {
    ids.moveEverythingWindowEditorTitleMeta.textContent = isITerm
      ? `Leave empty to use the live title: ${currentTitle}. This only changes the Window List label.`
      : `Leave empty to use the live title: ${currentTitle}`;
  }
  if (ids.moveEverythingWindowEditorBadgeTextInput) {
    ids.moveEverythingWindowEditorBadgeTextInput.value = isITerm ? String(editor.badgeTextValue || "") : "";
  }
  if (ids.moveEverythingWindowEditorBadgeTextMeta) {
    ids.moveEverythingWindowEditorBadgeTextMeta.textContent = isITerm
      ? "Leave empty to remove the custom badge text. Activity badges still work if enabled."
      : "";
  }
  if (ids.moveEverythingWindowEditorBadgeColorInput) {
    ids.moveEverythingWindowEditorBadgeColorInput.value = normalizeHexColor(
      editor.badgeColorValue,
      defaultMoveEverythingITermBadgeCustomColor
    );
  }
  if (ids.moveEverythingWindowEditorBadgeOpacityInput) {
    const opacityVal = Math.max(10, Math.min(100, Number(editor.badgeOpacityValue) || defaultMoveEverythingITermBadgeOpacity));
    ids.moveEverythingWindowEditorBadgeOpacityInput.value = String(opacityVal);
  }
  if (ids.moveEverythingWindowEditorBadgeOpacityLabel) {
    const opacityVal = Math.max(10, Math.min(100, Number(editor.badgeOpacityValue) || defaultMoveEverythingITermBadgeOpacity));
    ids.moveEverythingWindowEditorBadgeOpacityLabel.textContent = `${opacityVal}%`;
  }
  syncMoveEverythingWindowEditorBadgeColorVisibility();
}

function closeMoveEverythingWindowEditorModal() {
  state.moveEverythingWindowEditor = null;
  renderMoveEverythingWindowEditorModal();
  sendToNative("windowEditorClosed", {});
}

function focusMoveEverythingWindowEditorPrimaryField() {
  window.requestAnimationFrame(() => {
    const editor = state.moveEverythingWindowEditor;
    if (!editor) {
      return;
    }
    const targetInput = ids.moveEverythingWindowEditorTitleInput;
    if (!targetInput) {
      return;
    }
    targetInput.focus();
    targetInput.select();
  });
}

function openMoveEverythingWindowEditor(key) {
  const normalizedKey = String(key || "").trim();
  if (!normalizedKey) {
    sendJsLog("error", "moveEverythingWindowEditor.missingKey");
    return;
  }
  const windowItem = findMoveEverythingWindowByKey(normalizedKey);
  if (!windowItem) {
    sendJsLog("error", "moveEverythingWindowEditor.windowNotFound", normalizedKey);
    return;
  }
  const isITermWindow = isLikelyITermWindow(windowItem);
  state.moveEverythingWindowEditor = {
    key: normalizedKey,
    isITermWindow,
    appName: String(windowItem.appName || ""),
    sourceTitle: String(windowItem.title || ""),
    displayedTitle: String(resolveMoveEverythingDisplayedWindowTitle(windowItem) || windowItem.title || ""),
    titleValue: isITermWindow
      ? String(state.moveEverythingCustomITermWindowTitlesByKey[normalizedKey] || "")
      : String(state.moveEverythingCustomWindowTitlesByKey[normalizedKey] || ""),
    badgeTextValue: String(state.moveEverythingCustomITermWindowBadgeTextByKey[normalizedKey] || ""),
    badgeColorValue: normalizeHexColor(
      state.moveEverythingCustomITermWindowBadgeColorByKey[normalizedKey],
      defaultMoveEverythingITermBadgeCustomColor
    ),
    badgeOpacityValue: state.moveEverythingCustomITermWindowBadgeOpacityByKey[normalizedKey] ?? defaultMoveEverythingITermBadgeOpacity,
  };
  sendJsLog(
    "info",
    "moveEverythingWindowEditor.open",
    `key=${normalizedKey} isITerm=${isITermWindow} appName=${windowItem.appName || ""} windowNumber=${windowItem.windowNumber ?? "nil"} iTermWindowID=${windowItem.iTermWindowID || "nil"}`
  );
  renderMoveEverythingWindowEditorModal();
  focusMoveEverythingWindowEditorPrimaryField();
  // Measure the rendered card so Swift can size the window precisely
  window.requestAnimationFrame(() => {
    const card = document.querySelector("#moveEverythingWindowEditorModal .modal-card");
    if (!card) return;
    const rect = card.getBoundingClientRect();
    sendToNative("windowEditorOpened", {
      cardWidth: Math.ceil(rect.width),
      cardHeight: Math.ceil(rect.height),
    });
  });
}

function resetMoveEverythingWindowEditorFields() {
  const editor = state.moveEverythingWindowEditor;
  if (!editor) {
    return;
  }
  if (ids.moveEverythingWindowEditorTitleInput) {
    ids.moveEverythingWindowEditorTitleInput.value = "";
  }
  if (editor.isITermWindow) {
    if (ids.moveEverythingWindowEditorBadgeTextInput) {
      ids.moveEverythingWindowEditorBadgeTextInput.value = "";
    }
    if (ids.moveEverythingWindowEditorBadgeColorInput) {
      ids.moveEverythingWindowEditorBadgeColorInput.value = defaultMoveEverythingITermBadgeCustomColor;
    }
    if (ids.moveEverythingWindowEditorBadgeOpacityInput) {
      ids.moveEverythingWindowEditorBadgeOpacityInput.value = String(defaultMoveEverythingITermBadgeOpacity);
    }
    if (ids.moveEverythingWindowEditorBadgeOpacityLabel) {
      ids.moveEverythingWindowEditorBadgeOpacityLabel.textContent = `${defaultMoveEverythingITermBadgeOpacity}%`;
    }
    syncMoveEverythingWindowEditorBadgeColorVisibility();
  }
}

function submitMoveEverythingITermWindowOverride(windowItem, payload = {}) {
  const normalizedKey = String(windowItem?.key || "").trim();
  const displayedTitle = String(resolveMoveEverythingDisplayedWindowTitle(windowItem) || windowItem?.title || "");
  sendJsLog(
    "info",
    "moveEverythingWindowEditor.submitITerm",
    `key=${normalizedKey} titleProvided=${Boolean(payload.titleProvided)} title=${payload.title || ""} ` +
      `badgeTextProvided=${Boolean(payload.badgeTextProvided)} badgeText=${payload.badgeText || ""} ` +
      `badgeColorProvided=${Boolean(payload.badgeColorProvided)} badgeColor=${payload.badgeColor || ""}`
  );
  sendToNative("moveEverythingRenameITermWindow", {
    key: normalizedKey,
    windowNumber: Number.isInteger(windowItem.windowNumber) ? windowItem.windowNumber : null,
    iTermWindowID: typeof windowItem.iTermWindowID === "string" ? windowItem.iTermWindowID : "",
    frame: windowItem.frame && Number.isFinite(windowItem.frame.x)
      ? {
          x: windowItem.frame.x,
          y: windowItem.frame.y,
          width: windowItem.frame.width,
          height: windowItem.frame.height,
        }
      : null,
    appName: String(windowItem.appName || ""),
    sourceTitle: String(windowItem.title || ""),
    sourceDisplayedTitle: displayedTitle,
    titleProvided: Boolean(payload.titleProvided),
    title: String(payload.title || ""),
    badgeTextProvided: Boolean(payload.badgeTextProvided),
    badgeText: String(payload.badgeText || ""),
    badgeColorProvided: Boolean(payload.badgeColorProvided),
    badgeColor: String(payload.badgeColor || ""),
    badgeOpacity: Number.isFinite(payload.badgeOpacity) ? payload.badgeOpacity : defaultMoveEverythingITermBadgeOpacity,
  });
}

function submitMoveEverythingWindowEditor() {
  const editor = state.moveEverythingWindowEditor;
  if (!editor) {
    return;
  }
  const windowItem = findMoveEverythingWindowByKey(editor.key);
  if (!windowItem) {
    showToast("That window is no longer available.", "error");
    closeMoveEverythingWindowEditorModal();
    return;
  }

  const trimmedTitle = String(ids.moveEverythingWindowEditorTitleInput?.value || "").trim();

  if (editor.isITermWindow) {
    // Title: stored locally in Window List only (does not change real iTerm title)
    if (!trimmedTitle.length) {
      delete state.moveEverythingCustomITermWindowTitlesByKey[editor.key];
    } else {
      state.moveEverythingCustomITermWindowTitlesByKey[editor.key] = trimmedTitle;
    }
    delete state.moveEverythingCustomWindowTitlesByKey[editor.key];

    // Badge: sent to native to apply to iTerm
    const trimmedBadgeText = String(ids.moveEverythingWindowEditorBadgeTextInput?.value || "").trim();
    const trimmedBadgeColor = normalizeHexColor(
      ids.moveEverythingWindowEditorBadgeColorInput?.value,
      defaultMoveEverythingITermBadgeCustomColor
    );
    if (!trimmedBadgeText.length) {
      delete state.moveEverythingCustomITermWindowBadgeTextByKey[editor.key];
    } else {
      state.moveEverythingCustomITermWindowBadgeTextByKey[editor.key] = trimmedBadgeText;
    }
    if (!trimmedBadgeColor.length) {
      delete state.moveEverythingCustomITermWindowBadgeColorByKey[editor.key];
      delete state.moveEverythingCustomITermWindowBadgeOpacityByKey[editor.key];
    } else {
      state.moveEverythingCustomITermWindowBadgeColorByKey[editor.key] = trimmedBadgeColor;
      const opacityVal = Math.max(10, Math.min(100, parseInt(ids.moveEverythingWindowEditorBadgeOpacityInput?.value, 10) || 80));
      state.moveEverythingCustomITermWindowBadgeOpacityByKey[editor.key] = opacityVal;
    }
    const badgeOpacity = Math.max(10, Math.min(100, parseInt(ids.moveEverythingWindowEditorBadgeOpacityInput?.value, 10) || defaultMoveEverythingITermBadgeOpacity));
    submitMoveEverythingITermWindowOverride(windowItem, {
      titleProvided: true,
      title: trimmedTitle,
      badgeTextProvided: true,
      badgeText: trimmedBadgeText,
      badgeColorProvided: true,
      badgeColor: trimmedBadgeColor,
      badgeOpacity: badgeOpacity,
    });
  } else {
    if (!trimmedTitle.length) {
      delete state.moveEverythingCustomWindowTitlesByKey[editor.key];
    } else {
      state.moveEverythingCustomWindowTitlesByKey[editor.key] = trimmedTitle;
    }
    sendJsLog(
      "info",
      "moveEverythingWindowEditor.submitLocal",
      `key=${editor.key} title=${trimmedTitle}`
    );
  }

  closeMoveEverythingWindowEditorModal();
  if (moveEverythingWorkspaceVisible()) {
    renderMoveEverythingWorkspace();
  }
  sendToNative("requestState", { forceMoveEverythingWindowRefresh: true });
}

function renameMoveEverythingWindow(key) {
  openMoveEverythingWindowEditor(key);
}

function moveEverythingCoreGraphicsFallbackWindowLabel(windowItem) {
  const key = String(windowItem?.key || "");
  const match = key.match(/(?:-cg-|-)(\d+)$/);
  if (!match || !match[1]) {
    return "Window";
  }
  return `Window ${match[1]}`;
}

function hasMoveEverythingCustomWindowTitle(windowItem) {
  const key = String(windowItem?.key || "").trim();
  if (!key) {
    return false;
  }
  if (state.moveEverythingCustomITermWindowTitlesByKey[key]) {
    return true;
  }
  if (state.moveEverythingCustomWindowTitlesByKey[key]) {
    return true;
  }
  if (isLikelyITermWindow(windowItem) && state.config?.settings?.moveEverythingITermTitleFromBadge) {
    const badge = String(windowItem?.iTermBadgeText || "").trim();
    if (badge.length) {
      return true;
    }
  }
  return false;
}

function moveEverythingProfileSortPriority(windowItem) {
  const profileID = String(windowItem?.iTermProfileID || "").trim().toLowerCase();
  const base = profileID.split("+")[0];
  if (base === "claude-code") return 0;
  if (base === "codex") return 1;
  return 2;
}

function compareMoveEverythingVisibleWindowsByAppThenTitle(leftWindow, rightWindow) {
  const leftAppName = String(leftWindow?.appName || "").trim();
  const rightAppName = String(rightWindow?.appName || "").trim();
  const appNameComparison = leftAppName.localeCompare(rightAppName, undefined, {
    sensitivity: "base",
    numeric: true,
  });
  if (appNameComparison !== 0) {
    return appNameComparison;
  }

  // Within same app (iTerm): claude-code first, then codex, then others
  if (isLikelyITermWindow(leftWindow) && isLikelyITermWindow(rightWindow)) {
    const leftPriority = moveEverythingProfileSortPriority(leftWindow);
    const rightPriority = moveEverythingProfileSortPriority(rightWindow);
    if (leftPriority !== rightPriority) {
      return leftPriority - rightPriority;
    }
  }

  const leftTitle = String(resolveMoveEverythingDisplayedWindowTitle(leftWindow) || "").trim();
  const rightTitle = String(resolveMoveEverythingDisplayedWindowTitle(rightWindow) || "").trim();
  const titleComparison = leftTitle.localeCompare(rightTitle, undefined, {
    sensitivity: "base",
    numeric: true,
  });
  if (titleComparison !== 0) {
    return titleComparison;
  }

  return String(leftWindow?.key || "").localeCompare(String(rightWindow?.key || ""), undefined, {
    sensitivity: "base",
    numeric: true,
  });
}

function buildMoveEverythingWindowRow(windowItem, options = {}) {
  const { hovered = false, focused = false, hidden = false } = options;
  const isControlCenterRow = Boolean(windowItem.isControlCenter);
  const compactActions = moveEverythingActionCompactModeActive();
  const activityStatus = resolveMoveEverythingWindowActivityStatus(windowItem);
  const settings = state.config?.settings || {};
  const row = document.createElement("div");
  row.className = `move-window-row${hovered ? " hovered" : ""}${focused ? " focused-window" : ""}${hidden ? " hidden-window" : ""}`;
  row.dataset.meWindowKey = windowItem.key;
  row.dataset.meControlCenter = isControlCenterRow ? "1" : "0";

  const main = document.createElement("div");
  main.className = "move-window-main";

  if (windowItem.iconDataURL) {
    const icon = document.createElement("img");
    icon.className = "move-window-icon";
    icon.alt = "";
    icon.src = windowItem.iconDataURL;
    main.appendChild(icon);
  } else {
    const iconFallback = document.createElement("span");
    iconFallback.className = "move-window-icon-fallback";
    iconFallback.textContent = String(windowItem.appName || "?").charAt(0).toUpperCase() || "?";
    main.appendChild(iconFallback);
  }

  const copy = document.createElement("span");
  copy.className = "move-window-copy";
  const title = document.createElement("strong");
  const displayedTitle = String(resolveMoveEverythingDisplayedWindowTitle(windowItem) || "");
  title.dataset.fullTitle = displayedTitle;
  title.textContent = displayedTitle;
  const activeWindowHighlightColorizeEnabled = Boolean(settings.moveEverythingActiveWindowHighlightColorize);
  if (!hovered && focused && activeWindowHighlightColorizeEnabled) {
    const activeWindowColorPair = resolveMoveEverythingWindowActivityColorPair(
      settings.moveEverythingActiveWindowHighlightColor
    );
    if (activeWindowColorPair) {
      row.classList.add("activity-status-box", "active-window-highlight-box");
      row.style.setProperty("--activity-status-border-color", activeWindowColorPair.border);
      row.style.setProperty("--activity-status-background-color", activeWindowColorPair.background);
      row.style.setProperty("--selected-window-row-border-color", activeWindowColorPair.border);
      row.style.setProperty("--selected-window-row-background-color", activeWindowColorPair.background);
      row.style.setProperty("--selected-window-row-ring-color", activeWindowColorPair.border);
      copy.classList.add("activity-status-box");
    }
  }
  const activityColorizeEnabled = Boolean(settings.moveEverythingITermRecentActivityColorize);
  const activityColorizeNamedOnly = Boolean(settings.moveEverythingITermRecentActivityColorizeNamedOnly);
  const windowKey = String(windowItem.key || "");
  const windowIsNamed = Boolean(
    state.moveEverythingCustomITermWindowTitlesByKey[windowKey] ||
    state.moveEverythingCustomWindowTitlesByKey[windowKey]
  );
  const profileID = String(windowItem?.iTermProfileID || "").trim().toLowerCase();
  const baseProfile = profileID.split("+")[0];
  const isClaudeOrCodex = baseProfile === "claude-code" || baseProfile === "codex";
  if (activityColorizeEnabled && isClaudeOrCodex && (activityStatus === "active" || activityStatus === "idle")) {
    const baseColor = activityStatus === "active"
      ? settings.moveEverythingITermRecentActivityActiveColor
      : settings.moveEverythingITermRecentActivityIdleColor;
    const colorPair = resolveMoveEverythingWindowActivityColorPair(baseColor);
    if (colorPair) {
      row.classList.add("activity-status-box", `activity-status-${activityStatus}`);
      row.style.setProperty("--activity-status-border-color", colorPair.border);
      row.style.setProperty("--activity-status-background-color", colorPair.background);
      copy.classList.add("activity-status-box", `activity-status-${activityStatus}`);
    }
  }
  const subtitle = document.createElement("small");
  subtitle.textContent = resolveMoveEverythingWindowSubtitle(windowItem);
  copy.appendChild(title);
  copy.appendChild(subtitle);
  main.appendChild(copy);
  row.appendChild(main);

  if (!isControlCenterRow) {
    const actions = document.createElement("div");
    actions.className = "move-window-actions";
    if (compactActions) {
      actions.classList.add("compact");
    }

    const isPinned = state.moveEverythingPinnedWindowKeys.has(windowItem.key);

    if (isPinned) {
      row.classList.add("pinned-window");
      const unpinBtn = document.createElement("button");
      unpinBtn.type = "button";
      unpinBtn.className = "btn tiny move-everything";
      unpinBtn.textContent = "Unpin";
      unpinBtn.dataset.meWindowAction = "unpin";
      unpinBtn.dataset.meWindowKey = windowItem.key;
      actions.appendChild(unpinBtn);
    } else if (!hidden && state.moveEverythingPinMode) {
      const pinBtn = document.createElement("button");
      pinBtn.type = "button";
      pinBtn.className = "btn tiny primary";
      pinBtn.textContent = "Pin";
      pinBtn.dataset.meWindowAction = "pin";
      pinBtn.dataset.meWindowKey = windowItem.key;
      actions.appendChild(pinBtn);
    } else if (hidden) {
      const showBtn = document.createElement("button");
      showBtn.type = "button";
      showBtn.className = "btn tiny move-everything";
      showBtn.textContent = compactActions ? "S" : "Show";
      showBtn.dataset.meWindowAction = "show";
      showBtn.dataset.meWindowKey = windowItem.key;
      actions.appendChild(showBtn);

      const maxBtn = document.createElement("button");
      maxBtn.type = "button";
      maxBtn.className = "btn tiny primary";
      maxBtn.textContent = compactActions ? "M" : "Max";
      maxBtn.dataset.meWindowAction = "max";
      maxBtn.dataset.meWindowKey = windowItem.key;
      actions.appendChild(maxBtn);

      const closeBtn = document.createElement("button");
      closeBtn.type = "button";
      closeBtn.className = "btn tiny danger";
      closeBtn.textContent = compactActions ? "X" : (windowItem.isCoreGraphicsFallback ? "Quit" : "Close");
      closeBtn.dataset.meWindowAction = "close";
      closeBtn.dataset.meWindowKey = windowItem.key;
      actions.appendChild(closeBtn);
    } else {
      const hideBtn = document.createElement("button");
      hideBtn.type = "button";
      hideBtn.className = "btn tiny warning";
      hideBtn.textContent = compactActions ? "H" : "Hide";
      hideBtn.dataset.meWindowAction = "hide";
      hideBtn.dataset.meWindowKey = windowItem.key;
      actions.appendChild(hideBtn);

      const renameBtn = document.createElement("button");
      renameBtn.type = "button";
      renameBtn.className = "btn tiny rename";
      renameBtn.textContent = compactActions ? "N" : "Name";
      renameBtn.dataset.meRenameWindow = "1";
      renameBtn.dataset.meWindowKey = windowItem.key;
      actions.appendChild(renameBtn);

      const closeBtn = document.createElement("button");
      closeBtn.type = "button";
      closeBtn.className = "btn tiny danger";
      closeBtn.textContent = compactActions ? "X" : "Close";
      closeBtn.dataset.meWindowAction = "close";
      closeBtn.dataset.meWindowKey = windowItem.key;
      actions.appendChild(closeBtn);

    }
    row.appendChild(actions);
  }
  return row;
}

function renderGridCanvas(placement = selectedPlacement(), showSelectionOverlay = true) {
  if (!placement) {
    return;
  }

  const grid = ensureGrid(placement);
  ids.gridCanvas.innerHTML = "";
  ids.gridCanvas.style.gridTemplateColumns = `repeat(${grid.columns}, 1fr)`;
  ids.gridCanvas.style.gridTemplateRows = `repeat(${grid.rows}, minmax(0, 1fr))`;
  ids.gridCanvas.style.aspectRatio = `${grid.columns} / ${grid.rows}`;

  const fragment = document.createDocumentFragment();

  for (let y = 0; y < grid.rows; y += 1) {
    for (let x = 0; x < grid.columns; x += 1) {
      const cell = document.createElement("div");
      cell.className = "grid-cell";
      cell.dataset.cellX = String(x);
      cell.dataset.cellY = String(y);

      if (
        showSelectionOverlay &&
        x >= grid.x &&
        x < grid.x + grid.width &&
        y >= grid.y &&
        y < grid.y + grid.height
      ) {
        cell.classList.add("selected");
      }

      fragment.appendChild(cell);
    }
  }

  ids.gridCanvas.appendChild(fragment);
}

function syncFreeLabels(rect) {
  ids.freeXLabel.textContent = `${Math.round(rect.x * 100)}%`;
  ids.freeYLabel.textContent = `${Math.round(rect.y * 100)}%`;
  ids.freeWLabel.textContent = `${Math.round(rect.width * 100)}%`;
  ids.freeHLabel.textContent = `${Math.round(rect.height * 100)}%`;
}

function syncFreeCanvas(rect) {
  ids.freeRect.style.left = `${rect.x * 100}%`;
  ids.freeRect.style.top = `${rect.y * 100}%`;
  ids.freeRect.style.width = `${rect.width * 100}%`;
  ids.freeRect.style.height = `${rect.height * 100}%`;
}

function shortcutById(shortcutId) {
  if (!shortcutId) {
    return null;
  }
  return state.config?.shortcuts.find((item) => item.id === shortcutId) || null;
}

function selectedShortcut() {
  return shortcutById(state.selectedShortcutId);
}

function selectedPlacement() {
  const shortcut = selectedShortcut();
  if (!shortcut) {
    return null;
  }
  return shortcut.placements.find((item) => item.id === state.selectedPlacementId) || null;
}

function clearSelectedPlacement({ hidePreview = true, render = true } = {}) {
  if (state.selectedPlacementId === null) {
    return false;
  }
  state.selectedPlacementId = null;
  if (hidePreview) {
    hidePlacementPreview();
  }
  if (render) {
    pubsub.publish('selection');
  }
  return true;
}

function displayShortcut() {
  return shortcutById(state.hoveredShortcutId) || selectedShortcut();
}

function shortcutByPlacementId(placementId, config = null) {
  const shortcuts = Array.isArray((config || state.config)?.shortcuts)
    ? (config || state.config).shortcuts
    : [];
  if (!placementId) {
    return null;
  }
  return (
    shortcuts.find((shortcut) => shortcut?.placements?.some((placement) => placement.id === placementId)) ||
    null
  );
}

function placementByIdInShortcut(shortcut, placementId) {
  if (!shortcut || !placementId) {
    return null;
  }
  return shortcut.placements.find((item) => item.id === placementId) || null;
}

function displayPlacement() {
  return displayPlacementContext().placement;
}

function displayPlacementContext() {
  if (state.moveEverythingNarrowMode === true && state.narrowPreviewMode !== "sequences") {
    return {
      placement: null,
      readOnly: true,
    };
  }

  const selectedShortcutEntry = selectedShortcut();
  const selectedPlacementEntry = selectedShortcutEntry
    ? placementByIdInShortcut(selectedShortcutEntry, state.selectedPlacementId)
    : null;

  const hoveredPlacementShortcut = shortcutByPlacementId(state.hoveredPlacementId);
  if (hoveredPlacementShortcut) {
    const hoveredPlacement = placementByIdInShortcut(hoveredPlacementShortcut, state.hoveredPlacementId);
    if (hoveredPlacement) {
      return {
        placement: hoveredPlacement,
        readOnly:
          hoveredPlacementShortcut.id !== state.selectedShortcutId ||
          hoveredPlacement.id !== state.selectedPlacementId,
      };
    }
  }

  if (state.hoveredShortcutId && state.hoveredShortcutId !== state.selectedShortcutId) {
    const hoveredShortcut = shortcutById(state.hoveredShortcutId);
    const firstPlacement = hoveredShortcut?.placements?.[0] || null;
    if (firstPlacement) {
      return {
        placement: firstPlacement,
        readOnly:
          hoveredShortcut.id !== state.selectedShortcutId ||
          firstPlacement.id !== state.selectedPlacementId,
      };
    }
  }

  if (selectedPlacementEntry) {
    return {
      placement: selectedPlacementEntry,
      readOnly: false,
    };
  }

  return {
    placement: null,
    readOnly: true,
  };
}

function setPlacementHoverFromId(placementId) {
  const normalizedId = String(placementId || "").trim();
  if (!normalizedId) {
    state.hoveredShortcutId = null;
    state.hoveredPlacementId = null;
    return;
  }

  const hoveredShortcut = shortcutByPlacementId(normalizedId);
  if (!hoveredShortcut) {
    state.hoveredShortcutId = null;
    state.hoveredPlacementId = null;
    return;
  }

  state.hoveredShortcutId = hoveredShortcut.id;
  state.hoveredPlacementId = normalizedId;
}

function clearPlacementHoverState() {
  if (state.hoveredPlacementId === null && state.hoveredShortcutId === null) {
    return false;
  }
  state.hoveredShortcutId = null;
  state.hoveredPlacementId = null;
  return true;
}

function reconcilePlacementHoverFromPointerTarget(target) {
  if (state.hoveredPlacementId === null || state.listReorderDrag) {
    return false;
  }

  const targetElement = target instanceof Element ? target : null;
  if (targetElement && ids.placementList.contains(targetElement)) {
    return false;
  }

  return clearPlacementHoverState();
}

function livePointerTarget(event) {
  if (Number.isFinite(event?.clientX) && Number.isFinite(event?.clientY)) {
    const liveTarget = document.elementFromPoint(event.clientX, event.clientY);
    if (liveTarget instanceof Element) {
      return liveTarget;
    }
  }

  return event?.target instanceof Element ? event.target : null;
}

function isMassRecordingActive() {
  return Array.isArray(state.massRecordingOrder) && state.massRecordingOrder.length > 0;
}

function resolveThemeMode(value, legacyDarkMode) {
  const normalized = String(value || "")
    .toLowerCase()
    .trim();
  if (themeModeLookup.has(normalized)) {
    return normalized;
  }
  if (typeof legacyDarkMode === "boolean") {
    return legacyDarkMode ? "dark" : "system";
  }
  return "system";
}

function systemDefaultThemeLabel() {
  return systemThemeMediaQuery?.matches ? "System Default (Dark)" : "System Default (Light)";
}

function syncThemeModeSelect(themeModeValue) {
  if (!ids.settingThemeMode) {
    return;
  }

  const systemOption = ids.settingThemeMode.querySelector('option[value="system"]');
  if (systemOption) {
    systemOption.textContent = systemDefaultThemeLabel();
  }

  ids.settingThemeMode.value = resolveThemeMode(themeModeValue);
}

function controlCenterScalePercentText(scaleValue) {
  const clampedPercent = clampInt(
    clampControlCenterScale(scaleValue) * 100,
    minControlCenterScalePercent,
    maxControlCenterScalePercent
  );
  return String(clampedPercent);
}

function normalizeControlCenterScalePercentInput(value) {
  const trimmedValue = String(value ?? "").trim();
  if (!trimmedValue.length) {
    return defaultControlCenterScalePercent;
  }

  const parsedValue = Number(trimmedValue);
  if (!Number.isFinite(parsedValue)) {
    return defaultControlCenterScalePercent;
  }
  return clampInt(parsedValue, minControlCenterScalePercent, maxControlCenterScalePercent);
}

function syncControlCenterScaleDraftFromSettings() {
  state.settingControlCenterScaleDraft = controlCenterScalePercentText(state.config?.settings?.controlCenterScale);
}

function renderControlCenterScaleInput() {
  if (!ids.settingControlCenterScale) {
    return;
  }

  if (state.settingControlCenterScaleDraft === null) {
    syncControlCenterScaleDraftFromSettings();
  }

  ids.settingControlCenterScale.value = state.settingControlCenterScaleDraft;
}

function renderSettingsModal() {
  if (!ids.settingsModal) {
    return;
  }

  ids.settingsModal.classList.toggle("hidden", !state.settingsModalOpen);
  if (!state.settingsModalOpen || !state.config?.settings) {
    return;
  }

  ids.settingGridCols.value = clampInt(state.config.settings.defaultGridColumns, 1, 24);
  ids.settingGridRows.value = clampInt(state.config.settings.defaultGridRows, 1, 20);
  ids.settingGap.value = clampInt(state.config.settings.gap, 0, 80);
  ids.settingDefaultCycleDisplaysOnWrap.checked = Boolean(
    state.config.settings.defaultCycleDisplaysOnWrap
  );
  syncThemeModeSelect(state.config.settings.themeMode);
  renderControlCenterScaleInput();
  ids.settingLargerFonts.checked = Boolean(state.config.settings.largerFonts);
  ids.settingLaunchAtLogin.checked = Boolean(state.launchAtLogin.enabled);
  ids.settingLaunchAtLogin.disabled = !Boolean(state.launchAtLogin.supported);
  ids.openLoginItemsSettingsBtn.classList.toggle("hidden", !Boolean(state.launchAtLogin.supported));
  ids.settingsConfigPath.textContent = state.configPath || "";
}

function openSettingsModal(tab) {
  state.settingsModalOpen = true;
  state.settingsActiveTab = tab || state.settingsActiveTab || "general";
  syncControlCenterScaleDraftFromSettings();
  renderSettingsModal();
  renderSettingsTabContent();
}

function closeSettingsModal() {
  state.settingsModalOpen = false;
  state.settingControlCenterScaleDraft = null;
  renderSettingsModal();
}

function renderSettingsTabContent() {
  const tabs = document.querySelectorAll("[data-settings-tab]");
  const activeTab = state.settingsActiveTab || "general";
  tabs.forEach((btn) => {
    btn.classList.toggle("active", btn.dataset.settingsTab === activeTab);
  });
  const tabGeneral = document.getElementById("settingsTabGeneral");
  const tabWindowList = document.getElementById("settingsTabWindowList");
  const tabColors = document.getElementById("settingsTabColors");
  if (tabGeneral) tabGeneral.style.display = activeTab === "general" ? "" : "none";
  if (tabWindowList) tabWindowList.style.display = activeTab === "windowList" ? "" : "none";
  if (tabColors) tabColors.style.display = activeTab === "colors" ? "" : "none";
  if (activeTab === "windowList" || activeTab === "colors") {
    renderMoveEverythingModal();
  }
}

async function restoreDefaultSettingsFromModal() {
  const confirmed = await showConfirmDialog({
    title: "Restore Settings Defaults",
    message: "Reset all settings to their default values? This keeps your shortcuts.",
    confirmLabel: "Restore Defaults",
    tone: "danger",
  });
  if (!confirmed) {
    return;
  }

  state.config.settings = normalizeSettings(createDefaultConfig().settings);
  syncControlCenterScaleDraftFromSettings();
  applyTheme();
  applyControlCenterScale();
  applyLargerFonts();
  hidePlacementPreview();
  markDirty();
  renderAll();
  showToast("Settings restored to defaults.", "success");
}

window.vibeGridOpenSettingsModal = () => {
  openSettingsModal();
};

function requestPlacementPreview(placement = selectedPlacement()) {
  if (!placement) {
    hidePlacementPreview();
    return;
  }

  state.pendingPreviewPlacement = placement;
  if (state.previewRequestFrame !== null) {
    return;
  }

  state.previewRequestFrame = window.requestAnimationFrame(() => {
    state.previewRequestFrame = null;
    const pendingPlacement = state.pendingPreviewPlacement;
    state.pendingPreviewPlacement = null;

    if (!pendingPlacement) {
      return;
    }

    sendToNative("previewPlacement", pendingPlacement);
  });
}

function hidePlacementPreview() {
  if (state.previewRequestFrame !== null) {
    window.cancelAnimationFrame(state.previewRequestFrame);
    state.previewRequestFrame = null;
  }

  state.pendingPreviewPlacement = null;
  sendToNative("hidePlacementPreview");
}

function markDirty() {
  pushCurrentConfigToHistory();
  // Save immediately — server pushes state frequently and would overwrite
  // unsaved changes if we delayed. The guard window prevents stale server
  // pushes from reverting the config before Swift processes the save.
  cancelAutosave();
  saveConfig({ silent: true });
  configSaveGuardUntil = performance.now() + 5000;
}

function saveConfig(options = {}) {
  const { silent = false } = options;
  if (!state.config) {
    return;
  }
  sendToNative("saveConfig", {
    config: state.config,
    silent,
  });
}

function cancelAutosave() {
  if (autosaveTimer === null) {
    return false;
  }

  window.clearTimeout(autosaveTimer);
  autosaveTimer = null;
  return true;
}

function scheduleAutosave() {
  cancelAutosave();

  autosaveTimer = window.setTimeout(() => {
    autosaveTimer = null;
    saveConfig({ silent: true });
  }, autosaveDelayMs);
}

function flushAutosave() {
  if (!cancelAutosave()) {
    return;
  }
  saveConfig({ silent: true });
  // Protect local config from being overwritten by stale server pushes
  // that arrive before the server processes our save.
  configSaveGuardUntil = performance.now() + 5000;
}

function persistCurrentConfigAfterUndoRedo() {
  if (!state.config) {
    return;
  }
  cancelAutosave();
  saveConfig({ silent: true });
  configSaveGuardUntil = performance.now() + 5000;
}

function cloneConfig(config) {
  return JSON.parse(JSON.stringify(config));
}

function configSignature(config) {
  return JSON.stringify(config);
}

function historyEntryFromConfig(config, selection = null) {
  const selectedShortcutId = selection?.selectedShortcutId ?? state.selectedShortcutId;
  const selectedPlacementId = selection?.selectedPlacementId ?? state.selectedPlacementId;
  return {
    config: cloneConfig(config),
    selectedShortcutId: selectedShortcutId || null,
    selectedPlacementId: selectedPlacementId || null,
  };
}

function configFromHistoryEntry(entry) {
  if (!entry) {
    return null;
  }
  if (entry.config && typeof entry.config === "object") {
    return entry.config;
  }
  return entry;
}

function cloneHistoryEntry(entry) {
  const config = configFromHistoryEntry(entry);
  if (!config) {
    return null;
  }
  return {
    config: cloneConfig(config),
    selectedShortcutId: entry?.selectedShortcutId ?? null,
    selectedPlacementId: entry?.selectedPlacementId ?? null,
  };
}

function shortcutByIdInConfig(config, shortcutId) {
  if (!shortcutId || !Array.isArray(config?.shortcuts)) {
    return null;
  }
  return config.shortcuts.find((shortcut) => shortcut.id === shortcutId) || null;
}

function firstChangedPlacementId(beforeShortcut, afterShortcut) {
  const beforePlacements = Array.isArray(beforeShortcut?.placements) ? beforeShortcut.placements : [];
  const afterPlacements = Array.isArray(afterShortcut?.placements) ? afterShortcut.placements : [];
  const beforeIDs = beforePlacements.map((placement) => placement.id);
  const afterIDs = afterPlacements.map((placement) => placement.id);

  if (!sameStringArray(beforeIDs, afterIDs)) {
    for (const placementId of afterIDs) {
      if (!beforeIDs.includes(placementId)) {
        return placementId;
      }
    }

    const sharedCount = Math.min(beforeIDs.length, afterIDs.length);
    for (let index = 0; index < sharedCount; index += 1) {
      if (beforeIDs[index] !== afterIDs[index]) {
        return afterIDs[index] || null;
      }
    }

    return afterIDs[0] || null;
  }

  const beforeByID = new Map(beforePlacements.map((placement) => [placement.id, configSignature(placement)]));
  for (const placement of afterPlacements) {
    if (beforeByID.get(placement.id) !== configSignature(placement)) {
      return placement.id;
    }
  }

  return null;
}

function firstChangedSelectionTarget(beforeConfig, afterConfig) {
  const beforeShortcuts = Array.isArray(beforeConfig?.shortcuts) ? beforeConfig.shortcuts : [];
  const afterShortcuts = Array.isArray(afterConfig?.shortcuts) ? afterConfig.shortcuts : [];
  const beforeIDs = beforeShortcuts.map((shortcut) => shortcut.id);
  const afterIDs = afterShortcuts.map((shortcut) => shortcut.id);

  if (!sameStringArray(beforeIDs, afterIDs)) {
    for (const shortcutId of afterIDs) {
      if (!beforeIDs.includes(shortcutId)) {
        const changedShortcut = shortcutByIdInConfig(afterConfig, shortcutId);
        return {
          shortcutId,
          placementId: changedShortcut?.placements?.[0]?.id || null,
        };
      }
    }

    const fallbackShortcutId = afterIDs[0] || null;
    if (!fallbackShortcutId) {
      return null;
    }
    const fallbackShortcut = shortcutByIdInConfig(afterConfig, fallbackShortcutId);
    return {
      shortcutId: fallbackShortcutId,
      placementId: fallbackShortcut?.placements?.[0]?.id || null,
    };
  }

  const beforeByID = new Map(beforeShortcuts.map((shortcut) => [shortcut.id, shortcut]));
  for (const afterShortcut of afterShortcuts) {
    const beforeShortcut = beforeByID.get(afterShortcut.id);
    if (configSignature(beforeShortcut) !== configSignature(afterShortcut)) {
      return {
        shortcutId: afterShortcut.id,
        placementId: firstChangedPlacementId(beforeShortcut, afterShortcut),
      };
    }
  }

  return null;
}

function applyHistorySelection(entry, changedSelectionTarget = null) {
  const config = state.config;
  if (!config) {
    return;
  }

  const changedShortcutId = changedSelectionTarget?.shortcutId || null;
  if (changedShortcutId && shortcutByIdInConfig(config, changedShortcutId)) {
    state.selectedShortcutId = changedShortcutId;
    const shortcut = shortcutByIdInConfig(config, changedShortcutId);
    const changedPlacementId = changedSelectionTarget?.placementId || null;
    if (changedPlacementId && shortcut?.placements?.some((item) => item.id === changedPlacementId)) {
      state.selectedPlacementId = changedPlacementId;
    } else {
      state.selectedPlacementId = shortcut?.placements?.[0]?.id || null;
    }
    return;
  }

  const selectedShortcutId = entry?.selectedShortcutId || null;
  const selectedPlacementId = entry?.selectedPlacementId || null;

  if (selectedShortcutId && shortcutByIdInConfig(config, selectedShortcutId)) {
    state.selectedShortcutId = selectedShortcutId;
    const shortcut = shortcutByIdInConfig(config, selectedShortcutId);
    if (selectedPlacementId && shortcut?.placements?.some((item) => item.id === selectedPlacementId)) {
      state.selectedPlacementId = selectedPlacementId;
    } else {
      state.selectedPlacementId = shortcut?.placements?.[0]?.id || null;
    }
    return;
  }

  state.selectedShortcutId = config.shortcuts[0]?.id || null;
  state.selectedPlacementId = config.shortcuts[0]?.placements?.[0]?.id || null;
}

function resetHistoryFromCurrentConfig() {
  if (!state.config) {
    state.history = [];
    state.future = [];
    renderUndoRedoButtons();
    return;
  }

  state.history = [historyEntryFromConfig(state.config)];
  state.future = [];
  renderUndoRedoButtons();
}

function pushCurrentConfigToHistory() {
  if (!state.config) {
    return;
  }

  const snapshot = historyEntryFromConfig(state.config);
  const snapshotSignature = configSignature(configFromHistoryEntry(snapshot));
  const last = state.history[state.history.length - 1];
  const lastSignature = last ? configSignature(configFromHistoryEntry(last)) : null;

  if (snapshotSignature !== lastSignature) {
    state.history.push(snapshot);
    const maxEntries = maxUndoChanges + 1;
    if (state.history.length > maxEntries) {
      state.history.splice(0, state.history.length - maxEntries);
    }
  }

  state.future = [];
  renderUndoRedoButtons();
}

function undoChange() {
  if (state.history.length <= 1) {
    return;
  }

  const current = state.history.pop();
  if (!current) {
    return;
  }
  const currentClone = cloneHistoryEntry(current);
  if (!currentClone) {
    return;
  }
  state.future.push(currentClone);

  const previous = state.history[state.history.length - 1];
  const currentConfig = configFromHistoryEntry(current);
  const previousConfig = configFromHistoryEntry(previous);
  if (!previousConfig) {
    return;
  }
  state.config = cloneConfig(previousConfig);
  applyHistorySelection(previous, firstChangedSelectionTarget(currentConfig, previousConfig));

  enforceSelection();
  renderAll();
  persistCurrentConfigAfterUndoRedo();
}

function redoChange() {
  if (!state.future.length) {
    return;
  }

  const next = state.future.pop();
  const nextConfig = configFromHistoryEntry(next);
  if (!nextConfig) {
    return;
  }

  const previousConfig = state.config;
  const nextClone = cloneHistoryEntry(next);
  if (!nextClone) {
    return;
  }
  state.history.push(nextClone);
  state.config = cloneConfig(nextConfig);
  applyHistorySelection(next, firstChangedSelectionTarget(previousConfig, nextConfig));

  enforceSelection();
  renderAll();
  persistCurrentConfigAfterUndoRedo();
}

async function reloadConfig() {
  stopHotkeyRecording();
  hidePlacementPreview();

  const proceed = await showConfirmDialog({
    title: "Reload configuration?",
    message: "Reload will re-read the YAML file from disk and refresh all shortcuts.",
    confirmLabel: "Reload",
    tone: "primary",
  });
  if (!proceed) {
    return;
  }

  flushAutosave();
  sendToNative("reloadConfig");
  setTimeout(() => sendToNative("requestState"), 120);
}

async function loadFromYaml() {
  stopHotkeyRecording();
  hidePlacementPreview();

  const proceed = await showConfirmDialog({
    title: "Load configuration from YAML?",
    message: "Loading from YAML will replace the current shortcut configuration.",
    confirmLabel: "Load",
    tone: "danger",
  });
  if (!proceed) {
    return;
  }

  flushAutosave();
  sendToNative("loadFromYaml");
}

function addShortcut() {
  if (!state.config) {
    return;
  }

  const shortcut = {
    id: uid("shortcut"),
    name: "New Shortcut",
    enabled: true,
    hotkey: { key: "left", modifiers: ["cmd", "alt"] },
    cycleDisplaysOnWrap: Boolean(state.config.settings.defaultCycleDisplaysOnWrap),
    controlCenterOnly: false,
    ignoreExcludePinnedWindows: false,
    placements: [defaultGridPlacement()],
  };

  state.config.shortcuts.push(shortcut);
  state.selectedShortcutId = shortcut.id;
  state.selectedPlacementId = shortcut.placements[0].id;
  markDirty();
  pubsub.publishAll(['config', 'selection']);
}

function cloneShortcut() {
  const shortcut = selectedShortcut();
  if (!shortcut) {
    return;
  }

  const clone = {
    ...shortcut,
    id: uid("shortcut"),
    name: `${shortcut.name || "Shortcut"} Copy`,
    hotkey: {
      key: shortcut.hotkey?.key || "left",
      modifiers: [...(shortcut.hotkey?.modifiers || [])],
    },
    placements: (shortcut.placements || []).map((placement) => ({
      ...placement,
      id: uid("step"),
      grid: placement.grid ? { ...placement.grid } : null,
      rect: placement.rect ? { ...placement.rect } : null,
    })),
  };

  const sourceIndex = state.config.shortcuts.findIndex((item) => item.id === shortcut.id);
  if (sourceIndex >= 0) {
    state.config.shortcuts.splice(sourceIndex + 1, 0, clone);
  } else {
    state.config.shortcuts.push(clone);
  }
  state.selectedShortcutId = clone.id;
  state.selectedPlacementId = clone.placements[0]?.id || null;
  markDirty();
  pubsub.publishAll(['config', 'selection']);
}

function removeShortcut() {
  const shortcut = selectedShortcut();
  if (!shortcut) {
    return;
  }

  state.config.shortcuts = state.config.shortcuts.filter((item) => item.id !== shortcut.id);
  state.selectedShortcutId = state.config.shortcuts[0]?.id || null;
  state.selectedPlacementId = selectedShortcut()?.placements[0]?.id || null;
  markDirty();
  pubsub.publishAll(['config', 'selection']);
}

function toggleShortcutEnabled() {
  const shortcut = selectedShortcut();
  if (!shortcut) {
    return;
  }

  if (state.recordingShortcutId === shortcut.id) {
    stopHotkeyRecording();
  }

  shortcut.enabled = !shortcut.enabled;
  markDirty();
  pubsub.publish('config');
}

function addPlacement(mode) {
  const shortcut = selectedShortcut();
  if (!shortcut) {
    return;
  }

  const current = selectedPlacement();
  const placement = mode === "freeform" ? defaultFreeformPlacement() : defaultGridPlacement();
  if (mode === "grid" && current?.grid) {
    placement.grid.columns = current.grid.columns;
    placement.grid.rows = current.grid.rows;
    placement.grid.width = Math.max(1, Math.floor(current.grid.columns / 2));
    placement.grid.height = current.grid.rows;
  }
  const currentIndex = current ? shortcut.placements.findIndex(p => p.id === current.id) : -1;
  if (currentIndex >= 0) {
    shortcut.placements.splice(currentIndex + 1, 0, placement);
  } else {
    shortcut.placements.push(placement);
  }
  state.selectedPlacementId = placement.id;
  markDirty();
  pubsub.publishAll(['config', 'selection']);
}

function removePlacement() {
  const shortcut = selectedShortcut();
  const placement = selectedPlacement();
  if (!shortcut || !placement) {
    return;
  }

  shortcut.placements = shortcut.placements.filter((item) => item.id !== placement.id);
  state.selectedPlacementId = shortcut.placements[0]?.id || null;
  markDirty();
  pubsub.publishAll(['config', 'selection']);
}

function movePlacement(placementId, direction) {
  const shortcut = selectedShortcut();
  if (!shortcut) {
    return;
  }

  const index = shortcut.placements.findIndex((item) => item.id === placementId);
  if (index < 0) {
    return;
  }

  const nextIndex = direction === "up" ? index - 1 : index + 1;
  if (nextIndex < 0 || nextIndex >= shortcut.placements.length) {
    return;
  }

  const [item] = shortcut.placements.splice(index, 1);
  shortcut.placements.splice(nextIndex, 0, item);
  state.selectedPlacementId = item.id;
  markDirty();
  renderPlacementList();
}

function moveShortcut(shortcutId, direction) {
  const shortcuts = state.config.shortcuts;
  const index = shortcuts.findIndex((item) => item.id === shortcutId);
  if (index < 0) {
    return;
  }

  const nextIndex = direction === "up" ? index - 1 : index + 1;
  if (nextIndex < 0 || nextIndex >= shortcuts.length) {
    return;
  }

  const [shortcut] = shortcuts.splice(index, 1);
  shortcuts.splice(nextIndex, 0, shortcut);
  state.selectedShortcutId = shortcut.id;
  markDirty();
  renderShortcutList();
}

function canUseKeyboardListReorder(event) {
  if (!state.controlCenterFocused) {
    return false;
  }
  if (state.settingsModalOpen || state.moveEverythingModalOpen || state.confirmDialog) {
    return false;
  }
  if (event.defaultPrevented || event.metaKey || event.ctrlKey || event.altKey || event.shiftKey) {
    return false;
  }
  const target = event.target instanceof Element ? event.target : null;
  if ((target && isInteractiveElement(target)) ||
      (document.activeElement instanceof Element && isInteractiveElement(document.activeElement))) {
    return false;
  }
  if (typeof document.hasFocus === "function" && !document.hasFocus()) {
    return false;
  }
  return true;
}

function moveSelectedItemForLastHoveredKind(direction) {
  if (state.lastHoveredListKind === "placement") {
    const placementId = state.selectedPlacementId;
    if (!placementId) {
      return false;
    }
    movePlacement(placementId, direction);
    return true;
  }

  if (state.lastHoveredListKind === "shortcut") {
    const shortcutId = state.selectedShortcutId;
    if (!shortcutId) {
      return false;
    }
    moveShortcut(shortcutId, direction);
    return true;
  }

  return false;
}

function listItemSelector(kind) {
  return kind === "shortcut" ? ".shortcut-item" : ".placement-item";
}

function listContainerForKind(kind) {
  return kind === "shortcut" ? ids.shortcutList : ids.placementList;
}

function listItemID(kind, item) {
  if (!item) {
    return "";
  }
  return kind === "shortcut" ? item.dataset.shortcutId || "" : item.dataset.placementId || "";
}

function sameStringArray(left, right) {
  if (left.length !== right.length) {
    return false;
  }
  for (let index = 0; index < left.length; index += 1) {
    if (left[index] !== right[index]) {
      return false;
    }
  }
  return true;
}

function isInteractiveElement(target) {
  return Boolean(target.closest("button, input, select, textarea, label, a"));
}

function shouldSuppressListClick() {
  return performance.now() < state.listReorderClickSuppressUntil;
}

function suppressListReorderClickIfNeeded(event) {
  if (!shouldSuppressListClick()) {
    return false;
  }
  event.preventDefault();
  event.stopPropagation();
  return true;
}

function clearListReorderHoldTimer(drag) {
  if (!drag || drag.holdTimer === null) {
    return;
  }
  window.clearTimeout(drag.holdTimer);
  drag.holdTimer = null;
}

function startListReorderHold(event, kind) {
  if (event.button !== 0 || event.isPrimary === false) {
    return;
  }
  if (state.listReorderDrag) {
    return;
  }

  const container = listContainerForKind(kind);
  const selector = listItemSelector(kind);
  const item = event.target.closest(selector);
  if (!item || !container.contains(item) || isInteractiveElement(event.target)) {
    return;
  }

  const itemId = listItemID(kind, item);
  if (!itemId) {
    return;
  }

  const holdTimer = window.setTimeout(() => {
    activateListReorderDrag();
  }, listReorderHoldDelayMs);

  state.listReorderDrag = {
    kind,
    pointerId: event.pointerId,
    container,
    item,
    itemId,
    holdTimer,
    active: false,
    startX: event.clientX,
    startY: event.clientY,
    pointerOffsetX: 0,
    pointerOffsetY: 0,
    placeholder: null,
  };
}

function activateListReorderDrag() {
  const drag = state.listReorderDrag;
  if (!drag || drag.active) {
    return;
  }
  if (!drag.item.isConnected || !drag.container.isConnected) {
    cancelListReorderDrag();
    return;
  }

  drag.active = true;
  drag.holdTimer = null;

  const itemRect = drag.item.getBoundingClientRect();
  const naturalOffsetX = drag.startX - itemRect.left;
  const naturalOffsetY = drag.startY - itemRect.top;
  drag.pointerOffsetX = clampNumber(naturalOffsetX, 0, itemRect.width);
  drag.pointerOffsetY = clampNumber(naturalOffsetY, 0, itemRect.height);

  const placeholder = document.createElement("div");
  placeholder.className =
    drag.kind === "shortcut" ? "shortcut-drag-placeholder" : "placement-drag-placeholder";
  placeholder.style.height = `${itemRect.height}px`;
  drag.placeholder = placeholder;

  drag.container.classList.add("list-reorder-active");
  drag.item.classList.add("reorder-dragging");
  drag.item.style.width = `${itemRect.width}px`;
  drag.item.style.height = `${itemRect.height}px`;
  drag.item.style.position = "fixed";
  drag.item.style.left = `${itemRect.left}px`;
  drag.item.style.top = `${itemRect.top}px`;
  drag.item.style.zIndex = "1400";
  drag.item.style.pointerEvents = "none";

  drag.container.insertBefore(placeholder, drag.item.nextSibling);
  document.body.appendChild(drag.item);
  drag.item.setPointerCapture?.(drag.pointerId);
  positionReorderItemAtPointer(drag, drag.startX, drag.startY);
}

function positionReorderItemAtPointer(drag, clientX, clientY) {
  if (!drag?.active) {
    return;
  }
  drag.item.style.left = `${clientX - drag.pointerOffsetX}px`;
  drag.item.style.top = `${clientY - drag.pointerOffsetY}px`;
}

function moveListPlaceholderForPointer(drag, clientY) {
  if (!drag?.active || !drag.placeholder) {
    return;
  }

  const selector = listItemSelector(drag.kind);
  const items = Array.from(drag.container.querySelectorAll(selector)).filter((item) => item !== drag.item);
  let inserted = false;

  for (const item of items) {
    const rect = item.getBoundingClientRect();
    if (clientY < rect.top + rect.height / 2) {
      drag.container.insertBefore(drag.placeholder, item);
      inserted = true;
      break;
    }
  }

  if (!inserted) {
    drag.container.appendChild(drag.placeholder);
  }
}

function maybeAutoScrollListContainer(drag, clientY) {
  if (!drag?.active) {
    return;
  }

  const rect = drag.container.getBoundingClientRect();

  if (clientY < rect.top + listReorderAutoScrollEdgePx) {
    const intensity = Math.max(
      0.35,
      (rect.top + listReorderAutoScrollEdgePx - clientY) / listReorderAutoScrollEdgePx
    );
    drag.container.scrollTop -= Math.ceil(listReorderAutoScrollSpeedPx * intensity);
  } else if (clientY > rect.bottom - listReorderAutoScrollEdgePx) {
    const intensity = Math.max(
      0.35,
      (clientY - (rect.bottom - listReorderAutoScrollEdgePx)) / listReorderAutoScrollEdgePx
    );
    drag.container.scrollTop += Math.ceil(listReorderAutoScrollSpeedPx * intensity);
  }
}

function applyReorderedListFromDOM(kind, container) {
  const orderedIDs = Array.from(container.querySelectorAll(listItemSelector(kind)))
    .map((item) => listItemID(kind, item))
    .filter(Boolean);

  if (kind === "shortcut") {
    const currentIDs = state.config.shortcuts.map((item) => item.id);
    if (sameStringArray(currentIDs, orderedIDs)) {
      return false;
    }

    const lookup = new Map(state.config.shortcuts.map((shortcut) => [shortcut.id, shortcut]));
    state.config.shortcuts = orderedIDs.map((id) => lookup.get(id)).filter(Boolean);
    return true;
  }

  const shortcut = selectedShortcut();
  if (!shortcut) {
    return false;
  }

  const currentIDs = shortcut.placements.map((item) => item.id);
  if (sameStringArray(currentIDs, orderedIDs)) {
    return false;
  }

  const lookup = new Map(shortcut.placements.map((placement) => [placement.id, placement]));
  shortcut.placements = orderedIDs.map((id) => lookup.get(id)).filter(Boolean);
  return true;
}

function cleanupListReorderStyles(drag) {
  if (!drag) {
    return;
  }

  drag.container.classList.remove("list-reorder-active");

  if (drag.placeholder?.parentElement) {
    drag.placeholder.parentElement.removeChild(drag.placeholder);
  }

  drag.item.classList.remove("reorder-dragging");
  drag.item.style.width = "";
  drag.item.style.height = "";
  drag.item.style.position = "";
  drag.item.style.left = "";
  drag.item.style.top = "";
  drag.item.style.zIndex = "";
  drag.item.style.pointerEvents = "";

  try {
    if (drag.item.hasPointerCapture?.(drag.pointerId)) {
      drag.item.releasePointerCapture(drag.pointerId);
    }
  } catch {
    // Ignore browsers that don't fully support pointer capture lifecycle.
  }
}

function finishListReorderDrag() {
  const drag = state.listReorderDrag;
  if (!drag) {
    return;
  }

  clearListReorderHoldTimer(drag);

  if (!drag.active) {
    state.listReorderDrag = null;
    return;
  }

  if (drag.placeholder?.parentElement === drag.container) {
    drag.container.insertBefore(drag.item, drag.placeholder);
  }

  const changed = applyReorderedListFromDOM(drag.kind, drag.container);
  cleanupListReorderStyles(drag);

  state.listReorderClickSuppressUntil = performance.now() + listReorderClickSuppressMs;
  state.listReorderDrag = null;

  if (drag.kind === "shortcut") {
    state.selectedShortcutId = drag.itemId;
    state.selectedPlacementId = shortcutById(drag.itemId)?.placements?.[0]?.id || null;
  } else {
    state.selectedPlacementId = drag.itemId;
  }

  enforceSelection();
  if (changed) {
    markDirty();
  }
  renderAll();
}

function cancelListReorderDrag() {
  const drag = state.listReorderDrag;
  if (!drag) {
    return;
  }

  clearListReorderHoldTimer(drag);
  if (drag.active) {
    if (drag.placeholder?.parentElement === drag.container) {
      drag.container.insertBefore(drag.item, drag.placeholder);
    }
    cleanupListReorderStyles(drag);
    state.listReorderClickSuppressUntil = performance.now() + listReorderClickSuppressMs;
    renderAll();
  }
  state.listReorderDrag = null;
}

function handleListReorderPointerMove(event) {
  const drag = state.listReorderDrag;
  if (!drag || event.pointerId !== drag.pointerId) {
    return;
  }

  if (!drag.active) {
    const moveDistance = Math.hypot(event.clientX - drag.startX, event.clientY - drag.startY);
    if (moveDistance > listReorderMoveTolerancePx) {
      cancelListReorderDrag();
    }
    return;
  }

  event.preventDefault();
  positionReorderItemAtPointer(drag, event.clientX, event.clientY);
  maybeAutoScrollListContainer(drag, event.clientY);
  moveListPlaceholderForPointer(drag, event.clientY);
}

function handleListReorderPointerEnd(event) {
  const drag = state.listReorderDrag;
  if (!drag || event.pointerId !== drag.pointerId) {
    return;
  }
  if (drag.active && event.cancelable) {
    event.preventDefault();
  }
  finishListReorderDrag();
}

function flipSelectedPlacement(axis) {
  const shortcut = selectedShortcut();
  if (!shortcut) {
    showToast("Select a shortcut first", "info");
    return;
  }

  const flipAll = Boolean(ids.flipAllSteps?.checked);
  const placement = selectedPlacement();
  const targets = flipAll ? [...shortcut.placements] : (placement ? [placement] : []);

  if (!targets.length) {
    showToast("Select a step to flip", "info");
    return;
  }

  for (const target of targets) {
    if (target.mode === "grid") {
      const grid = ensureGrid(target);
      if (axis === "horizontal") {
        grid.x = grid.columns - grid.x - grid.width;
      } else {
        grid.y = grid.rows - grid.y - grid.height;
      }
    } else {
      const rect = ensureRect(target);
      if (axis === "horizontal") {
        rect.x = 1 - rect.x - rect.width;
      } else {
        rect.y = 1 - rect.y - rect.height;
      }
      ensureRect(target);
    }
  }

  markDirty();
  renderPlacementEditor();
  renderPlacementList();
  requestPlacementPreview(placement || targets[0]);
}

function updateShortcutName(value) {
  const shortcut = selectedShortcut();
  if (!shortcut) {
    return;
  }

  shortcut.name = value;
  markDirty();
  renderShortcutList();
}

function updatePlacementTitle(value) {
  const placement = selectedPlacement();
  if (!placement) {
    return;
  }

  placement.title = value;
  markDirty();
  renderPlacementList();
}

function updateDisplayTarget(value) {
  const placement = selectedPlacement();
  if (!placement) {
    return;
  }

  placement.display = value;
  markDirty();
  requestPlacementPreview(placement);
}

function updateCycleDisplaysOnWrap(value) {
  const shortcut = selectedShortcut();
  if (!shortcut) {
    return;
  }

  shortcut.cycleDisplaysOnWrap = Boolean(value);
  markDirty();
}

function updateControlCenterOnly(value) {
  const shortcut = selectedShortcut();
  if (!shortcut) {
    return;
  }

  shortcut.controlCenterOnly = Boolean(value);
  markDirty();
  renderShortcutList();
}

function updateIgnoreExcludePinnedWindows(value) {
  const shortcut = selectedShortcut();
  if (!shortcut) {
    return;
  }

  shortcut.ignoreExcludePinnedWindows = Boolean(value);
  markDirty();
}

function updateUseForRetiling(value) {
  const shortcut = selectedShortcut();
  if (!shortcut) return;
  shortcut.useForRetiling = value;
  markDirty();
  renderShortcutList();
  renderUseForRetilingError();
}

function retileDesignationErrors() {
  const errors = [];
  const iTermShortcuts = state.config.shortcuts.filter(s => s.useForRetiling === "iterm");
  const nonITermShortcuts = state.config.shortcuts.filter(s => s.useForRetiling === "non-iterm");
  if (iTermShortcuts.length > 1) {
    errors.push({ kind: "iterm", ids: iTermShortcuts.map(s => s.id), message: "Multiple shortcuts set as iTerm retile sequence" });
  }
  if (nonITermShortcuts.length > 1) {
    errors.push({ kind: "non-iterm", ids: nonITermShortcuts.map(s => s.id), message: "Multiple shortcuts set as Other retile sequence" });
  }
  return errors;
}

function renderUseForRetilingError() {
  const el = document.getElementById("useForRetilingError");
  if (!el) return;
  const shortcut = selectedShortcut();
  if (!shortcut || shortcut.useForRetiling === "no") {
    el.classList.add("hidden");
    el.textContent = "";
    return;
  }
  const errors = retileDesignationErrors();
  const relevant = errors.find(e => e.ids.includes(shortcut.id));
  if (relevant) {
    el.textContent = relevant.message;
    el.classList.remove("hidden");
  } else {
    el.classList.add("hidden");
    el.textContent = "";
  }
}

function updateSettings() {
  const previousSettings = { ...state.config.settings };

  state.config.settings.defaultGridColumns = clampInt(Number(ids.settingGridCols.value), 1, 24);
  state.config.settings.defaultGridRows = clampInt(Number(ids.settingGridRows.value), 1, 20);
  state.config.settings.gap = clampInt(Number(ids.settingGap.value), 0, 80);
  state.config.settings.defaultCycleDisplaysOnWrap = Boolean(
    ids.settingDefaultCycleDisplaysOnWrap.checked
  );
  state.config.settings.themeMode = resolveThemeMode(ids.settingThemeMode.value);
  state.config.settings.largerFonts = Boolean(ids.settingLargerFonts.checked);
  state.config.settings = normalizeSettings(state.config.settings);

  const nonThemeSettingsChanged =
    previousSettings.defaultGridColumns !== state.config.settings.defaultGridColumns ||
    previousSettings.defaultGridRows !== state.config.settings.defaultGridRows ||
    previousSettings.gap !== state.config.settings.gap ||
    previousSettings.defaultCycleDisplaysOnWrap !== state.config.settings.defaultCycleDisplaysOnWrap ||
    previousSettings.animationDuration !== state.config.settings.animationDuration;

  applyTheme();
  applyControlCenterScale();
  applyLargerFonts();
  markDirty();
  if (nonThemeSettingsChanged) {
    requestPlacementPreview();
  } else {
    hidePlacementPreview();
  }
  renderShortcutEditor();
  renderSettingsModal();
}

function applyControlCenterScaleSetting() {
  const normalizedPercent = normalizeControlCenterScalePercentInput(state.settingControlCenterScaleDraft);
  state.settingControlCenterScaleDraft = String(normalizedPercent);
  ids.settingControlCenterScale.value = state.settingControlCenterScaleDraft;

  const previousScale = clampControlCenterScale(state.config.settings.controlCenterScale);
  state.config.settings.controlCenterScale = clampControlCenterScale(normalizedPercent / 100);
  state.config.settings = normalizeSettings(state.config.settings);
  const nextScale = clampControlCenterScale(state.config.settings.controlCenterScale);

  applyControlCenterScale();

  if (Math.abs(previousScale - nextScale) < 0.0001) {
    return;
  }

  markDirty();
  renderShortcutEditor();
  renderSettingsModal();
}

function updateLaunchAtLogin(enabled) {
  sendToNative("setLaunchAtLogin", {
    enabled: Boolean(enabled),
  });
}

function setPlacementMode(mode) {
  const placement = selectedPlacement();
  if (!placement) {
    return;
  }

  if (placement.mode === mode) {
    return;
  }

  placement.mode = mode;
  if (mode === "grid") {
    placement.grid = ensureGrid(placement);
    placement.rect = null;
  } else {
    placement.rect = ensureRect(placement);
    placement.grid = null;
  }

  markDirty();
  renderPlacementEditor();
  renderPlacementList();
  requestPlacementPreview(placement);
}

function ensureGrid(placement) {
  if (!placement.grid) {
    placement.grid = { columns: 12, rows: 8, x: 0, y: 0, width: 6, height: 8 };
  }

  placement.grid.columns = clampInt(placement.grid.columns, 1, 24);
  placement.grid.rows = clampInt(placement.grid.rows, 1, 20);
  placement.grid.x = clampInt(placement.grid.x, 0, placement.grid.columns - 1);
  placement.grid.y = clampInt(placement.grid.y, 0, placement.grid.rows - 1);
  placement.grid.width = clampInt(placement.grid.width, 1, placement.grid.columns - placement.grid.x);
  placement.grid.height = clampInt(placement.grid.height, 1, placement.grid.rows - placement.grid.y);
  return placement.grid;
}

function ensureRect(placement) {
  if (!placement.rect) {
    placement.rect = { x: 0.1, y: 0.1, width: 0.8, height: 0.8 };
  }

  placement.rect.x = clampNumber(placement.rect.x, 0, 1);
  placement.rect.y = clampNumber(placement.rect.y, 0, 1);
  placement.rect.width = clampNumber(placement.rect.width, 0.05, 1);
  placement.rect.height = clampNumber(placement.rect.height, 0.05, 1);
  if (placement.rect.x + placement.rect.width > 1) {
    placement.rect.x = 1 - placement.rect.width;
  }
  if (placement.rect.y + placement.rect.height > 1) {
    placement.rect.y = 1 - placement.rect.height;
  }
  return placement.rect;
}

function gridBoundsSnapshot(grid) {
  return { x: grid.x, y: grid.y, width: grid.width, height: grid.height };
}

function sameGridBounds(left, right) {
  return (
    left.x === right.x &&
    left.y === right.y &&
    left.width === right.width &&
    left.height === right.height
  );
}

function sameRect(left, right, epsilon = 1e-6) {
  return (
    Math.abs(left.x - right.x) <= epsilon &&
    Math.abs(left.y - right.y) <= epsilon &&
    Math.abs(left.width - right.width) <= epsilon &&
    Math.abs(left.height - right.height) <= epsilon
  );
}

function commitGridDragIfNeeded() {
  const drag = state.gridDrag;
  state.gridDrag = null;
  if (!drag) {
    return;
  }

  const placement = selectedPlacement();
  if (!placement || placement.id !== drag.placementId || placement.mode !== "grid") {
    return;
  }

  const grid = ensureGrid(placement);
  if (sameGridBounds(gridBoundsSnapshot(grid), drag.startGrid)) {
    return;
  }

  markDirty();
  renderPlacementList();
}

function commitFreeDragIfNeeded() {
  const drag = state.freeDrag;
  state.freeDrag = null;
  if (!drag) {
    return;
  }

  const placement = selectedPlacement();
  if (!placement || placement.id !== drag.placementId || placement.mode !== "freeform") {
    return;
  }

  const rect = ensureRect(placement);
  if (sameRect(rect, drag.startRect)) {
    return;
  }

  markDirty();
  renderPlacementList();
}

function handleGridCellDrag(event) {
  const placement = selectedPlacement();
  if (!placement || placement.mode !== "grid") {
    return;
  }

  const grid = ensureGrid(placement);
  const cell = event.target.closest(".grid-cell");
  if (!cell) {
    return;
  }

  const x = Number(cell.dataset.cellX);
  const y = Number(cell.dataset.cellY);

  if (!state.gridDrag) {
    state.gridDrag = {
      placementId: placement.id,
      startX: x,
      startY: y,
      startGrid: gridBoundsSnapshot(grid),
    };
  }

  applyGridSelection(grid, state.gridDrag.startX, state.gridDrag.startY, x, y);
  renderGridCanvas();
  renderPlacementList();
  requestPlacementPreview(placement);
}

function applyGridSelection(grid, startX, startY, endX, endY) {
  grid.x = Math.min(startX, endX);
  grid.y = Math.min(startY, endY);
  grid.width = Math.abs(endX - startX) + 1;
  grid.height = Math.abs(endY - startY) + 1;
}

function updateGridDimensions() {
  const placement = selectedPlacement();
  if (!placement || placement.mode !== "grid") {
    return;
  }

  const grid = ensureGrid(placement);
  grid.columns = clampInt(Number(ids.gridCols.value), 1, 24);
  grid.rows = clampInt(Number(ids.gridRows.value), 1, 20);
  ensureGrid(placement);
  markDirty();
  renderGridCanvas();
  requestPlacementPreview(placement);
}

function updateFreeRange(field, value) {
  const placement = selectedPlacement();
  if (!placement || placement.mode !== "freeform") {
    return;
  }

  const rect = ensureRect(placement);
  rect[field] = Number(value);
  ensureRect(placement);
  markDirty();
  syncFreeLabels(rect);
  syncFreeCanvas(rect);
  requestPlacementPreview(placement);
}

function startHotkeyRecording() {
  const shortcut = selectedShortcut();
  if (!shortcut) {
    return;
  }

  if (state.recordingMoveEverythingField) {
    stopMoveEverythingHotkeyRecording({ silent: true });
  }

  if (state.recordingShortcutId) {
    stopHotkeyRecording({ silent: true });
  }

  sendToNative("beginHotkeyCapture");
  state.recordingShortcutId = shortcut.id;
  state.massRecordingOrder = null;
  state.massRecordingIndex = -1;
  pubsub.publish('hotkeys');
}

function startMassHotkeyRecording() {
  const shortcuts = state.config?.shortcuts || [];
  if (!shortcuts.length) {
    showToast("Add at least one shortcut before recording all hotkeys.", "info");
    return;
  }

  if (state.recordingMoveEverythingField) {
    stopMoveEverythingHotkeyRecording({ silent: true });
  }

  if (isMassRecordingActive()) {
    stopHotkeyRecording({ cancelled: true });
    return;
  }

  if (state.recordingShortcutId) {
    stopHotkeyRecording({ silent: true });
  }

  const order = shortcuts.map((shortcut) => shortcut.id);
  sendToNative("beginHotkeyCapture");
  state.massRecordingOrder = order;
  state.massRecordingIndex = 0;
  state.recordingShortcutId = order[0];
  state.selectedShortcutId = order[0];
  state.selectedPlacementId = shortcutById(order[0])?.placements?.[0]?.id || null;
  pubsub.publishAll(['hotkeys', 'selection']);
  showToast("Recording all hotkeys. Press a combo for each shortcut in order.", "info");
}

function stopHotkeyRecording(options = {}) {
  const { cancelled = false, silent = false } = options;
  const wasMass = isMassRecordingActive();

  if (state.recordingShortcutId) {
    sendToNative("endHotkeyCapture");
  }

  state.recordingShortcutId = null;
  state.massRecordingOrder = null;
  state.massRecordingIndex = -1;
  pubsub.publish('hotkeys');

  if (!silent && cancelled && wasMass) {
    showToast("Stopped recording all hotkeys.", "info");
  }
}

function startMoveEverythingHotkeyRecording(field) {
  if (!moveEverythingHotkeyFieldOrder.includes(field)) {
    return;
  }

  if (state.recordingShortcutId) {
    stopHotkeyRecording({ silent: true });
  }

  if (state.recordingMoveEverythingField === field) {
    stopMoveEverythingHotkeyRecording({ silent: true });
    return;
  }

  if (state.recordingMoveEverythingField) {
    stopMoveEverythingHotkeyRecording({ silent: true });
  }

  sendToNative("beginHotkeyCapture");
  state.recordingMoveEverythingField = field;
  renderMoveEverythingModal();
}

function stopMoveEverythingHotkeyRecording(options = {}) {
  const { silent = false } = options;

  if (state.recordingMoveEverythingField) {
    sendToNative("endHotkeyCapture");
  }

  state.recordingMoveEverythingField = null;
  renderMoveEverythingModal();

  if (!silent) {
    showToast("Stopped Window List hotkey capture.", "info");
  }
}

function clearMoveEverythingHotkey(field) {
  if (!moveEverythingHotkeyFieldOrder.includes(field)) {
    return;
  }

  const settings = state.config.settings;
  settings[field] = null;
  markDirty();
  renderMoveEverythingButton();
  renderMoveEverythingModal();
}

function maybeRecordMoveEverythingHotkey(event) {
  const field = state.recordingMoveEverythingField;
  if (!field) {
    return;
  }

  event.preventDefault();
  event.stopPropagation();

  if (event.key === "Escape") {
    stopMoveEverythingHotkeyRecording({ silent: true });
    return;
  }

  if (["Shift", "Meta", "Control", "Alt", "Fn"].includes(event.key)) {
    return;
  }

  const key = normalizeHotkeyKey(event);
  if (!key) {
    showToast("Unsupported key for hotkey", "error");
    return;
  }

  const modifiers = [];
  if (event.metaKey) modifiers.push("cmd");
  if (event.ctrlKey) modifiers.push("ctrl");
  if (event.altKey) modifiers.push("alt");
  if (event.shiftKey) modifiers.push("shift");
  if (event.getModifierState && event.getModifierState("Fn")) modifiers.push("fn");

  state.config.settings[field] = { key, modifiers };
  markDirty();
  stopMoveEverythingHotkeyRecording({ silent: true });
  renderMoveEverythingButton();
  renderMoveEverythingModal();
}

function advanceMassHotkeyRecording() {
  if (!isMassRecordingActive()) {
    return;
  }

  const nextIndex = state.massRecordingIndex + 1;
  if (nextIndex >= state.massRecordingOrder.length) {
    const firstShortcutID = state.massRecordingOrder[0] || null;
    stopHotkeyRecording({ silent: true });
    state.selectedShortcutId = firstShortcutID;
    state.selectedPlacementId = shortcutById(firstShortcutID)?.placements?.[0]?.id || null;
    pubsub.publishAll(['hotkeys', 'selection']);
    showToast("Recorded hotkeys for all shortcuts.", "success");
    return;
  }

  state.massRecordingIndex = nextIndex;
  const nextShortcutID = state.massRecordingOrder[nextIndex];
  state.recordingShortcutId = nextShortcutID;
  state.selectedShortcutId = nextShortcutID;
  state.selectedPlacementId = shortcutById(nextShortcutID)?.placements?.[0]?.id || null;
  pubsub.publishAll(['hotkeys', 'selection']);
}

function maybeRecordHotkey(event) {
  if (!state.recordingShortcutId) {
    return;
  }

  const shortcut = shortcutById(state.recordingShortcutId);
  if (!shortcut) {
    stopHotkeyRecording({ silent: true });
    return;
  }

  event.preventDefault();
  event.stopPropagation();

  if (event.key === "Escape") {
    stopHotkeyRecording({ cancelled: true });
    return;
  }

  if (["Shift", "Meta", "Control", "Alt", "Fn"].includes(event.key)) {
    return;
  }

  const key = normalizeHotkeyKey(event);
  if (!key) {
    showToast("Unsupported key for hotkey", "error");
    return;
  }

  const modifiers = [];
  if (event.metaKey) modifiers.push("cmd");
  if (event.ctrlKey) modifiers.push("ctrl");
  if (event.altKey) modifiers.push("alt");
  if (event.shiftKey) modifiers.push("shift");
  if (event.getModifierState && event.getModifierState("Fn")) modifiers.push("fn");

  shortcut.hotkey = {
    key,
    modifiers,
  };

  const conflictingShortcuts = conflictingShortcutNamesFor(
    shortcut.hotkey,
    shortcut.id
  );
  if (conflictingShortcuts.length > 0) {
    const names = conflictingShortcuts.join(", ");
    const noun = conflictingShortcuts.length === 1 ? "shortcut" : "shortcuts";
    showToast(
      `Hotkey conflict with ${noun}: ${names}. Update one of them to resolve.`,
      "info"
    );
  }

  markDirty();
  if (isMassRecordingActive()) {
    advanceMassHotkeyRecording();
    return;
  }

  stopHotkeyRecording({ silent: true });
  renderShortcutList();
  renderShortcutEditor();
}

function normalizeHotkeyKey(event) {
  const code = event.code || "";
  const key = event.key;

  if (/^Numpad[0-9]$/.test(code)) {
    return `keypad${code.slice("Numpad".length)}`;
  }

  const numpadCodeMap = {
    NumpadMultiply: "keypad_asterisk",
    NumpadAdd: "keypad_plus",
    NumpadSubtract: "keypad_minus",
    NumpadDivide: "keypad_slash",
    NumpadDecimal: "keypad_period",
    NumpadEnter: "keypad_enter",
    NumpadEqual: "keypad_equal",
    NumpadClear: "keypad_clear",
  };

  if (numpadCodeMap[code]) {
    return numpadCodeMap[code];
  }

  const table = {
    ArrowLeft: "left",
    ArrowRight: "right",
    ArrowUp: "up",
    ArrowDown: "down",
    Escape: "escape",
    Enter: "return",
    Backspace: "delete",
    Delete: "forwarddelete",
    Home: "home",
    End: "end",
    PageUp: "pageup",
    PageDown: "pagedown",
    Tab: "tab",
    CapsLock: "capslock",
    Help: "help",
    " ": "space",
    ",": "comma",
    ".": "period",
    "/": "slash",
    "\\": "backslash",
    "-": "minus",
    "=": "equal",
    "`": "grave",
    ";": "semicolon",
    "'": "quote",
    "[": "leftbracket",
    "]": "rightbracket",
  };

  if (table[key]) {
    return table[key];
  }

  const shiftedSymbolTable = {
    "!": "exclamation",
    "@": "at",
    "#": "hash",
    $: "dollar",
    "%": "percent",
    "^": "caret",
    "&": "ampersand",
    "*": "asterisk",
    "(": "leftparen",
    ")": "rightparen",
    _: "underscore",
    "+": "plus",
    "{": "leftbrace",
    "}": "rightbrace",
    "|": "pipe",
    ":": "colon",
    "\"": "doublequote",
    "<": "lessthan",
    ">": "greaterthan",
    "?": "question",
    "~": "tilde",
  };

  if (shiftedSymbolTable[key]) {
    return shiftedSymbolTable[key];
  }

  if (/^F\d{1,2}$/i.test(key)) {
    return key.toLowerCase();
  }

  if (/^[a-z0-9]$/i.test(key)) {
    return key.toLowerCase();
  }

  return null;
}

function formatHotkey(hotkey) {
  if (!hotkey) {
    return "Unassigned";
  }

  const sorted = [...(hotkey.modifiers || [])].sort(
    (left, right) => modifierOrder.indexOf(left) - modifierOrder.indexOf(right)
  );

  const labels = sorted.map((modifier) => {
    if (modifier === "cmd") return "Cmd";
    if (modifier === "ctrl") return "Ctrl";
    if (modifier === "alt") return "Opt";
    if (modifier === "shift") return "Shift";
    if (modifier === "fn") return "Fn";
    return modifier;
  });

  labels.push(formatKeyLabel(hotkey.key || "?"));
  return labels.join(" + ");
}

function formatKeyLabel(value) {
  const map = {
    left: "Left",
    right: "Right",
    up: "Up",
    down: "Down",
    return: "Return",
    pageup: "PageUp",
    pagedown: "PageDown",
    equal: "=",
    minus: "-",
    comma: ",",
    period: ".",
    slash: "/",
    backslash: "\\",
    quote: "'",
    doublequote: "\"",
    semicolon: ";",
    leftbracket: "[",
    rightbracket: "]",
    grave: "`",
    exclamation: "!",
    at: "@",
    hash: "#",
    dollar: "$",
    percent: "%",
    caret: "^",
    ampersand: "&",
    asterisk: "*",
    leftparen: "(",
    rightparen: ")",
    underscore: "_",
    plus: "+",
    leftbrace: "{",
    rightbrace: "}",
    pipe: "|",
    colon: ":",
    lessthan: "<",
    greaterthan: ">",
    question: "?",
    tilde: "~",
    tab: "Tab",
    capslock: "CapsLock",
    help: "Help",
    forwarddelete: "ForwardDelete",
    keypad0: "Num0",
    keypad1: "Num1",
    keypad2: "Num2",
    keypad3: "Num3",
    keypad4: "Num4",
    keypad5: "Num5",
    keypad6: "Num6",
    keypad7: "Num7",
    keypad8: "Num8",
    keypad9: "Num9",
    keypadasterisk: "Num*",
    keypadmultiply: "Num*",
    keypadplus: "Num+",
    keypadminus: "Num-",
    keypadslash: "Num/",
    keypaddivide: "Num/",
    keypadperiod: "Num.",
    keypaddecimal: "Num.",
    keypadenter: "NumEnter",
    keypadequal: "Num=",
    keypadequals: "Num=",
    keypadclear: "NumClear",
  };

  const normalized = String(value || "")
    .toLowerCase()
    .replace(/[\s_-]+/g, "");

  if (map[normalized]) {
    return map[normalized];
  }

  return value.length <= 2 ? value.toUpperCase() : value;
}

function conflictingShortcutNamesFor(hotkey, activeShortcutID) {
  const activeSignature = hotkeySignature(hotkey);
  if (!activeSignature) {
    return [];
  }

  const conflicting = [];
  for (const shortcut of state.config.shortcuts) {
    if (shortcut.id === activeShortcutID) {
      continue;
    }
    if (!shortcut.enabled) {
      continue;
    }

    if (hotkeySignature(shortcut.hotkey) === activeSignature) {
      conflicting.push(shortcut.name || shortcut.id || "Unnamed shortcut");
    }
  }
  return conflicting;
}

function hotkeySignature(hotkey) {
  if (!hotkey || !hotkey.key) {
    return "";
  }

  const key = String(hotkey.key).toLowerCase().trim();
  const modifiers = [...new Set((hotkey.modifiers || []).map((item) => String(item).toLowerCase().trim()))]
    .filter(Boolean)
    .sort((left, right) => modifierOrder.indexOf(left) - modifierOrder.indexOf(right));

  return `${key}|${modifiers.join("+")}`;
}

function placementDisplayTitle(placement) {
  const title = String(placement.title || "").trim();
  if (title) {
    return title;
  }

  if (placement.mode === "grid") {
    const grid = ensureGrid(placement);
    return `Grid ${grid.width}x${grid.height} @ (${grid.x},${grid.y})`;
  }

  const rect = ensureRect(placement);
  const x = Math.round(rect.x * 100);
  const y = Math.round(rect.y * 100);
  const width = Math.round(rect.width * 100);
  const height = Math.round(rect.height * 100);
  return `Frame ${width}%x${height}% @ (${x}%,${y}%)`;
}

function iconActionButton(symbol, action, placementId, disabled = false) {
  const button = document.createElement("button");
  button.className = "mini-action";
  button.textContent = symbol;
  button.dataset.action = action;
  button.dataset.placementId = placementId;
  button.disabled = disabled;
  return button;
}

function clampInt(value, min, max) {
  if (Number.isNaN(value)) {
    return min;
  }
  return Math.max(min, Math.min(max, Math.round(value)));
}

function clampNumber(value, min, max) {
  if (Number.isNaN(value)) {
    return min;
  }
  return Math.max(min, Math.min(max, value));
}

function clampControlCenterScale(value) {
  const numericValue = Number(value);
  if (!Number.isFinite(numericValue)) {
    return defaultControlCenterScale;
  }
  return clampNumber(numericValue, minControlCenterScale, maxControlCenterScale);
}

function normalizeHotkeyObject(value) {
  if (!value || typeof value !== "object") {
    return null;
  }

  const key = String(value.key || "")
    .trim()
    .toLowerCase();
  if (!key) {
    return null;
  }

  const modifiers = [...new Set((value.modifiers || []).map((modifier) => String(modifier).trim().toLowerCase()))]
    .filter((modifier) => modifierOrder.includes(modifier))
    .sort((left, right) => modifierOrder.indexOf(left) - modifierOrder.indexOf(right));

  return {
    key,
    modifiers,
  };
}

function normalizeMoveEverythingOverlayMode(value) {
  const normalized = String(value || "")
    .trim()
    .toLowerCase();
  if (moveEverythingOverlayModeLookup.has(normalized)) {
    return normalized;
  }
  return defaultMoveEverythingOverlayMode;
}

function normalizeMoveEverythingQuickViewVerticalMode(value) {
  const normalized = String(value || "").trim().toLowerCase();
  switch (normalized) {
    case "fullheight":
      return "fullHeight";
    case "fromcursor":
      return "fromCursor";
    case "padded":
      return "padded";
    default:
      return "fromCursor";
  }
}

function normalizeMoveEverythingRetileOrder(value) {
  const normalized = String(value || "").trim().toLowerCase();
  switch (normalized) {
    case "lefttoright":
      return "leftToRight";
    case "innermostfirst":
      return "innermostFirst";
    default:
      return "leftToRight";
  }
}

function normalizeMoveEverythingMoveOnSelectionMode(value) {
  const normalized = String(value || "").trim();
  switch (normalized.toLowerCase()) {
    case "never":
      return "never";
    case "minicontrolcenterontop":
    case "advancedcontrolcenterontop":
      return "miniControlCenterOnTop";
    case "controlcenteronly":
    case "controlcenteronce":
      return "miniControlCenterOnTop";
    case "firstselection":
      return "firstSelection";
    case "always":
      return "always";
    default:
      return defaultMoveEverythingMoveOnSelectionMode;
  }
}

function normalizeSettings(settings) {
  const defaults = createDefaultConfig().settings;
  const source = settings || defaults;
  const themeMode = resolveThemeMode(source.themeMode, source.darkMode);
  const moveEverythingMoveOnSelection = normalizeMoveEverythingMoveOnSelectionMode(
    source.moveEverythingMoveOnSelection ?? defaults.moveEverythingMoveOnSelection
  );
  return {
    defaultGridColumns: clampInt(Number(source.defaultGridColumns), 1, 24),
    defaultGridRows: clampInt(Number(source.defaultGridRows), 1, 20),
    gap: clampInt(Number(source.gap), 0, 80),
    defaultCycleDisplaysOnWrap: Boolean(source.defaultCycleDisplaysOnWrap),
    animationDuration: clampNumber(Number(source.animationDuration), 0, 30),
    controlCenterScale: clampControlCenterScale(source.controlCenterScale),
    largerFonts: Boolean(source.largerFonts),
    themeMode,
    moveEverythingMoveOnSelection,
    moveEverythingCenterWidthPercent: clampNumber(
      Number(source.moveEverythingCenterWidthPercent ?? defaults.moveEverythingCenterWidthPercent),
      minMoveEverythingPercent,
      maxMoveEverythingPercent
    ),
    moveEverythingCenterHeightPercent: clampNumber(
      Number(source.moveEverythingCenterHeightPercent ?? defaults.moveEverythingCenterHeightPercent),
      minMoveEverythingPercent,
      maxMoveEverythingPercent
    ),
    moveEverythingStartAlwaysOnTop: Boolean(
      source.moveEverythingStartAlwaysOnTop ?? defaults.moveEverythingStartAlwaysOnTop
    ),
    moveEverythingStartMoveToBottom: Boolean(
      source.moveEverythingStartMoveToBottom ?? defaults.moveEverythingStartMoveToBottom
    ),
    moveEverythingAdvancedControlCenterHover: Boolean(
      source.moveEverythingAdvancedControlCenterHover ??
        defaults.moveEverythingAdvancedControlCenterHover
    ),
    moveEverythingStickyHoverStealFocus: Boolean(
      source.moveEverythingStickyHoverStealFocus ??
        defaults.moveEverythingStickyHoverStealFocus
    ),
    moveEverythingCloseHideHotkeysOutsideMode: Boolean(
      source.moveEverythingCloseHideHotkeysOutsideMode ??
        defaults.moveEverythingCloseHideHotkeysOutsideMode
    ),
    moveEverythingCloseMuxKill: source.moveEverythingCloseMuxKill ?? defaults.moveEverythingCloseMuxKill,
    moveEverythingExcludePinnedWindows: Boolean(
      source.moveEverythingExcludePinnedWindows ??
        source.moveEverythingExcludeControlCenter ??
        defaults.moveEverythingExcludePinnedWindows
    ),
    moveEverythingQuickViewVerticalMode: normalizeMoveEverythingQuickViewVerticalMode(
      source.moveEverythingQuickViewVerticalMode ?? defaults.moveEverythingQuickViewVerticalMode
    ),
    moveEverythingRetileOrder: normalizeMoveEverythingRetileOrder(
      source.moveEverythingRetileOrder ?? defaults.moveEverythingRetileOrder
    ),
    moveEverythingITermGroupByRepository: source.moveEverythingITermGroupByRepository !== false,
    moveEverythingMiniRetileWidthPercent: clampNumber(
      Number(source.moveEverythingMiniRetileWidthPercent ?? defaults.moveEverythingMiniRetileWidthPercent),
      5,
      100
    ),
    moveEverythingBackgroundRefreshInterval: clampNumber(
      Number(source.moveEverythingBackgroundRefreshInterval ?? defaults.moveEverythingBackgroundRefreshInterval),
      0.5,
      30
    ),
    moveEverythingITermRecentActivityTimeout: clampNumber(
      Number(
        source.moveEverythingITermRecentActivityTimeout ??
          defaults.moveEverythingITermRecentActivityTimeout
      ),
      0,
      300
    ),
    moveEverythingITermRecentActivityBuffer: clampNumber(
      Number(
        source.moveEverythingITermRecentActivityBuffer ??
          defaults.moveEverythingITermRecentActivityBuffer
      ),
      0,
      300
    ),
    moveEverythingITermRecentActivityActiveText: String(
      source.moveEverythingITermRecentActivityActiveText ??
        defaults.moveEverythingITermRecentActivityActiveText
    ).trim(),
    moveEverythingITermRecentActivityIdleText: String(
      source.moveEverythingITermRecentActivityIdleText ??
        defaults.moveEverythingITermRecentActivityIdleText
    ).trim(),
    moveEverythingITermRecentActivityBadgeEnabled: Boolean(
      source.moveEverythingITermRecentActivityBadgeEnabled ??
        defaults.moveEverythingITermRecentActivityBadgeEnabled
    ),
    moveEverythingITermBadgeFromTitle: Boolean(
      source.moveEverythingITermBadgeFromTitle ??
        defaults.moveEverythingITermBadgeFromTitle
    ),
    moveEverythingITermTitleAllCaps: Boolean(
      source.moveEverythingITermTitleAllCaps ??
        defaults.moveEverythingITermTitleAllCaps
    ),
    moveEverythingITermTitleFromBadge: Boolean(
      source.moveEverythingITermTitleFromBadge ??
        defaults.moveEverythingITermTitleFromBadge
    ),
    moveEverythingITermRecentActivityColorize: Boolean(
      source.moveEverythingITermRecentActivityColorize ??
        defaults.moveEverythingITermRecentActivityColorize
    ),
    moveEverythingITermRecentActivityColorizeNamedOnly: Boolean(
      source.moveEverythingITermRecentActivityColorizeNamedOnly ??
        defaults.moveEverythingITermRecentActivityColorizeNamedOnly
    ),
    moveEverythingITermActivityTintIntensity: clampNumber(
      Number(
        source.moveEverythingITermActivityTintIntensity ??
          defaults.moveEverythingITermActivityTintIntensity
      ),
      0.05, 1
    ),
    moveEverythingITermActivityHoldSeconds: clampNumber(
      Number(
        source.moveEverythingITermActivityHoldSeconds ??
          defaults.moveEverythingITermActivityHoldSeconds
      ),
      1, 60
    ),
    moveEverythingITermActivityOverlayOpacity: clampNumber(
      Number(
        source.moveEverythingITermActivityOverlayOpacity ??
          defaults.moveEverythingITermActivityOverlayOpacity
      ),
      0, 1
    ),
    moveEverythingITermActivityBackgroundTintEnabled: Boolean(
      source.moveEverythingITermActivityBackgroundTintEnabled ??
        defaults.moveEverythingITermActivityBackgroundTintEnabled
    ),
    moveEverythingITermActivityTabColorEnabled: Boolean(
      source.moveEverythingITermActivityTabColorEnabled ??
        defaults.moveEverythingITermActivityTabColorEnabled
    ),
    moveEverythingActiveWindowHighlightColorize: Boolean(
      source.moveEverythingActiveWindowHighlightColorize ??
        defaults.moveEverythingActiveWindowHighlightColorize
    ),
    moveEverythingActiveWindowHighlightColor: normalizeHexColor(
      source.moveEverythingActiveWindowHighlightColor ??
        defaults.moveEverythingActiveWindowHighlightColor,
      defaultMoveEverythingActiveWindowHighlightColor
    ),
    moveEverythingITermRecentActivityActiveColor: normalizeHexColor(
      source.moveEverythingITermRecentActivityActiveColor ??
        defaults.moveEverythingITermRecentActivityActiveColor,
      defaultMoveEverythingITermRecentActivityActiveColor
    ),
    moveEverythingITermRecentActivityIdleColor: normalizeHexColor(
      source.moveEverythingITermRecentActivityIdleColor ??
        defaults.moveEverythingITermRecentActivityIdleColor,
      defaultMoveEverythingITermRecentActivityIdleColor
    ),
    moveEverythingITermRecentActivityActiveColorLight: normalizeHexColor(
      source.moveEverythingITermRecentActivityActiveColorLight ??
        defaults.moveEverythingITermRecentActivityActiveColorLight,
      defaultMoveEverythingITermRecentActivityActiveColorLight
    ),
    moveEverythingITermRecentActivityIdleColorLight: normalizeHexColor(
      source.moveEverythingITermRecentActivityIdleColorLight ??
        defaults.moveEverythingITermRecentActivityIdleColorLight,
      defaultMoveEverythingITermRecentActivityIdleColorLight
    ),
    moveEverythingITermBadgeTopMargin: clampInt(
      Number(
        source.moveEverythingITermBadgeTopMargin ??
          defaults.moveEverythingITermBadgeTopMargin
      ),
      0,
      200
    ),
    moveEverythingITermBadgeRightMargin: clampInt(
      Number(
        source.moveEverythingITermBadgeRightMargin ??
          defaults.moveEverythingITermBadgeRightMargin
      ),
      0,
      200
    ),
    moveEverythingOverlayMode: normalizeMoveEverythingOverlayMode(
      source.moveEverythingOverlayMode ?? defaults.moveEverythingOverlayMode
    ),
    moveEverythingOverlayDuration: clampNumber(
      Number(source.moveEverythingOverlayDuration ?? defaults.moveEverythingOverlayDuration),
      minMoveEverythingOverlayDuration,
      maxMoveEverythingOverlayDuration
    ),
    controlCenterFrameX: source.controlCenterFrameX ?? null,
    controlCenterFrameY: source.controlCenterFrameY ?? null,
    controlCenterFrameWidth: source.controlCenterFrameWidth ?? null,
    controlCenterFrameHeight: source.controlCenterFrameHeight ?? null,
    moveEverythingStartDontMoveVibeGrid: Boolean(
      source.moveEverythingStartDontMoveVibeGrid ?? defaults.moveEverythingStartDontMoveVibeGrid
    ),
    moveEverythingCloseWindowHotkey: normalizeHotkeyObject(source.moveEverythingCloseWindowHotkey),
    moveEverythingHideWindowHotkey: normalizeHotkeyObject(source.moveEverythingHideWindowHotkey),
    moveEverythingNameWindowHotkey: normalizeHotkeyObject(source.moveEverythingNameWindowHotkey),
    moveEverythingQuickViewHotkey: normalizeHotkeyObject(source.moveEverythingQuickViewHotkey),
    moveEverythingUndoWindowMovementHotkey: normalizeHotkeyObject(
      source.moveEverythingUndoWindowMovementHotkey
    ),
    moveEverythingRedoWindowMovementHotkey: normalizeHotkeyObject(
      source.moveEverythingRedoWindowMovementHotkey
    ),
  };
}

function normalizeLaunchAtLoginState(value) {
  const source = value || {};
  return {
    supported: Boolean(source.supported),
    enabled: Boolean(source.enabled),
    requiresApproval: Boolean(source.requiresApproval),
    message: typeof source.message === "string" ? source.message : "",
  };
}

function normalizeMoveEverythingWindow(value) {
  if (!value || typeof value !== "object") {
    return null;
  }

  const key = String(value.key || "").trim();
  if (!key.length) {
    return null;
  }

  const title = String(value.title || "").trim() || "Untitled Window";
  const appName = String(value.appName || "").trim() || "App";
  const iconDataURL = typeof value.iconDataURL === "string" && value.iconDataURL.startsWith("data:image/")
    ? value.iconDataURL
    : "";
  const parsedPid = Number(value.pid);
  const pid = Number.isInteger(parsedPid) && parsedPid > 0 ? parsedPid : null;
  const parsedWindowNumber = Number(value.windowNumber);
  const windowNumber = Number.isInteger(parsedWindowNumber) && parsedWindowNumber >= 0
    ? parsedWindowNumber
    : null;
  const iTermWindowID = typeof value.iTermWindowID === "string" && value.iTermWindowID.trim()
    ? value.iTermWindowID.trim()
    : null;
  const rawFrame = value.frame && typeof value.frame === "object"
    ? {
        x: Number(value.frame.x),
        y: Number(value.frame.y),
        width: Number(value.frame.width),
        height: Number(value.frame.height),
      }
    : null;
  const frame = rawFrame &&
    Number.isFinite(rawFrame.x) &&
    Number.isFinite(rawFrame.y) &&
    Number.isFinite(rawFrame.width) &&
    Number.isFinite(rawFrame.height)
    ? rawFrame
    : null;

  const iTermActivityStatus = typeof value.iTermActivityStatus === "string" ? value.iTermActivityStatus : null;
  const iTermBadgeText = typeof value.iTermBadgeText === "string" ? value.iTermBadgeText : null;
  const iTermWindowName = typeof value.iTermWindowName === "string" ? value.iTermWindowName.trim() || null : null;
  const iTermSessionName = typeof value.iTermSessionName === "string" ? value.iTermSessionName.trim() || null : null;
  const iTermLastLine = typeof value.iTermLastLine === "string" ? value.iTermLastLine.trim() || null : null;
  const iTermProfileID = typeof value.iTermProfileID === "string" ? value.iTermProfileID.trim() || null : null;
  const iTermPaneCommand = typeof value.iTermPaneCommand === "string" ? value.iTermPaneCommand.trim() || null : null;
  const iTermPanePath = typeof value.iTermPanePath === "string" ? value.iTermPanePath.trim() || null : null;

  return {
    key,
    pid,
    windowNumber,
    iTermWindowID,
    frame,
    title,
    appName,
    isControlCenter: Boolean(value.isControlCenter),
    iconDataURL,
    isCoreGraphicsFallback: Boolean(value.isCoreGraphicsFallback),
    iTermActivityStatus,
    iTermBadgeText,
    iTermWindowName,
    iTermSessionName,
    iTermLastLine,
    iTermProfileID,
    iTermPaneCommand,
    iTermPanePath,
  };
}

function moveEverythingHiddenCoreGraphicsDedupToken(windowItem) {
  if (!windowItem || !windowItem.isCoreGraphicsFallback) {
    return "";
  }
  const key = String(windowItem.key || "");
  const keyMatch = key.match(/^(\d+)-cg-/);
  if (!keyMatch || !keyMatch[1]) {
    return "";
  }
  const normalizedTitle = String(windowItem.title || "").trim().toLocaleLowerCase();
  if (!normalizedTitle) {
    return "";
  }
  return `${keyMatch[1]}::${normalizedTitle}`;
}

function dedupeMoveEverythingHiddenWindows(hiddenWindows) {
  if (!Array.isArray(hiddenWindows) || !hiddenWindows.length) {
    return [];
  }
  const seenCoreGraphicsTokens = new Set();
  const deduped = [];
  hiddenWindows.forEach((windowItem) => {
    const token = moveEverythingHiddenCoreGraphicsDedupToken(windowItem);
    if (!token) {
      deduped.push(windowItem);
      return;
    }
    if (seenCoreGraphicsTokens.has(token)) {
      return;
    }
    seenCoreGraphicsTokens.add(token);
    deduped.push(windowItem);
  });
  return deduped;
}

function normalizeMoveEverythingWindowInventory(value) {
  const visible = Array.isArray(value?.visible)
    ? value.visible.map(normalizeMoveEverythingWindow).filter(Boolean)
    : [];
  const hiddenRaw = Array.isArray(value?.hidden)
    ? value.hidden.map(normalizeMoveEverythingWindow).filter(Boolean)
    : [];
  const hidden = dedupeMoveEverythingHiddenWindows(hiddenRaw);
  return {
    visible,
    hidden,
    undoRetileAvailable: Boolean(value?.undoRetileAvailable),
    savedPositionsPreviousAvailable: Boolean(value?.savedPositionsPreviousAvailable),
    savedPositionsNextAvailable: Boolean(value?.savedPositionsNextAvailable),
  };
}

function applyTheme() {
  const themeMode = resolveThemeMode(state.config?.settings?.themeMode, state.config?.settings?.darkMode);
  const useDark = themeMode === "dark" || (themeMode === "system" && Boolean(systemThemeMediaQuery?.matches));
  if (useDark) {
    document.documentElement.setAttribute("data-theme", "dark");
    return;
  }
  document.documentElement.removeAttribute("data-theme");
}

function applyControlCenterScale() {
  const scale = clampControlCenterScale(state.config?.settings?.controlCenterScale);
  document.documentElement.classList.toggle("control-center-scale-fallback", !supportsControlCenterZoom);
  document.documentElement.style.setProperty("--control-center-scale", String(scale));
}

function applyLargerFonts() {
  document.documentElement.classList.toggle("larger-fonts", Boolean(state.config?.settings?.largerFonts));
}

function handleSystemThemePreferenceChanged() {
  syncThemeModeSelect(state.config?.settings?.themeMode);
  applyTheme();
}

function uid(prefix) {
  const token = globalThis.crypto?.randomUUID?.() || Math.random().toString(36).slice(2, 10);
  return `${prefix}-${token}`;
}

function defaultGridPlacement() {
  const columns = clampInt(state.config?.settings?.defaultGridColumns ?? 12, 1, 24);
  const rows = clampInt(state.config?.settings?.defaultGridRows ?? 8, 1, 20);
  return {
    id: uid("step"),
    title: "",
    mode: "grid",
    display: "active",
    grid: { columns, rows, x: 0, y: 0, width: Math.max(1, Math.floor(columns / 2)), height: rows },
    rect: null,
  };
}

function defaultFreeformPlacement() {
  return {
    id: uid("step"),
    title: "",
    mode: "freeform",
    display: "active",
    grid: null,
    rect: { x: 0.1, y: 0.1, width: 0.8, height: 0.8 },
  };
}

function createDefaultConfig() {
  return {
    version: 1,
    settings: {
      defaultGridColumns: 12,
      defaultGridRows: 8,
      gap: 2,
      defaultCycleDisplaysOnWrap: false,
      animationDuration: 0,
      controlCenterScale: 1,
      largerFonts: true,
      themeMode: "system",
      moveEverythingMoveOnSelection: "miniControlCenterOnTop",
      moveEverythingCenterWidthPercent: 33,
      moveEverythingCenterHeightPercent: 70,
      moveEverythingStartAlwaysOnTop: false,
      moveEverythingStartMoveToBottom: false,
      moveEverythingAdvancedControlCenterHover: true,
      moveEverythingStickyHoverStealFocus: false,
      moveEverythingCloseHideHotkeysOutsideMode: false,
      moveEverythingCloseMuxKill: true,
      moveEverythingExcludePinnedWindows: false,
      moveEverythingQuickViewVerticalMode: "fromCursor",
      moveEverythingRetileOrder: "leftToRight",
      moveEverythingITermGroupByRepository: true,
      moveEverythingMiniRetileWidthPercent: 25,
      moveEverythingBackgroundRefreshInterval: 5,
      moveEverythingITermRecentActivityTimeout: 1,
      moveEverythingITermRecentActivityBuffer: 4,
      moveEverythingITermRecentActivityActiveText: "[ACTIVE]",
      moveEverythingITermRecentActivityIdleText: "",
      moveEverythingITermRecentActivityBadgeEnabled: false,
      moveEverythingITermBadgeFromTitle: true,
      moveEverythingITermTitleFromBadge: true,
      moveEverythingITermTitleAllCaps: false,
      moveEverythingITermRecentActivityColorize: true,
      moveEverythingITermRecentActivityColorizeNamedOnly: false,
      moveEverythingITermActivityTintIntensity: 0.25,
      moveEverythingITermActivityHoldSeconds: 7,
      moveEverythingITermActivityOverlayOpacity: 0.0,
      moveEverythingITermActivityBackgroundTintEnabled: false,
      moveEverythingITermActivityTabColorEnabled: false,
      moveEverythingActiveWindowHighlightColorize: true,
      moveEverythingActiveWindowHighlightColor: "#4D88D4",
      moveEverythingITermBadgeTopMargin: 6,
      moveEverythingITermBadgeRightMargin: 8,
      // Keep literal defaults here because createDefaultConfig() runs during
      // top-level state initialization, before later const defaults are initialized.
      moveEverythingITermRecentActivityActiveColor: "#2F8F4E",
      moveEverythingITermRecentActivityIdleColor: "#BA4D4D",
      moveEverythingITermRecentActivityActiveColorLight: "#1A7535",
      moveEverythingITermRecentActivityIdleColorLight: "#A03030",
      moveEverythingOverlayMode: "persistent",
      moveEverythingOverlayDuration: 2,
      moveEverythingCloseWindowHotkey: null,
      moveEverythingHideWindowHotkey: null,
      moveEverythingNameWindowHotkey: null,
      moveEverythingQuickViewHotkey: null,
      moveEverythingUndoWindowMovementHotkey: null,
      moveEverythingRedoWindowMovementHotkey: null,
    },
    shortcuts: [],
  };
}

function updatePermissionBadge(hasAccess) {
  ids.permissionBadge.classList.toggle("good", hasAccess);
  ids.permissionBadge.classList.toggle("warning", !hasAccess);
  ids.permissionBadge.textContent = hasAccess
    ? "Accessibility: Granted"
    : "Permissions";
  ids.permissionBadge.classList.toggle("hidden", hasAccess);
}

function updateAccessibilityState(hasAccess) {
  state.permissions.accessibility = Boolean(hasAccess);
  updatePermissionBadge(state.permissions.accessibility);
  if (state.permissions.accessibility) {
    stopPermissionPolling();
  } else {
    startPermissionPollingIfNeeded();
  }
}

function startPermissionPollingIfNeeded() {
  if (state.permissions.accessibility) {
    stopPermissionPolling();
    return;
  }
  if (permissionPollTimer !== null) {
    return;
  }

  permissionPollTimer = window.setInterval(() => {
    if (state.permissions.accessibility) {
      stopPermissionPolling();
      return;
    }
    sendToNative("requestAccessibility", { prompt: false });
  }, 1000);
}

function stopPermissionPolling() {
  if (permissionPollTimer === null) {
    return;
  }
  window.clearInterval(permissionPollTimer);
  permissionPollTimer = null;
}

function showToast(message, level = "info") {
  if (!message) {
    return;
  }

  const toast = document.createElement("div");
  toast.className = `toast ${level}`;
  toast.textContent = message;
  ids.toastStack.appendChild(toast);

  setTimeout(() => {
    toast.remove();
  }, 3200);
}

function showConfirmDialog({ title, message, confirmLabel, tone = "primary" }) {
  return new Promise((resolve) => {
    if (state.confirmDialog?.resolve) {
      state.confirmDialog.resolve(false);
    }

    state.confirmDialog = { resolve };
    ids.confirmTitle.textContent = title || "Confirm";
    ids.confirmMessage.textContent = message || "";
    ids.confirmOkBtn.textContent = confirmLabel || "Confirm";
    ids.confirmOkBtn.classList.toggle("danger", tone === "danger");
    ids.confirmOkBtn.classList.toggle("primary", tone !== "danger");
    ids.confirmModal.classList.remove("hidden");
    ids.confirmOkBtn.focus();
  });
}

function closeConfirmDialog(confirmed) {
  if (!state.confirmDialog) {
    return;
  }

  const resolve = state.confirmDialog.resolve;
  state.confirmDialog = null;
  ids.confirmModal.classList.add("hidden");
  ids.confirmOkBtn.classList.remove("danger");
  ids.confirmOkBtn.classList.add("primary");
  resolve(Boolean(confirmed));
}

function handleWindowKeyDown(event) {
  if (state.confirmDialog && event.key === "Escape") {
    event.preventDefault();
    closeConfirmDialog(false);
    return;
  }

  if (state.recordingMoveEverythingField) {
    maybeRecordMoveEverythingHotkey(event);
    return;
  }

  if (state.recordingShortcutId) {
    maybeRecordHotkey(event);
    return;
  }

  if (state.moveEverythingModalOpen && event.key === "Escape") {
    event.preventDefault();
    closeMoveEverythingModal();
    return;
  }

  if (state.settingsModalOpen && event.key === "Escape") {
    event.preventDefault();
    closeSettingsModal();
    return;
  }

  if (state.moveEverythingWindowEditor && event.key === "Escape") {
    event.preventDefault();
    closeMoveEverythingWindowEditorModal();
    return;
  }

  if (event.key !== "ArrowUp" && event.key !== "ArrowDown") {
    return;
  }

  if (!canUseKeyboardListReorder(event)) {
    return;
  }

  const direction = event.key === "ArrowUp" ? "up" : "down";
  const didMove = moveSelectedItemForLastHoveredKind(direction);
  if (didMove) {
    event.preventDefault();
  }
}

function wireEvents() {
  sendJsLog("info", "wireEvents.start");

  const on = (element, eventName, handler, options) => {
    if (!element) {
      sendJsLog("error", "wireEvents.missingElement", `${eventName}`);
      return;
    }
    element.addEventListener(eventName, handler, options);
  };

  ids.undoBtn.addEventListener("click", undoChange);
  ids.redoBtn.addEventListener("click", redoChange);
  document.getElementById("reloadBtn").addEventListener("click", reloadConfig);
  ids.permissionBadge.addEventListener("click", () => {
    if (!state.permissions.accessibility) {
      sendToNative("requestAccessibility", { prompt: true, reset: true });
    }
  });
  ids.exitBtn.addEventListener("click", () => sendToNative("exitApp"));
  on(ids.moveEverythingBtn, "click", toggleMoveEverythingFromButton);
  on(ids.moveEverythingWindowList, "pointerdown", (event) => {
    if (event.button !== 0 || event.isPrimary === false) {
      return;
    }
    handleMoveEverythingWindowListButtonEvent(event, "pointerdown");
  });
  on(ids.moveEverythingWindowList, "click", (event) => {
    if (handleMoveEverythingWindowListButtonEvent(event, "click")) {
      return;
    }
    if (handleMoveEverythingWindowListRowClick(event)) {
      return;
    }
  });
  on(ids.moveEverythingWindowList, "dblclick", (event) => {
    const target = event.target instanceof Element ? event.target : null;
    if (!target || isInteractiveElement(target)) {
      return;
    }

    const row = target.closest(".move-window-row[data-me-window-key]");
    if (!row ||
        !ids.moveEverythingWindowList.contains(row) ||
        row.classList.contains("hidden-window") ||
        row.dataset.meControlCenter === "1") {
      return;
    }

    const key = String(row.dataset.meWindowKey || "").trim();
    if (!key) {
      return;
    }

    event.preventDefault();
    sendToNative("moveEverythingFocusWindow", {
      key,
      movePointerToTopMiddle: true,
    });
  });
  let _hoverHysteresisY = null;
  on(ids.moveEverythingWindowList, "pointermove", (event) => {
    // Don't change hover while a mouse button is pressed — a DOM rebuild
    // during a click would destroy the button element and eat the click.
    if (event.buttons !== 0) {
      return;
    }
    if (event.target instanceof Element && isInteractiveElement(event.target)) {
      const interactiveRow = event.target.closest?.(".move-window-row.hidden-window[data-me-window-key]");
      if (!interactiveRow || !ids.moveEverythingWindowList.contains(interactiveRow)) {
        return;
      }
    }
    const key = resolveMoveEverythingHoverKeyFromTarget(event.target, event.clientY);
    // undefined = pointer is in the list but between rows (rounded-corner gap,
    // section header); keep the current hover and let pointerleave clear it.
    if (key === undefined) {
      return;
    }
    // Hysteresis: when switching between rows, require the cursor to move at
    // least a few pixels past the boundary before committing. This prevents
    // flickering when the cursor wobbles at the exact boundary pixel, which
    // is amplified by DOM rebuilds shifting row positions by subpixels.
    if (key !== null && key !== state.moveEverythingHoveredWindowKey &&
        state.moveEverythingHoveredWindowKey !== null) {
      if (_hoverHysteresisY !== null && Math.abs(event.clientY - _hoverHysteresisY) < 4) {
        return;
      }
      _hoverHysteresisY = event.clientY;
    } else if (key === state.moveEverythingHoveredWindowKey) {
      // Cursor is still on the same row — update the anchor point so
      // hysteresis is measured from the latest stable position.
      _hoverHysteresisY = event.clientY;
    }
    setMoveEverythingHoveredWindow(key);
  });
  on(ids.moveEverythingWindowList, "pointerleave", () => {
    setMoveEverythingHoveredWindow(null, { immediate: true });
  });
  on(ids.moveEverythingAlwaysOnTop, "change", (event) =>
    updateMoveEverythingAlwaysOnTop(event.target.checked)
  );
  on(ids.moveEverythingMoveToBottom, "change", (event) =>
    updateMoveEverythingMoveToBottom(event.target.checked)
  );
  on(ids.moveEverythingDontMoveVibeGrid, "change", (event) =>
    updateMoveEverythingDontMoveVibeGrid(event.target.checked)
  );
  on(ids.moveEverythingPinModeBtn, "click", toggleMoveEverythingPinMode);
  on(ids.moveEverythingRetileBtn, "click", retileVisibleMoveEverythingWindows);
  on(ids.moveEverythingMiniRetileBtn, "click", miniRetileVisibleMoveEverythingWindows);
  on(ids.moveEverythingHybridRetileBtn, "click", hybridRetileVisibleMoveEverythingWindows);
  on(ids.moveEverythingITermRetileBtn, "click", iTermRetileVisibleMoveEverythingWindows);
  on(ids.moveEverythingNonITermRetileBtn, "click", nonITermRetileVisibleMoveEverythingWindows);
  on(ids.moveEverythingUndoRetileBtn, "click", undoLastMoveEverythingRetile);
  on(ids.moveEverythingSaveDefaultsBtn, "click", saveCurrentMoveEverythingAsDefaults);
  on(ids.moveEverythingResetDefaultsBtn, "click", resetMoveEverythingDefaults);
  ids.settingsBtn.addEventListener("click", () => openSettingsModal());
  if (ids.narrowModeWindowsBtn) ids.narrowModeWindowsBtn.addEventListener("click", () => setNarrowPreviewMode("windows"));
  if (ids.narrowModeSequencesBtn) ids.narrowModeSequencesBtn.addEventListener("click", () => setNarrowPreviewMode("sequences"));
  // Settings tab switching
  document.querySelectorAll("[data-settings-tab]").forEach((btn) => {
    btn.addEventListener("click", () => {
      state.settingsActiveTab = btn.dataset.settingsTab;
      renderSettingsTabContent();
    });
  });
  ids.hideBtn.addEventListener("click", () => sendToNative("hideControlCenter"));
  on(document.getElementById("openYamlBtn"), "click", () => sendToNative("openConfigFile"));
  on(document.getElementById("saveAsYamlBtn"), "click", () => sendToNative("saveAsYaml"));
  on(document.getElementById("loadFromYamlBtn"), "click", loadFromYaml);

  // Hide buttons that require native (non-web) host features
  if (window.vibeGridPlatform && window.vibeGridPlatform.noNativeFeatures) {
    const openYamlBtn = document.getElementById("openYamlBtn");
    if (openYamlBtn) openYamlBtn.style.display = "none";
  }

  document.getElementById("addShortcutBtn").addEventListener("click", (event) => {
    if (suppressListReorderClickIfNeeded(event)) {
      return;
    }
    addShortcut();
  });
  document.getElementById("cloneShortcutBtn").addEventListener("click", cloneShortcut);
  document.getElementById("emptyAddShortcutBtn").addEventListener("click", (event) => {
    if (suppressListReorderClickIfNeeded(event)) {
      return;
    }
    addShortcut();
  });
  ids.toggleShortcutEnabledBtn.addEventListener("click", toggleShortcutEnabled);
  document.getElementById("removeShortcutBtn").addEventListener("click", removeShortcut);

  document.getElementById("addGridPlacementBtn").addEventListener("click", (event) => {
    if (suppressListReorderClickIfNeeded(event)) {
      return;
    }
    addPlacement("grid");
  });
  document.getElementById("addFreePlacementBtn").addEventListener("click", (event) => {
    if (suppressListReorderClickIfNeeded(event)) {
      return;
    }
    addPlacement("freeform");
  });
  const addStepInEditorBtn = document.getElementById("addStepInEditorBtn");
  if (addStepInEditorBtn) {
    addStepInEditorBtn.addEventListener("click", () => addPlacement("grid"));
  }
  ids.flipHorizontalBtn.addEventListener("click", () => flipSelectedPlacement("horizontal"));
  ids.flipVerticalBtn.addEventListener("click", () => flipSelectedPlacement("vertical"));
  document.getElementById("removePlacementBtn").addEventListener("click", removePlacement);

  ids.shortcutList.addEventListener("pointerdown", (event) => startListReorderHold(event, "shortcut"));
  ids.placementList.addEventListener("pointerdown", (event) => startListReorderHold(event, "placement"));
  window.addEventListener("pointermove", handleListReorderPointerMove, { passive: false });
  window.addEventListener("pointermove", (event) => {
    if (!reconcilePlacementHoverFromPointerTarget(livePointerTarget(event))) {
      return;
    }
    pubsub.publish('selection');
  }, { passive: true });
  window.addEventListener("pointerup", handleListReorderPointerEnd);
  window.addEventListener("pointercancel", handleListReorderPointerEnd);

  ids.shortcutList.addEventListener("pointermove", (event) => {
    const shortcutId = resolveShortcutHoverIDFromTarget(event.target, event.clientY);
    if (shortcutId) {
      if (state.hoveredShortcutId === shortcutId && state.hoveredPlacementId === null) {
        return;
      }

      state.hoveredShortcutId = shortcutId;
      state.hoveredPlacementId = null;
      state.lastHoveredListKind = "shortcut";
      pubsub.publish('selection');
      return;
    }

    if (state.hoveredShortcutId === null && state.hoveredPlacementId === null) {
      return;
    }

    state.hoveredShortcutId = null;
    state.hoveredPlacementId = null;
    pubsub.publish('selection');
  });

  ids.shortcutList.addEventListener("pointerleave", () => {
    if (state.hoveredShortcutId === null && state.hoveredPlacementId === null) {
      return;
    }

    state.hoveredShortcutId = null;
    state.hoveredPlacementId = null;
    pubsub.publish('selection');
  });

  ids.placementList.addEventListener("pointermove", (event) => {
    const placementId = resolvePlacementHoverIDFromTarget(event.target, event.clientY);
    if (!placementId) {
      if (!clearPlacementHoverState()) {
        return;
      }
      pubsub.publish('selection');
      return;
    }

    if (state.hoveredPlacementId === placementId) {
      return;
    }

    setPlacementHoverFromId(placementId);
    state.lastHoveredListKind = "placement";
    pubsub.publish('selection');
  });

  ids.placementList.addEventListener("pointerleave", () => {
    if (!clearPlacementHoverState()) {
      return;
    }

    pubsub.publish('selection');
  });

  ids.shortcutList.addEventListener("click", (event) => {
    if (suppressListReorderClickIfNeeded(event)) {
      return;
    }

    const actionTarget = event.target.closest("button[data-action]");
    if (actionTarget) {
      const shortcutId = actionTarget.dataset.placementId;
      const action = actionTarget.dataset.action;
      moveShortcut(shortcutId, action === "move-shortcut-up" ? "up" : "down");
      return;
    }

    const item = event.target.closest(".shortcut-item");
    if (!item) {
      return;
    }
    state.selectedShortcutId = item.dataset.shortcutId;
    const shortcut = shortcutById(state.selectedShortcutId);
    state.selectedPlacementId = shortcut?.placements?.[0]?.id || null;
    if (!state.selectedPlacementId) {
      hidePlacementPreview();
    }
    pubsub.publish('selection');
  });

  ids.placementList.addEventListener("click", (event) => {
    if (suppressListReorderClickIfNeeded(event)) {
      return;
    }

    const actionTarget = event.target.closest("button[data-action]");
    if (actionTarget) {
      const placementId = actionTarget.dataset.placementId;
      const action = actionTarget.dataset.action;
      movePlacement(placementId, action === "move-up" ? "up" : "down");
      return;
    }

    const item = event.target.closest(".placement-item");
    if (!item) {
      clearSelectedPlacement();
      return;
    }
    const clickedPlacementId = item.dataset.placementId || null;

    // If already selected, keep it selected (no toggle-off)
    if (clickedPlacementId &&
        clickedPlacementId === state.selectedPlacementId &&
        selectedShortcut()?.id === state.selectedShortcutId) {
      return;
    }

    state.selectedPlacementId = clickedPlacementId;
    hidePlacementPreview();
    pubsub.publish('selection');
  });

  on(ids.editorPanel, "click", (event) => {
    if (suppressListReorderClickIfNeeded(event)) {
      return;
    }

    const target = event.target;
    if (!(target instanceof Element)) {
      return;
    }

    if (target.closest(".placement-item,button,input,select,textarea,label,a,#gridCanvas,#freeCanvas,#freeRect,.resize-handle,.hotkey-preview")) {
      return;
    }

    clearSelectedPlacement();
  });

  ids.shortcutName.addEventListener("input", (event) => updateShortcutName(event.target.value));
  ids.placementTitle.addEventListener("input", (event) => updatePlacementTitle(event.target.value));
  ids.displayTarget.addEventListener("change", (event) => updateDisplayTarget(event.target.value));
  ids.cycleDisplaysOnWrap.addEventListener("change", (event) => updateCycleDisplaysOnWrap(event.target.checked));
  ids.controlCenterOnly.addEventListener("change", (event) => updateControlCenterOnly(event.target.checked));
  ids.ignoreExcludePinnedWindows.addEventListener("change", (event) => updateIgnoreExcludePinnedWindows(event.target.checked));
  document.getElementById("useForRetiling").addEventListener("change", (event) => updateUseForRetiling(event.target.value));
  ids.settingGridCols.addEventListener("input", updateSettings);
  ids.settingGridRows.addEventListener("input", updateSettings);
  ids.settingGap.addEventListener("input", updateSettings);
  ids.settingDefaultCycleDisplaysOnWrap.addEventListener("change", updateSettings);
  ids.settingThemeMode.addEventListener("change", updateSettings);
  ids.settingControlCenterScale.addEventListener("input", (event) => {
    state.settingControlCenterScaleDraft = event.target.value;
  });
  ids.settingControlCenterScale.addEventListener("keydown", (event) => {
    if (event.key !== "Enter") {
      return;
    }
    event.preventDefault();
    applyControlCenterScaleSetting();
  });
  ids.applyControlCenterScaleBtn.addEventListener("click", applyControlCenterScaleSetting);
  ids.settingLargerFonts.addEventListener("change", updateSettings);
  ids.settingLaunchAtLogin.addEventListener("change", (event) =>
    updateLaunchAtLogin(event.target.checked)
  );
  ids.openLoginItemsSettingsBtn.addEventListener("click", () => sendToNative("openLoginItemsSettings"));
  ids.revealConfigBtn.addEventListener("click", () => sendToNative("revealConfigInFinder"));
  ids.openConfigBtn.addEventListener("click", () => sendToNative("openConfigFile"));
  ids.copyConfigPathBtn.addEventListener("click", () => sendToNative("copyConfigPath"));
  if (window.vibeGridPlatform && window.vibeGridPlatform.noNativeFeatures) {
    ids.revealConfigBtn.style.display = "none";
    ids.openConfigBtn.style.display = "none";
    ids.copyConfigPathBtn.style.display = "none";
  }
  on(ids.openMoveEverythingSettingsBtn, "click", () => openSettingsModal("windowList"));

  ids.hotkeyCaptureBtn.addEventListener("click", () => {
    if (state.recordingShortcutId) {
      stopHotkeyRecording({ cancelled: true });
    } else {
      startHotkeyRecording();
    }
  });
  ids.massHotkeyCaptureBtn.addEventListener("click", startMassHotkeyRecording);

  ids.modeGridBtn.addEventListener("click", () => setPlacementMode("grid"));
  ids.modeFreeBtn.addEventListener("click", () => setPlacementMode("freeform"));

  ids.gridCols.addEventListener("input", updateGridDimensions);
  ids.gridRows.addEventListener("input", updateGridDimensions);

  ids.gridCanvas.addEventListener("mousedown", (event) => {
    if (event.button !== 0) {
      return;
    }
    handleGridCellDrag(event);
  });

  ids.gridCanvas.addEventListener("mouseover", (event) => {
    if (event.buttons !== 1) {
      return;
    }
    handleGridCellDrag(event);
  });

  window.addEventListener("mouseup", () => {
    commitGridDragIfNeeded();
    commitFreeDragIfNeeded();
    ids.freeRect.classList.remove("dragging");
    hidePlacementPreview();
  });

  ids.freeX.addEventListener("input", (event) => updateFreeRange("x", event.target.value));
  ids.freeY.addEventListener("input", (event) => updateFreeRange("y", event.target.value));
  ids.freeW.addEventListener("input", (event) => updateFreeRange("width", event.target.value));
  ids.freeH.addEventListener("input", (event) => updateFreeRange("height", event.target.value));

  ids.freeRect.addEventListener("mousedown", (event) => {
    const placement = selectedPlacement();
    if (!placement || placement.mode !== "freeform") {
      return;
    }

    const rect = ensureRect(placement);
    const canvasRect = ids.freeCanvas.getBoundingClientRect();

    state.freeDrag = {
      placementId: placement.id,
      mode: event.target.classList.contains("resize-handle") ? "resize" : "move",
      startClientX: event.clientX,
      startClientY: event.clientY,
      startRect: { ...rect },
      canvasRect,
    };

    ids.freeRect.classList.add("dragging");
    requestPlacementPreview(placement);
    event.preventDefault();
  });

  window.addEventListener("mousemove", (event) => {
    if (!state.freeDrag) {
      return;
    }

    const placement = selectedPlacement();
    if (!placement || placement.mode !== "freeform") {
      return;
    }

    const rect = ensureRect(placement);
    const drag = state.freeDrag;

    const deltaX = (event.clientX - drag.startClientX) / drag.canvasRect.width;
    const deltaY = (event.clientY - drag.startClientY) / drag.canvasRect.height;

    if (drag.mode === "move") {
      rect.x = drag.startRect.x + deltaX;
      rect.y = drag.startRect.y + deltaY;
    } else {
      rect.width = drag.startRect.width + deltaX;
      rect.height = drag.startRect.height + deltaY;
    }

    ensureRect(placement);
    syncFreeLabels(rect);
    syncFreeCanvas(rect);
    requestPlacementPreview(placement);
  });

  ids.confirmCancelBtn.addEventListener("click", () => closeConfirmDialog(false));
  ids.confirmOkBtn.addEventListener("click", () => closeConfirmDialog(true));
  ids.confirmModal.addEventListener("click", (event) => {
    if (event.target === ids.confirmModal) {
      closeConfirmDialog(false);
    }
  });
  ids.settingsExitBtn.addEventListener("click", () => sendToNative("exitApp"));
  on(ids.settingsRestoreDefaultsBtn, "click", restoreDefaultSettingsFromModal);
  ids.settingsCloseBtn.addEventListener("click", closeSettingsModal);
  ids.settingsModal.addEventListener("click", (event) => {
    if (event.target === ids.settingsModal) {
      closeSettingsModal();
    }
  });
  on(ids.moveEverythingCloseBtn, "click", closeMoveEverythingModal);
  // Hotkey record/clear buttons — delegate from the settings modal (where they now live)
  const hotkeyDelegateTarget = ids.settingsModal || ids.moveEverythingModal;
  if (hotkeyDelegateTarget) {
    hotkeyDelegateTarget.addEventListener("click", (event) => {
      if (event.target.matches("input[type='checkbox']")) {
        return;
      }

      const recordBtn = event.target.closest("button[data-me-record]");
      if (recordBtn) {
        startMoveEverythingHotkeyRecording(recordBtn.dataset.meRecord);
        return;
      }

      const clearBtn = event.target.closest("button[data-me-clear]");
      if (clearBtn) {
        clearMoveEverythingHotkey(clearBtn.dataset.meClear);
      }
    });
  }
  on(ids.moveEverythingWindowEditorCancelBtn, "click", closeMoveEverythingWindowEditorModal);
  on(ids.moveEverythingWindowEditorResetBtn, "click", resetMoveEverythingWindowEditorFields);
  on(ids.moveEverythingWindowEditorBadgeColorInput, "input", syncMoveEverythingWindowEditorBadgeColorSwatchSelection);
  on(ids.moveEverythingWindowEditorBadgeOpacityInput, "input", () => {
    if (ids.moveEverythingWindowEditorBadgeOpacityLabel && ids.moveEverythingWindowEditorBadgeOpacityInput) {
      ids.moveEverythingWindowEditorBadgeOpacityLabel.textContent = `${ids.moveEverythingWindowEditorBadgeOpacityInput.value}%`;
    }
  });
  if (ids.moveEverythingWindowEditorBadgeColorSwatches) {
    ids.moveEverythingWindowEditorBadgeColorSwatches.addEventListener("click", (event) => {
      const swatch = event.target.closest(".badge-color-swatch");
      if (!swatch) {
        return;
      }
      const color = normalizeHexColor(swatch.dataset.color, "");
      if (color && ids.moveEverythingWindowEditorBadgeColorInput) {
        ids.moveEverythingWindowEditorBadgeColorInput.value = color;
        syncMoveEverythingWindowEditorBadgeColorSwatchSelection();
      }
    });
  }
  on(ids.moveEverythingWindowEditorModal, "click", (event) => {
    if (event.target === ids.moveEverythingWindowEditorModal) {
      closeMoveEverythingWindowEditorModal();
    }
  });
  on(ids.moveEverythingWindowEditorForm, "submit", (event) => {
    event.preventDefault();
    submitMoveEverythingWindowEditor();
  });
  on(ids.moveEverythingCloseHideOutsideMode, "change", updateMoveEverythingSettings);
  on(ids.moveEverythingStartAlwaysOnTopSetting, "change", updateMoveEverythingSettings);
  on(ids.moveEverythingStickyHoverStealFocusSetting, "change", updateMoveEverythingSettings);
  on(ids.moveEverythingCloseMuxKillSetting, "change", updateMoveEverythingSettings);
  on(ids.moveEverythingExcludePinnedWindowsSetting, "change", updateMoveEverythingSettings);
  on(ids.moveEverythingMiniRetileWidthPercentSetting, "change", updateMoveEverythingSettings);
  on(ids.moveEverythingRetileOrderSetting, "change", updateMoveEverythingSettings);
  on(ids.moveEverythingQuickViewVerticalModeSetting, "change", updateMoveEverythingSettings);
  on(ids.moveEverythingITermGroupByRepositorySetting, "change", updateMoveEverythingSettings);
  on(ids.moveEverythingBackgroundRefreshIntervalSetting, "change", updateMoveEverythingSettings);
  on(ids.moveEverythingBackgroundRefreshIntervalSetting, "input", updateMoveEverythingSettings);
  on(ids.moveEverythingITermRecentActivityTimeoutSetting, "change", updateMoveEverythingSettings);
  on(ids.moveEverythingITermRecentActivityTimeoutSetting, "input", updateMoveEverythingSettings);
  on(ids.moveEverythingITermRecentActivityBufferSetting, "change", updateMoveEverythingSettings);
  on(ids.moveEverythingITermRecentActivityBufferSetting, "input", updateMoveEverythingSettings);
  on(ids.moveEverythingITermRecentActivityActiveTextSetting, "change", updateMoveEverythingSettings);
  on(ids.moveEverythingITermRecentActivityActiveTextSetting, "input", updateMoveEverythingSettings);
  on(ids.moveEverythingITermRecentActivityIdleTextSetting, "change", updateMoveEverythingSettings);
  on(ids.moveEverythingITermRecentActivityIdleTextSetting, "input", updateMoveEverythingSettings);
  on(ids.moveEverythingITermRecentActivityBadgeEnabledSetting, "change", updateMoveEverythingSettings);
  on(ids.moveEverythingITermBadgeFromTitleSetting, "change", updateMoveEverythingSettings);
  on(ids.moveEverythingITermTitleFromBadgeSetting, "change", updateMoveEverythingSettings);
  on(ids.moveEverythingITermTitleAllCapsSetting, "change", updateMoveEverythingSettings);
  on(ids.moveEverythingITermRecentActivityColorizeSetting, "change", updateMoveEverythingSettings);
  on(ids.moveEverythingITermRecentActivityColorizeNamedOnlySetting, "change", updateMoveEverythingSettings);
  on(ids.moveEverythingITermActivityTintIntensitySetting, "change", updateMoveEverythingSettings);
  on(ids.moveEverythingITermActivityTintIntensitySetting, "input", updateMoveEverythingSettings);
  on(ids.moveEverythingITermActivityHoldSecondsSetting, "change", updateMoveEverythingSettings);
  on(ids.moveEverythingITermActivityHoldSecondsSetting, "input", updateMoveEverythingSettings);
  on(ids.moveEverythingITermActivityOverlayOpacitySetting, "change", updateMoveEverythingSettings);
  on(ids.moveEverythingITermActivityOverlayOpacitySetting, "input", updateMoveEverythingSettings);
  on(ids.moveEverythingITermActivityBackgroundTintEnabledSetting, "change", updateMoveEverythingSettings);
  on(ids.moveEverythingITermActivityTabColorEnabledSetting, "change", updateMoveEverythingSettings);
  on(ids.moveEverythingActiveWindowHighlightColorizeSetting, "change", updateMoveEverythingSettings);
  on(ids.moveEverythingActiveWindowHighlightColorSetting, "change", updateMoveEverythingSettings);
  on(ids.moveEverythingActiveWindowHighlightColorSetting, "input", updateMoveEverythingSettings);
  on(ids.moveEverythingITermRecentActivityActiveColorSetting, "change", updateMoveEverythingSettings);
  on(ids.moveEverythingITermRecentActivityActiveColorSetting, "input", updateMoveEverythingSettings);
  on(ids.moveEverythingITermRecentActivityIdleColorSetting, "change", updateMoveEverythingSettings);
  on(ids.moveEverythingITermRecentActivityIdleColorSetting, "input", updateMoveEverythingSettings);
  on(ids.moveEverythingITermRecentActivityActiveColorLightSetting, "change", updateMoveEverythingSettings);
  on(ids.moveEverythingITermRecentActivityActiveColorLightSetting, "input", updateMoveEverythingSettings);
  on(ids.moveEverythingITermRecentActivityIdleColorLightSetting, "change", updateMoveEverythingSettings);
  on(ids.moveEverythingITermRecentActivityIdleColorLightSetting, "input", updateMoveEverythingSettings);
  on(ids.moveEverythingITermBadgeTopMarginSetting, "change", updateMoveEverythingSettings);
  on(ids.moveEverythingITermBadgeTopMarginSetting, "input", updateMoveEverythingSettings);
  on(ids.moveEverythingITermBadgeRightMarginSetting, "change", updateMoveEverythingSettings);
  on(ids.moveEverythingITermBadgeRightMarginSetting, "input", updateMoveEverythingSettings);
  window.addEventListener("beforeunload", () => {
    cancelListReorderDrag();
    stopHotkeyRecording();
    stopMoveEverythingHotkeyRecording({ silent: true });
    stopPermissionPolling();
    hidePlacementPreview();
    cancelMoveEverythingHoverSendTimer();
    if (autosaveTimer !== null) {
      window.clearTimeout(autosaveTimer);
      autosaveTimer = null;
    }
  });
  window.addEventListener("blur", () => {
    cancelListReorderDrag();
    setMoveEverythingHoveredWindow(null, { immediate: true });
    if (clearPlacementHoverState()) {
      pubsub.publish('selection');
    }
  });
  window.addEventListener("resize", () => {
    const didLayoutChange = syncNarrowModeLayout();
    if (didLayoutChange) {
      renderAll();
      return;
    }
    const compactNow = moveEverythingActionCompactModeActive();
    if (state.moveEverythingActionButtonsCompact !== compactNow) {
      state.moveEverythingActionButtonsCompact = compactNow;
      if (moveEverythingWorkspaceVisible()) {
        renderMoveEverythingWorkspace();
      }
      return;
    }
    if (!moveEverythingWorkspaceVisible()) {
      return;
    }
    window.requestAnimationFrame(() => applyMoveEverythingTitleSizing());
  });

  window.addEventListener("keydown", handleWindowKeyDown, true);

  if (systemThemeMediaQuery) {
    if (typeof systemThemeMediaQuery.addEventListener === "function") {
      systemThemeMediaQuery.addEventListener("change", handleSystemThemePreferenceChanged);
    } else if (typeof systemThemeMediaQuery.addListener === "function") {
      systemThemeMediaQuery.addListener(handleSystemThemePreferenceChanged);
    }
  }

  // Re-check system appearance when the webview becomes active again.
  window.addEventListener("focus", handleSystemThemePreferenceChanged);
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") {
      handleSystemThemePreferenceChanged();
    }
  });

  sendJsLog("info", "wireEvents.done");
}

try {
  wireEvents();
} catch (error) {
  sendJsLog("error", "wireEvents.crash", error?.stack || String(error));
  console.error("VibeGrid startup failed while wiring events:", error);
}
syncThemeModeSelect(state.config?.settings?.themeMode);
applyTheme();
applyControlCenterScale();
applyLargerFonts();
syncNarrowModeLayout();
sendJsLog("info", "startup.ready");
sendToNative("ready", {});
// Always activate move-everything mode so the window list is populated
sendToNative("ensureMoveEverythingMode");
startPermissionPollingIfNeeded();
