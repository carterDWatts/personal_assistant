alter table assistant.credentials drop constraint credentials_slot_check;
alter table assistant.credentials add constraint credentials_slot_check
  check(slot in ('google_connect','google_tasks','google_drive','google_contacts','todoist','notion','github','supabase'));
