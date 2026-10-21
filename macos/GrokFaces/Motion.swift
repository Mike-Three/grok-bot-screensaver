// Grok Bot Screensaver for macOS: the faces, the blink and the motion. Plain Swift and Foundation only (no AppKit),
// the same model as the Windows version (windows/GrokFaces.cs). GrokFacesView.swift decodes the sprite sheets and
// draws what this produces.
// The faces are pre-rendered from the app's 3D face marks with flat, unlit color (see sprites/ and README). Each sheet
// holds 8-bit signed-distance masks (128 = the outline, eyes are holes), so the palette color is applied as one solid
// fill. Motion follows the "wait for it" reference video: a DVD-style bounce, an instant switch to a new shape and color
// on every wall, the face looking where it's heading, and a happy spin when it lands in a corner.
// The face tips in 3D (turn and nod) to look where it's heading. A bounce changes that and gives the tilt a push; a
// damped spring settles it in about a quarter of a second with one small overshoot. The four 3D renders around the
// current angle are blended. Travel is a straight line at constant speed with a mirror-exact bounce.
import Foundation

enum Faces {
    // The 13 shapes of the Grok Bot avatar picker, in picker order.
    static let shapes = ["blob", "cloud", "square", "sparkle", "clover", "heart", "flower",
                         "teardrop", "tablet", "wedge", "house", "star", "hex"]
    // Grok Bot palette (white is the app's black mark in dark mode).
    static let palette: [UInt32] = [
        0xFFFFFF, // white
        0x936439, // brown
        0xFF263C, // red
        0xFF6700, // orange
        0xFF9800, // yellow
        0x00C972, // green
        0x00BCA6, // cyan
        0x1084FE, // blue
        0x9159FE, // violet
        0xFF309B, // magenta
        0x777777  // gray
    ]
    static let cell = 256, cols = 12, px = 256 * 256
    // Frames 0-374: 3D renders on a turn x nod grid, frame = nod step * 25 + turn step, turn -24..24 and nod -14..14
    // degrees in 2 degree steps. Positive turn looks right, positive nod looks down. The blink is drawn from these
    // (see Lids). Frames 375-449: the corner celebration (happy eyes, a full spin and a wobble), 30 frames per second.
    static let turns = 25, nods = 15, celFirst = 25 * 15, celFrames = 75, straight = 4
    static let celFps: Float = 30, turn0: Float = -24, nod0: Float = -14, step: Float = 2
    static let frontFrame = 7 * turns + 12 // turn 0, nod 0
    // How far each shape turns and nods toward where it's heading, in degrees (measured from the reference video).
    static func gain(_ shape: Int) -> Float {
        switch shapes[shape] { case "heart": return 0.6; case "wedge": return 0.55; default: return 1 }
    }
    static func gazeTurn(_ shape: Int) -> Float { (shapes[shape] == "blob" ? 14.4 : 20.8) * gain(shape) }
    static func gazeNod(_ shape: Int) -> Float { (shapes[shape] == "blob" ? 8.4 : 11.4) * gain(shape) }
    static let celDuration = Float(celFrames - 1) / celFps
    static let cellFraction: Float = 0.283 // sprite cell edge relative to the shorter screen side
    static let alpha: [UInt8] = (0..<256).map { v in UInt8((255 * min(1, max(0, (Double(v) - 128) / 8 + 0.5))).rounded()) }

    // One decoded sheet: distance values (top row first) and the eye geometry of the open-eye frames.
    struct Sheet { let width: Int; let pixels: [UInt8]; let eyes: [Float] }
    // Set by the platform code: decodes face-<name>.png.
    static var decode: (String) -> Sheet? = { _ in nil }

    // Sheets are decoded once and kept for the 2 most recently used shapes (the one on screen and the next). The next
    // shape is decoded ahead of time in the background, and a bounce only switches to a shape that is ready.
    private static var cache: [Int: Sheet] = [:]
    private static var order: [Int] = []
    private static var boxes: [Int: (x0: Int, y0: Int, x1: Int, y1: Int)] = [:]
    private static let lock = NSLock()

    static func preload(_ shape: Int) {
        DispatchQueue.global(qos: .utility).async { _ = sheet(shape) }
    }

    static func ready(_ shape: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return cache[shape] != nil }

    // Another shape that is already decoded (the previous one), or nil.
    static func other(_ shape: Int) -> Int? { lock.lock(); defer { lock.unlock() }; return order.first { $0 != shape } }

