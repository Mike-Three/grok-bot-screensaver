// Grok Bot Screensaver for Windows (fan-made, inspired by the Grok Bot face marks).
// The faces are pre-rendered from the app's 3D face marks with flat, unlit color (see sprites/ and README).
// Each sprite sheet holds 8-bit signed-distance masks (128 = the outline, eyes are holes), so the palette
// color is applied as one solid fill and neighbouring 3D angles blend smoothly.
// Motion follows the "wait for it" reference video: a DVD-style bounce, an instant switch to a new shape and
// color on every wall, the face looking where it's heading, and a happy spin when it lands in a corner.
// The face tips in 3D (turn and nod) to look where it's heading. A bounce changes that and gives the tilt a push;
// a damped spring settles it in about a quarter of a second with one small overshoot. The four 3D renders around
// the current angle are blended. Travel is a straight line at constant speed with a mirror-exact bounce.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows.Forms;

static class Program {
    [STAThread]
    static void Main(string[] args) {
        string a = args.Length > 0 ? args[0].Trim() : "/s";
        if (a.StartsWith("-")) a = "/" + a.Substring(1);
        string mode = (a.Length >= 2 ? a.Substring(0, 2) : a).ToLowerInvariant();
        if (mode == "/c") { MessageBox.Show("Grok Bot Screensaver has no settings.", "Grok Bot Screensaver"); return; }
        Application.EnableVisualStyles();
        if (mode == "/p") {
            string h = a.Length > 2 ? a.Substring(2).Trim(':', ' ') : (args.Length > 1 ? args[1].Trim() : "");
            long v;
            if (!long.TryParse(h, out v)) return;
            IntPtr parent = new IntPtr(v);
            if (!Native.IsWindow(parent)) return;
            Application.Run(new SaverForm(parent));
            return;
        }
        foreach (Screen s in Screen.AllScreens) new SaverForm(s.Bounds).Show();
        Application.Run();
    }
}

static class Native {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern IntPtr SetParent(IntPtr child, IntPtr parent);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int index);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int index, int value);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
    public const int GWL_STYLE = -16, WS_CHILD = 0x40000000, WS_POPUP = unchecked((int)0x80000000);
}

static class Faces {
    // The 13 shapes of the Grok Bot avatar picker, in picker order.
    public static readonly string[] Shapes = { "blob", "cloud", "square", "sparkle", "clover", "heart", "flower",
                                               "teardrop", "tablet", "wedge", "house", "star", "hex" };
    // Grok Bot palette (white is the app's black mark in dark mode).
    static readonly int[] Pal = {
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
    };
    public static int ColorCount { get { return Pal.Length; } }
    public static int Rgb(int color) { return Pal[color] & 0xFFFFFF; }
    public const int Cell = 256, Cols = 12, Px = Cell * Cell;
    // Frames 0-374: 3D renders on a turn x nod grid, frame = nod step * 25 + turn step, turn -24..24 and nod -14..14
    // degrees in 2 degree steps. Positive turn looks right, positive nod looks down. The blink is drawn from these
    // (see Lids). Frames 375-449: the corner celebration (happy eyes, a full spin and a wobble), 30 frames per second.
    public const int Turns = 25, Nods = 15, CelFirst = Turns * Nods, CelFrames = 75, CelFps = 30, Straight = 4;
    public const float Turn0 = -24f, Nod0 = -14f, Step = 2f;
    public const int FrontFrame = 7 * Turns + 12; // turn 0, nod 0
    // How far each shape turns and nods toward where it's heading, in degrees (measured from the reference video).
    public static float Gain(int shape) {
        switch (Shapes[shape]) { case "heart": return 0.6f; case "wedge": return 0.55f; default: return 1f; }
    }
    public static float GazeTurn(int shape) { return (Shapes[shape] == "blob" ? 14.4f : 20.8f) * Gain(shape); }
    public static float GazeNod(int shape) { return (Shapes[shape] == "blob" ? 8.4f : 11.4f) * Gain(shape); }
    public const float CelDuration = (CelFrames - 1) / (float)CelFps;
    public const float CellFraction = 0.283f; // sprite cell edge relative to the shorter screen side

