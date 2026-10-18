#!/usr/bin/env node
// FlyCms 应用探针：验收 S7b 调用，检查「装起来能用」而不是「端口能连」。
//
// 环境（由 box-accept.mjs 注入）：
//   BASE_URL    浏览器侧基地址（--base auto 时是入口容器 web 的 IP，走 nginx）
//   ACCEPT_OUT  验收证据目录
//
// 退出码：0 全部通过；1 有断言失败。每条断言都打印成一行，便于贴进 EVIDENCE.md。
const BASE = (process.env.BASE_URL || '').replace(/\/+$/, '');
const OUT = process.env.ACCEPT_OUT || '';

if (!BASE) {
  console.error('缺少 BASE_URL');
  process.exit(1);
}

const results = [];
function check(name, ok, detail = '') {
  results.push({ name, ok: Boolean(ok), detail });
  console.log(`${ok ? '✓' : '✗'} ${name}${detail ? ` — ${detail}` : ''}`);
}

async function get(pathname) {
  const url = `${BASE}${pathname}`;
  const res = await fetch(url, { redirect: 'manual' });
  const body = await res.text();
  return { url, status: res.status, body };
}

try {
  // 1) 健康检查：不依赖外部组件的存活探针
  const health = await get('/api/health');
  let healthJson = null;
  try { healthJson = JSON.parse(health.body); } catch { /* 非 JSON 就是失败，下面自然报 */ }
  check(
    'GET /api/health 返回 UP',
    health.status === 200 && healthJson?.code === 0 && healthJson?.data?.status === 'UP',
    `HTTP ${health.status} ${healthJson ? JSON.stringify(healthJson.data) : health.body.slice(0, 80)}`,
  );

  // 2) 就绪检查：数据库与缓存都通（首次启动建库失败会卡在这一步）
  const ready = await get('/api/ready');
  let readyJson = null;
  try { readyJson = JSON.parse(ready.body); } catch { /* 同上 */ }
  check(
    'GET /api/ready 数据库与缓存均 UP',
    ready.status === 200 && readyJson?.data?.checks?.database === 'UP' && readyJson?.data?.checks?.cache === 'UP',
    `HTTP ${ready.status} ${readyJson ? JSON.stringify(readyJson.data?.checks) : ready.body.slice(0, 80)}`,
  );

  // 3) 门户前台：能渲染出页面，且是中文界面
  const home = await get('/');
  const homeIsPortal = home.status === 200 && /<title>/.test(home.body) && /[\u4e00-\u9fa5]/.test(home.body);
  check('GET / 门户前台可渲染且含中文', homeIsPortal, `HTTP ${home.status}，${home.body.length} 字节`);

  // 4) 上游 demo 数据没有问答模型，主题里的 /questions/ 硬链接必须在构建期删干净。
  //    这条断言把「死链已消失」钉死在验收里，避免以后改模板时静默回退。
  const deadLinks = (home.body.match(/href="\/questions\/"/g) || []).length;
  check('门户页无 /questions/ 死链', deadLinks === 0, `残留 ${deadLinks} 处`);

  // 5) 管理后台 SPA：入口容器（nginx）必须把 /admin/ 出成 Console 外壳，而不是后端 404 页
  const admin = await get('/admin/');
  const adminIsSpa = admin.status === 200 && /FlyCms Console/i.test(admin.body);
  check('GET /admin/ 出后台 SPA 外壳', adminIsSpa, `HTTP ${admin.status}，${(admin.body.match(/<title>([^<]*)<\/title>/) || [])[1] || '无标题'}`);

  // 6) 列表页：栏目内容可用（种子数据导入成功的最直接证据）
  const news = await get('/news/');
  const newsOk = news.status === 200 && /[\u4e00-\u9fa5]/.test(news.body);
  check('GET /news/ 栏目列表可用', newsOk, `HTTP ${news.status}，${news.body.length} 字节`);
} catch (err) {
  check('探针执行', false, `异常：${err?.message || err}`);
}

const failed = results.filter((r) => !r.ok);
console.log(`\n合计 ${results.length} 项，失败 ${failed.length} 项`);

if (OUT) {
  try {
    const fs = await import('node:fs');
    fs.writeFileSync(
      `${OUT}/probe.json`,
      JSON.stringify({ base: BASE, at: new Date().toISOString(), results }, null, 2),
    );
  } catch (err) {
    console.error(`写 probe.json 失败：${err?.message || err}`);
  }
}

process.exit(failed.length === 0 ? 0 : 1);