    static func sheet(_ shape: Int) -> Sheet? {
        lock.lock()
        if let s = cache[shape] { // most recently used last, so the shape on screen is never evicted
            if order.last != shape { order.removeAll { $0 == shape }; order.append(shape) }
            lock.unlock(); return s
        }
        lock.unlock()
        guard let s = decode(shapes[shape]) else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let have = cache[shape] { return have }
        cache[shape] = s; order.append(shape)
        if order.count > 2 { cache[order.removeFirst()] = nil }
        return s
    }

    // Copies one frame's distance values into dst (cell x cell, top row first).
    static func read(_ shape: Int, _ frame: Int, into dst: UnsafeMutablePointer<Float>) {
        guard let sh = sheet(shape) else { return }
        let sx = (frame % cols) * cell, sy = (frame / cols) * cell
        sh.pixels.withUnsafeBufferPointer { p in
            for y in 0..<cell {
                let row = (sy + y) * sh.width + sx, o = y * cell
                for x in 0..<cell { dst[o + x] = Float(p[row + x]) }
            }
        }
    }

    static func eyes(_ shape: Int) -> [Float] { sheet(shape)?.eyes ?? [] }

    // Collision box in sprite pixels (top-left origin, x1 and y1 exclusive): the outline of the straight-on pose.
    static func box(_ shape: Int) -> (x0: Int, y0: Int, x1: Int, y1: Int) {
        if let b = boxes[shape] { return b }
        var f = [Float](repeating: 0, count: px)
        f.withUnsafeMutableBufferPointer { read(shape, frontFrame, into: $0.baseAddress!) }
        var x0 = cell, y0 = cell, x1 = 0, y1 = 0
        for y in 0..<cell { for x in 0..<cell where f[y * cell + x] >= 128 {
            x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
        } }
        let b = x1 >= x0 ? (x0, y0, x1 + 1, y1 + 1) : (64, 64, 192, 192)
        boxes[shape] = b
        return b
    }

    // The eye geometry stored in a sheet's private "eyEs" PNG chunk (little-endian floats).
    static func eyeChunk(_ png: Data) -> [Float]? {
        var i = 8
        while i + 8 <= png.count {
            let len = png[i..<i + 4].reduce(0) { $0 << 8 | Int($1) }
            let type = String(decoding: png[i + 4..<i + 8], as: UTF8.self)
            if type == "eyEs", i + 8 + len <= png.count {
                return stride(from: i + 8, to: i + 8 + len, by: 4).map { (o: Int) -> Float in
                    let b0 = UInt32(png[o]), b1 = UInt32(png[o + 1]) << 8
                    let b2 = UInt32(png[o + 2]) << 16, b3 = UInt32(png[o + 3]) << 24
                    return Float(bitPattern: b0 | b1 | b2 | b3)
                }
            }
            if type == "IEND" { break }
            i += 12 + len
        }
        return nil
    }
}

// The blink, drawn from the open eyes the way the app's face engine does it: the lid comes down along the eye and
// squashes it about the point 60 percent of the way down, to 3 percent of its length at most. On the Blob the whole eye
// is squashed, so a closed eye is a thin line. On the other bodies the engine squashes only the straight middle of the
// capsule and keeps its round ends, so a closed eye is a dot as wide as the open eye. Per eye the sheet stores its centre
// (cx, cy), the lid direction u (the eye's long axis, pointing down), the direction e of the closed line (measured from
// the engine's closed-eye renders), and the half extents la along u and lb along e, all in sprite pixels.
enum Lids {
    static let pivot: Float = 0.6, thinnest: Float = 0.03, cap: Float = 0.26 / 0.57

    // Bilinear blend of the eye data of four frames (the same weights as the sprite blend), into q (16 floats).
    static func blend(_ m: [Float], _ f0: Int, _ turns: Int, _ a: Float, _ b: Float, into q: inout [Float]) {
        for i in 0..<16 {
            let v00 = m[f0 * 16 + i], v01 = m[(f0 + 1) * 16 + i], v10 = m[(f0 + turns) * 16 + i], v11 = m[(f0 + turns + 1) * 16 + i]
            let top = v00 + (v01 - v00) * a, bot = v10 + (v11 - v10) * a
            q[i] = top + (bot - top) * b
        }
    }

    // Closes both eyes of src (distance values) by lid (0 open, 1 shut) into dst, to a line or to dots. src and dst are
    // different buffers that start out equal.
    static func close(_ src: UnsafePointer<Float>, _ dst: UnsafeMutablePointer<Float>, _ q: [Float], _ lid: Float, line: Bool) {
        let ly = max(thinnest, 1 - lid)
        for e in 0..<2 { closeEye(src, dst, q, e * 8, ly, line) }
    }

