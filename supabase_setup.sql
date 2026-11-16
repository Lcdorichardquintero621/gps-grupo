-- Pega esto en Supabase > SQL Editor > Run
create table if not exists ubicaciones (
  device_id   text primary key,
  grupo       text not null,
  nombre      text not null,
  lat         double precision not null,
  lng         double precision not null,
  actualizado timestamptz not null default now()
);

alter table ubicaciones enable row level security;

-- Prototipo: acceso abierto con la anon key (el código del grupo es el "secreto").
create policy "leer"      on ubicaciones for select using (true);
create policy "insertar"  on ubicaciones for insert with check (true);
create policy "actualizar" on ubicaciones for update using (true);
create policy "borrar"    on ubicaciones for delete using (true);

-- Activar tiempo real
alter publication supabase_realtime add table ubicaciones;
