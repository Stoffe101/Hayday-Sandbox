"""Tiny isometric 3D rasterizer for original placeholder art.

Every placeholder sprite in Hayday Sandbox is rendered from simple 3D
primitives (boxes, roofs, cylinders, ellipsoids, flat polygons) with one shared
camera, light, outline and shadow treatment. That gives a coherent, original
"toy diorama" look with footprints that align exactly with the editor grid.

Coordinate system (matches src/core/iso.gd):
  x, y  : tile axes (1.0 = one tile edge). +x -> screen lower-right, +y -> lower-left
  z     : height in tile-edge units
  screen: sx = (x - y) * HALF_W * S,  sy = (x + y) * HALF_H * S - z * Z_UNIT * S
where S is the art scale (art pixels per world pixel).

Rendering: per-triangle vectorised edge-function rasterisation with a z-buffer
at SS x supersampling, deferred shading (sun + sky + fill light, contact
occlusion), internal part outlines, area-average downsampling, and a soft
silhouette outline. Ground shadows are produced separately by projecting the
mesh onto z=0 along the light direction.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field

import numpy as np
from PIL import Image, ImageFilter

TILE_W = 64.0
TILE_H = 32.0
HALF_W = TILE_W / 2
HALF_H = TILE_H / 2
Z_UNIT = TILE_W * 0.6123724

# View vector (towards the camera) is the null space of the projection.
VIEW = np.array([1.0, 1.0, (2 * HALF_H) / Z_UNIT])
VIEW = VIEW / np.linalg.norm(VIEW)
# Sun from the upper-left (screen) => lights +y faces, shades +x faces.
SUN = np.array([-0.30, 0.78, 1.05])
SUN = SUN / np.linalg.norm(SUN)
FILL = np.array([1.0, -0.2, 0.35])
FILL = FILL / np.linalg.norm(FILL)
SUN_COLOR = np.array([1.00, 0.97, 0.90])
SKY_COLOR = np.array([0.90, 0.94, 1.00])
FILL_COLOR = np.array([0.95, 0.85, 0.80])
OUTLINE_RGB = np.array([48, 36, 30], dtype=np.float32)


def hex_rgb(h: str) -> np.ndarray:
    h = h.lstrip("#")
    return np.array([int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4)])


def mix(a, b, t):
    return np.asarray(a) * (1 - t) + np.asarray(b) * t


@dataclass
class Mesh:
    verts: list = field(default_factory=list)    # (3,3) arrays
    normals: list = field(default_factory=list)  # (3,3) vertex normals
    colors: list = field(default_factory=list)   # rgb 0..1
    parts: list = field(default_factory=list)    # int, for outlines
    flags: list = field(default_factory=list)    # bit0 double-sided, bit1 unlit, bit2 no-shadow, bit3 no-outline
    _part: int = 0

    def new_part(self) -> int:
        self._part += 1
        return self._part

    # -- low level --------------------------------------------------------
    def tri(self, a, b, c, color, normal=None, part=None, flags=0, vnormals=None, center=None):
        a, b, c = (np.asarray(p, dtype=np.float64) for p in (a, b, c))
        if vnormals is None:
            n = np.cross(b - a, c - a)
            ln = np.linalg.norm(n)
            if ln < 1e-12:
                return
            n = n / ln
            if normal is not None:
                if np.dot(n, normal) < 0:
                    n = -n
            elif center is not None:
                if np.dot(n, (a + b + c) / 3 - np.asarray(center)) < 0:
                    n = -n
            vn = np.array([n, n, n])
        else:
            vn = np.asarray(vnormals, dtype=np.float64)
        self.verts.append(np.array([a, b, c]))
        self.normals.append(vn)
        self.colors.append(np.asarray(color, dtype=np.float64)[:3])
        self.parts.append(self._part if part is None else part)
        self.flags.append(flags)

    def poly(self, pts, color, normal=None, part=None, flags=0, center=None):
        """Convex polygon as a triangle fan."""
        pts = [np.asarray(p, dtype=np.float64) for p in pts]
        if normal is None and center is None:
            normal = np.cross(pts[1] - pts[0], pts[2] - pts[0])
        for i in range(1, len(pts) - 1):
            self.tri(pts[0], pts[i], pts[i + 1], color, normal=normal, part=part, flags=flags, center=center)

    # -- primitives -------------------------------------------------------
    def box(self, x0, y0, z0, x1, y1, z1, color, top=None, part=None, flags=0, side_x=None, side_y=None):
        p = self.new_part() if part is None else part
        c = np.asarray(color)
        top = c if top is None else np.asarray(top)
        sx = c if side_x is None else np.asarray(side_x)
        sy = c if side_y is None else np.asarray(side_y)
        P = lambda x, y, z: (x, y, z)
        self.poly([P(x0, y0, z1), P(x1, y0, z1), P(x1, y1, z1), P(x0, y1, z1)], top, normal=(0, 0, 1), part=p, flags=flags)
        self.poly([P(x1, y0, z0), P(x1, y1, z0), P(x1, y1, z1), P(x1, y0, z1)], sx, normal=(1, 0, 0), part=p, flags=flags)
        self.poly([P(x0, y1, z0), P(x1, y1, z0), P(x1, y1, z1), P(x0, y1, z1)], sy, normal=(0, 1, 0), part=p, flags=flags)
        # Back faces are culled but kept for shadows.
        self.poly([P(x0, y0, z0), P(x0, y1, z0), P(x0, y1, z1), P(x0, y0, z1)], c, normal=(-1, 0, 0), part=p, flags=flags)
        self.poly([P(x0, y0, z0), P(x1, y0, z0), P(x1, y0, z1), P(x0, y0, z1)], c, normal=(0, -1, 0), part=p, flags=flags)
        return p

    def gable_roof(self, x0, y0, x1, y1, z0, h, color, ridge="x", overhang=0.12, gable_color=None, part=None):
        """Two sloped planes meeting at a ridge parallel to `ridge` axis."""
        p = self.new_part() if part is None else part
        o = overhang
        gx0, gy0, gx1, gy1 = x0 - o, y0 - o, x1 + o, y1 + o
        gc = color if gable_color is None else gable_color
        if ridge == "x":
            ym = (y0 + y1) / 2
            r0, r1 = (gx0, ym, z0 + h), (gx1, ym, z0 + h)
            self.poly([(gx0, gy1, z0), (gx1, gy1, z0), r1, r0], color, center=((x0 + x1) / 2, ym, z0), part=p)
            self.poly([(gx0, gy0, z0), (gx1, gy0, z0), r1, r0], color, center=((x0 + x1) / 2, ym, z0), part=p)
            self.tri((x1, y0, z0), (x1, y1, z0), (x1, ym, z0 + h), gc, normal=(1, 0, 0), part=p)
            self.tri((x0, y0, z0), (x0, y1, z0), (x0, ym, z0 + h), gc, normal=(-1, 0, 0), part=p)
        else:
            xm = (x0 + x1) / 2
            r0, r1 = (xm, gy0, z0 + h), (xm, gy1, z0 + h)
            self.poly([(gx1, gy0, z0), (gx1, gy1, z0), r1, r0], color, center=(xm, (y0 + y1) / 2, z0), part=p)
            self.poly([(gx0, gy0, z0), (gx0, gy1, z0), r1, r0], color, center=(xm, (y0 + y1) / 2, z0), part=p)
            self.tri((x0, y1, z0), (x1, y1, z0), (xm, y1, z0 + h), gc, normal=(0, 1, 0), part=p)
            self.tri((x0, y0, z0), (x1, y0, z0), (xm, y0, z0 + h), gc, normal=(0, -1, 0), part=p)
        return p

    def hip_roof(self, x0, y0, x1, y1, z0, h, color, overhang=0.12, part=None, apex_inset=None):
        p = self.new_part() if part is None else part
        o = overhang
        a = (x0 - o, y0 - o, z0)
        b = (x1 + o, y0 - o, z0)
        c = (x1 + o, y1 + o, z0)
        d = (x0 - o, y1 + o, z0)
        cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
        if apex_inset is None:
            ins = min(x1 - x0, y1 - y0) / 2
        else:
            ins = apex_inset
        dx = max(0.0, (x1 - x0) / 2 - ins)
        dy = max(0.0, (y1 - y0) / 2 - ins)
        t0 = (cx - dx, cy - dy, z0 + h)
        t1 = (cx + dx, cy - dy, z0 + h)
        t2 = (cx + dx, cy + dy, z0 + h)
        t3 = (cx - dx, cy + dy, z0 + h)
        ctr = (cx, cy, z0)
        for q in ([a, b, t1, t0], [b, c, t2, t1], [c, d, t3, t2], [d, a, t0, t3]):
            pts = [q[0], q[1], q[2]] + ([q[3]] if q[2] != q[3] else [])
            self.poly(pts, color, center=ctr, part=p)
        if dx > 0 or dy > 0:
            self.poly([t0, t1, t2, t3], color, normal=(0, 0, 1), part=p)
        return p

    def cylinder(self, cx, cy, z0, z1, r, color, segs=20, top=None, part=None, flags=0, ry=None, r_top=None):
        p = self.new_part() if part is None else part
        ry = r if ry is None else ry
        rt = r if r_top is None else r_top
        rty = ry * (rt / r) if r > 0 else rt
        top = color if top is None else top
        ring0, ring1, norms = [], [], []
        for i in range(segs):
            a = 2 * math.pi * i / segs
            ca, sa = math.cos(a), math.sin(a)
            ring0.append((cx + r * ca, cy + ry * sa, z0))
            ring1.append((cx + rt * ca, cy + rty * sa, z1))
            slope = (r - rt) / max(1e-6, (z1 - z0))
            n = np.array([ca, sa, slope])
            norms.append(n / np.linalg.norm(n))
        for i in range(segs):
            j = (i + 1) % segs
            vn = [norms[i], norms[j], norms[j]]
            self.tri(ring0[i], ring0[j], ring1[j], color, vnormals=vn, part=p, flags=flags)
            self.tri(ring0[i], ring1[j], ring1[i], color, vnormals=[norms[i], norms[j], norms[i]], part=p, flags=flags)
        if rt > 0.001:
            self.poly(ring1, top, normal=(0, 0, 1), part=p, flags=flags)
        return p

    def cone(self, cx, cy, z0, h, r, color, segs=20, part=None, ry=None):
        p = self.new_part() if part is None else part
        ry = r if ry is None else ry
        apex = (cx, cy, z0 + h)
        for i in range(segs):
            a0 = 2 * math.pi * i / segs
            a1 = 2 * math.pi * (i + 1) / segs
            p0 = (cx + r * math.cos(a0), cy + ry * math.sin(a0), z0)
            p1 = (cx + r * math.cos(a1), cy + ry * math.sin(a1), z0)
            n0 = np.array([math.cos(a0) * h, math.sin(a0) * h, r]); n0 /= np.linalg.norm(n0)
            n1 = np.array([math.cos(a1) * h, math.sin(a1) * h, r]); n1 /= np.linalg.norm(n1)
            nm = (n0 + n1); nm /= np.linalg.norm(nm)
            self.tri(p0, p1, apex, color, vnormals=[n0, n1, nm], part=p)
        return p

    def ellipsoid(self, cx, cy, cz, rx, ry, rz, color, segs=16, rings=10, part=None, flags=0, zmin=None):
        p = self.new_part() if part is None else part
        pts = []
        nrm = []
        for i in range(rings + 1):
            th = math.pi * i / rings
            row, nrow = [], []
            for j in range(segs):
                ph = 2 * math.pi * j / segs
                x = math.sin(th) * math.cos(ph)
                y = math.sin(th) * math.sin(ph)
                z = math.cos(th)
                pz = cz + rz * z
                if zmin is not None:
                    pz = max(pz, zmin)
                row.append((cx + rx * x, cy + ry * y, pz))
                n = np.array([x / rx, y / ry, z / rz])
                nrow.append(n / (np.linalg.norm(n) + 1e-12))
            pts.append(row)
            nrm.append(nrow)
        for i in range(rings):
            for j in range(segs):
                k = (j + 1) % segs
                a, b, c, d = pts[i][j], pts[i][k], pts[i + 1][k], pts[i + 1][j]
                na, nb, nc, nd = nrm[i][j], nrm[i][k], nrm[i + 1][k], nrm[i + 1][j]
                if i > 0:
                    self.tri(a, b, c, color, vnormals=[na, nb, nc], part=p, flags=flags)
                if i < rings - 1:
                    self.tri(a, c, d, color, vnormals=[na, nc, nd], part=p, flags=flags)
        return p

    def flat(self, pts2d, z, color, part=None, flags=0):
        """Flat horizontal convex polygon at height z."""
        return self.poly([(x, y, z) for x, y in pts2d], color, normal=(0, 0, 1), part=part, flags=flags)

    def plane_quad(self, origin, u, v, w, h, color, part=None, flags=0, normal=None):
        o = np.asarray(origin, float); u = np.asarray(u, float); v = np.asarray(v, float)
        self.poly([o, o + u * w, o + u * w + v * h, o + v * h], color, normal=normal, part=part, flags=flags)

    def facade_poly(self, face: str, x0, y0, x1, y1, pts_uv, color, offset=0.012, part=None, flags=0):
        """Draw a 2D polygon (u,v in [0,1]) onto a vertical face of a box.
        face '+x' : plane x=x1, u along -y->+y? (u from y1 to y0 so it reads left-to-right on screen)
        face '+y' : plane y=y1, u along x0->x1."""
        out = []
        for (u, v) in pts_uv:
            if face == "+y":
                out.append((x0 + (x1 - x0) * u, y1 + offset, v))
            else:
                out.append((x1 + offset, y1 - (y1 - y0) * u, v))
        n = (0, 1, 0) if face == "+y" else (1, 0, 0)
        self.poly(out, color, normal=n, part=part, flags=flags)

    def extend(self, other: "Mesh", dx=0.0, dy=0.0, dz=0.0):
        off = np.array([dx, dy, dz])
        base = self._part
        for v, n, c, pa, fl in zip(other.verts, other.normals, other.colors, other.parts, other.flags):
            self.verts.append(v + off)
            self.normals.append(n)
            self.colors.append(c)
            self.parts.append(pa + base)
            self.flags.append(fl)
        self._part = base + other._part


def project(v: np.ndarray, scale: float) -> np.ndarray:
    """(...,3) world -> (...,2) art pixels."""
    sx = (v[..., 0] - v[..., 1]) * HALF_W * scale
    sy = (v[..., 0] + v[..., 1]) * HALF_H * scale - v[..., 2] * Z_UNIT * scale
    return np.stack([sx, sy], axis=-1)


def _raster_tri(p, inside_cb, W, H):
    x0 = max(int(math.floor(p[:, 0].min())), 0)
    x1 = min(int(math.ceil(p[:, 0].max())) + 1, W)
    y0 = max(int(math.floor(p[:, 1].min())), 0)
    y1 = min(int(math.ceil(p[:, 1].max())) + 1, H)
    if x0 >= x1 or y0 >= y1:
        return None
    xs = np.arange(x0, x1) + 0.5
    ys = np.arange(y0, y1) + 0.5
    X, Y = np.meshgrid(xs, ys)
    (ax, ay), (bx, by), (cx, cy) = p
    area = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
    if abs(area) < 1e-9:
        return None
    w0 = ((bx - X) * (cy - Y) - (by - Y) * (cx - X)) / area
    w1 = ((cx - X) * (ay - Y) - (cy - Y) * (ax - X)) / area
    w2 = 1.0 - w0 - w1
    eps = -1e-7
    inside = (w0 >= eps) & (w1 >= eps) & (w2 >= eps)
    if not inside.any():
        return None
    return x0, x1, y0, y1, w0, w1, w2, inside


@dataclass
class Sprite:
    image: Image.Image
    anchor: tuple            # pixel of the footprint ground centre
    shadow: Image.Image | None
    shadow_anchor: tuple | None


def render(mesh: Mesh, footprint=(1, 1), scale=2.0, ss=3, outline=True, shadow=True, shadow_alpha=0.30) -> Sprite:
    V = np.array(mesh.verts)               # (N,3,3)
    if len(V) == 0:
        raise ValueError("empty mesh")
    N = np.array(mesh.normals)
    C = np.array(mesh.colors)
    PART = np.array(mesh.parts)
    FL = np.array(mesh.flags)
    S = scale * ss
    P2 = project(V, S)                     # (N,3,2)
    fw, fh = footprint
    anchor_world = np.array([fw / 2, fh / 2, 0.0])
    a2 = project(anchor_world, S)
    # Canvas covering geometry + the footprint diamond.
    fp = project(np.array([[0, 0, 0], [fw, 0, 0], [fw, fh, 0], [0, fh, 0]], float), S)
    allp = np.concatenate([P2.reshape(-1, 2), fp])
    pad = 4 * ss
    mn = np.floor(allp.min(axis=0)) - pad
    mx = np.ceil(allp.max(axis=0)) + pad
    # Align canvas origin to ss so downsampling keeps the anchor exact.
    mn = np.floor(mn / ss) * ss
    mx = np.ceil(mx / ss) * ss
    W, H = int(mx[0] - mn[0]), int(mx[1] - mn[1])
    P2 = P2 - mn
    depth = V @ VIEW                       # (N,3)
    zbuf = np.full((H, W), -np.inf)
    base = np.zeros((H, W, 3))
    nbuf = np.zeros((H, W, 3))
    hbuf = np.zeros((H, W))
    pbuf = np.full((H, W), -1, dtype=np.int32)
    ubuf = np.zeros((H, W), dtype=bool)   # unlit
    obuf = np.zeros((H, W), dtype=bool)   # no outline
    face_n = np.cross(V[:, 1] - V[:, 0], V[:, 2] - V[:, 0])
    for i in range(len(V)):
        fn = N[i].mean(axis=0)
        facing = float(np.dot(fn, VIEW))
        dbl = bool(FL[i] & 1)
        if facing <= 1e-6 and not dbl:
            continue
        r = _raster_tri(P2[i], None, W, H)
        if r is None:
            continue
        x0, x1, y0, y1, w0, w1, w2, inside = r
        d = depth[i]
        z = w0 * d[0] + w1 * d[1] + w2 * d[2]
        sub = zbuf[y0:y1, x0:x1]
        m = inside & (z > sub + 1e-6)
        if not m.any():
            continue
        sub[m] = z[m]
        base[y0:y1, x0:x1][m] = C[i]
        nn = (w0[..., None] * N[i][0] + w1[..., None] * N[i][1] + w2[..., None] * N[i][2])
        if dbl and facing < 0:
            nn = -nn
        nbuf[y0:y1, x0:x1][m] = nn[m]
        hz = w0 * V[i][0][2] + w1 * V[i][1][2] + w2 * V[i][2][2]
        hbuf[y0:y1, x0:x1][m] = hz[m]
        pbuf[y0:y1, x0:x1][m] = PART[i]
        ubuf[y0:y1, x0:x1][m] = bool(FL[i] & 2)
        obuf[y0:y1, x0:x1][m] = bool(FL[i] & 8)
    alpha = np.isfinite(zbuf)
    # ---- deferred shading ------------------------------------------------
    nl = np.linalg.norm(nbuf, axis=2, keepdims=True)
    nrm = nbuf / np.maximum(nl, 1e-9)
    diff = np.clip(nrm @ SUN, 0, 1)
    fill = np.clip(nrm @ FILL, 0, 1)
    sky = 0.5 + 0.5 * nrm[..., 2]
    light = (SKY_COLOR * (0.57 + 0.14 * sky)[..., None]
             + SUN_COLOR * (0.55 * diff)[..., None]
             + FILL_COLOR * (0.14 * fill)[..., None])
    # Gentle specular highlight for rounded surfaces.
    half = SUN + VIEW
    half = half / np.linalg.norm(half)
    spec = np.clip(nrm @ half, 0, 1) ** 24 * 0.10
    col = base * light + spec[..., None]
    # Contact occlusion near the ground.
    ao = 1.0 - 0.22 * np.exp(-np.maximum(hbuf, 0) / 0.10)
    col = col * ao[..., None]
    col = np.where(ubuf[..., None], base, col)
    # Internal outlines where parts meet (thickness ~ss px => ~1px final).
    if outline:
        edge = np.zeros((H, W), dtype=bool)
        for (sy, sx) in ((0, 1), (1, 0)):
            a = pbuf[: H - sy, : W - sx]
            b = pbuf[sy:, sx:]
            e = (a != b) & (a >= 0) & (b >= 0)
            edge[: H - sy, : W - sx] |= e
            edge[sy:, sx:] |= e
        edge &= ~obuf
        if ss > 1:
            k = max(1, ss // 2)
            e2 = edge.copy()
            for dy in range(-k, k + 1):
                for dx in range(-k, k + 1):
                    e2 |= np.roll(np.roll(edge, dy, 0), dx, 1)
            edge = e2 & alpha
        col = np.where(edge[..., None], col * 0.62, col)
    col = np.clip(col, 0, 1)
    # ---- downsample (premultiplied area average) ------------------------
    a = alpha.astype(np.float64)
    pm = col * a[..., None]
    h2, w2 = H // ss, W // ss
    pm = pm[: h2 * ss, : w2 * ss].reshape(h2, ss, w2, ss, 3).mean(axis=(1, 3))
    aa = a[: h2 * ss, : w2 * ss].reshape(h2, ss, w2, ss).mean(axis=(1, 3))
    rgb = np.where(aa[..., None] > 0, pm / np.maximum(aa[..., None], 1e-9), 0)
    img = np.zeros((h2, w2, 4), dtype=np.float32)
    img[..., :3] = rgb * 255
    img[..., 3] = aa * 255
    anchor = ((a2[0] - mn[0]) / ss, (a2[1] - mn[1]) / ss)
    if outline:
        img = _silhouette(img)
    im = Image.fromarray(np.clip(img, 0, 255).astype(np.uint8), "RGBA")
    im, anchor = _crop(im, anchor, 2)
    sh, sh_anchor = (None, None)
    if shadow:
        sh, sh_anchor = _shadow(V, FL, footprint, scale, shadow_alpha)
    return Sprite(im, anchor, sh, sh_anchor)


def _silhouette(img: np.ndarray) -> np.ndarray:
    a = img[..., 3] / 255.0
    grown = a.copy()
    for dy, dx in ((-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, 1), (-1, 1), (1, -1)):
        w = 1.0 if dx == 0 or dy == 0 else 0.6
        grown = np.maximum(grown, np.roll(np.roll(a, dy, 0), dx, 1) * w)
    ring = np.clip(grown - a, 0, 1) * 0.85
    out = img.copy()
    # Composite sprite over outline.
    oa = ring
    sa = a
    total = sa + oa * (1 - sa)
    for c in range(3):
        out[..., c] = np.where(total > 0, (img[..., c] * sa + OUTLINE_RGB[c] * oa * (1 - sa)) / np.maximum(total, 1e-9), 0)
    out[..., 3] = total * 255
    return out


def _crop(im: Image.Image, anchor, pad):
    bbox = im.getbbox()
    if bbox is None:
        return im, anchor
    x0, y0, x1, y1 = bbox
    x0 = max(0, x0 - pad); y0 = max(0, y0 - pad)
    x1 = min(im.width, x1 + pad); y1 = min(im.height, y1 + pad)
    return im.crop((x0, y0, x1, y1)), (round(anchor[0] - x0, 2), round(anchor[1] - y0, 2))


def _shadow(V, FL, footprint, scale, alpha_k):
    keep = (FL & 4) == 0
    V = V[keep]
    if len(V) == 0:
        return None, None
    # Project along the sun onto z=0.
    t = V[..., 2:3] / SUN[2]
    G = V - SUN * t
    G[..., 2] = 0
    P = project(G, scale)
    fw, fh = footprint
    a2 = project(np.array([fw / 2, fh / 2, 0.0]), scale)
    pad = 12 * scale
    mn = np.floor(P.reshape(-1, 2).min(axis=0)) - pad
    mx = np.ceil(P.reshape(-1, 2).max(axis=0)) + pad
    W, H = int(mx[0] - mn[0]), int(mx[1] - mn[1])
    P = P - mn
    mask = np.zeros((H, W), dtype=bool)
    for i in range(len(P)):
        r = _raster_tri(P[i], None, W, H)
        if r is None:
            continue
        x0, x1, y0, y1, *_rest, inside = r
        mask[y0:y1, x0:x1] |= inside
    im = Image.fromarray((mask * 255).astype(np.uint8), "L").filter(ImageFilter.GaussianBlur(radius=2.2 * scale))
    a = np.asarray(im, dtype=np.float32) * alpha_k
    rgba = np.zeros((H, W, 4), dtype=np.uint8)
    rgba[..., 0] = 22; rgba[..., 1] = 40; rgba[..., 2] = 30
    rgba[..., 3] = np.clip(a, 0, 255).astype(np.uint8)
    out = Image.fromarray(rgba, "RGBA")
    anchor = (a2[0] - mn[0], a2[1] - mn[1])
    return _crop(out, anchor, 1)