    static readonly Dictionary<int, byte[]> sheets = new Dictionary<int, byte[]>();
    static readonly Dictionary<int, float[]> eyes = new Dictionary<int, float[]>();
    static readonly List<int> order = new List<int>();
    static readonly Dictionary<int, Rectangle> boxes = new Dictionary<int, Rectangle>();
    static int sheetWidth;
    public static readonly byte[] Alpha = new byte[256]; // distance value -> coverage (one sprite pixel of anti-aliasing)

    static Faces() {
        for (int v = 0; v < 256; v++) Alpha[v] = (byte)Math.Round(255 * Math.Min(1.0, Math.Max(0.0, (v - 128) / 8.0 + 0.5)));
    }

    // Sheets are decoded once and kept for the 2 most recently used shapes (the one on screen and the next). The next
    // shape is decoded ahead of time on a background thread, and a bounce only switches to a shape that is ready.
    static readonly object gate = new object();

    public static void Preload(int shape) {
        System.Threading.ThreadPool.QueueUserWorkItem(delegate { try { Sheet(shape); } catch { } });
    }

    public static bool Ready(int shape) { lock (gate) return sheets.ContainsKey(shape); }

    // Another shape that is already decoded (the previous one), or -1.
    public static int Other(int shape) { lock (gate) { foreach (int s in order) if (s != shape) return s; } return -1; }

    static byte[] Sheet(int shape) {
        byte[] px;
        lock (gate) {
            if (sheets.TryGetValue(shape, out px)) { // most recently used last, so the shape on screen is never evicted
                if (order[order.Count - 1] != shape) { order.Remove(shape); order.Add(shape); }
                return px;
            }
        }
        int w; float[] e;
        using (Stream st = Assembly.GetExecutingAssembly().GetManifestResourceStream("face-" + Shapes[shape] + ".png"))
            px = Png.ReadGray(st, TakeSpare(), out w, out e);
        lock (gate) {
            byte[] have;
            if (sheets.TryGetValue(shape, out have)) return have;
            sheetWidth = w;
            sheets[shape] = px; eyes[shape] = e; order.Add(shape);
            if (order.Count > 2) { spare = sheets[order[0]]; sheets.Remove(order[0]); eyes.Remove(order[0]); order.RemoveAt(0); }
        }
        return px;
    }

    static byte[] spare; // the last evicted sheet's pixels, reused by the next decode
    static byte[] TakeSpare() { lock (gate) { byte[] b = spare; spare = null; return b; } }

    // The eye geometry of the open-eye frames: 16 floats per frame (see Lids).
    public static float[] Eyes(int shape) { Sheet(shape); lock (gate) return eyes[shape]; }

    // Copies one frame's distance values into dst (Cell x Cell, top row first).
    public static void Read(int shape, int frame, float[] dst) {
        byte[] px = Sheet(shape);
        int sx = (frame % Cols) * Cell, sy = (frame / Cols) * Cell;
        for (int y = 0; y < Cell; y++) {
            int row = (sy + y) * sheetWidth + sx, o = y * Cell;
            for (int x = 0; x < Cell; x++) dst[o + x] = px[row + x];
        }
    }

    // Collision box in sprite pixels: the outline of the straight-on resting pose.
    public static Rectangle Box(int shape) {
        Rectangle r;
        if (boxes.TryGetValue(shape, out r)) return r;
        float[] f = new float[Px];
        Read(shape, FrontFrame, f);
        int x0 = Cell, y0 = Cell, x1 = 0, y1 = 0;
        for (int y = 0; y < Cell; y++)
            for (int x = 0; x < Cell; x++)
                if (f[y * Cell + x] >= 128) { if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y; }
        r = Rectangle.FromLTRB(x0, y0, x1 + 1, y1 + 1);
        boxes[shape] = r;
        return r;
    }
}

