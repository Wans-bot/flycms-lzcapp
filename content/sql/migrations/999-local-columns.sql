-- 999：本地兜底补列（最后执行，排在所有 2026-* 上游迁移之后）。
--
-- 为什么需要它：上游 FlyCms 的 Java 代码一直领先于它自己的 SQL。
--   1) 基线 sql/flycms_20260928_093335.sql 缺 fly_model.use_content/use_seo/
--      enable_comment/enable_submit/form_tabs/form_default_tab；
--   2) 基线还缺 fly_model_field.relate_model/is_unique；
--   3) sql/migrations/2026-09-28-model-field-structure.sql 里虽然有
--      parent_id/visible_when/rollup_expr/lookup_fields 的 ALTER，但它的
--      “已存在就跳过”判断在干净库上会误判，整段被跳过；formula 更是上游任何
--      SQL 都没定义过。
--   结果就是门户首页第一条 select（model__ModelFieldDao.xml 的 base_column）
--   直接报 Unknown column 'xxx' in 'field list' → HTTP 500。后台 /admin 不走
--   这条查询，所以后台一直正常，故障只在门户前台（2026-10-22/23 实机验收）。
--
-- MySQL 没有 ADD COLUMN IF NOT EXISTS，这里统一用 information_schema 实测 +
-- PREPARE 执行，重复跑安全（幂等），也可以安全地在已有数据的老库上执行。

SET @s := (SELECT IF(COUNT(*) = 0,
  'ALTER TABLE `fly_model` ADD COLUMN `use_content` tinyint(1) NOT NULL DEFAULT 0 COMMENT ''前台按模型生成栏目内容页：1=是''',
  'DO 0')
  FROM information_schema.columns
  WHERE table_schema = DATABASE() AND table_name = 'fly_model' AND column_name = 'use_content');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;

SET @s := (SELECT IF(COUNT(*) = 0,
  'ALTER TABLE `fly_model` ADD COLUMN `use_seo` tinyint(1) NOT NULL DEFAULT 0 COMMENT ''启用模型级 SEO 配置：1=是''',
  'DO 0')
  FROM information_schema.columns
  WHERE table_schema = DATABASE() AND table_name = 'fly_model' AND column_name = 'use_seo');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;

SET @s := (SELECT IF(COUNT(*) = 0,
  'ALTER TABLE `fly_model` ADD COLUMN `enable_comment` tinyint(1) NOT NULL DEFAULT 0 COMMENT ''内容页允许评论：1=是''',
  'DO 0')
  FROM information_schema.columns
  WHERE table_schema = DATABASE() AND table_name = 'fly_model' AND column_name = 'enable_comment');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;

SET @s := (SELECT IF(COUNT(*) = 0,
  'ALTER TABLE `fly_model` ADD COLUMN `enable_submit` tinyint(1) NOT NULL DEFAULT 0 COMMENT ''内容允许前台投稿：1=是''',
  'DO 0')
  FROM information_schema.columns
  WHERE table_schema = DATABASE() AND table_name = 'fly_model' AND column_name = 'enable_submit');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;

SET @s := (SELECT IF(COUNT(*) = 0,
  'ALTER TABLE `fly_model` ADD COLUMN `form_tabs` varchar(500) DEFAULT NULL COMMENT ''后台表单分组标签配置（JSON）''',
  'DO 0')
  FROM information_schema.columns
  WHERE table_schema = DATABASE() AND table_name = 'fly_model' AND column_name = 'form_tabs');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;

SET @s := (SELECT IF(COUNT(*) = 0,
  'ALTER TABLE `fly_model` ADD COLUMN `form_default_tab` varchar(64) DEFAULT NULL COMMENT ''后台表单默认标签''',
  'DO 0')
  FROM information_schema.columns
  WHERE table_schema = DATABASE() AND table_name = 'fly_model' AND column_name = 'form_default_tab');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;

