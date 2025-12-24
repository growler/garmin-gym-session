using Toybox.Application as App;
using Toybox.Application.Properties as Properties;
using Toybox.WatchUi as WatchUi;
using Toybox.System as Sys;
using Toybox.Graphics as Gfx;
using Toybox.Timer as Timer;
using Toybox.Sensor as Sensor;
using Toybox.Attention as Attention;
using Toybox.ActivityRecording as ActRec;
using Toybox.Activity as Activity;
using Toybox.UserProfile as UserProfile;
using Toybox.Time as Time;

import Toybox.Lang;

function formatSeconds(totalSeconds) {
    if (totalSeconds < 0) {
        totalSeconds = 0;
    }
    var secs = totalSeconds.toNumber().toLong();
    var minutes = secs / 60;
    var seconds = secs % 60;
    var secStr = (seconds < 10) ? "0" + seconds.toString() : seconds.toString();
    return minutes.toString() + ":" + secStr;
}

class GymActivityApp extends App.AppBase {

    var _session;
    var _recorder;

    var _tickTimer;
    var _alarmTimer;
    var _hrEnabled;
    var _confirmVisible;
    var _lastTouchMs;
    var _zones;
    var _uiLastLapSecond;
    var _uiLastRestSecond;
    var _uiLastState;

    function initialize() {
        AppBase.initialize();

        var restDuration = 30;
        try {
            var setting = Properties.getValue("restDuration");
            if (setting != null) {
                restDuration = setting.toNumber();
            }
        } catch(e) {
        }
        if (restDuration < 15) {
            restDuration = 15;
        }

        _session    = new SessionState(restDuration);
        _recorder   = null;
        _tickTimer  = new Timer.Timer();
        _alarmTimer = new Timer.Timer();
        _hrEnabled  = false;
        _confirmVisible = false;
        _lastTouchMs = null;
        _uiLastLapSecond = null;
        _uiLastRestSecond = null;
        _uiLastState = null;
    }

    function onStart(state) {
        try {
            if (Toybox has :ActivityRecording) {
                _recorder = ActRec.createSession({
                    :name     => "Gym Session",
                    :sport    => Activity.SPORT_TRAINING,
                    :subSport => Activity.SUB_SPORT_CARDIO_TRAINING,
                });
                var sport = UserProfile.getCurrentSport();
                if (sport != null) {
                    _zones = UserProfile.getHeartRateZones(sport);
                }
            }
            if (_recorder != null) {
                _recorder.start();
            }
        } catch(e) {
            Sys.println("Failed to start ActivityRecording: " + e);
            _recorder = null;
        }

        _tickTimer.start(method(:onTick), 1000, true);

        try {
            if (Toybox has :Sensor) {
                Sensor.setEnabledSensors([Sensor.SENSOR_HEARTRATE]);
                Sensor.enableSensorEvents(method(:onSensor));
                _hrEnabled = true;
            }
        } catch(e2) {
            Sys.println("Failed to enable HR sensor: " + e2);
            _hrEnabled = false;
        }
    }

    function onStop(state) {
        endSession(true);
    }

    function getInitialView() {
        return [ new MainView(), new AppDelegate() ];
    }

    function getSessionState() {
        return _session;
    }

    function showConfirmView() {
        if (_confirmVisible) {
            return;
        }
        _confirmVisible = true;
        stopAlarm();

        var menu = new WatchUi.Menu2({ :title => "Finish activity?" });
        menu.addItem(new WatchUi.MenuItem("Save & Exit",    null, "save_exit",    null));
        menu.addItem(new WatchUi.MenuItem("Discard & Exit", null, "discard_exit", null));
        menu.addItem(new WatchUi.MenuItem("Cancel",         null, "cancel",       null));
        try { menu.setFocus(0); } catch(e) { }

        WatchUi.pushView(menu, new ExitMenuDelegate(menu), WatchUi.SLIDE_UP);
    }

