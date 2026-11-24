-- =====================================================================
-- MESP FINANCE — étape 1 : plan comptable, exercices, taux de change,
-- caisses/banques (USD + CDF), journal de caisse, dépenses validées par
-- le directeur financier puis le secrétaire exécutif.
-- À exécuter APRÈS rh_etape2_entites.sql (réutilise la table hr_entites).
-- Chaque sujet a sa propre table, lisible séparément.
-- =====================================================================

-- ---------- accès Finance ----------
create table if not exists public.fin_acces (
  code text primary key,                       -- code de l'agent dans MESP Integra (ex. 10-056)
  nom text not null,
  niveau text not null check (niveau in ('df','se','comptable','caissier','lecture')),
  entite_id text not null default 'national' references public.hr_entites(id),
  created_at timestamptz not null default now()
);
comment on column public.fin_acces.niveau is 'df = directeur financier ; se = secrétaire exécutif ; comptable ; caissier ; lecture';

create table if not exists public.fin_journal (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  acteur text, action text, table_name text, ligne_id text, details jsonb
);

-- ---------- référentiels ----------
create table if not exists public.fin_exercices (
  id text primary key,
  libelle text not null unique,
  debut date not null,
  fin date not null,
  cloture boolean not null default false,
  check (fin > debut)
);

create table if not exists public.fin_comptes (
  id text primary key,                         -- numéro de compte (SYSCOHADA)
  intitule text not null,
  classe int not null check (classe between 1 and 9),
  type text not null default 'autre' check (type in ('actif','passif','charge','produit','autre')),
  actif boolean not null default true
);

create table if not exists public.fin_taux (
  id text primary key,
  jour date not null unique,
  usd_cdf numeric(14,4) not null check (usd_cdf > 0),
  saisi_par text
);

create table if not exists public.fin_param (
  cle text primary key,
  valeur numeric not null,
  note text
);

-- ---------- caisses et banques ----------
create table if not exists public.fin_caisses (
  id text primary key,
  entite_id text not null references public.hr_entites(id),
  nom text not null,
  type text not null default 'caisse' check (type in ('caisse','banque')),
  devise text not null check (devise in ('USD','CDF')),
  solde_initial numeric(16,2) not null default 0,
  actif boolean not null default true,
  created_at timestamptz not null default now()
);

-- journal de caisse : écritures immuables (pas de modification ni suppression)
create table if not exists public.fin_mouvements (
  id text primary key,
  entite_id text not null references public.hr_entites(id),
  caisse_id text not null references public.fin_caisses(id),
  jour date not null default current_date,
  sens text not null check (sens in ('entree','sortie')),
  montant numeric(16,2) not null check (montant > 0),
  devise text not null check (devise in ('USD','CDF')),
  compte_id text references public.fin_comptes(id),
  libelle text not null,
  reference text,
  depense_id text,
  created_by text,
  created_at timestamptz not null default now()
);
create index if not exists fin_mouvements_caisse on public.fin_mouvements (caisse_id, jour);

-- ---------- dépenses ----------
create table if not exists public.fin_depenses (
  id text primary key,
  entite_id text not null references public.hr_entites(id),
  objet text not null,
  beneficiaire text,
  montant numeric(16,2) not null check (montant > 0),
  devise text not null check (devise in ('USD','CDF')),
  compte_id text references public.fin_comptes(id),
  statut text not null default 'demande' check (statut in ('demande','valide_df','approuve','paye','refuse','annule')),
  demande_par text, demande_le timestamptz,
  df_par text, df_le timestamptz,
  se_par text, se_le timestamptz,
  decision_motif text,
  caisse_id text references public.fin_caisses(id),
  mouvement_id text,
  paye_par text, paye_le timestamptz
);
create index if not exists fin_depenses_statut on public.fin_depenses (entite_id, statut);

-- ---------- qui suis-je côté Finance ----------
create or replace function public.fin_niveau() returns text
language sql stable security definer set search_path = public as $$
  select case when public.me_code() is null then null
              else (select a.niveau from public.fin_acces a where a.code = public.me_code()) end
$$;
create or replace function public.fin_entite() returns text
language sql stable security definer set search_path = public as $$
  select a.entite_id from public.fin_acces a where a.code = public.me_code()
