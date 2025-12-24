using Toybox.System as Sys;

const STATE_WORKING  = 0;
const STATE_RESTING  = 1;
const STATE_ALARMING = 2;

class SessionState {
    var state;
    var restDurationSeconds;

    var lapStartMs;
    var restStartMs;

    var lastHeartRate;
    var minHeartRate;
    var maxHeartRate;

    var startMs;
    var lastStateChangeMs;
    var workingMillis;
    var restMillis;
    var lapCount;

    function initialize(restDurationSeconds) {
        var nowMs = Sys.getTimer();
        self.restDurationSeconds = restDurationSeconds;
        self.state               = STATE_WORKING;
        self.lapStartMs          = nowMs;
        self.restStartMs         = null;
        self.lastHeartRate       = null;
        self.minHeartRate        = null;
        self.maxHeartRate        = null;
        self.startMs             = nowMs;
        self.lastStateChangeMs   = nowMs;
        self.workingMillis       = 0;
        self.restMillis          = 0;
        self.lapCount            = 0;
    }

    function startNewLap(nowMs) {
        recordElapsed(nowMs);
        lapStartMs        = nowMs;
        restStartMs       = null;
        state             = STATE_WORKING;
        lastStateChangeMs = nowMs;
    }

    function startRest(nowMs) {
        recordElapsed(nowMs);
        restStartMs       = nowMs;
        state             = STATE_RESTING;
        lastStateChangeMs = nowMs;
        lapCount         += 1;
    }

    function startAlarm(nowMs) {
        recordElapsed(nowMs);
        state             = STATE_ALARMING;
        lastStateChangeMs = nowMs;
    }

    function getLapElapsedSeconds(nowMs) {
        return ((nowMs - lapStartMs) / 1000f).toNumber();
    }

    function getLapElapsedSecondsInt(nowMs) {
        var delta = nowMs - lapStartMs;
        if (delta < 0) {
            delta = 0;
        }
        return (delta / 1000).toLong();
    }

    function getRestRemainingMs(nowMs) {
        if (restStartMs == null) {
            return restDurationSeconds * 1000;
        }
        var elapsed = nowMs - restStartMs;
        var remaining = (restDurationSeconds * 1000) - elapsed;
        if (remaining < 0) {
            return 0;
        }
        return remaining;
    }

    function getRestRemainingSecondsCeil(nowMs) {
        var remainingMs = getRestRemainingMs(nowMs);
        return ((remainingMs + 999) / 1000).toLong();
    }

    function getTotalElapsedSeconds(nowMs) {
        return ((nowMs - startMs) / 1000f).toNumber();
    }

    function getTotalElapsedMinutes(nowMs) {
        var delta = nowMs - startMs;
        if (delta < 0) {
            delta = 0;
        }
        return (delta / 60000).toLong();
    }

    function recordElapsed(nowMs) {
        var delta = nowMs - lastStateChangeMs;
        if (delta < 0) {
            delta = 0;
        }
        if (state == STATE_WORKING) {
            workingMillis += delta;
        } else {
            restMillis += delta;
        }
        lastStateChangeMs = nowMs;
    }

    function updateHeartRate(hr) {
        lastHeartRate = hr;
        if (hr == null) {
            return;
        }
        if (minHeartRate == null || hr < minHeartRate) {
            minHeartRate = hr;
        }
        if (maxHeartRate == null || hr > maxHeartRate) {
            maxHeartRate = hr;
        }
    }
}
