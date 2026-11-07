// Macscapes — desktop weather that lives *behind* your windows.
// Particles treat every app window as a solid object: they land on window tops,
// slide down window sides, and fly off when you drag a window — but they are drawn
// at desktop level, so they can never cover or block what's in a window.

import Cocoa
import QuartzCore
import ServiceManagement

// MARK: - Settings

enum Effect: String, CaseIterable {
    case snow, rain, storm, tornado, dust, sakura, leaves, fireflies, starfall

    var title: String {
        switch self {
        case .snow: return "Snow"
        case .rain: return "Rain"
        case .storm: return "Thunderstorm"
        case .tornado: return "Tornado"
        case .sakura: return "Sakura"
        case .leaves: return "Autumn Leaves"
        case .fireflies: return "Fireflies"
        case .starfall: return "Starfall"
        case .dust: return "Dust Storm"
        }
    }

    var symbol: String {
        switch self {
        case .snow: return "snowflake"
        case .rain: return "cloud.rain"
        case .storm: return "cloud.bolt.rain"
        case .tornado: return "tornado"
        case .sakura: return "camera.macro"
        case .leaves: return "leaf"
        case .fireflies: return "sparkles"
        case .starfall: return "moon.stars"
        case .dust: return "sun.dust"
        }
    }
}

enum Settings {
    static let d = UserDefaults.standard
    static var effect: Effect {
        get { Effect(rawValue: d.string(forKey: "effect") ?? "") ?? .snow }
        set { d.set(newValue.rawValue, forKey: "effect") }
    }
    static var intensity: Double {
        get { let v = d.double(forKey: "intensity"); return v == 0 ? 1 : v }
        set { d.set(newValue, forKey: "intensity") }
    }
    static var solidIcons: Bool {
        get { d.object(forKey: "solidIcons") as? Bool ?? true }
        set { d.set(newValue, forKey: "solidIcons") }
    }
    /// 0 = calm … 3 = gale. Scales gusts for every effect.
    static var windStrength: Double {
        get { d.object(forKey: "windStrength") as? Double ?? 1 }
        set { d.set(newValue, forKey: "windStrength") }
    }
    /// Degrees from vertical, −60 (blowing left) … 60 (blowing right). Tilts everything that falls.
    static var windAngle: Double {
        get { d.object(forKey: "windAngle") as? Double ?? 0 }
        set { d.set(newValue, forKey: "windAngle") }
    }
    /// Rain effects slowly fill the screen with water.
    static var flood: Bool {
        get { d.bool(forKey: "flood") }
        set { d.set(newValue, forKey: "flood") }
    }
    static var paused: Bool {
        get { d.bool(forKey: "paused") }
        set { d.set(newValue, forKey: "paused") }
    }
}

@inline(__always) func rnd(_ a: CGFloat, _ b: CGFloat) -> CGFloat { CGFloat.random(in: a...b) }
@inline(__always) func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { min(max(v, lo), hi) }

// MARK: - Window tracking (positions only — no Screen Recording permission needed)

struct WinInfo {          // Cocoa global coords (y up)
    let id: Int
    let rect: CGRect
    var radius: CGFloat = 14   // visible corner radius of the shape
}

final class WindowTracker {
    static let shared = WindowTracker()
    private(set) var windows: [WinInfo] = []
    private(set) var generation = 0
    private(set) var pollDT: CGFloat = 1.0 / 20
    private var lastPoll: CFTimeInterval = 0
    private let myPID = Int(getpid())

    func refreshIfNeeded() {
        let now = CACurrentMediaTime()
        guard now - lastPoll >= 1.0 / 20 else { return }
        pollDT = clamp(CGFloat(now - lastPoll), 1.0 / 120, 0.2)
        lastPoll = now
        windows = poll()
        generation += 1
    }

    private func poll() -> [WinInfo] {
        guard let primary = NSScreen.screens.first,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        let primaryH = primary.frame.height
        var out: [WinInfo] = []
        for w in info {   // front-to-back order
            let layer = (w[kCGWindowLayer as String] as? Int) ?? 0
            let owner = (w[kCGWindowOwnerName as String] as? String) ?? ""
            // App windows (layer 0) + desktop widgets (Notification Center windows below normal level)
            let isWidget = owner == "Notification Center" && layer < 0
            guard layer == 0 || isWidget,
                  (w[kCGWindowOwnerPID as String] as? Int) != myPID,
                  ((w[kCGWindowAlpha as String] as? Double) ?? 1) > 0.05,
                  let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: bd as CFDictionary),
                  b.width > 40, b.height > 30,
                  !(isWidget && (b.width > 900 || b.height > 900)),
                  let num = w[kCGWindowNumber as String] as? Int
            else { continue }
            // A widget's window has a transparent margin around the visible card.
            let r = isWidget ? b.insetBy(dx: 8.5, dy: 8.5) : b
            out.append(WinInfo(id: num, rect: CGRect(x: r.minX, y: primaryH - r.maxY,
                                                      width: r.width, height: r.height),
                               radius: isWidget ? 22 : 14))
        }
        // Desktop file icons sit behind every window and widget.
        DesktopIconTracker.shared.refreshIfNeeded(primaryH: primaryH)
        out.append(contentsOf: DesktopIconTracker.shared.icons)
        return out
    }
}

// MARK: - Desktop icons (via Finder's accessibility tree — needs Accessibility permission)

final class DesktopIconTracker {
    static let shared = DesktopIconTracker()
    private(set) var icons: [WinInfo] = []
    private var last: CFTimeInterval = 0

    var trusted: Bool { AXIsProcessTrusted() }