SET @s := (SELECT IF(COUNT(*) = 0,
  'ALTER TABLE `fly_model_field` ADD COLUMN `relate_model` varchar(255) DEFAULT NULL COMMENT ''关联模型 code（跨模型字段）''',
  'DO 0')
  FROM information_schema.columns
  WHERE table_schema = DATABASE() AND table_name = 'fly_model_field' AND column_name = 'relate_model');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;

SET @s := (SELECT IF(COUNT(*) = 0,
  'ALTER TABLE `fly_model_field` ADD COLUMN `is_unique` tinyint(1) NOT NULL DEFAULT 0 COMMENT ''1=该字段值唯一''',
  'DO 0')
  FROM information_schema.columns
  WHERE table_schema = DATABASE() AND table_name = 'fly_model_field' AND column_name = 'is_unique');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;

SET @s := (SELECT IF(COUNT(*) = 0,
  'ALTER TABLE `fly_model_field` ADD COLUMN `parent_id` bigint(20) NOT NULL DEFAULT 0 COMMENT ''父字段id（GROUP/REPEATER 子字段）''',
  'DO 0')
  FROM information_schema.columns
  WHERE table_schema = DATABASE() AND table_name = 'fly_model_field' AND column_name = 'parent_id');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;

SET @s := (SELECT IF(COUNT(*) = 0,
  'ALTER TABLE `fly_model_field` ADD COLUMN `visible_when` varchar(500) DEFAULT NULL COMMENT ''条件显隐 JSON(field/op/value)''',
  'DO 0')
  FROM information_schema.columns
  WHERE table_schema = DATABASE() AND table_name = 'fly_model_field' AND column_name = 'visible_when');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;

SET @s := (SELECT IF(COUNT(*) = 0,
  'ALTER TABLE `fly_model_field` ADD COLUMN `rollup_expr` varchar(255) DEFAULT NULL COMMENT ''Rollup 聚合 JSON(source/func/column)''',
  'DO 0')
  FROM information_schema.columns
  WHERE table_schema = DATABASE() AND table_name = 'fly_model_field' AND column_name = 'rollup_expr');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;

SET @s := (SELECT IF(COUNT(*) = 0,
  'ALTER TABLE `fly_model_field` ADD COLUMN `lookup_fields` varchar(255) DEFAULT NULL COMMENT ''Lookup 展示列 JSON''',
  'DO 0')
  FROM information_schema.columns
  WHERE table_schema = DATABASE() AND table_name = 'fly_model_field' AND column_name = 'lookup_fields');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;

SET @s := (SELECT IF(COUNT(*) = 0,
  'ALTER TABLE `fly_model_field` ADD COLUMN `formula` varchar(500) DEFAULT NULL COMMENT ''公式表达式''',
  'DO 0')
  FROM information_schema.columns
  WHERE table_schema = DATABASE() AND table_name = 'fly_model_field' AND column_name = 'formula');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;

SET @s := (SELECT IF(COUNT(*) = 0,
  'ALTER TABLE `fly_model_field` ADD COLUMN `min_value` decimal(18,4) DEFAULT NULL COMMENT ''数值区间下限''',
  'DO 0')
  FROM information_schema.columns
  WHERE table_schema = DATABASE() AND table_name = 'fly_model_field' AND column_name = 'min_value');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;

SET @s := (SELECT IF(COUNT(*) = 0,
  'ALTER TABLE `fly_model_field` ADD COLUMN `max_value` decimal(18,4) DEFAULT NULL COMMENT ''数值区间上限''',
  'DO 0')
  FROM information_schema.columns
  WHERE table_schema = DATABASE() AND table_name = 'fly_model_field' AND column_name = 'max_value');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;

-- 收尾：把实际列清单打出来，方便从容器日志里核对（mysql 客户端会打印结果集）。
SELECT 'fly_model' AS tbl, COUNT(*) AS col_count FROM information_schema.columns
  WHERE table_schema = DATABASE() AND table_name = 'fly_model'
UNION ALL
SELECT 'fly_model_field', COUNT(*) FROM information_schema.columns
  WHERE table_schema = DATABASE() AND table_name = 'fly_model_field';
