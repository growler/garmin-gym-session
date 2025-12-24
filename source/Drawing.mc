using Toybox.Graphics as Gfx;
using Toybox.Math as Math;

function normDeg(d) {
    var x = (d.toLong()) % 360;
    if (x < 0) { x += 360; }
    return x;
}

function drawArcCW(dc, cx, cy, r, startDeg, endDeg) {
    startDeg = normDeg(startDeg);
    endDeg   = normDeg(endDeg);

    if (startDeg >= endDeg) {
        dc.drawArc(cx, cy, r, Gfx.ARC_CLOCKWISE, startDeg, endDeg);
    } else {
        dc.drawArc(cx, cy, r, Gfx.ARC_CLOCKWISE, startDeg, 0);
        dc.drawArc(cx, cy, r, Gfx.ARC_CLOCKWISE, 360, endDeg);
    }
}

function drawArcCWWithThickness(dc, cx, cy, r, thickness, startDeg, endDeg) {
    if (thickness <= 1) {
        drawArcCW(dc, cx, cy, r, startDeg, endDeg);
        return;
    }
    var half = (thickness / 2).toNumber().toLong();
    var i = 0;
    while (i < thickness) {
        var rr = r - half + i;
        if (rr > 0) {
            drawArcCW(dc, cx, cy, rr, startDeg, endDeg);
        }
        i += 1;
    }
}

function xAtY(xa, ya, xb, yb, y) {
    if (yb == ya) { return xa; }
    return xa + (xb - xa) * ((y - ya) / ((yb - ya) * 1.0));
}

function drawFilledTriangle(dc, ax, ay, bx, by, cx, cy) {
    var x0 = ax, y0 = ay;
    var x1 = bx, y1 = by;
    var x2 = cx, y2 = cy;


    if (y0 > y1) {
        var t = x0; x0 = x1; x1 = t;
        t = y0; y0 = y1; y1 = t;
    }
    if (y1 > y2) {
        var t2 = x1; x1 = x2; x2 = t2;
        t2 = y1; y1 = y2; y2 = t2;
    }
    if (y0 > y1) {
        var t3 = x0; x0 = x1; x1 = t3;
        t3 = y0; y0 = y1; y1 = t3;
    }

    if (y0 == y2) {
        return;
    }

    var y = y0.toLong();
    var yEnd = y2.toLong();

    while (y <= yEnd) {
        var xl, xr;

        if (y < y1) {
            xl = xAtY(x0, y0, x2, y2, y);
            xr = xAtY(x0, y0, x1, y1, y);
        } else {
            xl = xAtY(x0, y0, x2, y2, y);
            xr = xAtY(x1, y1, x2, y2, y);
        }

        if (xl > xr) {
            var tmp = xl; xl = xr; xr = tmp;
        }

        dc.drawLine(xl.toLong(), y, xr.toLong(), y);
        y += 1;
    }
}

function drawPointerTriangle(dc, cx, cy, angDeg, r, thickness) {
    var rad = Math.toRadians(angDeg);


    var gap   = 4;
    var triLen = 14;
    var triW   = 14;

    var rTip = r - ((thickness / 2) + gap).toNumber();

    var rBase = rTip - triLen;

    var ux = Math.cos(rad);
    var uy = Math.sin(rad);

    var px = -uy;
    var py =  ux;

    var tipX = cx + rTip * ux;
    var tipY = cy - rTip * uy;

    var baseX = cx + rBase * ux;
    var baseY = cy - rBase * uy;

    var halfW = triW / 2.0;

    var b0X = baseX + halfW * px;
    var b0Y = baseY - halfW * py;

    var b1X = baseX - halfW * px;
    var b1Y = baseY + halfW * py;

    drawFilledTriangle(dc, tipX, tipY, b0X, b0Y, b1X, b1Y);

    dc.drawLine(tipX.toLong(), tipY.toLong(), b0X.toLong(), b0Y.toLong());
    dc.drawLine(tipX.toLong(), tipY.toLong(), b1X.toLong(), b1Y.toLong());
    dc.drawLine(b0X.toLong(), b0Y.toLong(), b1X.toLong(), b1Y.toLong());
}