    func requestAccess() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    private func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
    }
    private func kids(_ e: AXUIElement) -> [AXUIElement] { attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
    private func role(_ e: AXUIElement) -> String { attr(e, kAXRoleAttribute) as? String ?? "" }

    func refreshIfNeeded(primaryH: CGFloat) {
        let now = CACurrentMediaTime()
        guard now - last >= 0.5 else { return }
        last = now
        guard Settings.solidIcons, trusted,
              let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
        else { icons = []; return }
        let app = AXUIElementCreateApplication(finder.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var out: [WinInfo] = []
        // Finder app → AXScrollArea (the desktop) → AXGroup → AXImage per icon
        for area in kids(app) where role(area) == "AXScrollArea" {
            for group in kids(area) where role(group) == "AXGroup" {
                for img in kids(group) where role(img) == "AXImage" {
                    var p = CGPoint.zero, s = CGSize.zero
                    guard let pv = attr(img, kAXPositionAttribute), let sv = attr(img, kAXSizeAttribute) else { continue }
                    AXValueGetValue(pv as! AXValue, .cgPoint, &p)
                    AXValueGetValue(sv as! AXValue, .cgSize, &s)
                    guard s.width > 8, s.height > 8 else { continue }
                    // Trim the transparent padding around the artwork, then include the name label below.
                    let inX = s.width * 0.14, inTop = s.height * 0.1
                    let tl = CGRect(x: p.x + inX, y: p.y + inTop, width: s.width - 2 * inX, height: s.height - inTop + 30)
                    let name = attr(img, kAXTitleAttribute) as? String ?? "\(p)"
                    let id = (1 << 40) | (name.hashValue & 0xFFFF_FFFF)
                    out.append(WinInfo(id: id, rect: CGRect(x: tl.minX, y: primaryH - tl.maxY,
                                                            width: tl.width, height: tl.height), radius: 6))
                }
            }
        }
        icons = out
    }
}

// MARK: - Model

enum Kind { case main, splash, spark, debris, runoff }   // debris hue: 0 carrot, 1 hat, 2 stick, 3 coal

// MARK: - Snowballs & snowmen

final class Ball {
    var x: CGFloat, y: CGFloat, r: CGFloat
    var vx: CGFloat = 0, vy: CGFloat = 0
    var held = false, resting = false, dead = false
    var restPile: Int? = nil
    weak var restBall: Ball?
    var spin: CGFloat = 0
    init(x: CGFloat, y: CGFloat, r: CGFloat) { self.x = x; self.y = y; self.r = r }
}

final class Snowman {
    var x: CGFloat, y: CGFloat          // x centre, y = feet
    var r: [CGFloat]                    // bottom, middle, head
    var vx: CGFloat = 0, vy: CGFloat = 0
    var held = false, resting = false, dead = false
    var restPile: Int? = nil
    var grabDX: CGFloat = 0, grabDY: CGFloat = 0
    var tilt: CGFloat = 0
    init(x: CGFloat, y: CGFloat, r: [CGFloat]) { self.x = x; self.y = y; self.r = r }

    /// Local (untilted) centres, relative to the feet.
    var localCentres: [CGPoint] {
        let c0 = r[0] * 0.88
        let c1 = c0 + (r[0] + r[1]) * 0.78
        let c2 = c1 + (r[1] + r[2]) * 0.80
        return [CGPoint(x: 0, y: c0), CGPoint(x: 0, y: c1), CGPoint(x: 0, y: c2)]
    }
    var centres: [CGPoint] {
        localCentres.map { p in
            CGPoint(x: x + p.x * cos(tilt) - p.y * sin(tilt), y: y + p.x * sin(tilt) + p.y * cos(tilt))
        }
    }
}

struct P {
    var x: CGFloat, y: CGFloat, vx: CGFloat, vy: CGFloat
    var size: CGFloat
    var rot: CGFloat = 0, vrot: CGFloat = 0
    var phase: CGFloat = rnd(0, .pi * 2)
    var life: CGFloat = 0
    var maxLife: CGFloat = .infinity
    var hue: Int = 0
    var kind: Kind = .main
    var ignoreID: Int = .min
    var ignoreT: CGFloat = 0
}

struct Rest {           // a petal / leaf lying on a surface, relative to the surface
    var dx: CGFloat, dy: CGFloat
    var rot: CGFloat, size: CGFloat, hue: Int
    var age: CGFloat = 0
}

final class Pile {
    static let col: CGFloat = 3
    let id: Int
    var rect: CGRect
    var h: [CGFloat]
    var rest: [Rest] = []
    let isGround: Bool
    var radius: CGFloat
    let seed = rnd(0, 100)
    var capNoise: [CGFloat] = []       // per-column height multiplier, so snow lies unevenly
    var icicles: [Icicle] = []         // icicles growing from this pile's bottom edge

    init(id: Int, rect: CGRect, radius: CGFloat = 0, ground: Bool = false) {
        self.id = id; self.rect = rect; self.isGround = ground; self.radius = radius
        h = Array(repeating: 0, count: max(1, Int(ceil(rect.width / Pile.col))))
        buildNoise()
    }

    /// Layered value noise in roughly [0.55, 1.3] so drifts build to varied heights, not a flat line.
    func buildNoise() {
        capNoise = (0..<h.count).map { i in
            let x = CGFloat(i)
            let v = 0.5
                + 0.26 * sin(x * 0.055 + seed)
                + 0.15 * sin(x * 0.17 + seed * 1.7)
                + 0.09 * sin(x * 0.41 + seed * 2.9)
            return clamp(0.5 + v * 0.62, 0.5, 1.3)
        }
    }

    /// Slow drag: ride the snow along with the window instead of destroying it.
    func carry(to r: CGRect) {
        if max(1, Int(ceil(r.width / Pile.col))) == h.count { rect = r }
        else { reset(r) }   // width changed — can't map columns cleanly
    }

    var slideAcc: CGFloat = 0
    /// Snow inertia: as the window slides under it, the snow stays put in world space,
    /// drifting toward the trailing edge and shedding off it (never glued to the window).
    func slide(windowDX: CGFloat, spill: (CGFloat, CGFloat) -> Void) {
        guard h.count > 1 else { return }
        slideAcc -= windowDX                 // snow holds its world position
        var guardN = 0
        while slideAcc >= Pile.col && guardN < 80 { shiftCells(by: 1, spill: spill); slideAcc -= Pile.col; guardN += 1 }
        while slideAcc <= -Pile.col && guardN < 80 { shiftCells(by: -1, spill: spill); slideAcc += Pile.col; guardN += 1 }
    }
    private func shiftCells(by n: Int, spill: (CGFloat, CGFloat) -> Void) {
        if n >= 1 {
            let off = h[h.count - 1]
            if off > 0.3 { spill(rect.maxX - Pile.col * 0.5, off) }
            for i in stride(from: h.count - 1, to: 0, by: -1) { h[i] = h[i - 1] }
            h[0] = 0
        } else {
            let off = h[0]
            if off > 0.3 { spill(rect.minX + Pile.col * 0.5, off) }
            for i in 0..<(h.count - 1) { h[i] = h[i + 1] }
            h[h.count - 1] = 0
        }
    }

    /// How far the rounded top corner dips below the flat top edge at x.
    @inline(__always) func drop(_ x: CGFloat) -> CGFloat {
        guard radius > 0 else { return 0 }
        let R = min(radius, rect.width / 2)
        let d = min(x - rect.minX, rect.maxX - x)
        if d >= R { return 0 }
        let k = R - max(0, d)
        return R - sqrt(max(0, R * R - k * k))
    }
    /// Top of the shape itself (no pile) at x.
    @inline(__always) func base(_ x: CGFloat) -> CGFloat { rect.maxY - drop(x) }

    func reset(_ r: CGRect) {
        rect = r
        h = Array(repeating: 0, count: max(1, Int(ceil(r.width / Pile.col))))
        rest.removeAll()
        slideAcc = 0
        buildNoise()
    }

    @inline(__always) func index(_ x: CGFloat) -> Int { clamp(Int((x - rect.minX) / Pile.col), 0, h.count - 1) }
    @inline(__always) func height(at x: CGFloat) -> CGFloat { h[index(x)] }

    func cap(_ i: Int, _ maxH: CGFloat) -> CGFloat {
        let noise = capNoise.isEmpty ? 1 : capNoise[min(i, capNoise.count - 1)]
        if isGround { return maxH * noise }
        // Thin out over the curved corners — snow can't stack on a steep slope.
        let d = CGFloat(min(i, h.count - 1 - i)) * Pile.col + Pile.col / 2
        let R = max(radius, 4)
        return maxH * noise * clamp((d - R * 0.35) / (R * 0.9 + 4), 0, 1)
    }

    func addSnow(x: CGFloat, amt: CGFloat, maxH: CGFloat) {
        let i = index(x)
        let w: [CGFloat] = [0.25, 0.6, 1, 0.6, 0.25]
        for k in -2...2 {
            let j = i + k
            guard j >= 0, j < h.count else { continue }
            h[j] = min(cap(j, maxH), h[j] + amt * w[k + 2] * 0.32)
        }
    }

    @discardableResult
    func addRest(x: CGFloat, size: CGFloat, hue: Int, maxH: CGFloat) -> Bool {
        let i = index(x)
        guard h[i] < cap(i, maxH) else { return false }
        rest.append(Rest(dx: x - rect.minX, dy: h[i] + size * 0.15 - drop(x),
                         rot: rnd(-0.6, 0.6) + (Bool.random() ? 0 : .pi), size: size, hue: hue))
        for k in -1...1 {
            let j = i + k
            if j >= 0, j < h.count { h[j] = min(cap(j, maxH), h[j] + size * (k == 0 ? 0.3 : 0.15)) }
        }
        if rest.count > 450 { rest.removeFirst(rest.count - 450) }
        return true
    }

    func relax(threshold: CGFloat = 1.6, strength: CGFloat = 0.3) {
        guard h.count > 1 else { return }
        for i in 1..<h.count {
            let d = h[i] - h[i - 1]
            if abs(d) > threshold {
                let m = (abs(d) - threshold) * strength * (d > 0 ? 1 : -1)
                h[i] -= m; h[i - 1] += m
            }
        }
    }

    func decay(_ amount: CGFloat) {
        for i in h.indices where h[i] > 0 { h[i] = max(0, h[i] - amount) }
    }
}

// MARK: - Simulation (one per screen, local coords, y up)

final class Simulation {
    let frame: CGRect           // screen frame, global
    let bounds: CGRect
    let groundY: CGFloat
    var effect = Settings.effect

    var particles: [P] = []
    var balls: [Ball] = []
    var men: [Snowman] = []
    var heldBall: Ball?
    var heldMan: Snowman?
    var optionDown = false
    var piles: [Int: Pile] = [:]
    var order: [Pile] = []      // front-to-back windows, then ground
    let ground: Pile
    var covered = false

    var time: CGFloat = 0
    var spawnAcc: CGFloat = 0
    var flash: CGFloat = 0
    var nextLightning: CGFloat = rnd(10, 25)
    var dustDir: CGFloat = Bool.random() ? 1 : -1
    var tumbleAcc: CGFloat = 0
    var bolts: [Bolt] = []
    var tornado: Tornado?
    var nextTornado: CGFloat = rnd(5, 10)
    var debrisAcc: CGFloat = 0
    var water: CGFloat = -12
    var ripples: [(x: CGFloat, t: CGFloat)] = []
    var fish: [Fish] = []
    var fishAcc: CGFloat = 0
    var boat: Boat?
    var nextBoat: CGFloat = rnd(5, 14)
    var iceFalls: [IceShard] = []                 // icicles knocked loose and falling
    var lightStrings: [LightString] = []
    var drawingLight: (a: CGPoint, b: CGPoint)?   // a string being drawn with ⌥-drag
    var dragAnchor: (s: Int, a: Int)?             // an existing attach point being moved
    var dragMoved = false
    var secondFlash: CGFloat = -1
    var gen = -1
    var relaxTick = 0

    var mouse = CGPoint(x: -9999, y: -9999)
    var mouseVel = CGVector.zero
    var mouseStill: CGFloat = 0

    init(screen: NSScreen) {
        frame = screen.frame
        bounds = CGRect(origin: .zero, size: frame.size)
        groundY = max(0, screen.visibleFrame.minY - frame.minY)
        ground = Pile(id: .min, rect: CGRect(x: 0, y: groundY - 100_000, width: frame.width, height: 100_000),
                      ground: true)
        order = [ground]
    }

    func clearAll() {
        particles.removeAll()
        balls.removeAll(); men.removeAll()
        heldBall = nil; heldMan = nil; optionDown = false
        for p in piles.values { p.reset(p.rect) }
        ground.reset(ground.rect)
        fish.removeAll(); boat = nil
        water = -12; ripples.removeAll()
        iceFalls.removeAll()
    }

    /// Effects whose fallen material is a smooth heightmap (snow, sand).
    var heaped: Bool { effect == .snow || effect == .dust }
    var rainy: Bool { effect == .rain || effect == .storm || effect == .tornado }
    var windK: CGFloat { CGFloat(Settings.windStrength) }
    /// Horizontal drift per unit of fall speed (tan of the wind angle).
    var slant: CGFloat { tan(CGFloat(clamp(Settings.windAngle, -60, 60)) * .pi / 180) }
    /// Storm conditions boost the wind.
    var stormBoost: CGFloat {
        switch effect {
        case .storm: return 1.8
        case .tornado: return tornado == nil ? 2.4 : 3.4
        default: return 1
        }
    }

    /// Dust storm wind: gusty, mostly horizontal, in one direction per session.
    var dustWind: CGFloat {
        let dir: CGFloat = Settings.windAngle > 2 ? 1 : Settings.windAngle < -2 ? -1 : dustDir
        return dir * max(40, (250 + 190 * sin(time * 0.23) + 90 * sin(time * 0.71 + 1.3) + 40 * sin(time * 2.3))
                             * max(0.25, windK) * (1 + abs(slant) * 0.5))
    }

    var maxH: (window: CGFloat, ground: CGFloat) {
        switch effect {
        case .snow: return (16, 30)
        case .sakura, .leaves: return (12, 22)
        case .dust: return (9, 18)
        case .tornado: return (10, 18)
        default: return (0, 0)
        }
    }

    // MARK: windows

    func syncWindows() {
        let t = WindowTracker.shared
        guard t.generation != gen else { return }
        gen = t.generation
        let dt = t.pollDT
        var seen = Set<Int>()
        var newOrder: [Pile] = []
        covered = false
        for w in t.windows {
            let r = w.rect.offsetBy(dx: -frame.minX, dy: -frame.minY)
            guard r.intersects(bounds) else { continue }
            if r.insetBy(dx: -2, dy: -2).contains(bounds) { covered = true }
            seen.insert(w.id)
            if let p = piles[w.id] {
                p.radius = w.radius
                let dx = r.minX - p.rect.minX, dy = r.maxY - p.rect.maxY, dw = r.width - p.rect.width
                if abs(dx) > 0.5 || abs(dy) > 0.5 || abs(dw) > 0.5 {
                    breakIcicles(p, vx: dx / dt, vy: dy / dt)   // moving the tab knocks its icicles off
                    p.reset(r)          // keep geometry fresh first …
                    spill(p, from: r, vx: dx / dt, vy: dy / dt, old: true)
                    carryBodies(w.id, dx: dx, dy: dy, vx: dx / dt, vy: dy / dt)
                }
                newOrder.append(p)
            } else {
                let p = Pile(id: w.id, rect: r, radius: w.radius)
                piles[w.id] = p
                newOrder.append(p)
            }
        }
        for (id, p) in piles where !seen.contains(id) {
            spill(p, from: p.rect, vx: 0, vy: 0, old: false)
            carryBodies(id, dx: 0, dy: 0, vx: 0, vy: 1, release: true)
            piles[id] = nil
        }
        newOrder.append(ground)
        order = newOrder
    }

    // Saved contents of a pile before reset, so spill can read them.
    private var pendingH: [Int: ([CGFloat], [Rest])] = [:]

    func spill(_ p: Pile, from r: CGRect, vx: CGFloat, vy: CGFloat, old: Bool) {
        // When called after reset (old == true) we read the snapshot taken in snapshot().
        let (hs, rests) = old ? (pendingH[p.id] ?? ([], [])) : (p.h, p.rest)
        pendingH[p.id] = nil
        let fvx = clamp(vx, -2500, 2500), fvy = clamp(vy, -2500, 2500)
        var budget = 700
        if heaped {
            for (i, hh) in hs.enumerated() where hh > 0.6 && budget > 0 {
                let n = min(budget, Int(hh / 3) + 1)
                budget -= n
                for _ in 0..<n {
                    var q = P(x: r.minX + CGFloat(i) * Pile.col + rnd(0, 3), y: r.maxY + rnd(0, hh),
                              vx: fvx * 0.85 + rnd(-40, 40), vy: fvy * 0.85 + rnd(10, 90),
                              size: effect == .dust ? rnd(0.8, 1.8) : rnd(1.4, 3))
                    q.ignoreID = p.id; q.ignoreT = 0.25
                    particles.append(q)
                }
            }
        }
        for s in rests {
            var q = P(x: r.minX + s.dx, y: r.maxY + s.dy + 2,
                      vx: fvx * 0.85 + rnd(-50, 50), vy: fvy * 0.85 + rnd(20, 120), size: s.size)
            q.rot = s.rot; q.vrot = rnd(-4, 4); q.hue = s.hue
            q.ignoreID = p.id; q.ignoreT = 0.25
            particles.append(q)
        }
    }

    func snapshotBeforeMove() {
        // Capture pile contents for windows that are about to be reset.
        let t = WindowTracker.shared
        guard t.generation != gen else { return }
        for w in t.windows {
            guard let p = piles[w.id] else { continue }
            let r = w.rect.offsetBy(dx: -frame.minX, dy: -frame.minY)
            if abs(r.minX - p.rect.minX) > 0.5 || abs(r.maxY - p.rect.maxY) > 0.5 || abs(r.width - p.rect.width) > 0.5 {
                pendingH[p.id] = (p.h, p.rest)
            }
        }
    }

    // MARK: collision

    enum Hit { case none, landed(Pile, CGFloat), removed }

    func collide(_ p: inout P, _ px: CGFloat, _ py: CGFloat) -> Hit {
        for pile in order {
            let r = pile.rect
            if p.x < r.minX || p.x >= r.maxX { continue }
            let base = pile.base(p.x)
            let surf = base + pile.height(at: p.x)
            if p.y >= surf || p.y <= r.minY { continue }
            if p.ignoreT > 0 && p.ignoreID == pile.id { continue }
            // came down onto the surface (including the curved corners)
            if py >= base - 0.5 {
                if effect == .fireflies && p.kind == .main {
                    p.y = surf + 0.5; p.vy = abs(p.vy) * 0.6
                    return .none
                }
                return .landed(pile, surf)
            }
            if px < r.minX { p.x = r.minX - 0.5; p.vx = -abs(p.vx) * 0.3; return .none }
            if px >= r.maxX { p.x = r.maxX + 0.5; p.vx = abs(p.vx) * 0.3; return .none }
            if py <= r.minY { p.y = r.minY - 0.5; p.vy = -abs(p.vy) * 0.3; return .none }
            return .removed      // a window appeared on top of it — it's hidden, drop it
        }
        return .none
    }

    func isFree(_ pt: CGPoint) -> Bool {
        if pt.y <= groundY + 4 { return false }
        for pile in order where !pile.isGround {
            if pile.rect.insetBy(dx: -6, dy: -6).contains(pt) { return false }
        }
        return true
    }

    // MARK: step

    func step(_ dt: CGFloat) {
        if effect != Settings.effect { effect = Settings.effect; clearAll() }
        WindowTracker.shared.refreshIfNeeded()
        snapshotBeforeMove()
        syncWindows()
        if covered { return }
        time += dt

        // pointer
        let gm = NSEvent.mouseLocation
        let m = CGPoint(x: gm.x - frame.minX, y: gm.y - frame.minY)
        if mouse.x > -9000 {
            let v = CGVector(dx: (m.x - mouse.x) / dt, dy: (m.y - mouse.y) / dt)
            mouseVel = CGVector(dx: mouseVel.dx * 0.6 + v.dx * 0.4, dy: mouseVel.dy * 0.6 + v.dy * 0.4)
        }
        mouse = m
        let mSpeed = hypot(mouseVel.dx, mouseVel.dy)
        mouseStill = mSpeed < 20 ? mouseStill + dt : 0

        spawn(dt)
        if mSpeed > 220 && bounds.insetBy(dx: -40, dy: -40).contains(mouse) { brushPiles() }

        // lightning
        if rainy {
            nextLightning -= dt
            if nextLightning <= 0 {
                flash = 1; secondFlash = 0.18
                switch effect {
                case .storm: nextLightning = rnd(2.5, 9); strikeBolt()
                case .tornado: nextLightning = rnd(6, 16); strikeBolt()
                default: nextLightning = rnd(18, 45)
                }
            }
            if secondFlash > 0 { secondFlash -= dt; if secondFlash <= 0 { flash = 0.8 } }
        }
        flash = max(0, flash - dt * 3.2)
        for i in bolts.indices { bolts[i].life += dt }
        bolts.removeAll { $0.life > 0.45 }
        if effect == .tornado { stepTornado(dt) } else { tornado = nil }
        stepWater(dt)

        let wind = (sin(time * 0.13) * 22 + sin(time * 0.41) * 10 + sin(time * 1.7) * 6 * windK) * windK * stormBoost
        let sl = slant
        let mh = maxH
        var out: [P] = []
        out.reserveCapacity(particles.count)

        for var p in particles {
            p.life += dt
            if p.ignoreT > 0 { p.ignoreT -= dt }
            let px = p.x, py = p.y

            switch (effect, p.kind) {
            case (_, .splash):
                p.vy -= 900 * dt
            case (_, .debris):
                p.vy -= 700 * dt; p.rot += p.vrot * dt
            case (_, .runoff):
                p.vy -= 1350 * dt                            // falls fast once off the edge
                p.vx += (abs(p.vy) * slant - p.vx) * dt * 2   // leans with the wind angle
            case (_, .spark):
                p.vy -= 320 * dt; p.vx *= 1 - 0.8 * dt
            case (.snow, _):
                let tx = wind + sin(time * 1.3 + p.phase) * 16 * max(0.3, windK) + abs(p.vy) * sl
                p.vx += (tx - p.vx) * dt * 1.4
                let tv = -(p.size * 18 + 22)
                p.vy += (tv - p.vy) * dt * 2
            case (.rain, _), (.storm, _), (.tornado, _):
                if p.hue >= 20 {    // flying leaves, twigs and paper
                    let tx = wind * 4 + abs(p.vy) * sl + sin(time * 1.4 + p.phase) * 90
                    p.vx += (tx - p.vx) * dt * 1.3
                    let tv = -95 + sin(time * 2.2 + p.phase) * 70
                    p.vy += (tv - p.vy) * dt * 1.2
                    p.rot += p.vrot * dt
                } else {
                    p.vx += (wind * 3 + abs(p.vy) * sl - p.vx) * dt * 2
                }
            case (.sakura, _):
                let tx = wind * 1.6 + sin(time * 1.1 + p.phase) * 42 + abs(p.vy) * sl
                p.vx += (tx - p.vx) * dt * 1.2
                let tv = -42 + sin(time * 2.1 + p.phase) * 16
                p.vy += (tv - p.vy) * dt * 1.5
                p.rot += p.vrot * dt
            case (.leaves, _):
                let tx = wind * 2 + sin(time * 0.9 + p.phase) * 55 + abs(p.vy) * sl
                p.vx += (tx - p.vx) * dt * 1.0
                let tv = -62 + sin(time * 1.7 + p.phase) * 22
                p.vy += (tv - p.vy) * dt * 1.3
                p.rot += p.vrot * dt
            case (.fireflies, _):
                p.vx += (cos(time * 0.6 + p.phase * 3) * 30 + rnd(-25, 25)) * dt
                p.vy += (sin(time * 0.5 + p.phase * 2) * 30 + rnd(-25, 25)) * dt
                if mouseStill > 0.6 {
                    let a = time * 0.8 + p.phase
                    let tx = mouse.x + cos(a) * (24 + p.size * 10), ty = mouse.y + sin(a) * (24 + p.size * 10)
                    let dx = tx - p.x, dy = ty - p.y
                    let d = max(1, hypot(dx, dy))
                    if d < 700 { p.vx += dx / d * 70 * dt; p.vy += dy / d * 70 * dt }
                }
                p.vx *= 1 - 0.6 * dt; p.vy *= 1 - 0.6 * dt
                let s = hypot(p.vx, p.vy); if s > 70 { p.vx *= 70 / s; p.vy *= 70 / s }
                if p.y > bounds.maxY - 40 { p.vy -= 40 * dt }
            case (.starfall, _):
                break
            case (.dust, _):
                if p.hue == 9 {     // tumbleweed: rolls and bounces downwind
                    p.vx += (dustWind * 0.75 - p.vx) * dt * 0.9
                    p.vy -= 520 * dt
                    p.rot -= p.vx / max(6, p.size) * dt
                } else {
                    let w = dustWind * (0.75 + 0.5 * sin(p.phase * 7))
                    p.vx += (w - p.vx) * dt * 2.2
                    let tv = -28 + sin(time * 3.1 + p.phase * 5) * 60
                    p.vy += (tv - p.vy) * dt * 1.8
                }
            }

            // pointer wake for light falling things
            if p.kind == .main, effect == .snow || effect == .sakura || effect == .leaves, mSpeed > 150 {
                let dx = p.x - mouse.x, dy = p.y - mouse.y
                let d2 = dx * dx + dy * dy
                if d2 < 90 * 90 {
                    let f = (1 - sqrt(d2) / 90) * 5 * dt
                    p.vx += mouseVel.dx * f; p.vy += mouseVel.dy * f
                    p.vrot += rnd(-6, 6) * f
                }
            }

            if let tw = tornado, p.kind == .main { tw.pull(&p, dt: dt, time: time) }

            p.x += p.vx * dt
            p.y += p.vy * dt

            if p.life > p.maxLife { continue }
            // off-screen: drop it unless the wind is still carrying it in
            if p.y < -80 || p.y > bounds.maxY + 600 { continue }
            if (p.x < -80 && p.vx <= 4) || (p.x > bounds.maxX + 80 && p.vx >= -4)
                || p.x < -bounds.width || p.x > bounds.maxX + bounds.width { continue }

            if water > 0 && handleWater(&p, py: py, into: &out) { continue }

            switch collide(&p, px, py) {
            case .none:
                out.append(p)
            case .removed:
                continue
            case .landed(let pile, let surf):
                land(p, pile: pile, surf: surf, mh: mh, into: &out)
            }
        }
        particles = out

        if effect == .snow { stepBodies(dt) }

        // piles: settle, melt, age
        relaxTick += 1
        stepLights(dt)
        stepIcicles(dt)
        let doRelax = relaxTick % 4 == 0
        for pile in order {
            if heaped {
                // Gentler smoothing on the ground so snow keeps its uneven drifts.
                if doRelax { pile.relax(threshold: pile.isGround ? 2.4 : 1.6, strength: pile.isGround ? 0.16 : 0.3) }
                pile.decay((effect == .dust ? 0.06 : 0.035) * dt)
            } else if !pile.rest.isEmpty {
                pile.decay(0.07 * dt)
                for i in pile.rest.indices { pile.rest[i].age += dt }
                pile.rest.removeAll { $0.age > 150 }
            }
        }
    }

    func land(_ p: P, pile: Pile, surf: CGFloat, mh: (window: CGFloat, ground: CGFloat), into out: inout [P]) {
        if p.kind == .debris {         // hats, carrots and sticks come to rest on the snow
            var q = p; q.y = surf + 1; q.vx = 0; q.vy = 0; q.vrot = 0
            out.append(q); return
        }
        if p.kind == .runoff {         // water running off an item: slide to the edge, then fall
            if pile.isGround {
                out.append(P(x: p.x, y: surf + 1, vx: rnd(-40, 40), vy: rnd(30, 90),
                             size: rnd(0.7, 1.1), maxLife: 0.3, kind: .splash))
            } else {
                let left = (p.x - pile.rect.minX) < (pile.rect.maxX - p.x)
                var q = p
                q.x = left ? pile.rect.minX - 1 : pile.rect.maxX + 1
                q.y = surf; q.vx = left ? -18 : 18; q.vy = 0
                q.ignoreID = pile.id; q.ignoreT = 0.25
                out.append(q)
            }
            return
        }
        guard p.kind == .main else { return }
        let maxH = pile.isGround ? mh.ground : mh.window
        switch effect {
        case .snow:
            pile.addSnow(x: p.x, amt: p.size, maxH: maxH)
        case .dust:
            if p.hue == 9 {     // tumbleweed bounces along
                var q = p; q.y = surf + 1
                q.vy = max(90, abs(p.vy) * 0.5) + rnd(0, 140)
                q.ignoreID = pile.id; q.ignoreT = 0.05
                out.append(q)
            } else {
                pile.addSnow(x: p.x, amt: p.size * 0.55, maxH: maxH)
            }
        case .sakura, .leaves:
            if !pile.addRest(x: p.x, size: p.size, hue: p.hue, maxH: maxH) {
                // surface is full here: tumble off
                var q = p; q.y = surf + 1; q.vy = 20; q.vx += Bool.random() ? 60 : -60
                q.ignoreID = pile.id; q.ignoreT = 0.15
                out.append(q)
            }
        case .rain, .storm, .tornado:
            if p.hue >= 20 {
                if effect == .tornado, !pile.addRest(x: p.x, size: p.size, hue: p.hue, maxH: maxH) {
                    var q = p; q.y = surf + 1; q.vy = 40; q.ignoreID = pile.id; q.ignoreT = 0.15
                    out.append(q)
                }
                return
            }
            // a splash where it hits …
            for _ in 0..<Int.random(in: 1...2) {
                out.append(P(x: p.x, y: surf + 1, vx: rnd(-70, 70), vy: rnd(60, 150), size: rnd(0.8, 1.4),
                             maxLife: 0.45, kind: .splash))
            }
            // … and on a window, some of it runs off the edge and trickles down to the bottom
            if !pile.isGround && CGFloat.random(in: 0...1) < 0.5 {
                let left = (p.x - pile.rect.minX) < (pile.rect.maxX - p.x)
                var q = P(x: left ? pile.rect.minX - 1 : pile.rect.maxX + 1, y: surf,
                          vx: left ? -16 : 16, vy: 0, size: rnd(1.6, 2.6), kind: .runoff)
                q.ignoreID = pile.id; q.ignoreT = 0.2
                out.append(q)
            }
        case .starfall:
            for _ in 0..<Int.random(in: 10...18) {
                let a = rnd(0.15, .pi - 0.15), s = rnd(60, 260)
                out.append(P(x: p.x, y: surf + 1, vx: cos(a) * s + p.vx * 0.15, vy: sin(a) * s,
                             size: rnd(0.8, 1.8), maxLife: rnd(0.5, 1.2), hue: Int.random(in: 0...2), kind: .spark))
            }
        case .fireflies:
            break
        }
    }

    func brushPiles() {
        for pile in order {
            let r = pile.rect
            guard mouse.x > r.minX - 10, mouse.x < r.maxX + 10,
                  mouse.y > r.maxY - 8, mouse.y < r.maxY + 40 else { continue }
            if heaped {
                let c = pile.index(mouse.x)
                for j in max(0, c - 6)...min(pile.h.count - 1, c + 6) where pile.h[j] > 1 {
                    let take = pile.h[j] * 0.7
                    pile.h[j] -= take
                    for _ in 0..<(Int(take / 2.5) + 1) {
                        var q = P(x: r.minX + CGFloat(j) * Pile.col, y: r.maxY + rnd(0, take),
                                  vx: mouseVel.dx * 0.5 + rnd(-40, 40), vy: abs(mouseVel.dy) * 0.3 + rnd(40, 140),
                                  size: rnd(1.4, 3))
                        q.ignoreID = pile.id; q.ignoreT = 0.2
                        particles.append(q)
                    }
                }
            } else if !pile.rest.isEmpty {
                pile.rest.removeAll { s in
                    let x = r.minX + s.dx, y = r.maxY + s.dy
                    guard hypot(x - mouse.x, y - mouse.y) < 46 else { return false }
                    var q = P(x: x, y: y + 2, vx: mouseVel.dx * 0.6 + rnd(-40, 40),
                              vy: abs(mouseVel.dy) * 0.3 + rnd(60, 180), size: s.size)
                    q.rot = s.rot; q.vrot = rnd(-8, 8); q.hue = s.hue
                    q.ignoreID = pile.id; q.ignoreT = 0.2
                    particles.append(q)
                    let i = pile.index(x)
                    pile.h[i] = max(0, pile.h[i] - s.size * 0.3)
                    return true
                }
            }
        }
    }

    func spawn(_ dt: CGFloat) {
        let lp: CGFloat = ProcessInfo.processInfo.isLowPowerModeEnabled ? 0.5 : 1
        let k = CGFloat(Settings.intensity) * lp * bounds.width / 1000
        let top = bounds.maxY + 8
        guard particles.count < 4000 else { return }

        if effect == .fireflies {
            let target = Int(28 * k)
            var tries = 0
            var live = particles.reduce(0) { $0 + ($1.kind == .main ? 1 : 0) }
            while live < target && tries < 20 {
                tries += 1
                let pt = CGPoint(x: rnd(0, bounds.width), y: rnd(groundY + 10, bounds.maxY - 30))
                if isFree(pt) {
                    particles.append(P(x: pt.x, y: pt.y, vx: rnd(-20, 20), vy: rnd(-20, 20), size: rnd(0.9, 1.8)))
                    live += 1
                }
            }
            return
        }

        let rate: CGFloat
        switch effect {
        case .snow: rate = 42 * k
        case .rain: rate = 240 * k
        case .storm: rate = 420 * k
        case .tornado: rate = 380 * k
        case .sakura: rate = 9 * k
        case .leaves: rate = 5 * k
        case .starfall: rate = max(0.25, 0.45 * k)
        case .fireflies: rate = 0
        case .dust: rate = 260 * k
        }
        spawnAcc += rate * dt
        while spawnAcc >= 1 {
            spawnAcc -= 1
            // with a slanted wind, spawn far enough upwind to cover the screen
            let reach = slant * bounds.height
            let x = rnd(min(-0.1 * bounds.width, -0.1 * bounds.width - reach),
                        max(1.1 * bounds.width, 1.1 * bounds.width - reach))
            switch effect {
            case .snow:
                let s = rnd(1.2, 3.6)
                let vy = -(s * 18 + 22)
                let drift = abs(vy) * slant                 // match the wind so flakes don't curl in late
                if abs(slant) > 0.12 && CGFloat.random(in: 0...1) < min(0.6, abs(slant) * 0.55) {
                    // seed from the upwind side too, so a cross-wind leaves no bare triangles at the edges
                    let fromLeft = slant > 0
                    particles.append(P(x: fromLeft ? -6 : bounds.width + 6, y: rnd(groundY, top),
                                       vx: drift, vy: vy, size: s))
                } else {
                    particles.append(P(x: x, y: top, vx: drift, vy: vy, size: s))
                }
            case .rain, .storm, .tornado:
                let heavy: CGFloat = effect == .rain ? 1 : 1.15
                let vy = -rnd(720, 950) * heavy
                particles.append(P(x: x, y: top + rnd(0, 40), vx: abs(vy) * slant, vy: vy, size: rnd(10, 18) * heavy))
            case .sakura:
                var p = P(x: x, y: top, vx: 0, vy: -40, size: rnd(3.5, 6.5), hue: Int.random(in: 0...2))
                p.rot = rnd(0, .pi * 2); p.vrot = rnd(-2.5, 2.5)
                particles.append(p)
            case .leaves:
                var p = P(x: x, y: top, vx: 0, vy: -60, size: rnd(6, 10), hue: Int.random(in: 0...4))
                p.rot = rnd(0, .pi * 2); p.vrot = rnd(-3, 3)
                particles.append(p)
            case .starfall:
                let dir: CGFloat = Bool.random() ? -1 : 1
                let sx = dir < 0 ? rnd(0.3, 1.25) * bounds.width : rnd(-0.25, 0.7) * bounds.width
                particles.append(P(x: sx, y: top + 20, vx: dir * rnd(260, 460), vy: -rnd(320, 540), size: rnd(1.6, 2.4)))
            case .fireflies:
                break
            case .dust:
                // blown in from the upwind edge, plus some from above
                let fromSide = Bool.random() || Bool.random()
                let sx = fromSide ? (dustDir > 0 ? -8 : bounds.maxX + 8) : x
                let sy = fromSide ? rnd(groundY, bounds.maxY) : top
                particles.append(P(x: sx, y: sy, vx: dustWind * rnd(0.6, 1.1), vy: rnd(-40, 20), size: rnd(0.7, 2.2),
                                   hue: Int.random(in: 0...3)))
            }
        }
        if effect == .tornado {    // wind-blown debris from the upwind side
            let dir: CGFloat = (Settings.windAngle >= 0) ? 1 : -1
            debrisAcc += dt * 9 * k * (tornado == nil ? 1 : 2.8)
            while debrisAcc >= 1 {
                debrisAcc -= 1
                var p = P(x: dir > 0 ? rnd(-40, -10) : bounds.maxX + rnd(10, 40), y: rnd(groundY + 20, bounds.maxY),
                          vx: dir * rnd(150, 350), vy: rnd(-40, 60), size: rnd(5, 9), hue: randomDebrisHue())
                p.rot = rnd(0, .pi * 2); p.vrot = rnd(-8, 8)
                particles.append(p)
            }
        }
        if effect == .dust {
            tumbleAcc += dt * 0.09 * CGFloat(Settings.intensity)
            if tumbleAcc >= 1 {
                tumbleAcc = 0
                var p = P(x: dustDir > 0 ? -30 : bounds.maxX + 30, y: rnd(groundY + 60, bounds.maxY * 0.75),
                          vx: dustWind * 0.6, vy: 0, size: rnd(12, 22), hue: 9)
                p.phase = rnd(0, 100)
                particles.append(p)
            }
        }
    }

    // MARK: drawing

    static let petal: [CGColor] = [
        CGColor(red: 1.0, green: 0.80, blue: 0.86, alpha: 1),
        CGColor(red: 0.98, green: 0.70, blue: 0.79, alpha: 1),
        CGColor(red: 1.0, green: 0.90, blue: 0.93, alpha: 1),
    ]
    static let leaf: [CGColor] = [
        CGColor(red: 0.86, green: 0.36, blue: 0.12, alpha: 1),
        CGColor(red: 0.94, green: 0.56, blue: 0.16, alpha: 1),
        CGColor(red: 0.74, green: 0.20, blue: 0.10, alpha: 1),
        CGColor(red: 0.95, green: 0.76, blue: 0.27, alpha: 1),
        CGColor(red: 0.55, green: 0.30, blue: 0.12, alpha: 1),
    ]
    static let greenLeaf: [CGColor] = [
        CGColor(red: 0.30, green: 0.62, blue: 0.22, alpha: 1),
        CGColor(red: 0.42, green: 0.72, blue: 0.28, alpha: 1),
        CGColor(red: 0.22, green: 0.50, blue: 0.20, alpha: 1),
        CGColor(red: 0.55, green: 0.78, blue: 0.33, alpha: 1),
    ]
    static let spark: [CGColor] = [
        CGColor(red: 1, green: 0.95, blue: 0.8, alpha: 1),
        CGColor(red: 1, green: 0.75, blue: 0.4, alpha: 1),
        CGColor(red: 0.75, green: 0.85, blue: 1, alpha: 1),
    ]
    static let glow: CGGradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [CGColor(red: 1, green: 0.93, blue: 0.55, alpha: 0.85),
                 CGColor(red: 0.85, green: 1, blue: 0.4, alpha: 0.25),
                 CGColor(red: 0.8, green: 1, blue: 0.3, alpha: 0)] as CFArray,
        locations: [0, 0.3, 1])!

    func drawPetal(_ c: CGContext, _ x: CGFloat, _ y: CGFloat, _ s: CGFloat, _ rot: CGFloat,
                   _ flip: CGFloat, _ hue: Int, _ a: CGFloat) {
        c.saveGState()
        c.translateBy(x: x, y: y); c.rotate(by: rot); c.scaleBy(x: 1, y: flip)
        c.setAlpha(a)
        c.setFillColor(Simulation.petal[hue % 3])
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -s, y: 0))
        path.addCurve(to: CGPoint(x: s, y: s * 0.18), control1: CGPoint(x: -s * 0.6, y: s * 0.9),
                      control2: CGPoint(x: s * 0.5, y: s * 0.8))
        path.addLine(to: CGPoint(x: s * 0.7, y: 0))
        path.addLine(to: CGPoint(x: s, y: -s * 0.18))
        path.addCurve(to: CGPoint(x: -s, y: 0), control1: CGPoint(x: s * 0.5, y: -s * 0.8),
                      control2: CGPoint(x: -s * 0.6, y: -s * 0.9))
        c.addPath(path); c.fillPath()
        c.restoreGState()
    }

    func drawLeaf(_ c: CGContext, _ x: CGFloat, _ y: CGFloat, _ s: CGFloat, _ rot: CGFloat,
                  _ flip: CGFloat, _ hue: Int, _ a: CGFloat, green: Bool = false) {
        c.saveGState()
        c.translateBy(x: x, y: y); c.rotate(by: rot); c.scaleBy(x: 1, y: flip)
        c.setAlpha(a)
        let col = green ? Simulation.greenLeaf[hue % 4] : Simulation.leaf[hue % 5]
        c.setFillColor(col)
        c.move(to: CGPoint(x: -s, y: 0))
        c.addQuadCurve(to: CGPoint(x: s, y: 0), control: CGPoint(x: -s * 0.1, y: s * 0.75))
        c.addQuadCurve(to: CGPoint(x: -s, y: 0), control: CGPoint(x: -s * 0.1, y: -s * 0.75))
        c.fillPath()
        c.setStrokeColor(CGColor(red: 0.35, green: 0.16, blue: 0.06, alpha: 0.55))
        c.setLineWidth(0.8)
        c.move(to: CGPoint(x: -s * 1.35, y: -s * 0.05)); c.addLine(to: CGPoint(x: s * 0.8, y: 0))
        c.strokePath()
        c.restoreGState()
    }

    func drawTumbleweed(_ c: CGContext, _ p: P) {
        let r = p.size
        c.saveGState()
        c.translateBy(x: p.x, y: p.y + r)      // p.y is the contact point
        c.rotate(by: p.rot)
        c.setShadow(offset: CGSize(width: 0, height: -2), blur: 4, color: CGColor(red: 0.2, green: 0.12, blue: 0.05, alpha: 0.35))
        c.setStrokeColor(CGColor(red: 0.58, green: 0.42, blue: 0.24, alpha: 0.95))
        c.setLineWidth(1.3)
        for k in 0..<9 {                         // tangled loops
            let a = CGFloat(k) * 0.7 + p.phase
            let rx = r * (0.55 + 0.4 * abs(sin(a * 1.7))), ry = r * (0.35 + 0.5 * abs(cos(a * 1.3)))
            c.saveGState(); c.rotate(by: a)
            c.strokeEllipse(in: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2))
            c.restoreGState()
        }
        c.setStrokeColor(CGColor(red: 0.42, green: 0.29, blue: 0.15, alpha: 0.9))
        c.setLineWidth(0.9)
        for k in 0..<6 {
            let a = CGFloat(k) * 1.05 + p.phase * 0.3
            c.move(to: CGPoint(x: cos(a) * r * 0.2, y: sin(a) * r * 0.2))
            c.addLine(to: CGPoint(x: cos(a + 0.4) * r * 0.95, y: sin(a + 0.4) * r * 0.95))
        }
        c.strokePath()
        c.restoreGState()
    }

    func draw(_ c: CGContext) {
        guard !covered else { return }

        if flash > 0 {
            c.setFillColor(CGColor(red: 0.85, green: 0.9, blue: 1, alpha: flash * 0.22))
            c.fill(bounds)
        }
        if effect == .dust {    // sandy haze behind the windows, thicker in gusts
            let g = clamp(abs(dustWind) / 560, 0, 1)
            c.setFillColor(CGColor(red: 0.74, green: 0.55, blue: 0.33, alpha: 0.07 + 0.13 * g))
            c.fill(bounds)
        }

        if effect == .storm || effect == .tornado {   // dark storm light behind the windows
            let a: CGFloat = effect == .storm ? 0.12 : (tornado == nil ? 0.14 : 0.22)
            c.setFillColor(CGColor(red: 0.16, green: 0.19, blue: 0.24, alpha: a))
            c.fill(bounds)
        }
        drawBolts(c)
        if let tw = tornado { tw.draw(c, time: time) }

        // piles
        for pile in order {
            let r = pile.rect
            if heaped {
                guard pile.h.contains(where: { $0 > 0.3 }) else { continue }
                let x0 = max(r.minX, -10), x1 = min(r.maxX, bounds.maxX + 10)
                let i0 = pile.index(x0), i1 = pile.index(x1)

                // Smooth the heightmap for drawing so the surface reads as soft drifts, not steps.
                var s = Array(pile.h[i0...i1])
                if s.count > 2 {
                    for _ in 0..<3 {
                        var t = s
                        for i in s.indices {
                            let a = s[max(0, i - 2)], b = s[max(0, i - 1)], d = s[min(s.count - 1, i + 1)],
                                e = s[min(s.count - 1, i + 2)]
                            t[i] = (a + 2 * b + 3 * s[i] + 2 * d + e) / 9
                        }
                        s = t
                    }
                }
                let pts: [CGPoint] = s.indices.map { k in
                    let x = r.minX + (CGFloat(i0 + k) + 0.5) * Pile.col
                    return CGPoint(x: x, y: pile.base(x) + s[k])
                }

                let path = CGMutablePath()
                path.move(to: CGPoint(x: x0, y: pile.base(x0)))
                if let first = pts.first { path.addLine(to: first) }
                // Quadratic curves through midpoints → smooth, rounded surface.
                if pts.count > 2 {
                    for k in 1..<(pts.count - 1) {
                        let mid = CGPoint(x: (pts[k].x + pts[k + 1].x) / 2, y: (pts[k].y + pts[k + 1].y) / 2)
                        path.addQuadCurve(to: mid, control: pts[k])
                    }
                }
                if let lastP = pts.last { path.addLine(to: lastP) }
                path.addLine(to: CGPoint(x: x1, y: pile.base(x1)))
                for k in stride(from: pts.count - 1, through: 0, by: -1) {   // back along the shape's curved top
                    path.addLine(to: CGPoint(x: pts[k].x, y: pile.base(pts[k].x)))
                }
                path.closeSubpath()

                let peak = s.max() ?? 0
                c.saveGState()
                // 1) soft glow so the top edge feathers into the background
                let sand = effect == .dust
                c.setShadow(offset: .zero, blur: sand ? 4 : 6,
                            color: sand ? CGColor(red: 0.85, green: 0.66, blue: 0.42, alpha: 0.5)
                                        : CGColor(red: 0.92, green: 0.95, blue: 1, alpha: 0.75))
                c.setFillColor(sand ? CGColor(red: 0.84, green: 0.68, blue: 0.47, alpha: 0.95)
                                    : CGColor(red: 0.95, green: 0.97, blue: 1, alpha: 0.9))
                c.addPath(path); c.fillPath()
                c.restoreGState()
                // 2) gentle top-to-bottom shading: bright crust, cool blue-grey underneath
                c.saveGState()
                c.addPath(path); c.clip()
                let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                   colors: sand
                                    ? [CGColor(red: 0.93, green: 0.80, blue: 0.60, alpha: 0.97),
                                       CGColor(red: 0.82, green: 0.65, blue: 0.44, alpha: 0.96),
                                       CGColor(red: 0.62, green: 0.45, blue: 0.28, alpha: 0.94)] as CFArray
                                    : [CGColor(red: 1, green: 1, blue: 1, alpha: 0.97),
                                       CGColor(red: 0.93, green: 0.95, blue: 0.99, alpha: 0.95),
                                       CGColor(red: 0.80, green: 0.86, blue: 0.95, alpha: 0.92)] as CFArray,
                                   locations: [0, 0.45, 1])!
                c.drawLinearGradient(g, start: CGPoint(x: 0, y: r.maxY + peak), end: CGPoint(x: 0, y: r.maxY - 2),
                                     options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                c.restoreGState()
            } else if effect == .sakura || effect == .leaves || effect == .tornado {
                for s in pile.rest {
                    let a = s.age > 145 ? max(0, (150 - s.age) / 5) : 1
                    let x = r.minX + s.dx, y = r.maxY + s.dy
                    if effect == .sakura { drawPetal(c, x, y, s.size, s.rot, 0.55, s.hue, a * 0.95) }
                    else if effect == .tornado { drawStormDebris(c, x, y, s.size, s.rot * 0.25, 0.6, s.hue, a) }
                    else { drawLeaf(c, x, y, s.size, s.rot * 0.25, 0.6, s.hue, a) }
                }
            }
        }

        drawIcicles(c)
        if effect == .snow { drawBodies(c) }
        drawWater(c)
        drawBoat(c)
        drawLights(c)      // behind every window, so the strings never cover window content

        // particles
        switch effect {
        case .snow:
            let path = CGMutablePath()
            for p in particles where p.kind != .debris {
                path.addEllipse(in: CGRect(x: p.x - p.size / 2, y: p.y - p.size / 2, width: p.size, height: p.size))
            }
            c.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
            c.addPath(path); c.fillPath()
            for p in particles where p.kind == .debris { drawDebris(c, p) }
        case .rain, .storm, .tornado:
            let path = CGMutablePath(), sp = CGMutablePath()
            for p in particles where p.hue >= 20 { drawStormDebris(c, p.x, p.y, p.size, p.rot, sin(time * 3 + p.phase), p.hue, 1) }
            for p in particles where p.hue < 20 {
                if p.kind == .spark {        // lightning impact
                    let a = max(0, 1 - p.life / p.maxLife)
                    c.setFillColor(Simulation.spark[2].copy(alpha: a)!)
                    c.fillEllipse(in: CGRect(x: p.x - p.size, y: p.y - p.size, width: p.size * 2, height: p.size * 2))
                } else if p.kind == .splash {
                    sp.addEllipse(in: CGRect(x: p.x - p.size, y: p.y - p.size, width: p.size * 2, height: p.size * 2))
                } else if p.kind == .runoff {   // a rounded droplet trickling down
                    sp.addEllipse(in: CGRect(x: p.x - p.size * 0.6, y: p.y - p.size, width: p.size * 1.2, height: p.size * 2))
                } else {
                    let sp = max(1, hypot(p.vx, p.vy))
                    path.move(to: CGPoint(x: p.x, y: p.y))
                    path.addLine(to: CGPoint(x: p.x - p.vx / sp * p.size, y: p.y - p.vy / sp * p.size))
                }
            }
            c.setStrokeColor(CGColor(red: 0.78, green: 0.86, blue: 1, alpha: 0.55))
            c.setLineWidth(1.1); c.setLineCap(.round)
            c.addPath(path); c.strokePath()
            c.setFillColor(CGColor(red: 0.85, green: 0.92, blue: 1, alpha: 0.6))
            c.addPath(sp); c.fillPath()
        case .sakura:
            for p in particles { drawPetal(c, p.x, p.y, p.size, p.rot, sin(time * 3 + p.phase), p.hue, 0.95) }
        case .leaves:
            for p in particles { drawLeaf(c, p.x, p.y, p.size, p.rot, sin(time * 2.4 + p.phase), p.hue, 1) }
        case .fireflies:
            for p in particles {
                let b = pow(0.5 + 0.5 * sin(time * 1.7 + p.phase * 5), 2.2)
                let rad = p.size * 5
                c.saveGState()
                c.setAlpha(0.15 + 0.85 * b)
                c.drawRadialGradient(Simulation.glow, startCenter: CGPoint(x: p.x, y: p.y), startRadius: 0,
                                     endCenter: CGPoint(x: p.x, y: p.y), endRadius: rad, options: [])
                c.restoreGState()
            }
        case .dust:
            let sandCols: [CGColor] = [
                CGColor(red: 0.86, green: 0.70, blue: 0.48, alpha: 0.55),
                CGColor(red: 0.78, green: 0.60, blue: 0.38, alpha: 0.55),
                CGColor(red: 0.93, green: 0.82, blue: 0.62, alpha: 0.5),
                CGColor(red: 0.66, green: 0.50, blue: 0.32, alpha: 0.55),
            ]
            c.setLineCap(.round)
            for hue in 0..<4 {
                let path = CGMutablePath()
                for p in particles where p.hue == hue {
                    path.move(to: CGPoint(x: p.x, y: p.y))
                    path.addLine(to: CGPoint(x: p.x - p.vx * 0.014 * p.size, y: p.y - p.vy * 0.014 * p.size))
                }
                c.setStrokeColor(sandCols[hue]); c.setLineWidth(hue == 3 ? 1.6 : 1.1)
                c.addPath(path); c.strokePath()
            }
            for p in particles where p.hue == 9 { drawTumbleweed(c, p) }
        case .starfall:
            for p in particles {
                if p.kind == .spark {
                    let a = max(0, 1 - p.life / p.maxLife)
                    c.setFillColor(Simulation.spark[p.hue % 3].copy(alpha: a)!)
                    c.fillEllipse(in: CGRect(x: p.x - p.size / 2, y: p.y - p.size / 2, width: p.size, height: p.size))
                } else {
                    let sp = max(1, hypot(p.vx, p.vy)), ux = p.vx / sp, uy = p.vy / sp
                    let len: CGFloat = 110
                    c.setLineCap(.round)
                    for seg in 0..<8 {
                        let t0 = CGFloat(seg) / 8, t1 = CGFloat(seg + 1) / 8
                        c.setStrokeColor(CGColor(red: 0.85, green: 0.9, blue: 1, alpha: (1 - t0) * 0.7))
                        c.setLineWidth(p.size * (1 - t0 * 0.8))
                        c.move(to: CGPoint(x: p.x - ux * len * t0, y: p.y - uy * len * t0))
                        c.addLine(to: CGPoint(x: p.x - ux * len * t1, y: p.y - uy * len * t1))
                        c.strokePath()
                    }
                    c.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                    c.fillEllipse(in: CGRect(x: p.x - p.size, y: p.y - p.size, width: p.size * 2, height: p.size * 2))
                }
            }
        }
    }
}

