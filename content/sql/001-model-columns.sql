-- FlyCms 基线（上游 2026-09-28 导出）缺这三列，而页面会直接读它们：
--   前台首页按 fly_model.use_content 决定内容渲染方式；
--   后台「模型字段」列表读 fly_model_field.relate_model / is_unique。
-- 缺列就 500。init-db.sh 的「关键列校验」正是卡在这里（2026-10-22 实机验收命中 0/3）。
-- 重复执行会报 1060（列已存在），init-db.sh 用 mysql --force 跳过，因此本文件幂等。
-- 三列分开写：一条语句里只要有一列已存在，整条都会失败。

ALTER TABLE `fly_model`
  ADD COLUMN `use_content` tinyint(1) NOT NULL DEFAULT '0' COMMENT '1=该模型的内容启用内容字段';

ALTER TABLE `fly_model_field`
  ADD COLUMN `relate_model` varchar(255) DEFAULT NULL COMMENT '关联模型 code（跨模型字段）';

ALTER TABLE `fly_model_field`
  ADD COLUMN `is_unique` tinyint(1) NOT NULL DEFAULT '0' COMMENT '1=该字段值唯一';
