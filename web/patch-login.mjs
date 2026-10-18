#!/usr/bin/env node
// 构建期清理上游 vben 模板遗留：把「别人的备案号」和「点了没反应的演示登录入口」从后台去掉。
//
// 为什么必须在源码层改而不是运行时藏：
//   - 备案号来自 @vben/preferences 的 copyright 默认值（闽ICP备19024351号 / Copyright © 2024 Vben），
//     它是被 web-antd 的 preferences.ts 显式覆盖进来的，关掉要在覆盖点改。
//   - 手机号登录 / 扫码登录 / 其他登录方式（微信·GitHub·Google）是 AuthenticationLogin 组件的
//     prop 默认值 true，FlyCms 的后台并没有实现这些流程，留着就是点了没反应。
//
// 每条替换都断言命中次数：上游改了结构就让构建失败，避免「补丁悄悄失效、备案号又回到截图里」。

import { readFileSync, writeFileSync } from 'node:fs';

// 构建镜像里源码固定在 /src/frontend；本地实测时用 PATCH_ROOT 指向一份等价目录。
const root = process.env.PATCH_ROOT ?? '/src/frontend';

function patch(relPath, edits) {
  const path = `${root}/${relPath}`;
  let src = readFileSync(path, 'utf8');
  for (const { from, to, expect = 1, note } of edits) {
    const hit = src.split(from).length - 1;
    if (hit !== expect) {
      throw new Error(
        `[patch-login] ${relPath}: 期望命中 ${expect} 次，实际 ${hit} 次 —— ${note}`,
      );
    }
    src = src.split(from).join(to);
  }
  writeFileSync(path, src);
  console.log(`[patch-login] 已改写 ${relPath}`);
}

// 1) 关掉版权条：companyName/enable/icp 全清，并禁止用户在偏好设置里再打开。
patch('apps/web-antd/src/preferences.ts', [
  {
    from: '  copyright: appCopyrightPreferences,',
    to: `  // 上游这里放的是 vben 模板自己的备案号与版权（闽ICP备19024351号 / Copyright © 2024 Vben），
  // 商店审核会把它当成应用方信息，因此整套关掉；settingShow 置 false 防止从偏好设置里再打开。
  copyright: {
    companyName: 'FlyCms',
    companySiteLink: '',
    date: '',
    enable: false,
    icp: '',
    icpLink: '',
    settingShow: false,
  },`,
    note: 'web-antd preferences.ts 里的 copyright 覆盖点变了',
  },
  {
    from: '  appCopyrightPreferences,\n',
    to: '',
    note: 'copyright 覆盖改成字面量后，这个导入应随之删除',
  },
]);

// 2) 关掉四个没实现的登录入口（验证码登录 / 忘记密码 / 二维码登录 / 注册 / 第三方登录）。
patch('apps/web-antd/src/views/_core/authentication/login.vue', [
  {
    from: '    :loading="authStore.loginLoading"\n',
    to: `    :loading="authStore.loginLoading"
    :show-code-login="false"
    :show-forget-password="false"
    :show-qrcode-login="false"
    :show-register="false"
    :show-third-party-login="false"
`,
    note: 'AuthenticationLogin 的调用点变了',
  },
]);

// 3) 换掉语言包里的模板宣传语：登录页会原样显示这两句，留着就是「这是 vben 模板」的自证。
patch('packages/locales/src/langs/zh-CN/authentication.json', [
  {
    from: '开箱即用的大型中后台管理系统',
    to: 'FlyCms 网站管理系统',
    note: 'zh-CN.json 里登录页副标题变了',
  },
  {
    from: '工程化、高性能、跨组件库的前端模版',
    to: '门户、内容与会员一体化后台',
    note: 'zh-CN.json 里登录页描述变了',
  },
]);

// 3) 断言补丁真的落到了产物源码里，避免上面某步被上游重构绕过。
const prefs = readFileSync(`${root}/apps/web-antd/src/preferences.ts`, 'utf8');
if (!prefs.includes('enable: false') || prefs.includes('appCopyrightPreferences')) {
  throw new Error('[patch-login] preferences.ts 版权条未如期关闭');
}
const login = readFileSync(
  `${root}/apps/web-antd/src/views/_core/authentication/login.vue`,
  'utf8',
);
if (!login.includes(':show-third-party-login="false"')) {
  throw new Error('[patch-login] login.vue 演示登录入口未如期关闭');
}
const zh = readFileSync(`${root}/packages/locales/src/langs/zh-CN/authentication.json`, 'utf8');
if (zh.includes('跨组件库的前端模版') || zh.includes('开箱即用的大型中后台管理系统')) {
  throw new Error('[patch-login] zh-CN.json 模板宣传语未如期替换');
}
// 卖点必须与实际功能一致：上游没有商城模块（84 张表里没有 shop/order/goods 类表，
// 唯一的 fly_share_order 与电商无关）。文案出现「商城」就是虚假宣传，审核会抓。
if (zh.includes('商城')) {
  throw new Error('[patch-login] 文案里出现「商城」，但上游没有商城模块');
}
console.log('[patch-login] 模板遗留清理完成');