// Reads the 8-bit grayscale sprite sheets without GDI+, so decoding the next sheet in the background never holds up
// drawing (GDI+ calls can wait on each other across threads).
static class Png {
    // Also returns the eye geometry stored in the sheet's private "eyEs" chunk (little-endian floats).
    public static byte[] ReadGray(Stream st, byte[] reuse, out int w, out float[] eyes) {
        var br = new BinaryReader(st);
        br.ReadBytes(8); // signature
        int h = 0; w = 0; var idat = new MemoryStream(); eyes = null;
        while (true) {
            int len = BE(br.ReadBytes(4)); string type = System.Text.Encoding.ASCII.GetString(br.ReadBytes(4));
            byte[] data = br.ReadBytes(len); br.ReadBytes(4); // CRC
            if (type == "IHDR") {
                w = BE(data); h = BE(new byte[] { data[4], data[5], data[6], data[7] });
                if (data[8] != 8 || data[9] != 0 || data[12] != 0) throw new InvalidDataException("sprite sheets are 8-bit gray PNGs");
            } else if (type == "IDAT") idat.Write(data, 0, data.Length);
            else if (type == "eyEs") { eyes = new float[data.Length / 4]; Buffer.BlockCopy(data, 0, eyes, 0, eyes.Length * 4); }
            else if (type == "IEND") break;
        }
        if (eyes == null) throw new InvalidDataException("sprite sheet without eye data");
        idat.Position = 0;
        return Unfilter(idat, w, h, reuse);
    }
    static int BE(byte[] b) { return (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3]; }
    // Inflates and unfilters row by row straight into px (reused when it is the right size), so a sheet costs no
    // big temporary buffers and the garbage collector stays quiet.
    static byte[] Unfilter(MemoryStream z, int w, int h, byte[] px) {
        z.ReadByte(); z.ReadByte(); // zlib header
        if (px == null || px.Length != w * h) px = new byte[w * h];
        byte[] row = new byte[w + 1];
        using (var d = new System.IO.Compression.DeflateStream(z, System.IO.Compression.CompressionMode.Decompress)) {
            for (int y = 0; y < h; y++) {
                for (int n = 0; n < row.Length; ) { int k = d.Read(row, n, row.Length - n); if (k <= 0) throw new EndOfStreamException(); n += k; }
                int f = row[0], o = y * w, u = o - w; // u: the row above
                switch (f) { // one tight loop per filter type
                    case 0: Buffer.BlockCopy(row, 1, px, o, w); break;
                    case 1: px[o] = row[1]; for (int x = 1; x < w; x++) px[o + x] = (byte)(row[x + 1] + px[o + x - 1]); break;
                    case 2: if (y == 0) Buffer.BlockCopy(row, 1, px, o, w); else for (int x = 0; x < w; x++) px[o + x] = (byte)(row[x + 1] + px[u + x]); break;
                    case 3:
                        for (int x = 0; x < w; x++) px[o + x] = (byte)(row[x + 1] + (((x > 0 ? px[o + x - 1] : 0) + (y > 0 ? px[u + x] : 0)) >> 1));
                        break;
                    default:
                        for (int x = 0; x < w; x++) {
                            int ca = x > 0 ? px[o + x - 1] : 0, cb = y > 0 ? px[u + x] : 0, cc = x > 0 && y > 0 ? px[u + x - 1] : 0;
                            int p = ca + cb - cc, pa = Math.Abs(p - ca), pb = Math.Abs(p - cb), pc = Math.Abs(p - cc);
                            px[o + x] = (byte)(row[x + 1] + (pa <= pb && pa <= pc ? ca : pb <= pc ? cb : cc));
                        }
                        break;
                }
            }
        }
        return px;
    }
}

// The blink, drawn from the open eyes the way the app's face engine does it: the lid comes down along the eye and
// squashes it about the point 60 percent of the way down, to 3 percent of its length at most. On the Blob the whole eye
// is squashed, so a closed eye is a thin line. On the other bodies the engine squashes only the straight middle of the
// capsule and keeps its round ends, so a closed eye is a dot as wide as the open eye. Per eye the sheet stores its centre
// (cx, cy), the lid direction u (the eye's long axis, pointing down), the direction e of the closed line (measured from
// the engine's closed-eye renders), and the half extents la along u and lb along e, all in sprite pixels.
static class Lids {
    const float Pivot = 0.6f, Thinnest = 0.03f, Cap = 0.26f / 0.57f;

