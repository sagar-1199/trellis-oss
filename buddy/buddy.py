#!/usr/bin/env python3
"""
Trellis Buddy — "Rivet", a tiny worker robot who lives on top of your Dock.

Original mascot design: cream rounded capsule body, dark screen-face with glowing
cyan eyes + blush, yellow hard hat, antenna bulb (green pulse = idle, orange blink =
working, dim = asleep), little Trellis sprout decal on the belly.

  - IDLE: waddles along the Dock, hops, waves, looks around, blinks
  - WORK: sits down with a laptop (syntax-colored code + blinking cursor), antenna
          blinks orange, status bubble overhead, arms-up cheer on each loop phase
  - SLEEP (after ~4 min quiet): lies down under a red blanket, screen dims, z's

All vector drawing — no image assets. Click-through, above the Dock, all Spaces.
"""
import math, os, random, subprocess, time

import objc
from AppKit import (
    NSAffineTransform, NSApplication, NSApplicationActivationPolicyAccessory,
    NSBackingStoreBuffered, NSBezierPath, NSColor, NSFont, NSFontAttributeName,
    NSForegroundColorAttributeName, NSGraphicsContext, NSMakeRect,
    NSScreen, NSString, NSView, NSWindow,
    NSWindowCollectionBehaviorCanJoinAllSpaces, NSWindowCollectionBehaviorStationary,
)
from Foundation import NSObject, NSTimer
import Quartz

STATUS_FILE = os.path.expanduser("~/.trellis/status")
# BUDDY_MODE=dock (default): Rivet lives IN the Dock as an animated app icon.
# BUDDY_MODE=float: the old free-roaming window walking on top of the Dock.
DOCK_ITEM = os.environ.get("BUDDY_MODE", "float") == "dock"
FPS = 30.0
WIN_H = 250.0
GROUND = 6.0                       # feet line inside the window (≈ top of the Dock)
SCALE = 0.62                       # render scale (design space is ~98 units tall)
TOTAL_H = 98.0                     # design-space height incl. antenna

def rgba(r, g, b, a=1.0):
    return NSColor.colorWithCalibratedRed_green_blue_alpha_(r, g, b, a)

# ------------------------------------------------------------------ palette
OUTLINE  = rgba(0.16, 0.17, 0.23)
CREAM    = rgba(0.97, 0.96, 0.92)
CREAM_SH = rgba(0.86, 0.85, 0.80)
SCREEN   = rgba(0.10, 0.12, 0.18)
CYAN     = rgba(0.55, 0.92, 1.00)
CYAN_DIM = rgba(0.55, 0.92, 1.00, 0.45)
BLUSH    = rgba(0.99, 0.55, 0.55, 0.50)
HAT      = rgba(0.99, 0.78, 0.20)
HAT_SH   = rgba(0.88, 0.65, 0.12)
FOOT     = rgba(0.24, 0.26, 0.34)
GREEN    = rgba(0.35, 0.82, 0.45)
ORANGE   = rgba(1.00, 0.58, 0.20)
GRAY     = rgba(0.55, 0.56, 0.60)
SPROUT   = rgba(0.30, 0.70, 0.42)
BLANKET  = rgba(0.72, 0.15, 0.15)
BLANKET2 = rgba(0.55, 0.10, 0.10)
CODE_COLORS = [rgba(1.0, 0.47, 0.78), rgba(0.55, 0.91, 0.99), rgba(0.31, 0.98, 0.48),
               rgba(0.74, 0.58, 0.98), rgba(0.95, 0.98, 0.55)]
BUBBLE_BG = NSColor.colorWithCalibratedWhite_alpha_(0.08, 0.84)

# ------------------------------------------------------------------ tiny toolkit
def _push():
    NSGraphicsContext.currentContext().saveGraphicsState()

def _pop():
    NSGraphicsContext.currentContext().restoreGraphicsState()