$$;
create or replace function public.fin_nat() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.fin_entite() = 'national', false)
$$;
create or replace function public.fin_ent_ok(e text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.fin_niveau() is not null and (public.fin_nat() or e = public.fin_entite())
$$;
grant execute on function public.fin_niveau(), public.fin_entite(), public.fin_nat(), public.fin_ent_ok(text) to authenticated;

-- ---------- journal automatique ----------
create or replace function public.fin_audit() returns trigger
language plpgsql security definer set search_path = public as $$
declare r jsonb := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
begin
  insert into public.fin_journal(acteur, action, table_name, ligne_id, details)
  values (public.me_code(), lower(tg_op), tg_table_name, coalesce(r->>'id', r->>'code', r->>'cle'),
          case when tg_op = 'UPDATE' then jsonb_build_object('avant', to_jsonb(old), 'apres', to_jsonb(new)) else r end);
  return coalesce(new, old);
end $$;
do $$
declare t text;
begin
  foreach t in array array['fin_acces','fin_exercices','fin_comptes','fin_taux','fin_param','fin_caisses','fin_mouvements','fin_depenses'] loop
    execute format('drop trigger if exists %I on public.%I', t || '_audit', t);
    execute format('create trigger %I after insert or update or delete on public.%I for each row execute function public.fin_audit()', t || '_audit', t);
  end loop;
end $$;

-- ---------- règles : écritures de caisse ----------
create or replace function public.fin_mouvement_check() returns trigger
language plpgsql security definer set search_path = public as $$
declare c record; solde numeric;
begin
  select * into c from public.fin_caisses where id = new.caisse_id for update;
  if not found then raise exception 'Caisse introuvable'; end if;
  if not c.actif then raise exception 'Cette caisse est fermée'; end if;
  new.entite_id := c.entite_id; new.devise := c.devise;
  if new.depense_id is not null and coalesce(current_setting('fin.payer', true), '') <> '1' then
    raise exception 'Une écriture liée à une dépense se fait uniquement par le paiement de la dépense';
  end if;
  if not exists (select 1 from public.fin_exercices e where new.jour between e.debut and e.fin) then
    raise exception 'Aucun exercice comptable ne couvre la date %', new.jour;
  end if;
  if exists (select 1 from public.fin_exercices e where new.jour between e.debut and e.fin and e.cloture) then
    raise exception 'L''exercice est clôturé : écriture impossible';
  end if;
  if new.sens = 'sortie' then
    select c.solde_initial + coalesce(sum(case m.sens when 'entree' then m.montant else -m.montant end), 0) into solde
      from public.fin_mouvements m where m.caisse_id = c.id;
    solde := coalesce(solde, c.solde_initial);
    if solde < new.montant then raise exception 'Solde insuffisant : % % disponibles', solde, c.devise; end if;
  end if;
  new.created_by := public.me_code(); new.created_at := now();
  return new;
end $$;
drop trigger if exists fin_mouvements_chk on public.fin_mouvements;
create trigger fin_mouvements_chk before insert on public.fin_mouvements for each row execute function public.fin_mouvement_check();

-- ---------- règles : circuit des dépenses ----------
create or replace function public.fin_usd(m numeric, d text) returns numeric
language sql stable security definer set search_path = public as $$
  select case when d = 'USD' then m
              else (select m / t.usd_cdf from public.fin_taux t order by t.jour desc limit 1) end
$$;

create or replace function public.fin_depense_check() returns trigger
language plpgsql security definer set search_path = public as $$
declare niv text := public.fin_niveau(); me text := public.me_code(); seuil numeric; usd numeric;
begin
  if tg_op = 'INSERT' then
    if niv is null or niv = 'lecture' then raise exception 'Vous n''avez pas le droit de demander une dépense'; end if;
    if new.statut <> 'demande' then raise exception 'Une dépense commence au statut « demande »'; end if;
    if not public.fin_ent_ok(new.entite_id) then raise exception 'Entité non autorisée'; end if;
    new.demande_par := me; new.demande_le := now();
    new.df_par := null; new.se_par := null; new.caisse_id := null; new.mouvement_id := null; new.paye_par := null;
    return new;
  end if;
  -- mise à jour
  if new.statut = old.statut then
    if (new.objet, new.montant, new.devise, new.entite_id, new.compte_id, new.beneficiaire)
       is distinct from (old.objet, old.montant, old.devise, old.entite_id, old.compte_id, old.beneficiaire)
       and not (old.statut = 'demande' and old.demande_par = me) then
      raise exception 'Les éléments de la dépense ne sont plus modifiables';
    end if;
    return new;
  end if;
  if (new.objet, new.montant, new.devise, new.entite_id, new.compte_id, new.beneficiaire)
     is distinct from (old.objet, old.montant, old.devise, old.entite_id, old.compte_id, old.beneficiaire) then
    raise exception 'Les éléments de la dépense ne sont pas modifiables avec un changement de statut';
  end if;
  if old.statut = 'demande' and new.statut = 'valide_df' then
    if niv <> 'df' or not public.fin_ent_ok(old.entite_id) then raise exception 'Seul le directeur financier valide cette étape'; end if;
    new.df_par := me; new.df_le := now();
    select valeur into seuil from public.fin_param where cle = 'seuil_se_usd';
    usd := public.fin_usd(old.montant, old.devise);
    if coalesce(seuil, 0) > 0 and usd is not null and usd < seuil then new.statut := 'approuve'; end if;
  elsif old.statut = 'valide_df' and new.statut = 'approuve' then
    if niv <> 'se' then raise exception 'Seul le secrétaire exécutif approuve cette étape'; end if;
    new.se_par := me; new.se_le := now();
  elsif old.statut in ('demande','valide_df') and new.statut = 'refuse' then
    if not ((old.statut = 'demande' and niv = 'df') or (old.statut = 'valide_df' and niv in ('se','df'))) then
      raise exception 'Vous ne pouvez pas refuser à cette étape'; end if;
    if coalesce(btrim(new.decision_motif), '') = '' then raise exception 'Le motif du refus est obligatoire'; end if;
  elsif old.statut in ('demande','valide_df','approuve') and new.statut = 'annule' then
    if not (old.demande_par = me or niv = 'df') then raise exception 'Seul le demandeur ou le directeur financier annule'; end if;
  elsif old.statut = 'approuve' and new.statut = 'paye' then
    if coalesce(current_setting('fin.payer', true), '') <> '1' then raise exception 'Le paiement se fait par le bouton « Payer »'; end if;
  else
    raise exception 'Changement de statut non autorisé (% vers %)', old.statut, new.statut;
  end if;
  return new;
end $$;
drop trigger if exists fin_depenses_chk on public.fin_depenses;
create trigger fin_depenses_chk before insert or update on public.fin_depenses for each row execute function public.fin_depense_check();

-- ---------- paiement d'une dépense approuvée ----------
create or replace function public.fin_payer(p_id text, p_caisse text) returns void
language plpgsql security definer set search_path = public as $$
declare d record; c record; mid text := 'm' || to_char(clock_timestamp(), 'YYMMDDHH24MISSMS') || substr(md5(random()::text), 1, 3);
begin
  if public.fin_niveau() not in ('df','comptable','caissier') then raise exception 'Seuls le directeur financier, le comptable ou le caissier paient'; end if;
  select * into d from public.fin_depenses where id = p_id for update;
  if not found then raise exception 'Dépense introuvable'; end if;
  if not public.fin_ent_ok(d.entite_id) then raise exception 'Entité non autorisée'; end if;
  if d.statut <> 'approuve' then raise exception 'La dépense n''est pas approuvée'; end if;
  select * into c from public.fin_caisses where id = p_caisse;
  if not found or c.entite_id <> d.entite_id then raise exception 'Caisse invalide pour cette entité'; end if;
  if c.devise <> d.devise then raise exception 'La caisse est en %, la dépense en %', c.devise, d.devise; end if;
  perform set_config('fin.payer', '1', true);
  insert into public.fin_mouvements(id, entite_id, caisse_id, jour, sens, montant, devise, compte_id, libelle, reference, depense_id)
  values (mid, d.entite_id, c.id, current_date, 'sortie', d.montant, d.devise, d.compte_id, 'Dépense : ' || d.objet, d.id, d.id);
  update public.fin_depenses set statut = 'paye', caisse_id = c.id, mouvement_id = mid, paye_par = public.me_code(), paye_le = now() where id = d.id;
end $$;
grant execute on function public.fin_payer(text, text) to authenticated;

-- ---------- soldes ----------
create or replace view public.fin_soldes_v with (security_invoker = true) as
select c.id as caisse_id,
       c.solde_initial + coalesce(sum(case m.sens when 'entree' then m.montant else -m.montant end), 0) as solde
  from public.fin_caisses c left join public.fin_mouvements m on m.caisse_id = c.id
 group by c.id, c.solde_initial;
grant select on public.fin_soldes_v to authenticated;

-- ---------- sécurité (RLS) ----------
do $$
declare t text;
begin
  foreach t in array array['fin_acces','fin_journal','fin_exercices','fin_comptes','fin_taux','fin_param','fin_caisses','fin_mouvements','fin_depenses'] loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;
grant select, insert, update, delete on public.fin_acces, public.fin_exercices, public.fin_comptes, public.fin_taux, public.fin_param, public.fin_caisses, public.fin_depenses to authenticated;
grant select, insert on public.fin_mouvements to authenticated;
grant select on public.fin_journal to authenticated;

drop policy if exists fin_acces_r on public.fin_acces; drop policy if exists fin_acces_w on public.fin_acces;
create policy fin_acces_r on public.fin_acces for select to authenticated using (public.fin_niveau() is not null);
create policy fin_acces_w on public.fin_acces for all to authenticated using (public.fin_niveau() = 'df') with check (public.fin_niveau() = 'df');

drop policy if exists fin_journal_r on public.fin_journal;
create policy fin_journal_r on public.fin_journal for select to authenticated using (public.fin_niveau() in ('df','se','comptable'));

drop policy if exists fin_exercices_r on public.fin_exercices; drop policy if exists fin_exercices_w on public.fin_exercices;
create policy fin_exercices_r on public.fin_exercices for select to authenticated using (public.fin_niveau() is not null);
create policy fin_exercices_w on public.fin_exercices for all to authenticated using (public.fin_niveau() = 'df') with check (public.fin_niveau() = 'df');

drop policy if exists fin_comptes_r on public.fin_comptes; drop policy if exists fin_comptes_w on public.fin_comptes;
create policy fin_comptes_r on public.fin_comptes for select to authenticated using (public.fin_niveau() is not null);
create policy fin_comptes_w on public.fin_comptes for all to authenticated using (public.fin_niveau() in ('df','comptable')) with check (public.fin_niveau() in ('df','comptable'));

drop policy if exists fin_taux_r on public.fin_taux; drop policy if exists fin_taux_w on public.fin_taux;
create policy fin_taux_r on public.fin_taux for select to authenticated using (public.fin_niveau() is not null);
create policy fin_taux_w on public.fin_taux for all to authenticated using (public.fin_niveau() in ('df','comptable')) with check (public.fin_niveau() in ('df','comptable'));

drop policy if exists fin_param_r on public.fin_param; drop policy if exists fin_param_w on public.fin_param;
create policy fin_param_r on public.fin_param for select to authenticated using (public.fin_niveau() is not null);
create policy fin_param_w on public.fin_param for all to authenticated using (public.fin_niveau() in ('df','se')) with check (public.fin_niveau() in ('df','se'));

drop policy if exists fin_caisses_r on public.fin_caisses; drop policy if exists fin_caisses_w on public.fin_caisses;
create policy fin_caisses_r on public.fin_caisses for select to authenticated using (public.fin_ent_ok(entite_id));
create policy fin_caisses_w on public.fin_caisses for all to authenticated using (public.fin_niveau() = 'df' and public.fin_ent_ok(entite_id)) with check (public.fin_niveau() = 'df' and public.fin_ent_ok(entite_id));

drop policy if exists fin_mouvements_r on public.fin_mouvements; drop policy if exists fin_mouvements_i on public.fin_mouvements;
create policy fin_mouvements_r on public.fin_mouvements for select to authenticated using (public.fin_ent_ok(entite_id));
create policy fin_mouvements_i on public.fin_mouvements for insert to authenticated with check (public.fin_niveau() in ('df','comptable','caissier') and public.fin_ent_ok(entite_id));

drop policy if exists fin_depenses_r on public.fin_depenses; drop policy if exists fin_depenses_i on public.fin_depenses; drop policy if exists fin_depenses_u on public.fin_depenses;
create policy fin_depenses_r on public.fin_depenses for select to authenticated using (public.fin_ent_ok(entite_id));
create policy fin_depenses_i on public.fin_depenses for insert to authenticated with check (public.fin_niveau() in ('df','se','comptable','caissier') and public.fin_ent_ok(entite_id));
create policy fin_depenses_u on public.fin_depenses for update to authenticated
  using (public.fin_ent_ok(entite_id) and (public.fin_niveau() in ('df','se') or demande_par = public.me_code()))
  with check (public.fin_ent_ok(entite_id));

-- ---------- données de départ ----------
insert into public.fin_param(cle, valeur, note) values
  ('seuil_se_usd', 0, 'En dessous de ce montant (équivalent USD) la validation du directeur financier suffit. 0 = le secrétaire exécutif valide toujours.')
on conflict (cle) do nothing;

insert into public.fin_exercices(id, libelle, debut, fin) values
  ('ex2026', 'Exercice 2026', '2026-01-01', '2026-12-31'),
  ('ex2027', 'Exercice 2027', '2027-01-01', '2027-12-31')
on conflict (id) do nothing;

-- Plan comptable de départ (SYSCOHADA révisé, comptes principaux) : à adapter ensuite depuis l'écran Finance
insert into public.fin_comptes(id, intitule, classe, type) values
 ('10','Capital et réserves',1,'passif'),('11','Réserves',1,'passif'),('12','Report à nouveau',1,'passif'),('13','Résultat net de l''exercice',1,'passif'),('14','Subventions d''investissement',1,'passif'),('16','Emprunts et dettes assimilées',1,'passif'),
 ('21','Immobilisations incorporelles',2,'actif'),('22','Terrains',2,'actif'),('23','Bâtiments, installations',2,'actif'),('24','Matériel, mobilier et actifs biologiques',2,'actif'),('245','Matériel de transport',2,'actif'),('244','Matériel et mobilier de bureau',2,'actif'),('28','Amortissements',2,'actif'),
 ('31','Marchandises',3,'actif'),('32','Matières premières et fournitures liées',3,'actif'),('33','Autres approvisionnements',3,'actif'),
 ('40','Fournisseurs et comptes rattachés',4,'passif'),('41','Clients (cotisants) et comptes rattachés',4,'actif'),('42','Personnel',4,'passif'),('421','Personnel, avances et acomptes',4,'actif'),('422','Personnel, rémunérations dues',4,'passif'),('43','Organismes sociaux',4,'passif'),('44','État et collectivités publiques',4,'passif'),('47','Débiteurs et créditeurs divers',4,'autre'),
 ('50','Titres de placement',5,'actif'),('52','Banques',5,'actif'),('53','Établissements financiers',5,'actif'),('57','Caisse',5,'actif'),('571','Caisse siège',5,'actif'),('58','Virements de fonds',5,'autre'),
 ('601','Achats de marchandises',6,'charge'),('602','Achats de matières et fournitures',6,'charge'),('604','Achats de fournitures de bureau',6,'charge'),('605','Autres achats (eau, énergie, carburant)',6,'charge'),
 ('61','Transports',6,'charge'),('62','Services extérieurs A (loyers, entretien, assurances)',6,'charge'),('63','Services extérieurs B (honoraires, publicité, télécoms)',6,'charge'),('64','Impôts et taxes',6,'charge'),('65','Autres charges',6,'charge'),
 ('66','Charges de personnel',6,'charge'),('661','Rémunérations directes',6,'charge'),('664','Charges sociales',6,'charge'),('67','Frais financiers',6,'charge'),('68','Dotations aux amortissements',6,'charge'),
 ('690','Prestations de soins prises en charge',6,'charge'),('691','Prestations aux assurés (remboursements)',6,'charge'),
 ('70','Ventes',7,'produit'),('706','Cotisations des adhérents',7,'produit'),('707','Droits d''adhésion',7,'produit'),('71','Subventions d''exploitation',7,'produit'),('75','Autres produits',7,'produit'),('77','Revenus financiers',7,'produit'),
 ('81','Valeurs comptables des cessions',8,'autre'),('82','Produits des cessions',8,'autre')
on conflict (id) do nothing;

-- Accès de départ : vous (10-056) êtes directeur financier du siège. Ajoutez ensuite les autres depuis l'onglet « Accès » du portail.
insert into public.fin_acces(code, nom, niveau, entite_id) values ('10-056', 'MUFWAR VAN', 'df', 'national') on conflict (code) do update set niveau = excluded.niveau;
