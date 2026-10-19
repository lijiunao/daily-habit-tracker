# 每日习惯记录

适配手机和电脑浏览器的喝水、抽烟记录网页。每个用户有独立账户、历史看板；加入同一小组后可互相查看记录。网页由 GitHub Pages 托管，账户和记录保存在 Supabase。

## 初始化 Supabase

1. 在 Supabase 创建一个项目。
2. 打开 SQL Editor，运行 `supabase/schema.sql`。
3. 在项目的 API 设置中复制 Project URL 和 anon/publishable key，填入 `config.js` 的 `url` 和 `anonKey`。
4. 在 Authentication 的 URL Configuration 中，把 Site URL 和 Redirect URL 设置为 GitHub Pages 地址 `https://lijiunao.github.io/daily-habit-tracker/`。
5. 为了让注册后可立即登录，可在 Authentication 设置中关闭 email confirmation；若保留邮件验证，用户注册后需要先确认邮箱。

不要把 Supabase `service_role` key 放进网页或 GitHub 仓库。前端只使用 anon/publishable key，数据库通过 SQL 中的 RLS 限制每个账号可访问的数据。

## 发布到 GitHub Pages

仓库包含 `.github/workflows/pages.yml`。推送到 `main` 后会自动构建并发布。首次发布如尚未启用 Pages，可在仓库 Settings → Pages 中将 Build and deployment 的 Source 设为 GitHub Actions。

网页地址：<https://lijiunao.github.io/daily-habit-tracker/>

## 数据共享

注册需要邮箱和至少 8 位密码。用户默认只能看自己的记录；创建小组后分享 24 位邀请码，组员加入后可以互相查看每日记录。只有群组 RPC 能返回组员记录；RLS 限制其他账号读取这些表。

## 隐私

本仓库不包含用户数据。请勿提交本地数据库、密码、Supabase `service_role` key 或任何个人记录。