def _xform(tx, ty, deg=0.0, s=1.0):
    tr = NSAffineTransform.transform()
    tr.translateXBy_yBy_(tx, ty)
    if deg:
        tr.rotateByDegrees_(deg)
    if s != 1.0:
        tr.scaleXBy_yBy_(s, s)
    tr.concat()

def _oval(cx, cy, rx, ry, color, outline=None, lw=1.8):
    p = NSBezierPath.bezierPathWithOvalInRect_(NSMakeRect(cx - rx, cy - ry, rx * 2, ry * 2))
    color.set(); p.fill()
    if outline is not None:
        outline.set(); p.setLineWidth_(lw); p.stroke()

def _line(p1, p2, w, color):
    p = NSBezierPath.bezierPath()
    p.moveToPoint_(p1); p.lineToPoint_(p2)
    p.setLineWidth_(w); p.setLineCapStyle_(1)
    color.set(); p.stroke()

def _arc(cx, cy, r, a0, a1, w, color):
    p = NSBezierPath.bezierPath()
    p.appendBezierPathWithArcWithCenter_radius_startAngle_endAngle_((cx, cy), r, a0, a1)
    p.setLineWidth_(w); p.setLineCapStyle_(1)
    color.set(); p.stroke()

def _rrect(x, y, w, h, r, color, outline=None, lw=1.8):
    p = NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(NSMakeRect(x, y, w, h), r, r)
    color.set(); p.fill()
    if outline is not None:
        outline.set(); p.setLineWidth_(lw); p.stroke()
    return p

def _text(s, x, y, size, color, bold=False):
    font = NSFont.boldSystemFontOfSize_(size) if bold else NSFont.systemFontOfSize_(size)
    NSString.stringWithString_(s).drawAtPoint_withAttributes_(
        (x, y), {NSFontAttributeName: font, NSForegroundColorAttributeName: color})

def _text_size(s, size, bold=False):
    font = NSFont.boldSystemFontOfSize_(size) if bold else NSFont.systemFontOfSize_(size)
    return NSString.stringWithString_(s).sizeWithAttributes_(
        {NSFontAttributeName: font, NSForegroundColorAttributeName: NSColor.whiteColor()})

# ------------------------------------------------------------------ signals
def _running(pat, exact=False):
    cmd = ["pgrep", "-x", pat] if exact else ["pgrep", "-f", pat]
    return subprocess.run(cmd, capture_output=True).returncode == 0

def claude_procs():
    """(exists, busiest single-process %cpu) across `claude` CLI processes.

    Max, not sum: several *idle* sessions each sip 2-5% CPU and would add up to a
    false "working" signal, while one actually-generating session runs 60%+."""
    try:
        out = subprocess.run(["ps", "-axo", "%cpu=,command="],
                             capture_output=True, text=True, timeout=3).stdout
    except Exception:
        return False, 0.0
    exists, cpu = False, 0.0
    for line in out.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) < 2:
            continue
        head = parts[1].split()[0]
        if head == "claude" or head.endswith("/claude"):
            exists = True
            try:
                cpu = max(cpu, float(parts[0].replace(",", ".")))
            except ValueError:
                pass
    return exists, cpu

def status_fresh(sec):
    try:
        return (time.time() - os.path.getmtime(STATUS_FILE)) < sec
    except OSError:
        return False

def status_line():
    try:
        with open(STATUS_FILE, encoding="utf-8", errors="ignore") as fh:
            return fh.readline().strip()
    except OSError:
        return ""

