-- Task deadlines do not expire tasks. Check-ins have a bounded delivery window.
alter table memory.reminders
 add column kind text not null default 'task' check (kind in ('task','check_in')),
 add constraint check_in_window_required check (kind <> 'check_in' or window_end is not null);