    private static func closeEye(_ src: UnsafePointer<Float>, _ dst: UnsafeMutablePointer<Float>, _ q: [Float], _ o: Int,
                                 _ ly: Float, _ line: Bool) {
        let cx = q[o], cy = q[o + 1], la = q[o + 6], lb = q[o + 7]
        var n = (q[o + 2] * q[o + 2] + q[o + 3] * q[o + 3]).squareRoot()
        let ux = q[o + 2] / n, uy = q[o + 3] / n
        n = (q[o + 4] * q[o + 4] + q[o + 5] * q[o + 5]).squareRoot()
        let ex = q[o + 4] / n, ey = q[o + 5] / n
        let det = ux * ey - uy * ex, k = 1 / ly - 1, pv = (pivot - 0.5) * 2 * la, px = cx + ux * pv, py = cy + uy * pv
        // the squashed part along u, from the pivot: the whole eye for a line, all but the round ends for dots; what
        // lies beyond it only moves with its end. Each round end is cap of the half length, as in the engine's eye (0.26
        // wide, 0.57 long), so it is measured along u and keeps the eye's own foreshortening there
        let keep = line ? 0 : la * cap, lo = (keep - la - pv) * ly, hi = (la - keep - pv) * ly
        let r = Int(max(la, lb)) + 4, C = Faces.cell
        let x0 = max(1, Int(cx) - r), x1 = min(C - 2, Int(cx) + r), y0 = max(1, Int(cy) - r), y1 = min(C - 2, Int(cy) + r)
        guard x0 <= x1, y0 <= y1 else { return }
        for yi in y0...y1 {
            for xi in x0...x1 {
                let i = yi * C + xi, x = Float(xi), y = Float(yi)
                var v = dst[i]
                // p = cx,cy + a u + b e (oblique coordinates); first fill in the open eye
                let a = ((x - cx) * ey - (y - cy) * ex) / det, b = (ux * (y - cy) - uy * (x - cx)) / det
                if abs(a) <= la + 1.5 && abs(b) <= lb + 1.5 && v < 136 { v = 255 }
                // then cut the squashed eye: where this pixel came from in the open eye
                let ap = ((x - px) * ey - (y - py) * ex) / det, bp = (ux * (y - py) - uy * (x - px)) / det
                let c = min(hi, max(lo, ap)), kc = c == ap ? k : 0, sap = ap + c * k
                let sx = px + sap * ux + bp * ex, sy = py + sap * uy + bp * ey
                let sa = ((sx - cx) * ey - (sy - cy) * ex) / det, sb = (ux * (sy - cy) - uy * (sx - cx)) / det
                if abs(sa) <= la + 3 && abs(sb) <= lb + 3 {
                    let d = (sample(src, sx, sy) - 128) / 8
                    let gx = (sample(src, sx + 0.5, sy) - sample(src, sx - 0.5, sy)) / 8
                    let gy = (sample(src, sx, sy + 0.5) - sample(src, sx, sy - 0.5)) / 8
                    // the squash stretches distances along u: rescale so the edge stays one pixel soft
                    let gu = gx * ux + gy * uy, Gx = gx + kc * gu * ey / det, Gy = gy - kc * gu * ex / det
                    let g = (Gx * Gx + Gy * Gy).squareRoot()
                    v = min(v, 128 + 8 * d / max(g, 1e-3))
                }
                // no point of the closed eye lies deeper than its distance to the ends of the closed eye along u (this
                // keeps the thin line's distances right where the open eye's are far deeper)
                let depth = min(ap - lo + keep, hi + keep - ap) * abs(det)
                if depth > 0 { v = max(v, 128 - 8 * depth) }
                dst[i] = v
            }
        }
    }

    private static func sample(_ f: UnsafePointer<Float>, _ x0: Float, _ y0: Float) -> Float {
        let C = Faces.cell
        let x = min(Float(C) - 1.001, max(0, x0)), y = min(Float(C) - 1.001, max(0, y0))
        let ix = Int(x), iy = Int(y), fx = x - Float(ix), fy = y - Float(iy), i = iy * C + ix
        let top = f[i] + (f[i + 1] - f[i]) * fx, bot = f[i + C] + (f[i + C + 1] - f[i + C]) * fx
        return top + (bot - top) * fy
    }
}