    // Bilinear blend of the eye data of four frames (the same weights as the sprite blend), into q (16 floats).
    public static void Blend(float[] m, int f0, int turns, float a, float b, float[] q) {
        for (int i = 0; i < 16; i++) {
            float v00 = m[f0 * 16 + i], v01 = m[(f0 + 1) * 16 + i], v10 = m[(f0 + turns) * 16 + i], v11 = m[(f0 + turns + 1) * 16 + i];
            float top = v00 + (v01 - v00) * a, bot = v10 + (v11 - v10) * a;
            q[i] = top + (bot - top) * b;
        }
    }

    // Closes both eyes of src (distance values) by lid (0 open, 1 shut) into dst, to a line or to dots. src and dst are
    // different buffers that start out equal.
    public static void Close(float[] src, float[] dst, float[] q, float lid, bool line) {
        float ly = Math.Max(Thinnest, 1 - lid);
        for (int e = 0; e < 2; e++) CloseEye(src, dst, q, e * 8, ly, line);
    }

    static void CloseEye(float[] src, float[] dst, float[] q, int o, float ly, bool line) {
        float cx = q[o], cy = q[o + 1], ux = q[o + 2], uy = q[o + 3], ex = q[o + 4], ey = q[o + 5], la = q[o + 6], lb = q[o + 7];
        float n = (float)Math.Sqrt(ux * ux + uy * uy); ux /= n; uy /= n;
        n = (float)Math.Sqrt(ex * ex + ey * ey); ex /= n; ey /= n;
        float det = ux * ey - uy * ex, k = 1 / ly - 1, pv = (Pivot - 0.5f) * 2 * la, px = cx + ux * pv, py = cy + uy * pv;
        // the squashed part along u, from the pivot: the whole eye for a line, all but the round ends for dots; what
        // lies beyond it only moves with its end. Each round end is Cap of the half length, as in the engine's eye (0.26
        // wide, 0.57 long), so it is measured along u and keeps the eye's own foreshortening there
        float keep = line ? 0 : la * Cap, lo = (keep - la - pv) * ly, hi = (la - keep - pv) * ly;
        int r = (int)Math.Max(la, lb) + 4, C = Faces.Cell;
        int x0 = Math.Max(1, (int)cx - r), x1 = Math.Min(C - 2, (int)cx + r), y0 = Math.Max(1, (int)cy - r), y1 = Math.Min(C - 2, (int)cy + r);
        for (int y = y0; y <= y1; y++)
            for (int x = x0; x <= x1; x++) {
                int i = y * C + x; float v = dst[i];
                // p = cx,cy + a u + b e (oblique coordinates); first fill in the open eye
                float a = ((x - cx) * ey - (y - cy) * ex) / det, b = (ux * (y - cy) - uy * (x - cx)) / det;
                if (Math.Abs(a) <= la + 1.5f && Math.Abs(b) <= lb + 1.5f && v < 136) v = 255;
                // then cut the squashed eye: where this pixel came from in the open eye
                float ap = ((x - px) * ey - (y - py) * ex) / det, bp = (ux * (y - py) - uy * (x - px)) / det;
                float c = Math.Min(hi, Math.Max(lo, ap)), kc = c == ap ? k : 0, sap = ap + c * k;
                float sx = px + sap * ux + bp * ex, sy = py + sap * uy + bp * ey;
                float sa = ((sx - cx) * ey - (sy - cy) * ex) / det, sb = (ux * (sy - cy) - uy * (sx - cx)) / det;
                if (Math.Abs(sa) <= la + 3 && Math.Abs(sb) <= lb + 3) {
                    float d = (Sample(src, sx, sy) - 128) / 8;
                    float gx = (Sample(src, sx + 0.5f, sy) - Sample(src, sx - 0.5f, sy)) / 8;
                    float gy = (Sample(src, sx, sy + 0.5f) - Sample(src, sx, sy - 0.5f)) / 8;
                    // the squash stretches distances along u: rescale so the edge stays one pixel soft
                    float gu = gx * ux + gy * uy, Gx = gx + kc * gu * ey / det, Gy = gy - kc * gu * ex / det;
                    float g = (float)Math.Sqrt(Gx * Gx + Gy * Gy);
                    v = Math.Min(v, 128 + 8 * d / Math.Max(g, 1e-3f));
                }
                // no point of the closed eye lies deeper than its distance to the ends of the closed eye along u (this
                // keeps the thin line's distances right where the open eye's are far deeper)
                float depth = Math.Min(ap - lo + keep, hi + keep - ap) * Math.Abs(det);
                if (depth > 0) v = Math.Max(v, 128 - 8 * depth);
                dst[i] = v;
            }
    }