    function resumeFromConfirm() {
        if (!_confirmVisible) {
            return;
        }
        _confirmVisible = false;
        if (_session.state == STATE_ALARMING) {
            startAlarm();
        }
        WatchUi.requestUpdate();
    }

    function finalizeAndExit(saveRecording) {
        _confirmVisible = false;
        endSession(saveRecording);
        Sys.exit();
    }

    function markTouchInteraction() {
        try {
            _lastTouchMs = Sys.getTimer();
        } catch(e) {
            _lastTouchMs = null;
        }
    }

    function selectLikelyFromTouch() {
        if (_lastTouchMs == null) {
            return false;
        }
        var delta = Sys.getTimer() - _lastTouchMs;
        return delta >= 0 && delta < 800;
    }

    function onTick() {
        try {
            var nowMs = Sys.getTimer();
            var stateBefore = _session.state;
            var remainingRestMs = updateRestState(nowMs);

            var needsUpdate = false;
            if (_uiLastState != _session.state) {
                _uiLastState = _session.state;
                needsUpdate = true;
            }

            if (_session.state == STATE_WORKING) {
                var lapSecond = _session.getLapElapsedSecondsInt(nowMs);
                if (_uiLastLapSecond != lapSecond) {
                    _uiLastLapSecond = lapSecond;
                    needsUpdate = true;
                }
            } else {
                _uiLastLapSecond = null;
            }

            if (_session.state == STATE_RESTING) {
                var restSecond = ((remainingRestMs + 999) / 1000).toLong();
                if (_uiLastRestSecond != restSecond) {
                    _uiLastRestSecond = restSecond;
                    needsUpdate = true;
                }
                // Keep the rest arc animation smooth.
                needsUpdate = true;
            } else {
                _uiLastRestSecond = null;
            }

            // Keep the clock fresh while alarming, but at a low rate.
            if (_session.state == STATE_ALARMING) {
                needsUpdate = true;
            }

            // Once we enter alarming, the UI is mostly static; slow the tick rate.
            if (stateBefore != STATE_ALARMING && _session.state == STATE_ALARMING) {
                _tickTimer.stop();
                _tickTimer.start(method(:onTick), 60000, true);
            }

            if (needsUpdate) {
                WatchUi.requestUpdate();
            }
        } catch(e) {
            Sys.println("Tick error: " + e);
        }
    }

    function onSensor(sensorInfo as Sensor.Info) as Void {
        try {
            if (sensorInfo != null && sensorInfo.heartRate != null) {
                _session.updateHeartRate(sensorInfo.heartRate);
            }
        } catch(e) {
            Sys.println("Sensor error: " + e);
        }
    }

    function updateRestState(nowMs) {
        var remaining = 0;
        if (_session.state == STATE_RESTING) {
            remaining = _session.getRestRemainingMs(nowMs);
            if (remaining <= 0) {
                _session.startAlarm(nowMs);
                if (!_confirmVisible) {
                    startAlarm();
                }
            }
        }
        return remaining;
    }

    function startRest() {
        var nowMs = Sys.getTimer();
        _tickTimer.stop();
        _tickTimer.start(method(:onTick), 100, true);
        _session.startRest(nowMs);
        if (_recorder != null) {
           try {
                _recorder.addLap();
            } catch(e) {
                Sys.println("Failed to add lap to ActivityRecording: " + e);
            }
        }
        _uiLastRestSecond = null;
        _uiLastState = null;
    }

    function startNewLap() {
        stopAlarm();
        _tickTimer.stop();
        _tickTimer.start(method(:onTick), 1000, true);
        var nowMs = Sys.getTimer();
        _session.startNewLap(nowMs);
        _uiLastLapSecond = null;
        _uiLastState = null;
    }

    function startAlarm() {
        stopAlarm();
        _alarmTimer.start(method(:onAlarmTick), 700, true);
    }