# ------------------------------------------------------------------ the character
class Mini:
    def __init__(self, screen_w):
        self.W = screen_w
        self.x = screen_w / 2.0
        self.dir = 1
        self.target = self.x
        self.walking = False
        self.y = 0.0; self.vy = 0.0
        self.phase = 0.0
        self.mode = "IDLE"                            # WORK | IDLE | SLEEP
        self.blink_start = -10.0; self.next_blink = time.time() + 2
        self.decide_at = 0.0
        self.look = 0.0
        self.wave_until = 0.0
        self.jump_until = 0.0
        self.cheer_until = 0.0
        self.status = ""; self._prev_status = ""
        self.last_activity = time.time()
        self._sig_at = 0.0; self._work = False; self._awake = False
        self._busy_until = 0.0
        self.stationary = False           # dock-tile mode: no wandering
        self.dozing = False               # idle-in-the-corner nap

    def _signals(self, t):
        if t - self._sig_at < 1.0:
            return
        self._sig_at = t
        trellis = (_running("loop.sh") or _running("retro.sh") or _running("plan.sh")
                   or status_fresh(120))
        exists, cpu = claude_procs()
        if cpu > 30.0:                        # one session is genuinely computing
            self._busy_until = t + 8.0        # hold through brief dips between tool calls
        busy = t < self._busy_until
        self._work = trellis or busy
        self._awake = self._work or exists
        if trellis:
            self.status = status_line() or "working on it"
        elif busy:
            self.status = "Claude is working"
        if self._awake:
            self.last_activity = t

    def _jump(self, v=300.0):
        if self.y == 0:
            self.vy = v
            self.jump_until = time.time() + 0.8

    def update(self, dt, t):
        self._signals(t)

        if self._work:
            self.mode = "WORK"
        elif t - self.last_activity < 240:
            self.mode = "IDLE"
        else:
            self.mode = "SLEEP"

        if self.mode == "WORK" and self.status != self._prev_status:
            self._prev_status = self.status
            self.cheer_until = t + 1.0

        if self.mode != "SLEEP" and t > self.next_blink:
            self.blink_start = t
            self.next_blink = t + random.uniform(1.8, 5.0)

        if self.y > 0 or self.vy != 0:
            self.y += self.vy * dt
            self.vy -= 1500 * dt
            if self.y <= 0:
                self.y, self.vy = 0.0, 0.0

        if self.mode in ("WORK", "SLEEP"):
            self.walking = False
            self.dozing = False
            return

        # ----- IDLE: retire to the corner and doze until there's work -----
        corner = 74.0 if self.stationary else self.W - 84.0
        if abs(self.x - corner) > 6.0:
            self.dozing = False
            self.walking = True
            self.dir = 1 if corner > self.x else -1
            self.x += 46.0 * dt * self.dir
            self.phase += dt * 9.0
            self.look = float(self.dir)
            if (self.dir > 0 and self.x >= corner) or (self.dir < 0 and self.x <= corner):
                self.x = corner
                self.walking = False
        else:
            self.walking = False
            self.dozing = True