    static float Sample(float[] f, float x, float y) {
        int C = Faces.Cell;
        x = Math.Min(C - 1.001f, Math.Max(0, x)); y = Math.Min(C - 1.001f, Math.Max(0, y));
        int ix = (int)x, iy = (int)y; float fx = x - ix, fy = y - iy; int i = iy * C + ix;
        float top = f[i] + (f[i + 1] - f[i]) * fx, bot = f[i + C] + (f[i + C + 1] - f[i + C]) * fx;
        return top + (bot - top) * fy;
    }
}

class SaverForm : Form {
    // Blink timing from the app's face engine: the lid closes in 0.08 s, stays shut 0.07 s and opens in 0.11 s. Then
    // the eyes stay open at least MinOpen before the next blink, so two blinks never run into each other.
    const float LidClose = 0.08f, LidHold = 0.07f, LidOpen = 0.11f, BlinkTime = LidClose + LidHold + LidOpen, MinOpen = 0.3f;
    // Tilt spring: natural frequency (Hz) and damping ratio (one overshoot of about 6 percent), the push per
    // bounce relative to the speed into the wall (doubled with the half travel speed, so the kick is unchanged), and
    // the physics step (s).
    const float SpringHz = 1.4f, Damping = 0.65f, PushGain = 0.6f, Step = 1f / 120;
    static readonly Random R = new Random();
    readonly Timer timer = new Timer();
    readonly Stopwatch clock = Stopwatch.StartNew();
    readonly bool preview;
    readonly IntPtr previewParent;
    readonly float[] cur = new float[Faces.Px], next = new float[Faces.Px];
    readonly float[] open = new float[Faces.Px], tmp = new float[Faces.Px], eye = new float[16];
    readonly int[] argb = new int[Faces.Px];
    Bitmap sprite;
    int W, H, shape, upcoming, color, dir, tick, lastHitX = -99, lastHitY = -99;
    float x, y, vx, vy, cellPx, t, celT = -1, blinkT = -1, nextBlink;
    float turn, nod, turnVel, nodVel; // tilt (degrees) and its speed (degrees per second)
    double lastTime;
    Point? lastMouse;

    public SaverForm(Rectangle b) {
        FormBorderStyle = FormBorderStyle.None; StartPosition = FormStartPosition.Manual;
        Bounds = b; TopMost = true; ShowInTaskbar = false;
        Cursor.Hide();
        Init(b.Width, b.Height);
        KeyDown += delegate { Application.Exit(); };
        MouseDown += delegate { Application.Exit(); };
        MouseMove += (s, e) => {
            if (lastMouse == null) { lastMouse = e.Location; return; }
            if (Math.Abs(e.X - lastMouse.Value.X) + Math.Abs(e.Y - lastMouse.Value.Y) > 10) Application.Exit();
        };
    }

    // Preview inside the little monitor of the Screen Saver Settings dialog (/p <HWND>).
    public SaverForm(IntPtr parent) {
        preview = true; previewParent = parent;
        FormBorderStyle = FormBorderStyle.None; StartPosition = FormStartPosition.Manual; ShowInTaskbar = false;
        Native.SetParent(Handle, parent);
        int style = Native.GetWindowLong(Handle, Native.GWL_STYLE);
        Native.SetWindowLong(Handle, Native.GWL_STYLE, (style | Native.WS_CHILD) & ~Native.WS_POPUP);
        Native.RECT r;
        Native.GetClientRect(parent, out r);
        Location = Point.Empty;
        Size = new Size(Math.Max(1, r.Right - r.Left), Math.Max(1, r.Bottom - r.Top));
        Init(Size.Width, Size.Height);
    }

