#!/usr/bin/env node
// 实机验证「后台登录页」的两件事：
//   1. 密码注入真的生效——输入框里已经有 admin 账号与密码，而不是等用户手打；
//   2. vben 模板遗留真的清掉了——页面上不再出现别人的备案号与未接通的登录入口。
//
// 为什么要用浏览器而不是 curl：注入脚本由平台在入口 HTML 里拼进来，只有在浏览器里跑完
// /_lzc/injects/persist/v1 之后才会把值填进 DOM；HTTP 层只能看到「脚本被引用了」。
//
// 用法：CDP=127.0.0.1:9334 ORIGIN=https://flycms.wans.heiyu.space node tools/verify-ui.mjs
// 退出码 0 全部通过，1 有断言失败。

import { createRequire } from 'node:module';

const KB = '/lzcapp/document/智能体知识库/scripts';
const require = createRequire(`${KB}/`);
const puppeteer = require('puppeteer-core');

const CDP = process.env.CDP || '';
const ORIGIN = (process.env.ORIGIN || 'https://flycms.wans.heiyu.space').replace(/\/+$/, '');
const OUT = process.env.OUT || '/tmp/flycms-inject-check';

if (!CDP) {
  console.error('缺少 CDP（形如 127.0.0.1:9334）');
  process.exit(1);
}

const browserURL = /^https?:\/\//.test(CDP) ? CDP : `http://${CDP}`;
const results = [];
const check = (name, ok, detail = '') => {
  results.push({ name, ok: Boolean(ok), detail });
  console.log(`${ok ? '✓' : '✗'} ${name}${detail ? ` — ${detail}` : ''}`);
};

const browser = await puppeteer.connect({ browserURL, defaultViewport: { width: 1440, height: 1024 } });
// harness 的 Chrome 配置目录是复用的，普通 page 会命中上一版 SPA 的强缓存（默认 max-age 很长），
// 于是「容器里已经清干净的页面」在浏览器里还是旧文案。用独立隐身上下文 + 关缓存保证看到当次产物。
const ctx = await browser.createBrowserContext();
const page = await ctx.newPage();
await page.setCacheEnabled(false);
try {
  const url = `${ORIGIN}/admin/`;
  console.log(`打开 ${url}`);
  await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
  // 注入器要跑一轮 fetch + 等表单渲染，给它时间
  await new Promise((r) => setTimeout(r, 6000));

  const snap = await page.evaluate(() => {
    const inputs = [...document.querySelectorAll('input')].map((el) => ({
      type: el.type,
      name: el.name || el.id || '',
      placeholder: el.placeholder || '',
      value: el.value || '',
    }));
    const text = document.body ? document.body.innerText : '';
    return {
      inputs,
      text: text.slice(0, 1200),
      url: location.href,
      injected: [...document.querySelectorAll('script[src*="/_lzc/injects/"]')].map((s) => s.src),
    };
  });

  await page.screenshot({ path: `${OUT}.png`, fullPage: false });

  console.log(`页面地址：${snap.url}`);
  console.log(`注入脚本：${snap.injected.length} 个 -> ${snap.injected.join(', ') || '(无)'}`);
  console.log('输入框：');
  for (const i of snap.inputs) {
    console.log(`  - type=${i.type || '(无)'} name=${i.name} placeholder=${i.placeholder} value=${i.value}`);
  }

  const userInput = snap.inputs.find((i) => i.value === 'flycms');
  const passInput = snap.inputs.find((i) => i.type === 'password' && i.value === 'admin123');
  // 注入是否生效只在「走入口域名 + 已登录设备会话」时才能看到；
  // 走容器直连时页面里没有注入脚本，这两条断言只在 EXPECT_INJECT=1 时要求。
  const expectInject = process.env.EXPECT_INJECT === '1';
  if (expectInject) {
    check('注入脚本已加载', snap.injected.length > 0, `${snap.injected.length} 个`);
    check('用户名已自动填充', Boolean(userInput), userInput ? `value=${userInput.value}` : '没有 value=flycms 的输入框');
    check('密码已自动填充', Boolean(passInput), passInput ? 'password 输入框已有值' : 'password 输入框为空或未找到');
  } else {
    console.log(`· 跳过注入断言（EXPECT_INJECT 未置 1），注入脚本 ${snap.injected.length} 个`);
  }

  check('页面上没有别人的备案号', !snap.text.includes('19024351') && !snap.text.includes('粤ICP') && !snap.text.includes('闽ICP'));
  check('页面上没有 vben 版权字样', !snap.text.includes('Vben') && !snap.text.includes('vben.pro'));
  check('页面上没有未接通的手机号登录', !snap.text.includes('手机号登录'));
  check('页面上没有未接通的扫码登录', !snap.text.includes('扫码登录'));
  check('页面上没有第三方登录入口', !snap.text.includes('其他登录方式'));
  // 验证码的「请先完成验证」是输入框 placeholder，innerText 里没有，要连 placeholder 一起看
  check('验证码仍然保留', /请先完成验证|验证码/.test(snap.text) || snap.inputs.some((i) => /验证/.test(i.placeholder)));

  console.log('--- 页面文本片段 ---');
  console.log(snap.text.replace(/\n{2,}/g, '\n').slice(0, 400));
} catch (err) {
  check('打开后台登录页', false, String(err && err.message ? err.message : err));
} finally {
  await page.close().catch(() => {});
  await browser.disconnect().catch(() => {});
}

const failed = results.filter((r) => !r.ok);
console.log(`\n结果：${results.length - failed.length}/${results.length} 通过，截图 ${OUT}.png`);
process.exit(failed.length ? 1 : 0);
