-- 運営者用：組織アカウントの一覧（Supabase の SQL Editor で実行）
-- owner_email が空の行は、作成者を特定できていない団体です。
SELECT
  s.id                       AS school_id,
  s.school_name,
  s.club_name,
  u.email                    AS owner_email,
  m.full_name                AS owner_name,
  m.grade                    AS owner_grade,       -- 空（NULL）なら学年未設定
  m.is_admin                 AS owner_is_admin,
  (m.full_name LIKE '%管理者%') AS name_has_kanrisha, -- 参考。判定には使っていません
  p.plan,
  s.created_at
FROM public.schools AS s
LEFT JOIN auth.users AS u ON u.id = s.created_by
LEFT JOIN public.school_memberships AS m
  ON m.school_id = s.id AND m.user_id = s.created_by
LEFT JOIN public.school_plans AS p ON p.school_id = s.id
ORDER BY s.created_at;