# ------------------------------------------------------------------ the view
class BuddyView(NSView):
    def drawRect_(self, rect):
        m = self.model; t = time.time()
        working = m.mode == "WORK"
        sleeping = m.mode == "SLEEP"

        if sleeping:
            self._sleep_scene(m, t)
            return

        sh = max(0.35, 1.0 - m.y / 110.0)
        NSColor.colorWithCalibratedWhite_alpha_(0, 0.12).set()
        NSBezierPath.bezierPathWithOvalInRect_(
            NSMakeRect(m.x - 27 * sh * SCALE, GROUND - 3, 54 * sh * SCALE, 9 * sh * SCALE + 1)).fill()

        bob = abs(math.sin(m.phase)) * 2.0 if m.walking else 0.0
        waddle = math.sin(m.phase) * 4.0 if m.walking else 0.0
        # squash & stretch on hops
        if m.vy != 0:
            sy = max(0.92, min(1.10, 1.0 + m.vy / 2800.0))
        else:
            sy = 1.0 + 0.012 * math.sin(t * 2.6)
        sx = 2.0 - sy if sy < 1.0 else 1.0 - (sy - 1.0) * 0.6

        _push()
        _xform(m.x, GROUND + (m.y + bob) * SCALE, waddle, SCALE)
        tr = NSAffineTransform.transform(); tr.scaleXBy_yBy_(sx, sy); tr.concat()
        if working:
            self._sitting(m, t)
        else:
            self._standing(m, t)
        _pop()

        if working:
            self._bubble(m, t)
        elif m.dozing:
            self._zzz(m.x + 22 * SCALE, GROUND + 58 * SCALE, t)

    # ================= poses =================
    @objc.python_method
    def _standing(self, m, t):
        jumping = m.y > 0 or t < m.jump_until
        waving = (t < m.wave_until) and not m.dozing

        # feet (alternate lift while waddling)
        for side in (-1, 1):
            lift = max(0.0, math.sin(m.phase + (0 if side < 0 else math.pi))) * 3 if m.walking else 0.0
            _rrect(side * 9 - 6.5, lift, 13, 7, 3, FOOT, OUTLINE, 1.6)

        # arms
        if jumping:
            hands = [(-29, 56 + math.sin(t * 12) * 2), (29, 56 + math.sin(t * 12 + 1) * 2)]
        elif m.walking:
            s0 = math.sin(m.phase) * 5
            hands = [(-28, 24 + s0), (28, 24 - s0)]
        else:
            hands = [(-28, 23), (28, 23)]
        self._arm((-22, 38), hands[0])
        if not waving:
            self._arm((22, 38), hands[1])

        face = "sleep" if (m.dozing and not jumping) else ("happy" if (jumping or waving) else "normal")
        self._body(m, t, face=face)

        if waving:
            hand = (32 + math.sin(t * 11) * 4, 54 + abs(math.sin(t * 11)) * 3)
            self._arm((22, 38), hand)

    @objc.python_method
    def _sitting(self, m, t):
        cheering = t < m.cheer_until
        # feet poke out front while sitting
        for side in (-1, 1):
            _rrect(side * 10 - 6.5, 0.5, 13, 6.5, 3, FOOT, OUTLINE, 1.6)

        _push(); _xform(0, -4 + (1.5 if cheering else 0))
        if cheering:
            self._arm((-22, 38), (-29, 56))
            self._arm((22, 38), (29, 56))
            self._body(m, t, face="happy")
        else:
            self._body(m, t, face="focused")
        _pop()

        if not cheering:
            self._laptop(t)
            for side in (-1, 1):
                hy = 13.5 + max(0, math.sin(t * 15 + (0 if side < 0 else math.pi))) * 2.2
                self._arm((side * 22, 30), (side * 9, hy))

    @objc.python_method
    def _arm(self, shoulder, hand):
        _line(shoulder, hand, 9.6, OUTLINE)
        _line(shoulder, hand, 6.8, CREAM)
        _oval(hand[0], hand[1], 3.8, 3.8, CREAM, OUTLINE, 1.6)

    # ================= the robot =================
    @objc.python_method
    def _body(self, m, t, face):
        # capsule body
        body = NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(
            NSMakeRect(-23, 6, 46, 56), 21, 21)
        CREAM.set(); body.fill()
        _push()
        body.addClip()
        CREAM_SH.set(); NSBezierPath.fillRect_(NSMakeRect(-23, 6, 46, 8))      # ground shade
        _push(); _xform(-11, 54, 30); _oval(0, 0, 9, 3.5,
            NSColor.colorWithCalibratedWhite_alpha_(1.0, 0.55)); _pop()        # gloss
        _pop()
        OUTLINE.set(); body.setLineWidth_(2.0); body.stroke()

        # belly sprout decal (the Trellis mark)
        _line((0, 14), (0, 19.5), 2.0, SPROUT)
        _push(); _xform(0, 19.5, 35); _oval(0, 2.6, 2.2, 3.4, SPROUT); _pop()
        _push(); _xform(0, 19.5, -35); _oval(0, 2.6, 2.2, 3.4, SPROUT); _pop()

        self._screen_face(m, t, face)
        self._hat()
        self._antenna(m, t)

    @objc.python_method
    def _screen_face(self, m, t, face):
        scr = _rrect(-16, 27, 32, 22, 9, SCREEN, OUTLINE, 1.8)
        _push(); scr.addClip()
        # blush on the screen corners
        _oval(-11.5, 32.5, 2.8, 1.8, BLUSH)
        _oval(11.5, 32.5, 2.8, 1.8, BLUSH)

        bp = (t - m.blink_start) / 0.16
        blink_h = abs(math.cos(math.pi * bp)) if 0.0 <= bp <= 1.0 else 1.0

        if face == "happy":
            for side in (-1, 1):                      # ^ ^ eyes
                _arc(side * 7, 40, 3.6, 20, 160, 2.4, CYAN)
            mo = NSBezierPath.bezierPath()            # open little smile
            mo.appendBezierPathWithArcWithCenter_radius_startAngle_endAngle_((0, 34.5), 3.4, 200, 340)
            mo.setLineWidth_(2.2); mo.setLineCapStyle_(1); CYAN.set(); mo.stroke()
        elif face == "sleep":
            for side in (-1, 1):
                _arc(side * 7, 40, 3.4, 200, 340, 2.2, CYAN_DIM)
        else:
            focused = face == "focused"
            eh = 4.6 * blink_h * (0.55 if focused else 1.0)
            ey = 40.0 - (1.4 if focused else 0.0)
            lx = 0.0 if focused else m.look * 2.2
            for side in (-1, 1):
                ex = side * 7 + lx
                if blink_h < 0.2:
                    _line((ex - 2.6, ey), (ex + 2.6, ey), 2.0, CYAN)
                else:
                    _rrect(ex - 2.6, ey - eh, 5.2, eh * 2, 2.6, CYAN)
                    _oval(ex - 0.9, ey + eh * 0.45, 0.9, 0.9,
                          NSColor.colorWithCalibratedWhite_alpha_(1.0, 0.95))
            if focused:
                _line((-2.2, 33.5), (2.2, 33.5), 2.0, CYAN)
            else:
                _arc(0, 35.5, 3.0, 215, 325, 2.0, CYAN)
        _pop()

    @objc.python_method
    def _hat(self):
        dome = NSBezierPath.bezierPathWithOvalInRect_(NSMakeRect(-21, 52, 42, 26))
        HAT.set(); dome.fill()
        _push()
        dome.addClip()
        HAT_SH.set(); NSBezierPath.fillRect_(NSMakeRect(-21, 52, 42, 7))
        _oval(-9, 71, 6, 2.6, NSColor.colorWithCalibratedWhite_alpha_(1.0, 0.5))
        _pop()
        OUTLINE.set(); dome.setLineWidth_(2.0); dome.stroke()
        _rrect(-5, 74.5, 10, 5, 2.5, HAT, OUTLINE, 1.7)                 # top ridge
        _rrect(-26, 56, 52, 5.5, 2.7, HAT, OUTLINE, 1.8)                # brim

    @objc.python_method
    def _antenna(self, m, t):
        _line((0, 79), (0, 87), 2.4, OUTLINE)
        if m.mode == "WORK":
            a = 0.45 + 0.55 * abs(math.sin(t * 6))
            col = ORANGE.colorWithAlphaComponent_(a)
            halo = rgba(1.0, 0.58, 0.20, 0.30 * a)
        elif m.mode == "SLEEP":
            col, halo = GRAY, rgba(0.55, 0.56, 0.60, 0.12)
        else:
            a = 0.65 + 0.35 * math.sin(t * 2.2)
            col = GREEN.colorWithAlphaComponent_(max(0.4, a))
            halo = rgba(0.35, 0.82, 0.45, 0.25 * a)
        _oval(0, 91, 6.5, 6.5, halo)
        _oval(0, 91, 3.3, 3.3, col, OUTLINE, 1.6)

    @objc.python_method
    def _laptop(self, t):
        _rrect(-19, 9, 38, 5.5, 2, rgba(0.16, 0.16, 0.18), OUTLINE, 1.6)
        _rrect(-17, 14, 34, 21, 2.5, rgba(0.22, 0.22, 0.25), OUTLINE, 1.6)
        _rrect(-15, 16, 30, 17, 1.5, rgba(0.09, 0.10, 0.14))
        last_w = 0
        for i in range(4):
            seed = int(t * 7) + i * 5
            wln = 6 + (seed * 7 + i * 11) % 16
            last_w = wln
            CODE_COLORS[(seed + i) % len(CODE_COLORS)].set()
            NSBezierPath.fillRect_(NSMakeRect(-13 + (2 if i % 2 else 0), 29.5 - i * 3.5, wln, 1.6))
        if int(t * 2.5) % 2:
            NSColor.colorWithCalibratedWhite_alpha_(1.0, 0.9).set()
            NSBezierPath.fillRect_(NSMakeRect(-13 + 2 + last_w + 1.2, 29.5 - 3 * 3.5, 1.9, 1.6))
        _oval(0, 11.8, 1.5, 1.2, rgba(0.85, 0.47, 0.25))

    # ================= sleep scene =================
    @objc.python_method
    def _sleep_scene(self, m, t):
        lx = max(2.0, min(m.x, m.W - TOTAL_H * SCALE - 30))
        NSColor.colorWithCalibratedWhite_alpha_(0, 0.10).set()
        NSBezierPath.bezierPathWithOvalInRect_(
            NSMakeRect(lx - 6, GROUND - 4, (TOTAL_H + 14) * SCALE, 9 * SCALE + 3)).fill()
        _push()
        _xform(lx, GROUND, 0, SCALE)
        _rrect(TOTAL_H - 58, -2, 58, 11, 5, rgba(0.97, 0.97, 0.98), OUTLINE, 1.6)  # pillow
        _push()
        _xform(0, 26, -90)                             # lie flat, hat to the right
        for side in (-1, 1):
            _rrect(side * 9 - 6.5, 0, 13, 7, 3, FOOT, OUTLINE, 1.6)
        self._arm((-22, 38), (-27, 20))
        self._arm((22, 38), (27, 20))
        self._body(m, t, face="sleep")
        _pop()
        blanket_w = TOTAL_H * 0.52                     # red blanket up to his screen
        _rrect(-10, -3, blanket_w, 48, 7, BLANKET, OUTLINE, 1.8)
        BLANKET2.set(); NSBezierPath.fillRect_(NSMakeRect(-10 + blanket_w - 5, -2, 5, 46))
        NSColor.colorWithCalibratedWhite_alpha_(0.94, 1.0).set()
        NSBezierPath.fillRect_(NSMakeRect(-10 + blanket_w, -2, 3.5, 46))
        _pop()
        self._zzz(lx + (TOTAL_H - 18) * SCALE, GROUND + 54 * SCALE, t)

    # ================= overlays =================
    @objc.python_method
    def _bubble(self, m, t):
        msg = m.status or "working on it"
        if len(msg) > 58:
            msg = msg[:57] + "…"
        msg += "." * (int(t * 2) % 4)
        size = _text_size(msg, 12.5, bold=True)
        bw, bh = size.width + 24, size.height + 12
        by = GROUND + (m.y + TOTAL_H) * SCALE + 10
        bx = max(8, min(m.x - bw / 2, m.W - bw - 8))
        BUBBLE_BG.set()
        NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(
            NSMakeRect(bx, by, bw, bh), bh / 2, bh / 2).fill()
        tail = NSBezierPath.bezierPath()
        tail.moveToPoint_((m.x - 5, by + 2)); tail.lineToPoint_((m.x + 5, by + 2))
        tail.lineToPoint_((m.x, by - 8)); tail.closePath(); tail.fill()
        _text(msg, bx + 12, by + 6, 12.5, NSColor.whiteColor(), bold=True)

    @objc.python_method
    def _zzz(self, zx0, zy0, t):
        for i in range(3):
            prog = (t * 0.35 + i * 0.33) % 1.0
            alpha = max(0.0, 1.0 - prog)
            zx = zx0 + prog * 14 + i * 7
            zy = zy0 + prog * 24 + i * 4
            _text("z", zx + 0.8, zy - 0.8, 9 + i * 3,
                  NSColor.colorWithCalibratedWhite_alpha_(0.1, alpha * 0.8), bold=True)
            _text("z", zx, zy, 9 + i * 3,
                  NSColor.colorWithCalibratedWhite_alpha_(1.0, alpha * 0.9), bold=True)

