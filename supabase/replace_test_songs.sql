-- テスト団体「あったらいいな高校 吹奏楽部」のレパートリーを、吹奏楽の曲に入れ替える。
-- この団体以外の曲には一切触りません。

-- 1) まず、今入っている曲を確認します（結果を見るだけで、何も変わりません）
SELECT s.school_name, s.club_name, g.title, g.composer, g.arranger
FROM public.schools AS s
JOIN public.songs AS g ON g.school_id = s.id
WHERE s.school_name = 'あったらいいな高校' AND s.club_name = '吹奏楽部'
ORDER BY g.sort_reading;

-- 2) 入れ替え
BEGIN;

DO $replace$
DECLARE
  v_count integer;
  v_school_id uuid;
BEGIN
  SELECT COUNT(*) INTO v_count
  FROM public.schools
  WHERE school_name = 'あったらいいな高校' AND club_name = '吹奏楽部';
  IF v_count <> 1 THEN
    RAISE EXCEPTION '対象の団体が1つに決まりません（%件）。団体名を確認してください。', v_count;
  END IF;

  SELECT id INTO v_school_id
  FROM public.schools
  WHERE school_name = 'あったらいいな高校' AND club_name = '吹奏楽部';

  -- 音源ファイルが付いた曲があるときは、ファイルが残ってしまうので中止する
  IF EXISTS (SELECT 1 FROM public.songs WHERE school_id = v_school_id AND audio_file_path IS NOT NULL) THEN
    RAISE EXCEPTION '音源ファイルが登録された曲があるため、中止しました。';
  END IF;

  DELETE FROM public.songs WHERE school_id = v_school_id;

  INSERT INTO public.songs (school_id, title, sort_reading, composer, arranger) VALUES
    (v_school_id, '宝島', 'Takarajima', '和泉 宏隆', '真島 俊夫'),
    (v_school_id, 'アルセナール', 'Arsenale', 'ヤン・ヴァンデルロースト', NULL),
    (v_school_id, 'カンタベリー・コラール', 'Canterbury Chorale', 'ヤン・ヴァンデルロースト', NULL),
    (v_school_id, 'ディープ・パープル・メドレー', 'Deep Purple Medley', '', '佐橋 俊彦'),
    (v_school_id, 'マードックからの最後の手紙', 'The Last Letter from Murdoch', '樽屋 雅徳', NULL),
    (v_school_id, '銀河鉄道999', 'Galaxy Express 999', 'タケカワ ユキヒデ', '樽屋 雅徳'),
    (v_school_id, '風紋', 'Fumon', '保科 洋', NULL);
END;
$replace$;

COMMIT;