// MARK: - Overlay

final class OverlayView: NSView {
    let sim: Simulation
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0

    init(screen: NSScreen) {
        sim = Simulation(screen: screen)
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { false }

    /// Render the weather at 1× even on Retina: soft particles look the same and it's 4× fewer pixels.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = 1
    }

    func start() {
        let l = displayLink(target: self, selector: #selector(tick(_:)))
        let lp = ProcessInfo.processInfo.isLowPowerModeEnabled
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: lp ? 30 : 60)
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() { link?.invalidate(); link = nil }

    @objc func tick(_ l: CADisplayLink) {
        let now = l.timestamp
        let dt = last == 0 ? 1.0 / 60 : clamp(now - last, 1.0 / 240, 1.0 / 20)
        last = now
        sim.step(CGFloat(dt))
        if let l = layer, l.contentsScale != 1 { l.contentsScale = 1 }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let c = NSGraphicsContext.current?.cgContext else { return }
        c.clear(bounds)
        sim.draw(c)
    }
}

final class Overlay {
    let window: NSWindow
    let view: OverlayView

    init(screen: NSScreen) {
        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrame(screen.frame, display: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true          // every click goes through
        // Desktop level + 1: above the wallpaper, BELOW desktop icons and every app window,
        // so nothing ever blocks your view.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        window.isReleasedWhenClosed = false
        view = OverlayView(screen: screen)
        window.contentView = view
        window.orderFrontRegardless()
        view.start()
    }

    func close() { view.stop(); window.orderOut(nil) }
}

// MARK: - Menu slider

final class SliderMenuView: NSView {
    private let slider: NSSlider
    private let valueLabel = NSTextField(labelWithString: "")
    private let format: (Double) -> String
    private let onChange: (Double) -> Void

