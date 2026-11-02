# Tutti

## デプロイ

Vercelには静的サイトとして `index.html` をデプロイします。Supabaseの
`schema.sql` はVercelに配置するファイルではなく、SupabaseのSQL Editorで
実行してデータベースに適用してください。デプロイ対象からは
`supabase/schema.sql` を除外しています。

1. SupabaseのSQL Editorで `supabase/schema.sql` を実行する
2. Vercelでこのリポジトリを静的サイトとしてデプロイする

401が続く場合は、Vercelのデプロイ詳細に表示されるエラーを確認してください。
VercelアカウントやGit連携の認証エラーは、SQLファイルの配置とは別に設定の確認が必要です。