-- 002：把上游 jar（ModelDao 的 base_column）要求、但 09-28 基线 SQL 里缺失的
-- fly_model 列补齐。
--
-- 根因：上游基线 sql/flycms_20260928_093335.sql 落后于代码。代码里
--   backend/src/main/resources/mapper/model__ModelDao.xml 的 base_column 明确 select
--   use_content, use_seo, enable_comment, enable_submit, form_tabs, form_default_tab
-- 而基线建表语句里没有这些列 → 首页（前台读模型配置）直接
--   java.sql.SQLSyntaxErrorException: Unknown column 'use_seo' in 'field list'
-- → HTTP 500。后台 /admin 不走这条查询，所以后台一直正常，问题只在门户前台。
--
-- 写法说明：MySQL 不支持 ADD COLUMN IF NOT EXISTS，这里用 information_schema +
-- PREPARE 做幂等判断，重复执行安全（001 已加过 use_content 的情况也覆盖）。

SET @db := DATABASE();

SET @s := (SELECT IF(COUNT(*) = 0,
  'ALTER TABLE `fly_model` ADD COLUMN `use_content` tinyint(1) NOT NULL DEFAULT 1 COMMENT ''前台按模型生成栏目内容页：1=是''',
  'DO 0')
  FROM information_schema.columns
  WHERE table_schema = @db AND table_name = 'fly_model' AND column_name = 'use_content');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;

SET @s := (SELECT IF(COUNT(*) = 0,
  'ALTER TABLE `fly_model` ADD COLUMN `use_seo` tinyint(1) NOT NULL DEFAULT 0 COMMENT ''启用模型级 SEO 配置：1=是''',
  'DO 0')
  FROM information_schema.columns
  WHERE table_schema = @db AND table_name = 'fly_model' AND column_name = 'use_seo');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;

SET @s := (SELECT IF(COUNT(*) = 0,
  'ALTER TABLE `fly_model` ADD COLUMN `enable_comment` tinyint(1) NOT NULL DEFAULT 0 COMMENT ''内容页允许评论：1=是''',
  'DO 0')
  FROM information_schema.columns
  WHERE table_schema = @db AND table_name = 'fly_model' AND column_name = 'enable_comment');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;

SET @s := (SELECT IF(COUNT(*) = 0,
  'ALTER TABLE `fly_model` ADD COLUMN `enable_submit` tinyint(1) NOT NULL DEFAULT 0 COMMENT ''内容允许前台投稿：1=是''',
  'DO 0')
  FROM information_schema.columns
  WHERE table_schema = @db AND table_name = 'fly_model' AND column_name = 'enable_submit');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;

SET @s := (SELECT IF(COUNT(*) = 0,
  'ALTER TABLE `fly_model` ADD COLUMN `form_tabs` varchar(500) DEFAULT NULL COMMENT ''后台表单分组标签配置（JSON）''',
  'DO 0')
  FROM information_schema.columns
  WHERE table_schema = @db AND table_name = 'fly_model' AND column_name = 'form_tabs');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;

SET @s := (SELECT IF(COUNT(*) = 0,
  'ALTER TABLE `fly_model` ADD COLUMN `form_default_tab` varchar(64) DEFAULT NULL COMMENT ''后台表单默认标签''',
  'DO 0')
  FROM information_schema.columns
  WHERE table_schema = @db AND table_name = 'fly_model' AND column_name = 'form_default_tab');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;