    init(title: String, min: Double, max: Double, value: Double,
         format: @escaping (Double) -> String, onChange: @escaping (Double) -> Void) {
        self.format = format; self.onChange = onChange
        slider = NSSlider(value: value, minValue: min, maxValue: max, target: nil, action: nil)
        super.init(frame: CGRect(x: 0, y: 0, width: 250, height: 46))
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .menuFont(ofSize: 13)
        valueLabel.font = .menuFont(ofSize: 11)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        slider.target = self; slider.action = #selector(changed)
        slider.isContinuous = true
        slider.controlSize = .small
        for v in [titleLabel, valueLabel, slider] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            valueLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            slider.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
        ])
        valueLabel.stringValue = format(value)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed() {
        valueLabel.stringValue = format(slider.doubleValue)
        onChange(slider.doubleValue)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var status: NSStatusItem!
    var overlays: [Overlay] = []

    var clickMonitor: Any?

    func applicationDidFinishLaunching(_ n: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        status.menu = menu
        updateIcon()
        rebuild()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screensChanged),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        // Watch clicks anywhere (the overlay itself passes clicks through) so a click on the
        // sailboat can sink it. A global mouse-down monitor needs no special permission and
        // does not consume the event.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] e in
            guard let self else { return }
            let p = NSEvent.mouseLocation
            let option = e.modifierFlags.contains(.option)
            let phase = e.type == .leftMouseDown ? 0 : (e.type == .leftMouseDragged ? 1 : 2)
            self.overlays.forEach { $0.view.sim.lightMouse(global: p, phase: phase, option: option) }
            if phase == 0 { self.overlays.forEach { $0.view.sim.clickAt(global: p) } }
        }
    }

