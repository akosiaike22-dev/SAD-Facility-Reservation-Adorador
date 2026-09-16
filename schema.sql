-- =====================================================================
-- Role-Based Facility Reservation and Approval System
-- Supabase (PostgreSQL) Schema
-- Lab 4 - Section B
-- =====================================================================
-- Run this whole file once in Supabase SQL Editor (Project > SQL Editor)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. EXTENSIONS
-- ---------------------------------------------------------------------
create extension if not exists "uuid-ossp";

-- ---------------------------------------------------------------------
-- 1. PROFILES (extends Supabase auth.users with a role)
-- ---------------------------------------------------------------------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  role text not null check (role in ('admin','staff','requester')) default 'requester',
  created_at timestamptz not null default now()
);

-- Auto-create a profile row whenever a new auth user signs up.
-- Role defaults to 'requester'; an Administrator promotes staff/admin manually
-- (or via the metadata trick shown in README.md).
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', new.email),
    coalesce(new.raw_user_meta_data->>'role', 'requester')
  );
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- ---------------------------------------------------------------------
-- 2. FACILITIES
-- ---------------------------------------------------------------------
create table if not exists public.facilities (
  id uuid primary key default uuid_generate_v4(),
  name text not null,
  description text,
  location text,
  status text not null check (status in ('active','maintenance','inactive')) default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 3. RESERVATIONS
-- ---------------------------------------------------------------------
create table if not exists public.reservations (
  id uuid primary key default uuid_generate_v4(),
  facility_id uuid not null references public.facilities(id) on delete restrict,
  requester_id uuid not null references public.profiles(id) on delete cascade,
  purpose text not null,
  start_time timestamptz not null,
  end_time timestamptz not null,
  status text not null check (
    status in ('Pending','Approved','Rejected','Scheduled','In Use','Completed','Cancelled')
  ) default 'Pending',
  decided_by uuid references public.profiles(id),
  decided_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- BR-B4-02: start must precede end
  constraint chk_start_before_end check (start_time < end_time)
);

-- ---------------------------------------------------------------------
-- 4. SERVICE REQUESTS (Facility Staff logs concerns / condition updates)
-- ---------------------------------------------------------------------
create table if not exists public.service_requests (
  id uuid primary key default uuid_generate_v4(),
  facility_id uuid not null references public.facilities(id) on delete cascade,
  staff_id uuid not null references public.profiles(id),
  description text not null,
  status text not null check (status in ('open','in_progress','resolved')) default 'open',
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 5. AUDIT LOGS (BR-B4-10)
-- ---------------------------------------------------------------------
create table if not exists public.audit_logs (
  id uuid primary key default uuid_generate_v4(),
  actor_id uuid references public.profiles(id),
  action text not null,          -- e.g. 'RESERVATION_SUBMITTED', 'RESERVATION_APPROVED'
  table_name text not null,
  record_id uuid,
  details jsonb,
  created_at timestamptz not null default now()
);

-- Helper to write an audit row (bypasses RLS via security definer)
create or replace function public.write_audit_log(
  p_action text,
  p_table text,
  p_record_id uuid,
  p_details jsonb
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.audit_logs (actor_id, action, table_name, record_id, details)
  values (auth.uid(), p_action, p_table, p_record_id, p_details);
end;
$$;

-- ---------------------------------------------------------------------
-- 6. BUSINESS RULE ENFORCEMENT (trigger on reservations)
-- ---------------------------------------------------------------------
create or replace function public.enforce_reservation_rules()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_facility_status text;
  v_overlap_count int;
  v_old_status text;
begin
  select status into v_facility_status from public.facilities where id = new.facility_id;

  -- BR-B4-01 / BR-B4-08: facility must be active (not maintenance/inactive)
  if v_facility_status is distinct from 'active' then
    raise exception 'Facility is not active (status: %). Reservation blocked.', v_facility_status;
  end if;

  if TG_OP = 'UPDATE' then
    v_old_status := old.status;

    -- BR-B4-07: completed reservations cannot be edited
    if v_old_status = 'Completed' then
      raise exception 'Completed reservations cannot be edited.';
    end if;

    -- BR-B4-05: rejected reservations cannot become Scheduled/Approved/In Use/Completed
    if v_old_status = 'Rejected' and new.status not in ('Rejected','Cancelled') then
      raise exception 'Rejected reservations cannot change to %.', new.status;
    end if;
  end if;

  -- BR-B4-03 / BR-B4-06: block overlapping Approved/Scheduled/In Use reservations
  if new.status in ('Approved','Scheduled','In Use') then
    select count(*) into v_overlap_count
    from public.reservations r
    where r.facility_id = new.facility_id
      and r.id <> coalesce(new.id, uuid_nil())
      and r.status in ('Approved','Scheduled','In Use')
      and tstzrange(r.start_time, r.end_time) && tstzrange(new.start_time, new.end_time);

    if v_overlap_count > 0 then
      raise exception 'Schedule conflict: an approved/scheduled reservation already exists for this time slot.';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_enforce_reservation_rules on public.reservations;
create trigger trg_enforce_reservation_rules
  before insert or update on public.reservations
  for each row execute procedure public.enforce_reservation_rules();

-- ---------------------------------------------------------------------
-- 7. AUDIT TRIGGER (logs submission / status changes)
-- ---------------------------------------------------------------------
create or replace function public.audit_reservation_changes()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if TG_OP = 'INSERT' then
    perform public.write_audit_log(
      'RESERVATION_SUBMITTED', 'reservations', new.id,
      jsonb_build_object('status', new.status, 'facility_id', new.facility_id)
    );
  elsif TG_OP = 'UPDATE' and old.status is distinct from new.status then
    perform public.write_audit_log(
      'RESERVATION_STATUS_CHANGED', 'reservations', new.id,
      jsonb_build_object('from', old.status, 'to', new.status)
    );
  end if;
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_audit_reservation_changes on public.reservations;
create trigger trg_audit_reservation_changes
  before insert or update on public.reservations
  for each row execute procedure public.audit_reservation_changes();

-- Facility updates audit
create or replace function public.audit_facility_changes()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if TG_OP = 'UPDATE' then
    perform public.write_audit_log(
      'FACILITY_UPDATED', 'facilities', new.id,
      jsonb_build_object('old_status', old.status, 'new_status', new.status)
    );
  elsif TG_OP = 'DELETE' then
    perform public.write_audit_log('FACILITY_DELETED', 'facilities', old.id, to_jsonb(old));
  end if;
  if TG_OP = 'UPDATE' then
    new.updated_at = now();
    return new;
  end if;
  return old;
end;
$$;

drop trigger if exists trg_audit_facility_changes on public.facilities;
create trigger trg_audit_facility_changes
  before update or delete on public.facilities
  for each row execute procedure public.audit_facility_changes();

-- ---------------------------------------------------------------------
-- 8. ROW LEVEL SECURITY
-- ---------------------------------------------------------------------
alter table public.profiles enable row level security;
alter table public.facilities enable row level security;
alter table public.reservations enable row level security;
alter table public.service_requests enable row level security;
alter table public.audit_logs enable row level security;

-- Helper: current user's role
create or replace function public.current_role()
returns text
language sql
security definer
stable
set search_path = public
as $$
  select role from public.profiles where id = auth.uid();
$$;

-- PROFILES
create policy "profiles_select_own_or_admin"
  on public.profiles for select
  using (id = auth.uid() or public.current_role() = 'admin');

create policy "profiles_update_own"
  on public.profiles for update
  using (id = auth.uid());

-- FACILITIES: everyone signed-in can read; only admin writes
create policy "facilities_select_all"
  on public.facilities for select
  using (auth.uid() is not null);

create policy "facilities_admin_write"
  on public.facilities for insert
  with check (public.current_role() = 'admin');

create policy "facilities_admin_update"
  on public.facilities for update
  using (public.current_role() = 'admin');

create policy "facilities_staff_update_condition"
  on public.facilities for update
  using (public.current_role() = 'staff');

create policy "facilities_admin_delete"
  on public.facilities for delete
  using (public.current_role() = 'admin');

-- RESERVATIONS
-- Requesters see own; staff/admin see all
create policy "reservations_select"
  on public.reservations for select
  using (
    requester_id = auth.uid()
    or public.current_role() in ('admin','staff')
  );

-- Requester creates own Pending reservation
create policy "reservations_insert_requester"
  on public.reservations for insert
  with check (
    requester_id = auth.uid()
    and status = 'Pending'
  );

-- BR-B4-09: requester may update only own Pending requests (e.g. cancel)
create policy "reservations_update_requester_own_pending"
  on public.reservations for update
  using (
    requester_id = auth.uid()
    and status = 'Pending'
  );

-- BR-B4-04: only admin can approve/reject
create policy "reservations_update_admin"
  on public.reservations for update
  using (public.current_role() = 'admin');

-- Staff can transition Scheduled -> In Use -> Completed
create policy "reservations_update_staff"
  on public.reservations for update
  using (public.current_role() = 'staff');

-- SERVICE REQUESTS: staff creates/reads; admin reads all
create policy "service_requests_select"
  on public.service_requests for select
  using (staff_id = auth.uid() or public.current_role() = 'admin');

create policy "service_requests_insert_staff"
  on public.service_requests for insert
  with check (staff_id = auth.uid() and public.current_role() = 'staff');

-- AUDIT LOGS: admin only (staff optionally, per policy below)
create policy "audit_logs_select_admin"
  on public.audit_logs for select
  using (public.current_role() = 'admin');

-- Note: inserts into audit_logs are done only via the SECURITY DEFINER
-- function write_audit_log(), so no direct insert policy is granted to users.

-- ---------------------------------------------------------------------
-- 9. SEED DATA (optional, for quick testing)
-- ---------------------------------------------------------------------
insert into public.facilities (name, description, location, status) values
  ('Main Conference Hall', 'Seats 100, projector + sound system', 'Bldg A, 2F', 'active'),
  ('Computer Lab 1', '40 units, air-conditioned', 'Bldg B, 3F', 'active'),
  ('Gymnasium', 'Full court, bleachers', 'Sports Complex', 'maintenance')
on conflict do nothing;

-- =====================================================================
-- END OF SCHEMA
-- After running this, promote a test account to admin/staff with:
--   update public.profiles set role = 'admin'   where id = '<user-uuid>';
--   update public.profiles set role = 'staff'   where id = '<user-uuid>';
-- =====================================================================
