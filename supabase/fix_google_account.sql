-- 1) 「県立船橋高校ジャズバンド部」の Google アカウントの誤記を修正
--    実行前に SELECT で対象行を確認してください。
SELECT id, school_name, club_name, google_account_email
FROM public.schools
WHERE club_name LIKE '%ジャズバンド%';

UPDATE public.schools
SET google_account_email = 'fnbs.jazzband1@gmail.com'
WHERE club_name LIKE '%ジャズバンド%'
  AND school_name LIKE '%船橋%';
