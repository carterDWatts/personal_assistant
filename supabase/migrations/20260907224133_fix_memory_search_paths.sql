-- Memory functions must not resolve names through the caller's search path.
-- pg_temp is last explicitly, so temporary relations cannot shadow real tables.
do $$
declare fn regprocedure;
begin
  for fn in select p.oid::regprocedure from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace where n.nspname='memory' and p.prokind='f'
  loop
    execute format('alter function %s set search_path = pg_catalog, memory, extensions, pg_temp', fn);
  end loop;
end $$;
