begin;
alter table public.roster_shifts add column if not exists client_name text;
alter table public.roster_shifts add column if not exists updated_at timestamptz not null default now();
alter table public.progress_notes add column if not exists site_id uuid references public.work_sites(id) on delete set null;
create index if not exists idx_progress_notes_site on public.progress_notes(site_id);

drop function if exists public.ensure_next_week_availability();
create function public.ensure_next_week_availability() returns integer language plpgsql security definer set search_path=public as $$
declare v_this_monday date;v_count integer:=0;
begin
 if auth.uid() is null or not public.is_manager() then raise exception 'Manager access required';end if;
 v_this_monday:=((now() at time zone 'Australia/Sydney')::date-((extract(isodow from (now() at time zone 'Australia/Sydney')::date)::int)-1));
 insert into public.staff_availability(staff_id,available_date,start_time,end_time)
 select a.staff_id,a.available_date+7,a.start_time,a.end_time from public.staff_availability a
 where a.available_date between v_this_monday and v_this_monday+6
 and not exists(select 1 from public.staff_availability n where n.staff_id=a.staff_id and n.available_date=a.available_date+7);
 get diagnostics v_count=row_count;return v_count;
end;$$;
revoke all on function public.ensure_next_week_availability() from public,anon;
grant execute on function public.ensure_next_week_availability() to authenticated;

drop function if exists public.staff_relevant_progress_notes(integer,integer);
create function public.staff_relevant_progress_notes(p_days_back integer default 14,p_limit integer default 30)
returns table(id uuid,support_date date,client_name text,site_id uuid,site_name text,staff_id uuid,staff_name text,start_time time,end_time time,note_text text,status text,created_at timestamptz)
language sql security definer set search_path=public as $$
 select pn.id,pn.support_date,pn.client_name,pn.site_id,ws.name,pn.staff_id,coalesce(p.full_name,'Support Worker'),pn.start_time,pn.end_time,pn.note_text,pn.status,pn.created_at
 from public.progress_notes pn left join public.work_sites ws on ws.id=pn.site_id left join public.profiles p on p.id=pn.staff_id
 where auth.uid() is not null
 and pn.support_date>=((now() at time zone 'Australia/Sydney')::date-greatest(coalesce(p_days_back,14),0))
 and exists(select 1 from public.roster_shifts r where r.staff_id=auth.uid() and r.site_id=pn.site_id and lower(coalesce(r.client_name,''))=lower(coalesce(pn.client_name,'')) and r.shift_date between ((now() at time zone 'Australia/Sydney')::date-7) and ((now() at time zone 'Australia/Sydney')::date+14))
 order by pn.support_date desc,pn.created_at desc limit least(greatest(coalesce(p_limit,30),1),100);
$$;
revoke all on function public.staff_relevant_progress_notes(integer,integer) from public,anon;
grant execute on function public.staff_relevant_progress_notes(integer,integer) to authenticated;

