# Tutti

## デプロイ

Vercelには静的サイトとして `index.html` をデプロイします。Supabaseの
`schema.sql` はVercelに配置するファイルではなく、SupabaseのSQL Editorで
実行してデータベースに適用してください。デプロイ対象からは
`supabase/schema.sql` を除外しています。

1. SupabaseのSQL Editorで `supabase/schema.sql` を実行する
2. Vercelでこのリポジトリを静的サイトとしてデプロイする

`schema.sql` は認証ユーザー作成時に学校・部活とプロフィールを安全に作成する
データベーストリガーも設定します。既存のSupabaseプロジェクトにもこのSQLを再実行して
招待コード列とトリガーを追加してください。サービスロールキーをHTMLに設定しないでください。

組織の登録者へ招待コードと基本情報をメール送信するには、Supabase Edge Functionと
Resendの送信元ドメイン設定が必要です。チャットやソースコードへ共有したResend APIキーは
失効させ、新しいキーを発行してください。キーはHTMLやGitに置かず、Supabase Dashboardの
「Edge Functions」→「Secrets」へ直接登録します。

1. Supabase SQL Editorで最新の `supabase/schema.sql` を実行する
2. Resendで送信元ドメインを検証する
3. Supabase CLIを対象プロジェクトにリンクし、Edge Functionsをデプロイする

```sh
supabase functions deploy send-organization-welcome
supabase functions deploy manage-member
supabase functions deploy join-group
```

Supabase DashboardのEdge Function Secretsに次の値を登録してください。
supabase functions deploy join-group

`manage-member` Functionは同じ団体の管理者だけに所属ごとの部員情報編集と除籍を許可します。
他団体の所属が残る場合はAuthアカウントを維持し、最後の管理者や自分自身の除籍は拒否します。
`join-group` Functionはログインユーザーの認証と招待コードを検証し、追加の所属を作成します。
- `TUTTI_APP_URL`: VercelにデプロイしたTuttiのURL

Functionは認証ユーザーが学校作成者かつ管理者であることを確認し、登録メールアドレスへ
団体名・招待コード・アプリURLを送信します。送信済み時刻を記録して重複送信を防ぎます。
`manage-member` Functionは同じ団体の管理者だけに所属プロフィールの編集と除籍を許可します。
他団体の所属が残る場合はAuthアカウントを維持し、最後の所属を外した場合だけアカウントも削除します。
`join-group` Functionは認証ユーザーのプロフィール情報を使い、招待コードから追加の所属を作成します。

部員はホーム画面に表示される招待コードを使って参加できます。このコードは同じ団体の
ログイン済みユーザー全員に表示されます。コードを知っている人が参加できる仕様です。

401が続く場合は、Vercelのデプロイ詳細に表示されるエラーを確認してください。
VercelアカウントやGit連携の認証エラーは、SQLファイルの配置とは別に設定の確認が必要です。