#!/usr/bin/env node
// 生成 256x256 应用图标：蓝色渐变圆角底 + 白色 F 字标。
// 不依赖任何图像库：直接写 RGBA 缓冲，再用 zlib 编码成 PNG。
const zlib = require('zlib');
const fs = require('fs');

const S = 256;
const SS = 4; // 超采样倍数，用于抗锯齿
const W = S * SS;

const buf = new Float32Array(W * W * 4); // 预乘前：r,g,b,a 在 0..1

function clamp01(v) { return v < 0 ? 0 : v > 1 ? 1 : v; }
function smoothstep(e0, e1, x) {
  const t = clamp01((x - e0) / (e1 - e0));
  return t * t * (3 - 2 * t);
}
// 圆角矩形有符号距离场（负值在内）
function sdRoundRect(px, py, cx, cy, hw, hh, r) {
  const qx = Math.abs(px - cx) - (hw - r);
  const qy = Math.abs(py - cy) - (hh - r);
  const ax = Math.max(qx, 0), ay = Math.max(qy, 0);
  return Math.hypot(ax, ay) + Math.min(Math.max(qx, qy), 0) - r;
}

// 背景：整块 256 圆角 56
const bgCx = W / 2, bgCy = W / 2, bgHw = W / 2, bgHh = W / 2, bgR = 56 * SS;
// 白色 F 字标（坐标按 256 设计稿，乘 SS）
const k = SS;
const stem = { cx: 88 * k, cy: 128 * k, hw: 16 * k, hh: 64 * k, r: 6 * k };
const topBar = { cx: 130 * k, cy: 78 * k, hw: 42 * k, hh: 16 * k, r: 6 * k };
const midBar = { cx: 122 * k, cy: 130 * k, hw: 34 * k, hh: 14 * k, r: 6 * k };

for (let y = 0; y < W; y++) {
  for (let x = 0; x < W; x++) {
    const px = x + 0.5, py = y + 0.5;
    const i = (y * W + x) * 4;

    // 底：垂直渐变 #2F6BFF → #1246C8
    const t = py / W;
    let r = 0x2f + (0x12 - 0x2f) * t;
    let g = 0x6b + (0x46 - 0x6b) * t;
    let b = 0xff + (0xc8 - 0xff) * t;

    // F 字标：三个圆角矩形并集，取最小距离
    const dF = Math.min(
      sdRoundRect(px, py, stem.cx, stem.cy, stem.hw, stem.hh, stem.r),
      sdRoundRect(px, py, topBar.cx, topBar.cy, topBar.hw, topBar.hh, topBar.r),
      sdRoundRect(px, py, midBar.cx, midBar.cy, midBar.hw, midBar.hh, midBar.r),
    );
    const aF = smoothstep(0.75 * SS, -0.75 * SS, dF);
    r = r + (255 - r) * aF;
    g = g + (255 - g) * aF;
    b = b + (255 - b) * aF;

    // 外轮廓圆角遮罩
    const dBg = sdRoundRect(px, py, bgCx, bgCy, bgHw, bgHh, bgR);
    const aBg = smoothstep(0.75 * SS, -0.75 * SS, dBg);

    buf[i] = r / 255;
    buf[i + 1] = g / 255;
    buf[i + 2] = b / 255;
    buf[i + 3] = aBg;
  }
}

// 盒式降采样 SS×SS
const out = Buffer.alloc(S * S * 4);
for (let y = 0; y < S; y++) {
  for (let x = 0; x < S; x++) {
    let r = 0, g = 0, b = 0, a = 0;
    for (let dy = 0; dy < SS; dy++) {
      for (let dx = 0; dx < SS; dx++) {
        const i = ((y * SS + dy) * W + (x * SS + dx)) * 4;
        const aa = buf[i + 3];
        r += buf[i] * aa;
        g += buf[i + 1] * aa;
        b += buf[i + 2] * aa;
        a += aa;
      }
    }
    const n = SS * SS;
    const o = (y * S + x) * 4;
    out[o] = a > 0 ? Math.round((r / a) * 255) : 0;
    out[o + 1] = a > 0 ? Math.round((g / a) * 255) : 0;
    out[o + 2] = a > 0 ? Math.round((b / a) * 255) : 0;
    out[o + 3] = Math.round((a / n) * 255);
  }
}

// ---- 最小 PNG 编码器 ----
const CRC_TABLE = (() => {
  const t = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k2 = 0; k2 < 8; k2++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c;
  }
  return t;
})();
function crc32(b) {
  let c = -1;
  for (let i = 0; i < b.length; i++) c = CRC_TABLE[(c ^ b[i]) & 0xff] ^ (c >>> 8);
  return (c ^ -1) >>> 0;
}
function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, 'latin1'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([len, body, crc]);
}

const ihdr = Buffer.alloc(13);
ihdr.writeUInt32BE(S, 0);
ihdr.writeUInt32BE(S, 4);
ihdr[8] = 8;  // bit depth
ihdr[9] = 6;  // RGBA
ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;

// 每行加 filter 字节 0
const raw = Buffer.alloc(S * (S * 4 + 1));
for (let y = 0; y < S; y++) {
  raw[y * (S * 4 + 1)] = 0;
  out.copy(raw, y * (S * 4 + 1) + 1, y * S * 4, (y + 1) * S * 4);
}

const png = Buffer.concat([
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
  chunk('IHDR', ihdr),
  chunk('IDAT', zlib.deflateSync(raw, { level: 9 })),
  chunk('IEND', Buffer.alloc(0)),
]);

const dest = process.argv[2] || 'icon.png';
fs.writeFileSync(dest, png);
console.log(`${dest}: ${S}x${S}, ${png.length} bytes`);