    function stopAlarm() {
        if (_alarmTimer != null) {
            _alarmTimer.stop();
        }
    }

    function onAlarmTick() {
        try {
            if (_session.state != STATE_ALARMING) {
                stopAlarm();
                return;
            }

            if (Attention has :vibrate) {
                var vibeData = [
                    new Attention.VibeProfile(100, 500),
                    new Attention.VibeProfile(0, 200)
                ];
                Attention.vibrate(vibeData);
            }
        } catch(e) {
            Sys.println("Alarm tick error: " + e);
            stopAlarm();
        }
    }

    function endSession(saveRecording) {
        if (_tickTimer != null) {
            _tickTimer.stop();
        }
        stopAlarm();

        if (_hrEnabled) {
            try {
                Sensor.enableSensorEvents(null);
            } catch(e2) {
                Sys.println("Failed to disable HR sensor events: " + e2);
            }
            _hrEnabled = false;
        }

        if (_recorder != null) {
            try {
                _recorder.stop();
                if (saveRecording) {
                    _recorder.save();
                } else {
                    try {
                        _recorder.discard();
                    } catch(e2) {
                    }
                }
            } catch(e) {
                Sys.println("Failed to stop ActivityRecording: " + e);
            }
            _recorder = null;
        }
    }

    function getHrZones() {
        return _zones;
    }
}

function performShowConfirm() {
    try {
        var app = App.getApp() as GymActivityApp;
        app.showConfirmView();
        return true;
    } catch(e) {
        Sys.println("Show confirm error: " + e);
        return false;
    }
}

function performResumeFromConfirm() {
    try {
        var app = App.getApp() as GymActivityApp;
        app.resumeFromConfirm();
        return true;
    } catch(e) {
        Sys.println("Resume handler error: " + e);
        return false;
    }
}

function dismissExitMenu() {
    var resumed = performResumeFromConfirm();
    try {
        WatchUi.popView(WatchUi.SLIDE_DOWN);
    } catch(e) {
        Sys.println("Pop confirm view error: " + e);
    }
    return resumed;
}

function performSaveAndExit() {
    try {
        var app = App.getApp() as GymActivityApp;
        app.finalizeAndExit(true);
        return true;
    } catch(e) {
        Sys.println("Save handler error: " + e);
        return false;
    }
}

function performAbandonAndExit() {
    try {
        var app = App.getApp() as GymActivityApp;
        app.finalizeAndExit(false);
        return true;
    } catch(e) {
        Sys.println("Abandon handler error: " + e);
        return false;
    }
}

function performLapTransition() {
    try {
        var app     = App.getApp() as GymActivityApp;
        var session = app.getSessionState();
        if (session.state == STATE_WORKING) {
            app.startRest();
        } else {
            app.startNewLap();
        }
        WatchUi.requestUpdate();
        return true;
    } catch(e) {
        Sys.println("Lap handler error: " + e);
        return false;
    }
}

function isLapKey(key) {
    return (key == WatchUi.KEY_LAP) ||
           (WatchUi has :KEY_DOWN && key == WatchUi.KEY_DOWN) ||
           (WatchUi has :KEY_ESC && key == WatchUi.KEY_ESC) ||
           (WatchUi has :KEY_BACK && key == WatchUi.KEY_BACK);
}

function isStopKey(key) {
    return (key == WatchUi.KEY_START) ||
           (WatchUi has :KEY_ENTER && key == WatchUi.KEY_ENTER) ||
           (WatchUi has :KEY_MENU && key == WatchUi.KEY_MENU);
}

function clamp(x, lo, hi) {
    if (x < lo) { return lo; }
    if (x > hi) { return hi; }
    return x;
}

function angleAlongTopGauge(t) {
    // 210° span clockwise from 195 -> 345 (wraps past 0), centered at 90°
    var left = 195;
    var span = 210;

    t = clamp(t, 0.0, 1.0);

    var a = left - (span * t); // clockwise means decreasing degrees
    if (a < 0) { a += 360; }
    return a;
}