// The face's motion and what it looks like, for a screen of w x h points (top-left origin, y grows downward).
final class Saver<R: RandomNumberGenerator> {
    // Blink timing from the app's face engine: the lid closes in 0.08 s, stays shut 0.07 s and opens in 0.11 s. Then
    // the eyes stay open at least minOpen before the next blink, so two blinks never run into each other.
    private let lidClose: Float = 0.08, lidHold: Float = 0.07, lidOpen: Float = 0.11, minOpen: Float = 0.3
    private var blinkTime: Float { lidClose + lidHold + lidOpen }
    // Tilt spring: natural frequency (Hz) and damping ratio (one overshoot of about 6 percent), the push per bounce
    // relative to the speed into the wall (doubled with the half travel speed, so the kick is unchanged), and the
    // physics step (s).
    private let springHz: Float = 1.4, damping: Float = 0.65, pushGain: Float = 0.6, physStep: Float = 1.0 / 120

    private(set) var x: Float = 0, y: Float = 0, cellPx: Float = 100
    private(set) var vx: Float = 0, vy: Float = 0
    private(set) var turn: Float = 0, nod: Float = 0 // tilt (degrees)
    private var turnVel: Float = 0, nodVel: Float = 0 // and its speed (degrees per second)
    private(set) var shape = 0, color = 0, celT: Float = -1, blinkT: Float = -1
    private var W: Float, H: Float
    private var upcoming = 1, dir = 4, tick = 0, lastHitX = -99, lastHitY = -99
    private var t: Float = 0, nextBlink: Float = 6
    private var rng: R
    private var cur = [Float](repeating: 0, count: Faces.px), nxt = [Float](repeating: 0, count: Faces.px)
    private var open = [Float](repeating: 0, count: Faces.px), tmp = [Float](repeating: 0, count: Faces.px)
    private var eye = [Float](repeating: 0, count: 16)
    // The composed sprite: premultiplied RGBA, cell x cell, top row first.
    private(set) var rgba = [UInt8](repeating: 0, count: Faces.px * 4)

    init(width w: Float, height h: Float, rng: R) {
        W = w; H = h; self.rng = rng
        cellPx = max(16, min(w, h) * Faces.cellFraction)
        // px per second: half the earlier pace, so 0.625 of the reference video's (the video moves
        // 7.9 px per frame at 1080p), heading 28 to 62 degrees off the horizontal
        let sp = min(w, h) / 137 * 60 * 0.625, a = rand(28, 62) * .pi / 180
        vx = sp * cos(a) * (Bool.random(using: &self.rng) ? 1 : -1); vy = sp * sin(a) * (Bool.random(using: &self.rng) ? 1 : -1)
        shape = Int.random(in: 0..<Faces.shapes.count, using: &self.rng)
        color = Int.random(in: 0..<Faces.palette.count, using: &self.rng)
        pickUpcoming()
        let b = boxAt(0, 0)
        x = -b.l + rand(0, 1) * max(1, w - (b.r - b.l))
        y = -b.t + rand(0, 1) * max(1, h - (b.b - b.t))
        dir = pickDir()
        nextBlink = 4 + rand(0, 4)
        turn = targetTurn(); nod = targetNod()
        compose()
    }

    // A new screen size: same heading, speed and face size scaled to it.
    func resize(width w: Float, height h: Float) {
        guard w > 0, h > 0, w != W || h != H else { return }
        let k = min(w, h) / min(W, H)
        vx *= k; vy *= k; x *= w / W; y *= h / H; W = w; H = h
        cellPx = max(16, min(w, h) * Faces.cellFraction)
    }

    private func rand(_ a: Float, _ b: Float) -> Float { a + Float.random(in: 0..<1, using: &rng) * (b - a) }

    // The face's collision box on screen if its sprite cell were centered at (cx, cy).
    private func boxAt(_ cx: Float, _ cy: Float) -> (l: Float, t: Float, r: Float, b: Float) {
        let bx = Faces.box(shape), sc = cellPx / Float(Faces.cell), h = Float(Faces.cell) / 2
        return (cx + (Float(bx.x0) - h) * sc, cy + (Float(bx.y0) - h) * sc, cx + (Float(bx.x1) - h) * sc, cy + (Float(bx.y1) - h) * sc)
    }

