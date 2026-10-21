-- 食事記録アプリ（meal-log）のデータベース
-- Supabase の SQL Editor に全部貼り付けて、一度だけ実行する。
--
-- 考え方
--   ・記録は「1品＝1行」で持つ。どの端末・どのタブから書いても、行ごとの上書きなので他の記録を消さない
--   ・行の id はアプリ側で作る。同じ記録を2回送っても同じ行になる（重複しない）
--   ・削除は deleted_at に日時を入れる（あとで調べられるように、行そのものは消さない）
--   ・ログインした本人の行しか読み書きできない（行レベルセキュリティ）
--   ・iPhoneのショートカットはログインできないので、「合言葉」を使う専用の関数からだけ読み書きする

create extension if not exists pgcrypto with schema extensions;

-- ---------- 食事・お酒の記録 ----------
create table if not exists public.entries (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  id text not null,
  date date not null,
  time text not null default '12:00',
  meal text not null,                 -- 朝食 / 昼食 / 夕食 / 間食 / お酒
  name text not null,
  unit text not null default '',
  kcal numeric not null default 0,
  carb numeric not null default 0,
  fiber numeric not null default 0,
  fat numeric not null default 0,
  protein numeric not null default 0,
  alc numeric not null default 0,     -- 純アルコール（g）
  alc_est boolean not null default false,
  food_id text,
  kai_req text,                       -- KAIに頼む前にアプリで計算した分の印
  health_synced_at timestamptz,       -- ヘルスケアに書き込んだ日時（ショートカットが入れる）
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, id)
);
create index if not exists entries_user_date on public.entries (user_id, date);

-- ---------- からだの記録（1日1行） ----------
create table if not exists public.body_days (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  date date not null,
  weight numeric,   -- 体重 kg（朝いちばん）
  fat numeric,      -- 体脂肪率 %
  active numeric,   -- アクティブエネルギー kcal
  basal numeric,    -- 安静時消費エネルギー kcal
  steps numeric,
  lift numeric,     -- 筋トレ（分。手でチェックしたときは 1）
  muscle numeric,   -- 骨格筋率 %（手入力）
  waist numeric,    -- 腹囲 cm（手入力）
  updated_at timestamptz not null default now(),
  primary key (user_id, date)
);

-- ---------- マイ食品（話して記録の辞書） ----------
create table if not exists public.foods (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  id text not null,
  data jsonb not null,                -- 名前・量・栄養・呼び方など
  deleted_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key (user_id, id)
);

-- ---------- 設定（1人1行） ----------
create table if not exists public.settings (
  user_id uuid primary key default auth.uid() references auth.users (id) on delete cascade,
  data jsonb not null default '{}',
  updated_at timestamptz not null default now()
);

-- ---------- 取り込み済みのKAIのリンク（同じリンクを2回取り込まないため） ----------
create table if not exists public.kai_imports (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  key text not null,
  created_at timestamptz not null default now(),
  primary key (user_id, key)
);

-- ---------- ヘルスケアから届いたデータ（ショートカットが置き、アプリが読んで反映する） ----------
create table if not exists public.health_imports (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  text text not null,
  received_at timestamptz not null default now(),
  processed_at timestamptz
);
create index if not exists health_imports_user on public.health_imports (user_id, processed_at);

-- ---------- ショートカット用の合言葉（本体は保存せず、ハッシュだけ持つ） ----------
create table if not exists public.device_tokens (
  token_hash text primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  label text not null default 'iPhoneのショートカット',
  created_at timestamptz not null default now()
);

-- ---------- 更新日時を自動で入れる ----------
create or replace function public.touch_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end $$;

do $$
declare t text;
begin
  foreach t in array array['entries', 'body_days', 'foods', 'settings'] loop
    execute format('drop trigger if exists touch on public.%I', t);
    execute format('create trigger touch before update on public.%I for each row execute function public.touch_updated_at()', t);
  end loop;
end $$;

-- ---------- 本人の行しか読み書きできないようにする ----------
alter table public.entries enable row level security;
alter table public.body_days enable row level security;
alter table public.foods enable row level security;
alter table public.settings enable row level security;
alter table public.kai_imports enable row level security;
alter table public.health_imports enable row level security;
alter table public.device_tokens enable row level security;

do $$
declare t text;
begin
  foreach t in array array['entries', 'body_days', 'foods', 'settings', 'kai_imports', 'health_imports'] loop
    execute format('drop policy if exists own on public.%I', t);
    execute format('create policy own on public.%I for all to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()))', t);
  end loop;
