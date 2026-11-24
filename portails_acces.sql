-- Portails accessibles à chaque agent (une ligne par agent).
-- Sans ligne, l'application déduit les droits : Santé pour tous, RH si l'agent a un dossier ou un accès RH
-- (ou s'il est de niveau national), Finance s'il a un accès Finance.
-- L'administrateur (admin = true) voit tous les portails et règle ceux des autres agents.
create table if not exists public.portails_acces (
  code text primary key,
  portails text[] not null default array['sante'],
  admin boolean not null default false,
  updated_by text,
  updated_at timestamptz not null default now(),
  check (portails <@ array['sante','rh','finance','ident','admin','archiv'])
);

create or replace function public.pt_est_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select admin from public.portails_acces where code = public.me_code()), false)
$$;
grant execute on function public.pt_est_admin() to authenticated;

alter table public.portails_acces enable row level security;
grant select, insert, update, delete on public.portails_acces to authenticated;
drop policy if exists portails_acces_r on public.portails_acces;
drop policy if exists portails_acces_w on public.portails_acces;
create policy portails_acces_r on public.portails_acces for select to authenticated
  using (code = public.me_code() or public.pt_est_admin());
create policy portails_acces_w on public.portails_acces for all to authenticated
  using (public.pt_est_admin()) with check (public.pt_est_admin());

-- L'administrateur de départ (vous, 10-056) : tous les portails.
insert into public.portails_acces(code, portails, admin) values ('10-056', array['sante','rh','finance'], true)
on conflict (code) do update set admin = true;