var _ZONE_COLS = null;
function zoneCols() as Array {
    if (_ZONE_COLS == null) {
        _ZONE_COLS = [
            Gfx.COLOR_LT_GRAY,
            Gfx.COLOR_BLUE,
            Gfx.COLOR_GREEN,
            (Gfx has :COLOR_ORANGE) ? Gfx.COLOR_ORANGE : Gfx.COLOR_YELLOW,
            Gfx.COLOR_RED
        ];
    }
    return _ZONE_COLS;
}

function bpmColor(hr, zones as Array) {
    if (zones == null || zones.size() < 6) {
        return Gfx.COLOR_DK_GRAY;
    }
    if (hr == null || hr < zones[1]) {
        return Gfx.COLOR_LT_GRAY;
    } else if (hr < zones[2]) {
        return Gfx.COLOR_BLUE;
    } else if (hr < zones[3]) {
        return Gfx.COLOR_GREEN;
    } else if (hr < zones[4]) {
        return (Gfx has :COLOR_ORANGE) ? Gfx.COLOR_ORANGE : Gfx.COLOR_YELLOW;
    } else {
        return Gfx.COLOR_RED;
    }
}

function drawZonesGauge(dc, cx, cy, r, thickness, degStart, degEnd, zones as Array, hr) {
    if (zones == null || zones.size() < 6) {
        return;
    }

    var minHr = zones[0];
    var maxHr = zones[5];

    // Guard against weird profile data
    if (maxHr <= minHr) {
        return;
    }

    var cols = zoneCols();

    var gapDeg = 2.0; // tune: 2..4 usually looks good
    var halfGap = gapDeg / 2.0;

    // Draw 5 segments
    var i = 0;
    while (i < 5) {
        var lo = (i == 0) ? zones[0] : zones[i];      // minZ1, maxZ1, maxZ2...
        var hi = zones[i + 1];                        // maxZ1..maxZ5

        // Convert bpm bounds to t bounds
        var t0 = (lo - minHr) / ((maxHr - minHr) * 1.0);
        var t1 = (hi - minHr) / ((maxHr - minHr) * 1.0);

        // Convert to angles along the gauge
        var a0 = angleAlongTopGauge(t0); // start (left side of this segment)
        var a1 = angleAlongTopGauge(t1); // end (right side of this segment)

        // Shrink segment to create gaps (avoid array allocation)
        var s0 = a0 - halfGap;
        var s1 = a1 + halfGap;

        dc.setColor(cols[i], Gfx.COLOR_BLACK);
        drawArcCWWithThickness(dc, cx, cy, r, thickness, s0, s1);

        i += 1;
    }

    if (hr != null) {
        var hrc = clamp(hr, minHr, maxHr);
        var t = (hrc - minHr) / ((maxHr - minHr) * 1.0);
        var ang = angleAlongTopGauge(t);

        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_BLACK);
        drawPointerTriangle(dc, cx, cy, ang, r, thickness);
    }
}

function formatClock() {
    var now = Time.now();
    var mi  = Time.Gregorian.info(now, Time.FORMAT_SHORT);
    var hh = mi.hour;
    var mm = mi.min;
    var mmStr = (mm < 10) ? ("0" + mm.toString()) : mm.toString();
    return hh.toString() + ":" + mmStr;
}

function formatClockFromMoment(now) {
    var mi  = Time.Gregorian.info(now, Time.FORMAT_SHORT);
    var hh = mi.hour;
    var mm = mi.min;
    var mmStr = (mm < 10) ? ("0" + mm.toString()) : mm.toString();
    return hh.toString() + ":" + mmStr;
}

