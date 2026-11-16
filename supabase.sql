-- Pega esto en Supabase > SQL Editor > Run
-- Es seguro ejecutarlo varias veces (no borra datos).

-- 1) Ubicaciones en tiempo real
create table if not exists public.ubicaciones (
  device_id   text not null,
  grupo       text not null,
  nombre      text,
  lat         double precision not null,
  lng         double precision not null,
  actualizado timestamptz not null default now(),
  primary key (device_id, grupo)
);

-- Si la tabla ya existía con clave solo por device_id, la cambia a (device_id, grupo)
do $$
begin
  if (select count(*) from information_schema.key_column_usage
       where table_schema = 'public' and table_name = 'ubicaciones'
         and constraint_name = 'ubicaciones_pkey') = 1 then
    alter table public.ubicaciones drop constraint ubicaciones_pkey;
    alter table public.ubicaciones add primary key (device_id, grupo);
  end if;
end $$;
create index if not exists ubicaciones_grupo_idx on public.ubicaciones (grupo);

-- 2) Grupos (para que sigan existiendo aunque salgas de la app)
create table if not exists public.grupos (
  codigo  text primary key,
  nombre  text not null,
  creador text not null,
  creado  timestamptz not null default now()
);

alter table public.ubicaciones enable row level security;
alter table public.grupos      enable row level security;

drop policy if exists "leer"       on public.ubicaciones;
drop policy if exists "insertar"   on public.ubicaciones;
drop policy if exists "actualizar" on public.ubicaciones;
drop policy if exists "borrar"     on public.ubicaciones;
create policy "leer"       on public.ubicaciones for select using (true);
create policy "insertar"   on public.ubicaciones for insert with check (true);
create policy "actualizar" on public.ubicaciones for update using (true) with check (true);
create policy "borrar"     on public.ubicaciones for delete using (true);

drop policy if exists "leer"       on public.grupos;
drop policy if exists "insertar"   on public.grupos;
drop policy if exists "actualizar" on public.grupos;
drop policy if exists "borrar"     on public.grupos;
create policy "leer"       on public.grupos for select using (true);
create policy "insertar"   on public.grupos for insert with check (true);
create policy "actualizar" on public.grupos for update using (true) with check (true);
create policy "borrar"     on public.grupos for delete using (true);

-- Tiempo real
do $$
begin
  alter publication supabase_realtime add table public.ubicaciones;
exception when duplicate_object then null;
end $$;