    void Init(int w, int h) {
        BackColor = Color.Black; DoubleBuffered = true;
        W = w; H = h;
        cellPx = Math.Max(16f, Math.Min(w, h) * Faces.CellFraction);
        // px per second: half the earlier pace, so 0.625 of the reference video's (the video moves
        // 7.9 px per frame at 1080p), heading 28 to 62 degrees off the horizontal
        float sp = Math.Min(w, h) / 137f * 60f * 0.625f, a = Rand(28, 62) * (float)Math.PI / 180;
        vx = sp * (float)Math.Cos(a) * (R.Next(2) == 0 ? 1 : -1); vy = sp * (float)Math.Sin(a) * (R.Next(2) == 0 ? 1 : -1);
        shape = R.Next(Faces.Shapes.Length); color = R.Next(Faces.ColorCount);
        PickUpcoming();
        RectangleF bx = BoxAt(0, 0);
        x = (float)(-bx.Left + R.NextDouble() * Math.Max(1, w - bx.Width));
        y = (float)(-bx.Top + R.NextDouble() * Math.Max(1, h - bx.Height));
        dir = PickDir();
        nextBlink = 4 + (float)R.NextDouble() * 4;
        turn = TargetTurn(); nod = TargetNod();
        sprite = new Bitmap(Faces.Cell, Faces.Cell, PixelFormat.Format32bppArgb);
        Compose();
        lastTime = clock.Elapsed.TotalSeconds;
        timer.Interval = 15; timer.Tick += Tick; timer.Start();
    }

    // The face's collision box on screen if its sprite cell were centered at (cx, cy).
    RectangleF BoxAt(float cx, float cy) {
        Rectangle b = Faces.Box(shape); float sc = cellPx / Faces.Cell, h = Faces.Cell / 2f;
        return RectangleF.FromLTRB(cx + (b.Left - h) * sc, cy + (b.Top - h) * sc, cx + (b.Right - h) * sc, cy + (b.Bottom - h) * sc);
    }

    // Look where it's heading; if the next wall contact will be a corner, look straight at the viewer ("wait for it").
    int PickDir() {
        RectangleF b = BoxAt(x, y);
        float tx = vx < 0 ? -b.Left / -vx : (W - b.Right) / vx;
        float ty = vy < 0 ? -b.Top / -vy : (H - b.Bottom) / vy;
        if (Math.Abs(tx - ty) < 1.5f / 60f) return Faces.Straight;
        return (vx < 0 ? 0 : 1) + (vy < 0 ? 0 : 2);
    }

    static float First(float a, float b) { return a < 0 ? b : Math.Min(a, b); }

    static float Rand(float a, float b) { return a + (float)R.NextDouble() * (b - a); }

    // The next face is chosen one bounce ahead so its sheet can be decoded in the background.
    void PickUpcoming() {
        int n; do { n = R.Next(Faces.Shapes.Length); } while (n == shape); upcoming = n;
        Faces.Preload(upcoming);
    }

    int Heading() { return dir == Faces.Straight ? 0 : (dir == 0 || dir == 2 ? -1 : 1); }

    // Where the tilt settles: looking where it's heading (straight at you before a corner).
    float TargetTurn() { return Faces.GazeTurn(shape) * Heading(); }
    float TargetNod() { return dir == Faces.Straight ? 0 : Faces.GazeNod(shape) * (dir < 2 ? -1 : 1); }

    // One physics step of the tilt: a damped spring toward the target, on both axes.
    void Settle(float h) {
        float w = 2 * (float)Math.PI * SpringHz;
        turnVel += (-w * w * (turn - TargetTurn()) - 2 * Damping * w * turnVel) * h;
        nodVel += (-w * w * (nod - TargetNod()) - 2 * Damping * w * nodVel) * h;
        turn += turnVel * h; nod += nodVel * h;
    }