function formatTotal(totalSeconds) as String{
    if (totalSeconds < 0) {
        totalSeconds = 0;
    }
    var secs = totalSeconds.toNumber().toLong();
    var minutes = (secs / 60) % 60;
    var hours = secs / 3600;
    var minStr = (minutes < 10) ? "0" + minutes.toString() : minutes.toString();
    return hours.toString() + ":" + minStr;
}

function formatTotalFromMinutes(totalMinutes) as String {
    if (totalMinutes < 0) {
        totalMinutes = 0;
    }
    var mins = totalMinutes.toNumber().toLong();
    var hours = mins / 60;
    var minutes = mins % 60;
    var minStr = (minutes < 10) ? "0" + minutes.toString() : minutes.toString();
    return hours.toString() + ":" + minStr;
}


class MainView extends WatchUi.View {

    var _lastW;
    var _lastH;
    var _centerX;
    var _centerY;
    var _mainY;
    var _bpmY;
    var _infoY;
    var _lineY;
    var _lineY2;
    var _lineW;
    var _x0;
    var _x1;
    var _arcRadiusRest;
    var _arcRadiusWork;
    var _hHr;
    var _hMain;
    var _hInfo;
    var _hClock;
    var _clockY;

    var _lapSecondsCached;
    var _lapTextCached;
    var _restSecondsCached;
    var _restTextCached;
    var _hrCached;
    var _hrTextCached;
    var _lapCountCached;
    var _setsTextCached;
    var _totalMinutesCached;
    var _totalTextCached;

    var _clockMinuteKeyCached;
    var _clockTextCached;

    function initialize() {
        View.initialize();
        _lastW = null;
        _lastH = null;
        _lapSecondsCached = null;
        _restSecondsCached = null;
        _hrCached = null;
        _hrTextCached = "--";
        _lapCountCached = null;
        _totalMinutesCached = null;
        _clockMinuteKeyCached = null;
    }

    function computeLayout(dc) {
        var w = dc.getWidth();
        var h = dc.getHeight();

        _lastW = w;
        _lastH = h;

        _centerX = (w / 2).toLong();
        _centerY = (h / 2).toLong();

        _hMain = dc.getFontHeight(Gfx.FONT_NUMBER_HOT);
        var mainYOffset = ((_hMain + 2) / 4).toLong();
        _mainY = (_centerY - mainYOffset).toLong();

        _lineW = ((w * 60) / 100).toLong();
        _x0 = (_centerX - (_lineW / 2)).toLong();
        _x1 = (_centerX + (_lineW / 2)).toLong();

        var halfMin = ((w < h) ? w : h) / 2;
        _arcRadiusRest = (halfMin - 8).toLong();
        _arcRadiusWork = (halfMin - 8).toLong();

        _hHr = dc.getFontHeight(Gfx.FONT_NUMBER_MILD);
        _hInfo = dc.getFontHeight(Gfx.FONT_MEDIUM);

        _bpmY = (_mainY - (_hMain / 2) - _hHr + 4).toLong();
        _infoY = (_mainY + (_hMain / 2)).toLong();
        _lineY = (_infoY).toLong();
        _lineY2 = (_infoY + _hInfo).toLong();

        _clockY = _lineY2;
    }

    function onLayout(dc as Gfx.Dc) as Void {
        computeLayout(dc);
    }

    function onUpdate(dc) {
        var app     = App.getApp() as GymActivityApp;
        var session = app.getSessionState();
        var nowMs   = Sys.getTimer();
        var zones   = app.getHrZones();

        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_BLACK);
        dc.clear();

        if (_lastW == null || _lastH == null || _lastW != dc.getWidth() || _lastH != dc.getHeight()) {
            computeLayout(dc);
        }

        var lapSeconds = session.getLapElapsedSecondsInt(nowMs);
        var restMs     = session.getRestRemainingMs(nowMs);
        var restSeconds = ((restMs + 999) / 1000).toLong();

