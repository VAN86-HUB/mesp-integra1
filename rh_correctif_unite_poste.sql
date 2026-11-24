-- Correctif v109 : un agent affecté à un poste prend l'unité de ce poste quand aucune unité n'est renseignée.
-- À exécuter une fois dans Supabase (SQL Editor). Sans danger : ne touche que les agents sans unité.
update public.hr_agents a
   set unite_id = p.unite_id
  from public.hr_postes p
 where a.poste_id = p.id
   and a.unite_id is null
   and p.unite_id is not null
   and p.entite_id = a.entite_id;