end $$;

-- 合言葉は一覧と削除だけ（作るのは下の関数から）
drop policy if exists own_select on public.device_tokens;
create policy own_select on public.device_tokens for select to authenticated using (user_id = (select auth.uid()));
drop policy if exists own_delete on public.device_tokens;
create policy own_delete on public.device_tokens for delete to authenticated using (user_id = (select auth.uid()));

-- アプリ（ログイン中の本人）からテーブルを使えるようにする。ログインしていない人には見せない
-- （ヘルスケアへの送信済みの印 health_synced_at は、アプリからは書き換えない。ショートカットの関数だけが入れる）
grant select, insert, update, delete on public.entries, public.body_days, public.foods, public.settings,
  public.kai_imports, public.health_imports to authenticated;
grant select, delete on public.device_tokens to authenticated;
revoke all on public.entries, public.body_days, public.foods, public.settings,
  public.kai_imports, public.health_imports, public.device_tokens from anon;

-- ========== ショートカット用の関数（合言葉で本人を見分ける） ==========

-- 合言葉を作る（アプリの設定画面から。作った合言葉は一度だけ表示される）
create or replace function public.create_device_token(p_label text default 'iPhoneのショートカット')
returns text language plpgsql security definer set search_path = '' as $$
declare t text;
begin
  if auth.uid() is null then raise exception 'ログインが必要です'; end if;
  t := encode(extensions.gen_random_bytes(24), 'hex');
  insert into public.device_tokens (token_hash, user_id, label)
    values (encode(extensions.digest(t, 'sha256'), 'hex'), auth.uid(), p_label);
  return t;
end $$;

create or replace function public.token_user(p_token text) returns uuid
language sql stable security definer set search_path = '' as $$
  select user_id from public.device_tokens
  where token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex')
$$;

-- まだヘルスケアに送っていない記録（カロリーが0のものは送らない）
create or replace function public.health_pending(p_token text)
returns table (id text, date text, kcal numeric, carb numeric, fiber numeric, fat numeric, protein numeric)
language plpgsql security definer set search_path = '' as $$
declare u uuid := public.token_user(p_token);
begin
  if u is null then raise exception '合言葉が違います'; end if;
  return query
    select e.id, to_char(e.date, 'YYYY-MM-DD') || ' ' || e.time,
           round(e.kcal, 1), round(e.carb, 1), round(e.fiber, 1), round(e.fat, 1), round(e.protein, 1)
    from public.entries e
    where e.user_id = u and e.health_synced_at is null and e.deleted_at is null and e.kcal > 0
    order by e.date, e.time
    limit 50;
end $$;

-- 1品ずつ「送信済み」にする（ヘルスケアに書けた直後に呼ぶ。途中で止まっても、書けた分だけが送信済みになる）
create or replace function public.health_mark_synced(p_token text, p_id text)
returns void language plpgsql security definer set search_path = '' as $$
declare u uuid := public.token_user(p_token);
begin
  if u is null then raise exception '合言葉が違います'; end if;
  update public.entries set health_synced_at = now() where user_id = u and id = p_id;
end $$;

-- ヘルスケアから読み出したデータを置く（体重・体脂肪率・消費カロリー・歩数など。1行1件のテキスト）
create or replace function public.health_push(p_token text, p_text text)
returns void language plpgsql security definer set search_path = '' as $$
declare u uuid := public.token_user(p_token);
begin
  if u is null then raise exception '合言葉が違います'; end if;
  insert into public.health_imports (user_id, text) values (u, p_text);
end $$;

-- アプリ（ログイン中）から、取り込み済みの印を外す（ヘルスケアから消したので送り直したいとき）
create or replace function public.health_unsync(p_id text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'ログインが必要です'; end if;
  update public.entries set health_synced_at = null where user_id = auth.uid() and id = p_id;
end $$;

-- 関数を呼べる人をしぼる
revoke all on function public.token_user(text) from public, anon, authenticated;
revoke all on function public.create_device_token(text) from public, anon;
revoke all on function public.health_unsync(text) from public, anon;
grant execute on function public.create_device_token(text) to authenticated;
grant execute on function public.health_unsync(text) to authenticated;
revoke all on function public.health_pending(text) from public;
revoke all on function public.health_mark_synced(text, text) from public;
revoke all on function public.health_push(text, text) from public;
grant execute on function public.health_pending(text) to anon, authenticated;
grant execute on function public.health_mark_synced(text, text) to anon, authenticated;
grant execute on function public.health_push(text, text) to anon, authenticated;