        if (_lapSecondsCached != lapSeconds) {
            _lapSecondsCached = lapSeconds;
            _lapTextCached = formatSeconds(lapSeconds);
        }
        if (_restSecondsCached != restSeconds) {
            _restSecondsCached = restSeconds;
            _restTextCached = formatSeconds(restSeconds);
        }

        var hr = session.lastHeartRate;
        if (_hrTextCached == null || _hrCached != hr) {
            _hrCached = hr;
            _hrTextCached = (hr != null) ? hr.toString() : "--";
        }

        if (session.state == STATE_RESTING) {
            var totalRestMs = session.restDurationSeconds * 1000;
            var sweep = (totalRestMs > 0) ? ((restMs * 360) / totalRestMs) : 0;
            if (sweep > 0 && sweep <= 360) {
                var startAngle = 90;
                var endAngle   = startAngle - sweep;
                var arcThickness = 4;
                var arcColor;
                if (sweep >= 180) {
                    arcColor = Gfx.COLOR_GREEN;
                } else if (sweep >= 90) {
                    arcColor = (Gfx has :COLOR_ORANGE) ? Gfx.COLOR_ORANGE : Gfx.COLOR_YELLOW;
                } else {
                    arcColor = Gfx.COLOR_RED;
                }
                dc.setColor(arcColor, Gfx.COLOR_BLACK);
                drawArcCWWithThickness(dc, _centerX, _centerY, _arcRadiusRest, arcThickness, startAngle, endAngle);
            }
        } else if (session.state == STATE_WORKING) {
            var arcThickness = 6;
            drawZonesGauge(dc, _centerX, _centerY, _arcRadiusWork, arcThickness, 165, 15, zones, hr);
        }

        // --- TEXT LAYOUT (main timer centered) ---

        var fontHr    = Gfx.FONT_NUMBER_MILD;
        var fontMain  = Gfx.FONT_NUMBER_HOT;
        var fontInfo  = Gfx.FONT_MEDIUM;
        var fontClock = Gfx.FONT_NUMBER_MEDIUM;

        // 1) Main timer centered
        var mainText = (session.state == STATE_WORKING) ? _lapTextCached : _restTextCached;

        if (session.state == STATE_WORKING) {
            dc.setColor(Gfx.COLOR_BLUE, Gfx.COLOR_BLACK);
        } else if (restMs <= 0) {
            dc.setColor(Gfx.COLOR_RED, Gfx.COLOR_BLACK);
        } else {
            dc.setColor(Gfx.COLOR_GREEN, Gfx.COLOR_BLACK);
        }

        dc.drawText(_centerX, _mainY, fontMain, mainText, Gfx.TEXT_JUSTIFY_CENTER | Gfx.TEXT_JUSTIFY_VCENTER);

        // 2) BPM above main timer
        dc.setColor(bpmColor(hr, zones), Gfx.COLOR_BLACK);
        dc.drawText(_centerX, _bpmY, fontHr, _hrTextCached, Gfx.TEXT_JUSTIFY_CENTER);

        // 3) Info below main timer
        if (_lapCountCached != session.lapCount) {
            _lapCountCached = session.lapCount;
            _setsTextCached = session.lapCount.toString();
        }
        var totalMinutes = session.getTotalElapsedMinutes(nowMs);
        if (_totalMinutesCached != totalMinutes) {
            _totalMinutesCached = totalMinutes;
            _totalTextCached = formatTotalFromMinutes(totalMinutes);
        }