    void SettleFor(float time) {
        for (float left = time; left > 1e-6f; left -= Step) Settle(Math.Min(Step, left));
    }

    // The push a bounce gives the tilt: a side wall pushes the turn, a top or bottom wall the nod, toward the new
    // target, in proportion to the speed into the wall over the face's radius.
    float Push(float speedIn, float now, float target) {
        return PushGain * Math.Sign(target - now) * speedIn / (cellPx * 0.33f) * 180 / (float)Math.PI;
    }

    static float Ease(float u) { u = Math.Min(1f, Math.Max(0f, u)); return u * u * (3 - 2 * u); }

    // How far the eyes are closed during a blink (0 open, 1 shut).
    static float Lid(float bt) {
        if (bt < LidClose) return Ease(bt / LidClose);
        if (bt < LidClose + LidHold) return 1;
        return 1 - Ease((bt - LidClose - LidHold) / LidOpen);
    }

    // What the face looks like right now, as distance values in cur.
    void Current() {
        if (celT >= 0) {
            float f = Math.Min(celT * Faces.CelFps, Faces.CelFrames - 1);
            int i = (int)f; float fr = f - i;
            Faces.Read(shape, Faces.CelFirst + i, cur);
            if (fr > 0.001f && i + 1 < Faces.CelFrames) {
                Faces.Read(shape, Faces.CelFirst + i + 1, next);
                for (int k = 0; k < Faces.Px; k++) cur[k] += (next[k] - cur[k]) * fr;
            }
            return;
        }
        int f0; float wa, wb;
        Grid(cur, out f0, out wa, out wb);
        float l = blinkT >= 0 ? Lid(blinkT) : 0;
        if (l > 0.001f) {
            Array.Copy(cur, open, Faces.Px);
            Lids.Blend(Faces.Eyes(shape), f0, Faces.Turns, wa, wb, eye);
            Lids.Close(open, cur, eye, l, Faces.Shapes[shape] == "blob");
        }
    }

    // The four renders around the current tilt, blended by where the tilt sits between them.
    void Grid(float[] dst, out int f0, out float a, out float b) {
        float ft = Math.Min(Faces.Turns - 1, Math.Max(0, (turn - Faces.Turn0) / Faces.Step));
        float fn = Math.Min(Faces.Nods - 1, Math.Max(0, (nod - Faces.Nod0) / Faces.Step));
        int it = Math.Min(Faces.Turns - 2, (int)ft), inod = Math.Min(Faces.Nods - 2, (int)fn), T = Faces.Turns;
        a = ft - it; b = fn - inod;
        f0 = inod * T + it;
        Faces.Read(shape, f0, dst); Faces.Read(shape, f0 + 1, tmp);
        for (int k = 0; k < Faces.Px; k++) dst[k] += (tmp[k] - dst[k]) * a;
        Faces.Read(shape, f0 + T, next); Faces.Read(shape, f0 + T + 1, tmp);
        for (int k = 0; k < Faces.Px; k++) { float lo = next[k] + (tmp[k] - next[k]) * a; dst[k] += (lo - dst[k]) * b; }
    }

