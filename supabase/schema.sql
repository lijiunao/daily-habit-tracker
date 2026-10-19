-- Run once in Supabase SQL Editor. Public-facing rows are protected by RLS.
create schema if not exists private;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null,
  goal integer not null default 10 check (goal between 1 and 100),
  start text not null default '08:00' check (start ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'),
  "end" text not null default '23:59' check ("end" ~ '^(([01][0-9]|2[0-3]):[0-5][0-9]|24:00)$'),
  created_at timestamptz not null default now()
);

create table if not exists public.records (
  user_id uuid not null references public.profiles(id) on delete cascade,
  record_date date not null,
  water integer not null default 0 check (water between 0 and 10000),
  smoke integer not null default 0 check (smoke between 0 and 1000),
  updated_at timestamptz not null default now(),
  primary key (user_id, record_date)
);

create table if not exists public.habit_groups (
  id uuid primary key default gen_random_uuid(),
  invite_code text not null unique,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.group_members (
  group_id uuid not null references public.habit_groups(id) on delete cascade,
  user_id uuid not null unique references public.profiles(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (group_id, user_id)
);

create index if not exists records_by_date on public.records(record_date desc);

create or replace function private.create_profile_for_new_auth_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, username)
  values (new.id, coalesce(nullif(trim(new.raw_user_meta_data->>'username'), ''), split_part(new.email, '@', 1)));
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_habit_profile on auth.users;
create trigger on_auth_user_created_habit_profile
  after insert on auth.users for each row execute procedure private.create_profile_for_new_auth_user();

create or replace function private.are_group_mates(target_user_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.group_members mine
    join public.group_members theirs on theirs.group_id = mine.group_id
    where mine.user_id = auth.uid() and theirs.user_id = target_user_id
  );
$$;

alter table public.profiles enable row level security;
alter table public.records enable row level security;
alter table public.habit_groups enable row level security;
alter table public.group_members enable row level security;

drop policy if exists "profiles are visible to self and group" on public.profiles;
create policy "profiles are visible to self and group" on public.profiles
  for select to authenticated using (id = auth.uid() or private.are_group_mates(id));
drop policy if exists "profiles are editable by self" on public.profiles;
create policy "profiles are editable by self" on public.profiles
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists "records are visible to self and group" on public.records;
create policy "records are visible to self and group" on public.records
  for select to authenticated using (user_id = auth.uid() or private.are_group_mates(user_id));
drop policy if exists "records are inserted by owner" on public.records;
create policy "records are inserted by owner" on public.records
  for insert to authenticated with check (user_id = auth.uid());
drop policy if exists "records are updated by owner" on public.records;
create policy "records are updated by owner" on public.records
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists "records are deleted by owner" on public.records;
create policy "records are deleted by owner" on public.records
  for delete to authenticated using (user_id = auth.uid());

create or replace function private.group_snapshot_impl()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare g public.habit_groups%rowtype; result jsonb;
begin
  select hg.* into g from public.habit_groups hg
  join public.group_members gm on gm.group_id = hg.id
  where gm.user_id = auth.uid() limit 1;
  if not found then return null; end if;
  select jsonb_build_object(
    'id', g.id,
    'inviteCode', g.invite_code,
    'createdAt', g.created_at,
    'members', coalesce((
      select jsonb_agg(jsonb_build_object(
        'user', jsonb_build_object('id', p.id, 'username', p.username, 'goal', p.goal, 'start', p.start, 'end', p."end"),
        'records', coalesce((
          select jsonb_object_agg(r.record_date::text, jsonb_build_object('water', r.water, 'smoke', r.smoke, 'updatedAt', r.updated_at))
          from public.records r where r.user_id = p.id
        ), '{}'::jsonb)
      ) order by p.username)
      from public.group_members gm join public.profiles p on p.id = gm.user_id
      where gm.group_id = g.id
    ), '[]'::jsonb)
  ) into result;
  return result;
end;
$$;

create or replace function public.group_snapshot()
returns jsonb language sql stable security invoker set search_path = '' as $$
  select private.group_snapshot_impl();
$$;

create or replace function private.create_group_impl()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare group_id uuid;
begin
  if auth.uid() is null then raise exception '请先登录'; end if;
  if exists (select 1 from public.group_members where user_id = auth.uid()) then raise exception '你已经在一个共享小组中'; end if;
  insert into public.habit_groups(invite_code, created_by)
  values (upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 24)), auth.uid()) returning id into group_id;
  insert into public.group_members(group_id, user_id) values (group_id, auth.uid());
  return private.group_snapshot_impl();
end;
$$;

create or replace function public.create_group()
returns jsonb language sql security invoker set search_path = '' as $$
  select private.create_group_impl();
$$;

create or replace function private.join_group_impl(p_invite_code text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare group_id uuid;
begin
  if auth.uid() is null then raise exception '请先登录'; end if;
  if exists (select 1 from public.group_members where user_id = auth.uid()) then raise exception '请先退出当前共享小组'; end if;
  select id into group_id from public.habit_groups where habit_groups.invite_code = upper(trim(p_invite_code));
  if group_id is null then raise exception '邀请码无效，请检查后重试'; end if;
  insert into public.group_members(group_id, user_id) values (group_id, auth.uid());
  return private.group_snapshot_impl();
end;
$$;

create or replace function public.join_group(p_invite_code text)
returns jsonb language sql security invoker set search_path = '' as $$
  select private.join_group_impl(p_invite_code);
$$;

create or replace function private.leave_group_impl()
returns void language plpgsql security definer set search_path = '' as $$
declare g public.habit_groups%rowtype; next_owner uuid;
begin
  select hg.* into g from public.habit_groups hg join public.group_members gm on gm.group_id = hg.id
  where gm.user_id = auth.uid() limit 1;
  if not found then return; end if;
  delete from public.group_members where group_id = g.id and user_id = auth.uid();
  select user_id into next_owner from public.group_members where group_id = g.id order by joined_at limit 1;
  if next_owner is null then delete from public.habit_groups where id = g.id;
  elsif g.created_by = auth.uid() then update public.habit_groups set created_by = next_owner where id = g.id;
  end if;
end;
$$;

create or replace function public.leave_group()
returns void language sql security invoker set search_path = '' as $$
  select private.leave_group_impl();
$$;

revoke all on schema private from public;
grant usage on schema private to authenticated;
revoke all on function private.create_profile_for_new_auth_user() from public;
revoke all on function private.are_group_mates(uuid) from public;
revoke all on function private.group_snapshot_impl() from public;
revoke all on function private.create_group_impl() from public;
revoke all on function private.join_group_impl(text) from public;
revoke all on function private.leave_group_impl() from public;
grant execute on function private.are_group_mates(uuid) to authenticated;
grant execute on function private.group_snapshot_impl() to authenticated;
grant execute on function private.create_group_impl() to authenticated;
grant execute on function private.join_group_impl(text) to authenticated;
grant execute on function private.leave_group_impl() to authenticated;
revoke all on function public.group_snapshot() from public;
revoke all on function public.create_group() from public;
revoke all on function public.join_group(text) from public;
revoke all on function public.leave_group() from public;
grant execute on function public.group_snapshot() to authenticated;
grant execute on function public.create_group() to authenticated;
grant execute on function public.join_group(text) to authenticated;
grant execute on function public.leave_group() to authenticated;

grant select, update on public.profiles to authenticated;
grant select, insert, update, delete on public.records to authenticated;