    @objc func screensChanged() { rebuild() }

    func rebuild() {
        overlays.forEach { $0.close() }
        overlays = Settings.paused ? [] : NSScreen.screens.map { Overlay(screen: $0) }
    }

    func updateIcon() {
        let name = Settings.paused ? "pause.circle" : Settings.effect.symbol
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Macscapes")
        img?.isTemplate = true
        status.button?.image = img
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let head = NSMenuItem(title: "Macscapes", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        for e in Effect.allCases {
            let it = NSMenuItem(title: e.title, action: #selector(pick(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = e.rawValue
            it.image = NSImage(systemSymbolName: e.symbol, accessibilityDescription: nil)
            it.state = e == Settings.effect ? .on : .off
            menu.addItem(it)
        }
        if Settings.effect == .snow {
            let hint = NSMenuItem(title: "Hold ⌥ Option over snow to make a snowball", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            hint.image = NSImage(systemSymbolName: "circle.circle", accessibilityDescription: nil)
            menu.addItem(hint)
        }
        if [.rain, .storm, .tornado].contains(Settings.effect) {
            let flood = NSMenuItem(title: "Flood: Rain Fills the Screen", action: #selector(toggleFlood), keyEquivalent: "")
            flood.target = self
            flood.state = Settings.flood ? .on : .off
            flood.image = NSImage(systemSymbolName: "water.waves", accessibilityDescription: nil)
            menu.addItem(flood)
            if overlays.contains(where: { $0.view.sim.water > 0 }) {
                let drain = NSMenuItem(title: "Drain the Water", action: #selector(drainWater), keyEquivalent: "")
                drain.target = self
                menu.addItem(drain)
            }
        }
        let addLights = NSMenuItem(title: "Add Christmas Lights  (⌥-drag to hang · ⌥-click cord to pin)", action: #selector(addLights), keyEquivalent: "")
        addLights.target = self
        addLights.image = NSImage(systemSymbolName: "lightbulb.2", accessibilityDescription: nil)
        menu.addItem(addLights)
        if overlays.contains(where: { !$0.view.sim.lightStrings.isEmpty }) {
            let clearLights = NSMenuItem(title: "Clear Christmas Lights", action: #selector(clearLights), keyEquivalent: "")
            clearLights.target = self
            menu.addItem(clearLights)
        }
        menu.addItem(.separator())
        let inten = NSMenuItem(title: "Intensity", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (t, v) in [("Light", 0.5), ("Normal", 1.0), ("Heavy", 2.0), ("Blizzard", 3.5)] {
            let it = NSMenuItem(title: t, action: #selector(setIntensity(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = v
            it.state = abs(Settings.intensity - v) < 0.01 ? .on : .off
            sub.addItem(it)
        }
        inten.submenu = sub
        menu.addItem(inten)
        menu.addItem(.separator())
        let ws = NSMenuItem()
        ws.view = SliderMenuView(title: "Wind strength", min: 0, max: 3, value: Settings.windStrength,
                                 format: { v in v < 0.25 ? "Calm" : v < 0.8 ? "Breeze" : v < 1.5 ? "Normal" : v < 2.3 ? "Strong" : "Gale" },
                                 onChange: { Settings.windStrength = $0 })
        menu.addItem(ws)
        let wa = NSMenuItem()
        wa.view = SliderMenuView(title: "Wind angle", min: -60, max: 60, value: Settings.windAngle,
                                 format: { v in let a = Int(v.rounded()); return abs(a) < 1 ? "Straight" : a < 0 ? "\(-a)° ←" : "\(a)° →" },
                                 onChange: { Settings.windAngle = abs($0) < 3 ? 0 : $0 })
        menu.addItem(wa)
        menu.addItem(.separator())
        let needsAX = Settings.solidIcons && !DesktopIconTracker.shared.trusted
        let icons = NSMenuItem(title: needsAX ? "Solid Desktop Icons (allow Accessibility…)" : "Solid Desktop Icons",
                               action: #selector(toggleIcons), keyEquivalent: "")
        icons.target = self
        icons.state = Settings.solidIcons ? (needsAX ? .mixed : .on) : .off
        menu.addItem(icons)
        let clear = NSMenuItem(title: "Clear Piles", action: #selector(clearPiles), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
        let pause = NSMenuItem(title: Settings.paused ? "Resume" : "Pause", action: #selector(togglePause),
                               keyEquivalent: "p")
        pause.target = self
        menu.addItem(pause)
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Macscapes", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc func pick(_ s: NSMenuItem) {
        guard let raw = s.representedObject as? String, let e = Effect(rawValue: raw) else { return }
        Settings.effect = e
        if Settings.paused { Settings.paused = false; rebuild() }
        updateIcon()
    }

    @objc func setIntensity(_ s: NSMenuItem) {
        if let v = s.representedObject as? Double { Settings.intensity = v }
    }

    @objc func toggleIcons() {
        if Settings.solidIcons && !DesktopIconTracker.shared.trusted {
            DesktopIconTracker.shared.requestAccess()
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            return
        }
        Settings.solidIcons.toggle()
        if Settings.solidIcons && !DesktopIconTracker.shared.trusted { DesktopIconTracker.shared.requestAccess() }
    }

    @objc func toggleFlood() { Settings.flood.toggle() }
    @objc func addLights() { overlays.forEach { $0.view.sim.addDefaultLightString() } }
    @objc func clearLights() { overlays.forEach { $0.view.sim.lightStrings.removeAll() } }
    @objc func drainWater() { overlays.forEach { $0.view.sim.drainWater() } }

    @objc func clearPiles() { overlays.forEach { $0.view.sim.clearAll() } }

    @objc func togglePause() {
        Settings.paused.toggle()
        rebuild(); updateIcon()
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let a = NSAlert()
            a.messageText = "Couldn't change Open at Login"
            a.informativeText = error.localizedDescription
            a.runModal()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