create or replace function public.roster_shift_notification_trigger() returns trigger language plpgsql security definer set search_path=public as $$
declare v_site_name text;v_client text;v_start timestamptz;v_end timestamptz;v_changed boolean:=false;
begin
 if tg_op='DELETE' then
  select name into v_site_name from public.work_sites where id=old.site_id;v_client:=nullif(trim(coalesce(old.client_name,'')),'');
  delete from public.staff_notifications where shift_id=old.id and notification_type='clock_in_reminder' and read_at is null;
  insert into public.staff_notifications(staff_id,notification_type,title,message,shift_id) values(old.staff_id,'shift_cancelled','Shift cancelled','Your shift'||case when v_client is not null then ' with '||v_client else '' end||' at '||coalesce(v_site_name,'your assigned site')||' on '||to_char(old.shift_date,'Dy DD Mon')||' has been cancelled.',old.id);
  return old;
 end if;
 select name into v_site_name from public.work_sites where id=new.site_id;v_client:=nullif(trim(coalesce(new.client_name,'')),'');
 v_start:=((new.shift_date+new.start_time)::timestamp at time zone 'Australia/Sydney');
 v_end:=case when new.end_time<=new.start_time then (((new.shift_date+1)+new.end_time)::timestamp at time zone 'Australia/Sydney') else ((new.shift_date+new.end_time)::timestamp at time zone 'Australia/Sydney') end;
 if tg_op='INSERT' then
  insert into public.staff_notifications(staff_id,notification_type,title,message,shift_id) values(new.staff_id,'shift_assigned','New shift assigned','You have been assigned'||case when v_client is not null then ' to support '||v_client else '' end||' at '||coalesce(v_site_name,'a UCC site')||' on '||to_char(new.shift_date,'Dy DD Mon')||' from '||to_char(v_start at time zone 'Australia/Sydney','HH12:MI AM')||' to '||to_char(v_end at time zone 'Australia/Sydney','HH12:MI AM')||'.',new.id);
 else
  v_changed:=new.staff_id is distinct from old.staff_id or new.site_id is distinct from old.site_id or new.client_name is distinct from old.client_name or new.shift_date is distinct from old.shift_date or new.start_time is distinct from old.start_time or new.end_time is distinct from old.end_time or new.note is distinct from old.note;
  if v_changed then
   if new.staff_id is distinct from old.staff_id then
    delete from public.staff_notifications where shift_id=old.id and notification_type='clock_in_reminder' and read_at is null;
    insert into public.staff_notifications(staff_id,notification_type,title,message,shift_id) values(old.staff_id,'shift_cancelled','Shift reassigned','A shift previously assigned to you on '||to_char(old.shift_date,'Dy DD Mon')||' has been reassigned.',old.id);
   end if;
   insert into public.staff_notifications(staff_id,notification_type,title,message,shift_id) values(new.staff_id,'shift_updated','Roster shift updated','Your shift'||case when v_client is not null then ' for '||v_client else '' end||' at '||coalesce(v_site_name,'a UCC site')||' is now '||to_char(new.shift_date,'Dy DD Mon')||', '||to_char(v_start at time zone 'Australia/Sydney','HH12:MI AM')||' to '||to_char(v_end at time zone 'Australia/Sydney','HH12:MI AM')||'.',new.id);
  end if;
 end if;
 delete from public.staff_notifications where shift_id=new.id and notification_type='clock_in_reminder' and read_at is null;
 insert into public.staff_notifications(staff_id,notification_type,title,message,shift_id,remind_at) values(new.staff_id,'clock_in_reminder','Shift starts in 15 minutes','Reminder: your shift'||case when v_client is not null then ' supporting '||v_client else '' end||' at '||coalesce(v_site_name,'your assigned site')||' starts at '||to_char(v_start at time zone 'Australia/Sydney','HH12:MI AM')||' on '||to_char(new.shift_date,'Dy DD Mon')||'. Please be ready to clock in.',new.id,v_start-interval '15 minutes');
 return new;
end;$$;
drop trigger if exists trg_roster_shift_notifications on public.roster_shifts;
create trigger trg_roster_shift_notifications after insert or update or delete on public.roster_shifts for each row execute function public.roster_shift_notification_trigger();
commit;

select 'roster_client_name' check_name,case when exists(select 1 from information_schema.columns where table_schema='public' and table_name='roster_shifts' and column_name='client_name') then 'OK' else 'MISSING' end result
union all select 'progress_site_id',case when exists(select 1 from information_schema.columns where table_schema='public' and table_name='progress_notes' and column_name='site_id') then 'OK' else 'MISSING' end
union all select 'relevant_progress_rpc',case when exists(select 1 from pg_proc where proname='staff_relevant_progress_notes') then 'OK' else 'MISSING' end
union all select 'availability_repeat_rpc',case when exists(select 1 from pg_proc where proname='ensure_next_week_availability') then 'OK' else 'MISSING' end;