    // Look where it's heading; if the next wall contact will be a corner, look straight at the viewer ("wait for it").
    private func pickDir() -> Int {
        let b = boxAt(x, y)
        let tx = vx < 0 ? -b.l / -vx : (W - b.r) / vx
        let ty = vy < 0 ? -b.t / -vy : (H - b.b) / vy
        if abs(tx - ty) < 1.5 / 60 { return Faces.straight }
        return (vx < 0 ? 0 : 1) + (vy < 0 ? 0 : 2)
    }

    // The next face is chosen one bounce ahead so its sheet can be decoded in the background.
    private func pickUpcoming() {
        var n = shape; while n == shape { n = Int.random(in: 0..<Faces.shapes.count, using: &rng) }
        upcoming = n; Faces.preload(n)
    }

    private func heading() -> Float { dir == Faces.straight ? 0 : (dir == 0 || dir == 2 ? -1 : 1) }

    // Where the tilt settles: looking where it's heading (straight at you before a corner).
    private func targetTurn() -> Float { Faces.gazeTurn(shape) * heading() }
    private func targetNod() -> Float { dir == Faces.straight ? 0 : Faces.gazeNod(shape) * (dir < 2 ? -1 : 1) }

    // One physics step of the tilt: a damped spring toward the target, on both axes.
    private func settle(_ h: Float) {
        let w = 2 * Float.pi * springHz
        turnVel += (-w * w * (turn - targetTurn()) - 2 * damping * w * turnVel) * h
        nodVel += (-w * w * (nod - targetNod()) - 2 * damping * w * nodVel) * h
        turn += turnVel * h; nod += nodVel * h
    }

    private func settle(for time: Float) {
        var left = time
        while left > 1e-6 { settle(min(physStep, left)); left -= physStep }
    }

    // The push a bounce gives the tilt: a side wall pushes the turn, a top or bottom wall the nod, toward the new
    // target, in proportion to the speed into the wall over the face's radius.
    private func push(_ speedIn: Float, _ now: Float, _ target: Float) -> Float {
        let s: Float = target > now ? 1 : (target < now ? -1 : 0)
        return pushGain * s * speedIn / (cellPx * 0.33) * 180 / .pi
    }

    private func ease(_ u0: Float) -> Float { let u = min(1, max(0, u0)); return u * u * (3 - 2 * u) }

    // How far the eyes are closed during a blink (0 open, 1 shut).
    private func lid(_ bt: Float) -> Float {
        if bt < lidClose { return ease(bt / lidClose) }
        if bt < lidClose + lidHold { return 1 }
        return 1 - ease((bt - lidClose - lidHold) / lidOpen)
    }

    private static func first(_ a: Float, _ b: Float) -> Float { a < 0 ? b : min(a, b) }

    // Advances by dt seconds and composes the new sprite.
    func step(_ dt0: Float) {
        let dt = min(0.25, max(0, dt0))
        t += dt; tick += 1
        // Fixed physics steps. A wall mirrors the overshoot back, so the face never jumps and its speed never changes.
        var hx = false, hy = false, inX: Float = 0, inY: Float = 0, hitAt: Float = -1 // speed into the wall, time of impact
        var done: Float = 0
        while dt - done > 1e-6 {
            let h = min(physStep, dt - done)
            x += vx * h; y += vy * h
            let b = boxAt(x, y)
            // a wall counts only while moving into it
            if (b.l <= 0 && vx < 0) || (b.r >= W && vx > 0) {
                // how far it moved past the wall in this step (the impact was over / speed ago); a new, bigger shape can
                // start out past a wall, and that part is left alone so the face never jumps
                inX = abs(vx); let over = min(vx < 0 ? -b.l : b.r - W, inX * h)
                x += vx < 0 ? 2 * over : -2 * over; vx = -vx; hx = true
                hitAt = Saver.first(hitAt, done + h - over / inX)
            }
            if (b.t <= 0 && vy < 0) || (b.b >= H && vy > 0) {
                inY = abs(vy); let over = min(vy < 0 ? -b.t : b.b - H, inY * h)
                y += vy < 0 ? 2 * over : -2 * over; vy = -vy; hy = true
                hitAt = Saver.first(hitAt, done + h - over / inY)
            }
            done += physStep
        }
        if hitAt < 0 { if celT < 0 { settle(for: dt) } }
        else {
            if celT < 0 { settle(for: hitAt) } // the tilt runs up to the moment of impact, then gets its push
            let prevX = lastHitX, prevY = lastHitY
            if hx { lastHitX = tick }
            if hy { lastHitY = tick }
            let corner = abs(lastHitX - lastHitY) <= 1
            let merged = (hx && !hy && tick - prevY <= 1) || (hy && !hx && tick - prevX <= 1) // second wall of a corner
            if !merged { // new shape and color right away
                // two bounces in quick succession can come before the next sheet is decoded: use the previous shape then
                if Faces.ready(upcoming) { shape = upcoming; pickUpcoming() }
                else if let o = Faces.other(shape) { shape = o }
                var n = color; while n == color { n = Int.random(in: 0..<Faces.palette.count, using: &rng) }; color = n
                if !corner && blinkT < 0 && Float.random(in: 0..<1, using: &rng) < 0.35 { blinkT = 0 }
            }
            celT = corner ? 0 : -1
            if corner { blinkT = -1; turn = 0; nod = 0; turnVel = 0; nodVel = 0 } // the spin starts and ends straight on
            dir = pickDir()
            if celT < 0 {
                if hx { turnVel += push(inX, turn, targetTurn()) }
                if hy { nodVel += push(inY, nod, targetNod()) }
                settle(for: dt - hitAt)
            }
        }
        if celT >= 0 && hitAt < 0 {
            celT += dt
            if celT > Faces.celDuration { celT = -1 }
        }
        if blinkT >= 0 { blinkT += dt; if blinkT > blinkTime + minOpen { blinkT = -1 } }
        else if celT < 0 && t >= nextBlink { blinkT = 0; nextBlink = t + 4 + rand(0, 4) }
        compose()
    }

