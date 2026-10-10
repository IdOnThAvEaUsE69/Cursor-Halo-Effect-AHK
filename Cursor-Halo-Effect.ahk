#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent
ListLines false
KeyHistory 0

; ============================================================================
;  Cursor Halo v7  (v3 drawing engine, single window)
;  - Ring + small centre dot that INVERT whatever is on screen beneath them
;  - Ring trails lazily; the dot follows with a smaller delay (same window)
;  - Ring expands for any cursor other than the normal arrow / busy cursors
;  - Ring "breathes" while the cursor is busy
;  - Hidden (opacity only) when the cursor is hidden
;
;  Ctrl+Alt+H -> pause / resume   Ctrl+Alt+Q -> exit   Ctrl+Alt+R -> restart
; ============================================================================

DllCall("SetThreadDpiAwarenessContext", "ptr", -4, "ptr")
A_IconTip := "Cursor Halo"

; ============================== CONFIGURATION ===============================
BaseRadius     := 40     ; idle outer radius (px)
ExpandedRadius := 80     ; outer radius when the cursor is "something else"
RingWidth      := 2      ; ring thickness (px)
DotRadius      := 5      ; centre dot radius (px)
PosTau         := 0.12   ; RING trail delay in seconds (bigger = lazier)
DotTau         := 0.06   ; DOT trail delay in seconds (smaller than the ring's)
SizeTau        := 0.09   ; grow/shrink smoothness in seconds
BreathAmp      := 0.20   ; busy breathing: +/- 20% radius
BreathPeriod   := 1.8    ; seconds per breath
TargetHz       := 144    ; update rate
ActiveRefreshMs := 0    ; redraw rate during the grace period after movement
IdleDelayMs     := 5000   ; how long after the last movement before going idle
IdleRefreshMs   := 10000  ; redraw rate once idle
; ============================================================================

MaxRadius := Max(ExpandedRadius, BaseRadius * (1 + BreathAmp))
Canvas    := 2 * Ceil(MaxRadius) + 8
Half      := Canvas // 2
DotLimit  := Half - DotRadius - 2        ; dot can't leave the window
TwoPi     := 6.283185307179586

MouseGetPos &curX, &curY
dotX := curX, dotY := curY
curR := BaseRadius
busyAmt := 0, phase := 0
lastWX := -99999, lastWY := -99999, lastDX := -99999, lastDY := -99999
lastDrawR := -1, lastDrawTick := 0, lastMoveTick := 0
shown := false, paused := false, looping := false
blankCache := Map()

hArrow    := DllCall("LoadCursor", "ptr", 0, "ptr", 32512, "ptr")
hWait     := DllCall("LoadCursor", "ptr", 0, "ptr", 32514, "ptr")
hAppStart := DllCall("LoadCursor", "ptr", 0, "ptr", 32650, "ptr")
ci := Buffer(16 + A_PtrSize, 0)

DllCall("winmm\timeBeginPeriod", "uint", 1)
qpcBuf := Buffer(8)
DllCall("QueryPerformanceFrequency", "ptr", qpcBuf)
freq        := NumGet(qpcBuf, 0, "int64")
frameTicks  := freq / TargetHz
hiddenTicks := freq / 30
lastT       := Qpc()

Qpc() {
    global qpcBuf
    DllCall("QueryPerformanceCounter", "ptr", qpcBuf)
    return NumGet(qpcBuf, 0, "int64")
}

DllCall("LoadLibrary", "str", "gdiplus")
gdipToken := 0
si := Buffer(24, 0), NumPut("uint", 1, si)
DllCall("gdiplus\GdiplusStartup", "ptr*", &gdipToken, "ptr", si, "ptr", 0)

halo := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x80000 +E0x20 +E0x08000000")
halo.Show("NA x0 y0 w" Canvas " h" Canvas)
hwnd := halo.Hwnd

affinityOK := DllCall("SetWindowDisplayAffinity", "ptr", hwnd, "uint", 0x11)
ropInvert  := 0x00330008 | (affinityOK ? 0x40000000 : 0)

MakeDIB(&hdc, &hbm, &hOld, &pBits) {
    global Canvas
    hdc := DllCall("CreateCompatibleDC", "ptr", 0, "ptr")
    bi := Buffer(40, 0)
    NumPut("uint", 40, bi, 0), NumPut("int", Canvas, bi, 4), NumPut("int", -Canvas, bi, 8)
    NumPut("ushort", 1, bi, 12), NumPut("ushort", 32, bi, 14)
    pBits := 0
    hbm  := DllCall("CreateDIBSection", "ptr", hdc, "ptr", bi, "uint", 0
                  , "ptr*", &pBits, "ptr", 0, "uint", 0, "ptr")
    hOld := DllCall("SelectObject", "ptr", hdc, "ptr", hbm, "ptr")
}

MakeDIB(&hdcCap, &hbmCap, &hOldCap, &pBitsCap)
MakeDIB(&hdcOut, &hbmOut, &hOldOut, &pBitsOut)
hdcScr := DllCall("GetDC", "ptr", 0, "ptr")

pBmp := 0
DllCall("gdiplus\GdipCreateBitmapFromScan0", "int", Canvas, "int", Canvas
      , "int", Canvas * 4, "int", 0x22009, "ptr", pBitsCap, "ptr*", &pBmp)

pG := 0
DllCall("gdiplus\GdipCreateFromHDC", "ptr", hdcOut, "ptr*", &pG)
DllCall("gdiplus\GdipSetSmoothingMode", "ptr", pG, "int", 4)

ptDst := Buffer(8, 0), ptSrc := Buffer(8, 0), szWnd := Buffer(8, 0)
NumPut("int", Canvas, "int", Canvas, szWnd)
blend := Buffer(4, 0)
NumPut("uchar", 255, blend, 2)
NumPut("uchar", 1,   blend, 3)

A_TrayMenu.Delete()
A_TrayMenu.Add("Pause / Resume  (Ctrl+Alt+H)", TogglePause)
A_TrayMenu.Add("Exit  (Ctrl+Alt+Q)", (*) => ExitApp())
A_TrayMenu.Add("Restart  (Ctrl+Alt+R)", (*) => Reload())
OnExit(Cleanup)

SetTimer RunLoop, -1

; ---- Invisible-cursor detection (cached per handle) ---------------------------
IsBlankCached(h) {
    global blankCache
    if blankCache.Has(h)
        return blankCache[h]
    if (blankCache.Count > 128)
        blankCache.Clear()
    return blankCache[h] := IsBlankCursor(h)
}

IsBlankCursor(h) {
    ii := Buffer(40, 0)
    if !DllCall("GetIconInfo", "ptr", h, "ptr", ii)
        return false
    off    := (A_PtrSize = 8) ? 16 : 12
    hMask  := NumGet(ii, off, "ptr")
    hColor := NumGet(ii, off + A_PtrSize, "ptr")
    blank  := false
    try blank := BitmapsBlank(hMask, hColor)
    if hMask
        DllCall("DeleteObject", "ptr", hMask)
    if hColor
        DllCall("DeleteObject", "ptr", hColor)
    return blank
}

BitmapsBlank(hMask, hColor) {
    bm := Buffer(32, 0)
    if !DllCall("GetObject", "ptr", hMask, "int", 32, "ptr", bm)
        return false
    w    := NumGet(bm, 4, "int")
    hgt  := NumGet(bm, 8, "int")
    imgH := hColor ? hgt : hgt // 2
    if (w <= 2 && imgH <= 2)
        return true
    if !hColor
        return false
    if !DllCall("GetObject", "ptr", hColor, "int", 32, "ptr", bm)
        return false
    if (NumGet(bm, 18, "ushort") != 32)
        return false
    n := NumGet(bm, 12, "int") * NumGet(bm, 8, "int")
    if (n <= 0)
        return false
    buf  := Buffer(n, 0)
    zero := Buffer(n, 0)
    if !DllCall("GetBitmapBits", "ptr", hColor, "int", n, "ptr", buf)
        return false
    return DllCall("ntdll\RtlCompareMemory", "ptr", buf, "ptr", zero, "uptr", n, "uptr") = n
}

; ---- Frame loop (same as v3) ----------------------------------------------------
RunLoop() {
    global paused, looping
    if looping
        return
    looping := true
    next := Qpc()
    while !paused {
        step := Update()
        next += step
        if (Qpc() - next > step * 4)
            next := Qpc()
        while (Qpc() < next)
            Sleep 1
    }
    looping := false
}

Update() {
    global curX, curY, curR, dotX, dotY, lastT, lastWX, lastWY, lastDX, lastDY
    global lastDrawR, lastDrawTick, busyAmt, phase, ci, shown, blend, hwnd
    global Half, BaseRadius, ExpandedRadius, PosTau, DotTau, SizeTau
    global hArrow, hWait, hAppStart, BreathAmp, BreathPeriod, TwoPi
    global IdleRefreshMs, ActiveRefreshMs, IdleDelayMs, lastMoveTick, freq, frameTicks, hiddenTicks

    t  := Qpc()
    dt := Min((t - lastT) / freq, 0.1)
    lastT := t

    NumPut("uint", ci.Size, ci, 0)
    DllCall("GetCursorInfo", "ptr", ci)
    flags := NumGet(ci, 4, "uint")
    hCur  := NumGet(ci, 8, "ptr")
    mx    := NumGet(ci, 8 + A_PtrSize, "int")
    my    := NumGet(ci, 12 + A_PtrSize, "int")

    ; Cursor hidden: change opacity once, then touch nothing
    if !((flags & 1) && !(flags & 2) && hCur && !IsBlankCached(hCur)) {
        if shown {
            NumPut("uchar", 0, blend, 2)
            DllCall("UpdateLayeredWindow", "ptr", hwnd, "ptr", 0, "ptr", 0, "ptr", 0
                  , "ptr", 0, "ptr", 0, "uint", 0, "ptr", blend, "uint", 2)
            shown := false
        }
        return hiddenTicks
    }

    if !shown {
        curX := mx, curY := my, dotX := mx, dotY := my
        curR := BaseRadius
        busyAmt := 0, phase := 0, dt := 0
        lastDrawR := -1
        lastWX := lastWY := lastDX := lastDY := -99999
        NumPut("uchar", 255, blend, 2)
        shown := true
    }

    busy   := (hCur = hWait || hCur = hAppStart)
    expand := !busy && (hCur != hArrow)

    busyAmt += ((busy ? 1 : 0) - busyAmt) * (1 - Exp(-dt / 0.15))
    if (busyAmt < 0.002) {
        busyAmt := 0, phase := 0
    } else {
        phase := Mod(phase + dt * TwoPi / BreathPeriod, TwoPi)
    }

    targetR := expand ? ExpandedRadius : BaseRadius * (1 + BreathAmp * busyAmt * Sin(phase))

    aPos  := 1 - Exp(-dt / PosTau)
    aDot  := 1 - Exp(-dt / DotTau)
    aSize := 1 - Exp(-dt / SizeTau)
    curX += (mx - curX) * aPos
    curY += (my - curY) * aPos
    dotX += (mx - dotX) * aDot
    dotY += (my - dotY) * aDot
    curR += (targetR - curR) * aSize

    if (Abs(mx - curX) < 0.05)
        curX := mx
    if (Abs(my - curY) < 0.05)
        curY := my
    if (Abs(mx - dotX) < 0.05)
        dotX := mx
    if (Abs(my - dotY) < 0.05)
        dotY := my
    if (Abs(targetR - curR) < 0.05)
        curR := targetR

    wx := Round(curX - Half)
    wy := Round(curY - Half)
    dx := Round(dotX)
    dy := Round(dotY)

    moved := (wx != lastWX || wy != lastWY || dx != lastDX || dy != lastDY || curR != lastDrawR)
    if moved
        lastMoveTick := A_TickCount
    refreshMs := (A_TickCount - lastMoveTick < IdleDelayMs) ? ActiveRefreshMs : IdleRefreshMs
    idle  := !moved && (A_TickCount - lastDrawTick >= refreshMs)
    if (moved || idle) {
        lastWX := wx, lastWY := wy, lastDX := dx, lastDY := dy
        Redraw(curR, wx, wy, dx - wx, dy - wy)
    }
    return frameTicks
}

; (ox, oy) = dot centre in canvas coordinates
Redraw(r, wx, wy, ox, oy) {
    global pG, pBmp, Half, RingWidth, DotRadius, DotLimit, lastDrawR, lastDrawTick, Canvas
    global hwnd, hdcCap, hdcScr, ropInvert, ptDst, ptSrc, szWnd, blend, hdcOut

    DllCall("BitBlt", "ptr", hdcCap, "int", 0, "int", 0, "int", Canvas, "int", Canvas
          , "ptr", hdcScr, "int", wx, "int", wy, "uint", ropInvert)

    brush := 0, pen := 0
    DllCall("gdiplus\GdipCreateTexture", "ptr", pBmp, "int", 0, "ptr*", &brush)
    DllCall("gdiplus\GdipCreatePen2", "ptr", brush, "float", RingWidth, "int", 0, "ptr*", &pen)

    DllCall("gdiplus\GdipGraphicsClear", "ptr", pG, "uint", 0)
    ri := r - RingWidth / 2
    if (ri > 0)
        DllCall("gdiplus\GdipDrawEllipse", "ptr", pG, "ptr", pen
              , "float", Half - ri, "float", Half - ri, "float", ri * 2, "float", ri * 2)

    ; Keep the dot inside the window
    vx := ox - Half, vy := oy - Half
    len := Sqrt(vx * vx + vy * vy)
    if (len > DotLimit) {
        s := DotLimit / len
        vx *= s, vy *= s
    }
    DllCall("gdiplus\GdipFillEllipse", "ptr", pG, "ptr", brush
          , "float", Half + vx - DotRadius, "float", Half + vy - DotRadius
          , "float", DotRadius * 2, "float", DotRadius * 2)

    DllCall("gdiplus\GdipDeletePen", "ptr", pen)
    DllCall("gdiplus\GdipDeleteBrush", "ptr", brush)

    NumPut("int", wx, "int", wy, ptDst)
    DllCall("UpdateLayeredWindow", "ptr", hwnd, "ptr", 0, "ptr", ptDst, "ptr", szWnd
          , "ptr", hdcOut, "ptr", ptSrc, "uint", 0, "ptr", blend, "uint", 2)

    lastDrawR := r
    lastDrawTick := A_TickCount
}

TogglePause(*) {
    global paused, shown, blend, hwnd
    paused := !paused
    if paused {
        NumPut("uchar", 0, blend, 2)
        DllCall("UpdateLayeredWindow", "ptr", hwnd, "ptr", 0, "ptr", 0, "ptr", 0
              , "ptr", 0, "ptr", 0, "uint", 0, "ptr", blend, "uint", 2)
        shown := false
    } else {
        SetTimer RunLoop, -1
    }
}

Cleanup(*) {
    global
    paused := true
    DllCall("gdiplus\GdipDeleteGraphics", "ptr", pG)
    DllCall("gdiplus\GdipDisposeImage", "ptr", pBmp)
    DllCall("SelectObject", "ptr", hdcCap, "ptr", hOldCap)
    DllCall("SelectObject", "ptr", hdcOut, "ptr", hOldOut)
    DllCall("DeleteObject", "ptr", hbmCap)
    DllCall("DeleteObject", "ptr", hbmOut)
    DllCall("DeleteDC", "ptr", hdcCap)
    DllCall("DeleteDC", "ptr", hdcOut)
    DllCall("ReleaseDC", "ptr", 0, "ptr", hdcScr)
    DllCall("gdiplus\GdiplusShutdown", "ptr", gdipToken)
    DllCall("winmm\timeEndPeriod", "uint", 1)
}

^!h:: TogglePause()
^!q:: ExitApp()
^!r:: Reload()