    void Compose() {
        Current();
        int rgb = Faces.Rgb(color);
        for (int k = 0; k < Faces.Px; k++) {
            float v = cur[k];
            int a = Faces.Alpha[v <= 0 ? 0 : v >= 255 ? 255 : (int)(v + 0.5f)];
            argb[k] = a == 0 ? 0 : (a << 24) | rgb;
        }
        BitmapData bd = sprite.LockBits(new Rectangle(0, 0, Faces.Cell, Faces.Cell), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        Marshal.Copy(argb, 0, bd.Scan0, argb.Length);
        sprite.UnlockBits(bd);
    }

    void Tick(object s, EventArgs e) {
        if (preview && !Native.IsWindow(previewParent)) { Application.Exit(); return; }
        if (ClientSize.Width > 0 && ClientSize.Height > 0) { W = ClientSize.Width; H = ClientSize.Height; }
        double now = clock.Elapsed.TotalSeconds;
        float dt = (float)Math.Min(0.25, Math.Max(0.0, now - lastTime)); lastTime = now;
        t += dt; tick++;
        // Fixed physics steps. A wall mirrors the overshoot back, so the face never jumps and its speed never changes.
        bool hx = false, hy = false; float inX = 0, inY = 0, hitAt = -1; // speed into the wall, time of impact into this frame
        for (float done = 0; dt - done > 1e-6f; done += Step) {
            float h = Math.Min(Step, dt - done);
            x += vx * h; y += vy * h;
            RectangleF b = BoxAt(x, y);
            // a wall counts only while moving into it
            if ((b.Left <= 0 && vx < 0) || (b.Right >= W && vx > 0)) {
                // how far it moved past the wall in this step (the impact was over / speed ago); a new, bigger shape can
                // start out past a wall, and that part is left alone so the face never jumps
                inX = Math.Abs(vx); float over = Math.Min(vx < 0 ? -b.Left : b.Right - W, inX * h);
                x += vx < 0 ? 2 * over : -2 * over; vx = -vx; hx = true;
                hitAt = First(hitAt, done + h - over / inX);
            }
            if ((b.Top <= 0 && vy < 0) || (b.Bottom >= H && vy > 0)) {
                inY = Math.Abs(vy); float over = Math.Min(vy < 0 ? -b.Top : b.Bottom - H, inY * h);
                y += vy < 0 ? 2 * over : -2 * over; vy = -vy; hy = true;
                hitAt = First(hitAt, done + h - over / inY);
            }
        }
        if (hitAt < 0) { if (celT < 0) SettleFor(dt); }
        else {
            if (celT < 0) SettleFor(hitAt); // the tilt runs up to the moment of impact, then gets its push
            int prevX = lastHitX, prevY = lastHitY;
            if (hx) lastHitX = tick;
            if (hy) lastHitY = tick;
            bool corner = Math.Abs(lastHitX - lastHitY) <= 1;
            bool merged = (hx && !hy && tick - prevY <= 1) || (hy && !hx && tick - prevX <= 1); // second wall of a corner
            if (!merged) { // new shape and color right away
                // two bounces in quick succession can come before the next sheet is decoded: use the previous shape then
                if (Faces.Ready(upcoming)) { shape = upcoming; PickUpcoming(); }
                else { int o = Faces.Other(shape); if (o >= 0) shape = o; }
                int n; do { n = R.Next(Faces.ColorCount); } while (n == color); color = n;
                if (!corner && blinkT < 0 && R.NextDouble() < 0.35) blinkT = 0;
            }
            celT = corner ? 0 : -1;
            if (corner) { blinkT = -1; turn = nod = turnVel = nodVel = 0; } // the spin starts and ends straight on
            dir = PickDir();
            if (celT < 0) {
                if (hx) turnVel += Push(inX, turn, TargetTurn());
                if (hy) nodVel += Push(inY, nod, TargetNod());
                SettleFor(dt - hitAt);
            }
        }
        if (celT >= 0 && hitAt < 0) {
            celT += dt;
            if (celT > Faces.CelDuration) celT = -1;
        }
        if (blinkT >= 0) { blinkT += dt; if (blinkT > BlinkTime + MinOpen) blinkT = -1; }
        else if (celT < 0 && t >= nextBlink) { blinkT = 0; nextBlink = t + 4 + (float)R.NextDouble() * 4; }
        Compose();
        Invalidate();
    }

    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.Clear(Color.Black);
        g.InterpolationMode = InterpolationMode.HighQualityBilinear;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        g.CompositingQuality = CompositingQuality.HighQuality;
        g.TranslateTransform(x, y);
        g.DrawImage(sprite, new RectangleF(-cellPx / 2, -cellPx / 2, cellPx, cellPx));
        g.ResetTransform();
    }

    protected override void OnPaintBackground(PaintEventArgs e) { }

    protected override void Dispose(bool disposing) {
        if (disposing) { timer.Dispose(); if (sprite != null) sprite.Dispose(); }
        base.Dispose(disposing);
    }
}