        if (_lapCountCached > 0) {
            dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_BLACK);
            dc.drawText(_x0 + 8, _infoY, fontInfo, _setsTextCached, Gfx.TEXT_JUSTIFY_LEFT);
        }
        dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_BLACK);
        dc.drawText(_x1 - 8, _infoY, fontInfo, _totalTextCached, Gfx.TEXT_JUSTIFY_RIGHT);

        dc.setColor(Gfx.COLOR_DK_GRAY, Gfx.COLOR_BLACK);
        dc.drawLine(_x0, _lineY, _x1, _lineY);
        dc.drawLine(_x0, _lineY2, _x1, _lineY2);

        // 3) Clock at bottom, larger + brighter
        var now = Time.now();
        var minuteKey = (now.value() / 60).toLong();
        if (_clockMinuteKeyCached != minuteKey) {
            _clockMinuteKeyCached = minuteKey;
            _clockTextCached = formatClockFromMoment(now);
        }

        dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_BLACK);
        dc.drawText(_centerX, _clockY, fontClock, _clockTextCached, Gfx.TEXT_JUSTIFY_CENTER);
    }

    function onSelect() {
        try {
            var app = App.getApp() as GymActivityApp;
            if (app != null) {
                app.markTouchInteraction();
            }
        } catch(e) {
        }
        return performLapTransition();
    }

    function onMenu() {
        try {
            var app = App.getApp() as GymActivityApp;
            if (app != null) {
                app.markTouchInteraction();
            }
        } catch(e) {
        }
        return performLapTransition();
    }

    function onBack() {
        return performLapTransition();
    }

    function onTap(tapEvent) {
        try {
            var app = App.getApp() as GymActivityApp;
            if (app != null) {
                app.markTouchInteraction();
            }
        } catch(e) {
        }
        return performLapTransition();
    }

    function onSwipe(swipeEvent) {
        try {
            var app = App.getApp() as GymActivityApp;
            if (app != null) {
                app.markTouchInteraction();
            }
        } catch(e) {
        }
        return performLapTransition();
    }

    function onKey(keyEvent) {
        try {
            var key = keyEvent.getKey();
            if (isLapKey(key)) {
                return performLapTransition();
            } else if (isStopKey(key)) {
                var app = App.getApp() as GymActivityApp;
                if (app != null && app.selectLikelyFromTouch()) {
                    return performLapTransition();
                }
                return performShowConfirm();
            }
        } catch(e) {
            Sys.println("View key handler error: " + e);
        }
        return false;
    }
}

class AppDelegate extends WatchUi.BehaviorDelegate {

    function initialize() {
        BehaviorDelegate.initialize();
    }

    function onSelect() {
        try {
            var app = App.getApp() as GymActivityApp;
            if (app != null) {
                app.markTouchInteraction();
            }
        } catch(e) {
        }
        return performLapTransition();
    }

    function onMenu() {
        try {
            var app = App.getApp() as GymActivityApp;
            if (app != null) {
                app.markTouchInteraction();
            }
        } catch(e) {
        }
        return performLapTransition();
    }

    function onBack() {
        return performLapTransition();
    }

    function onKey(keyEvent) {
        try {
            var key = keyEvent.getKey();
            if (isLapKey(key)) {
                return performLapTransition();
            } else if (isStopKey(key)) {
                var app = App.getApp() as GymActivityApp;
                if (app != null && app.selectLikelyFromTouch()) {
                    return performLapTransition();
                }
                return performShowConfirm();
            }
        } catch(e) {
            Sys.println("Key handler error: " + e);
        }
        return false;
    }

    function onTap(tapEvent) {
        try {
            var app = App.getApp() as GymActivityApp;
            if (app != null) {
                app.markTouchInteraction();
            }
        } catch(e) {
        }
        return performLapTransition();
    }
}

class ExitMenuDelegate extends WatchUi.Menu2InputDelegate {

    function initialize(menu) {
        Menu2InputDelegate.initialize();
    }

    function onSelect(item as WatchUi.MenuItem) {
        var id = (item == null) ? null : item.getId();
        var idStr = (id == null) ? null : id.toString();

        if (idStr != null && idStr.equals("save_exit")) {
            performSaveAndExit();
        } else if (idStr != null && idStr.equals("discard_exit")) {
            performAbandonAndExit();
        } else {
            dismissExitMenu(); // cancel
        }
    }

    function onBack() {
        dismissExitMenu();
    }
}