    // What the face looks like right now, as distance values in cur.
    private func current() {
        cur.withUnsafeMutableBufferPointer { c in
            nxt.withUnsafeMutableBufferPointer { n in
                tmp.withUnsafeMutableBufferPointer { m in
                    let cp = c.baseAddress!, np = n.baseAddress!, mp = m.baseAddress!
                    if celT >= 0 {
                        let f = min(celT * Faces.celFps, Float(Faces.celFrames - 1))
                        let i = Int(f), fr = f - Float(i)
                        Faces.read(shape, Faces.celFirst + i, into: cp)
                        if fr > 0.001 && i + 1 < Faces.celFrames {
                            Faces.read(shape, Faces.celFirst + i + 1, into: np)
                            for k in 0..<Faces.px { cp[k] += (np[k] - cp[k]) * fr }
                        }
                        return
                    }
                    // The four renders around the current tilt, blended by where the tilt sits between them.
                    let T = Faces.turns
                    let ft = min(Float(T - 1), max(0, (turn - Faces.turn0) / Faces.step))
                    let fn = min(Float(Faces.nods - 1), max(0, (nod - Faces.nod0) / Faces.step))
                    let it = min(T - 2, Int(ft)), inod = min(Faces.nods - 2, Int(fn))
                    let a = ft - Float(it), b = fn - Float(inod), f0 = inod * T + it
                    Faces.read(shape, f0, into: cp); Faces.read(shape, f0 + 1, into: mp)
                    for k in 0..<Faces.px { cp[k] += (mp[k] - cp[k]) * a }
                    Faces.read(shape, f0 + T, into: np); Faces.read(shape, f0 + T + 1, into: mp)
                    for k in 0..<Faces.px { let lo = np[k] + (mp[k] - np[k]) * a; cp[k] += (lo - cp[k]) * b }
                    let l = blinkT >= 0 ? lid(blinkT) : 0
                    if l > 0.001 {
                        let m = Faces.eyes(shape)
                        if m.count >= (f0 + T + 2) * 16 {
                            open.withUnsafeMutableBufferPointer { o in
                                o.baseAddress!.update(from: cp, count: Faces.px)
                                Lids.blend(m, f0, T, a, b, into: &eye)
                                Lids.close(o.baseAddress!, cp, eye, l, line: Faces.shapes[shape] == "blob")
                            }
                        }
                    }
                }
            }
        }
    }

    private func compose() {
        current()
        let c = Faces.palette[color]
        let cr = Int((c >> 16) & 0xFF), cg = Int((c >> 8) & 0xFF), cb = Int(c & 0xFF)
        cur.withUnsafeBufferPointer { v in
            rgba.withUnsafeMutableBufferPointer { o in
                for k in 0..<Faces.px {
                    let a = Int(Faces.alpha[Int(min(255, max(0, v[k] + 0.5)))])
                    let i = k * 4 // premultiplied
                    o[i] = UInt8(cr * a / 255); o[i + 1] = UInt8(cg * a / 255); o[i + 2] = UInt8(cb * a / 255); o[i + 3] = UInt8(a)
                }
            }
        }
    }
}