# ------------------------------------------------------------------ app plumbing
class Controller(NSObject):
    def start(self):
        if DOCK_ITEM:
            self._start_dock_tile()
        else:
            self._start_floating()

    @objc.python_method
    def _start_dock_tile(self):
        global SCALE
        SCALE = 1.15                                   # fill the 128pt tile
        self.model = Mini(128.0)
        self.model.x = 64.0
        self.model.stationary = True
        view = BuddyView.alloc().initWithFrame_(NSMakeRect(0, 0, 128, 128))
        view.model = self.model
        self.tile = NSApplication.sharedApplication().dockTile()
        self.tile.setContentView_(view)
        self.view, self.win = view, None
        self.t_prev = time.time()
        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            1.0 / 10.0, self, b"tick:", None, True)    # dock tiles don't need 30fps

    @objc.python_method
    def _start_floating(self):
        # find the screen that actually hosts the Dock (reserved space at its bottom);
        # mainScreen() is just the focused screen and lies on multi-monitor setups
        screen = None
        for cand in NSScreen.screens():
            cf, cvf = cand.frame(), cand.visibleFrame()
            if cvf.origin.y - cf.origin.y > 20:
                screen = cand
                break
        if screen is None:
            screen = NSScreen.screens()[0]     # Dock hidden/side-docked: primary screen
        f, vf = screen.frame(), screen.visibleFrame()
        floor_y = max(f.origin.y, vf.origin.y - GROUND + 2)
        rect = NSMakeRect(f.origin.x, floor_y, f.size.width, WIN_H)

        win = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            rect, 0, NSBackingStoreBuffered, False)
        win.setOpaque_(False)
        win.setBackgroundColor_(NSColor.clearColor())
        from AppKit import NSFloatingWindowLevel
        win.setLevel_(NSFloatingWindowLevel)   # under the Dock/menus/popups, over app windows
        win.setIgnoresMouseEvents_(True)
        win.setCollectionBehavior_(
            NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary)
        win.setHasShadow_(False)

        self.model = Mini(f.size.width)
        view = BuddyView.alloc().initWithFrame_(NSMakeRect(0, 0, f.size.width, WIN_H))
        view.model = self.model
        win.setContentView_(view)
        win.orderFrontRegardless()

        self.win, self.view = win, view
        self.t_prev = time.time()
        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            1.0 / FPS, self, b"tick:", None, True)

    def tick_(self, _timer):
        t = time.time()
        dt = min(0.15, t - self.t_prev)
        self.t_prev = t
        self.model.update(dt, t)
        self.view.setNeedsDisplay_(True)
        if getattr(self, "tile", None) is not None:
            self.tile.display()

if __name__ == "__main__":
    app = NSApplication.sharedApplication()
    if DOCK_ITEM:                                      # a real Dock item needs Regular policy
        from AppKit import NSApplicationActivationPolicyRegular
        app.setActivationPolicy_(NSApplicationActivationPolicyRegular)
    else:
        app.setActivationPolicy_(NSApplicationActivationPolicyAccessory)
    c = Controller.alloc().init()
    c.start()
    app.run()
