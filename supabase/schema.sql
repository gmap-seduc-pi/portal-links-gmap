-- =====================================================================
-- PORTAL DE LINKS DA GMAP / SEDUC-PI
-- Estrutura do banco no Supabase (PostgreSQL)
-- Executar em: Supabase > SQL Editor > New query > Run
-- Pode ser rodado mais de uma vez sem perder dados.
-- Deve ser rodado num projeto Supabase exclusivo do Portal de Links.
-- As funções começam com "portal_" por segurança extra contra
-- conflito de nomes.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. ADMINISTRADORES
--    Somente quem estiver nesta tabela (e ativo) pode cadastrar, editar
--    e excluir. O usuário é criado em Authentication > Users e depois
--    inserido aqui (ver GUIA-DE-IMPLANTACAO.txt).
-- ---------------------------------------------------------------------
create table if not exists public.administradores (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  nome       text not null,
  email      text not null,
  ativo      boolean not null default true,
  criado_em  timestamptz not null default now()
);

create or replace function public.portal_is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.administradores a
    where a.user_id = auth.uid() and a.ativo
  );
$$;

-- ---------------------------------------------------------------------
-- 2. CATEGORIAS
-- ---------------------------------------------------------------------
create table if not exists public.categorias (
  id            uuid primary key default gen_random_uuid(),
  nome          text not null unique,
  descricao     text,
  ordem         integer not null default 100,
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 3. LINKS E PASTAS (tabela "sistemas")
--    tipo = 'link'  -> item com endereço; pode estar dentro de uma pasta
--    tipo = 'pasta' -> agrupa links; não tem endereço; não fica em pasta
--    Estrutura de um nível só: Categoria > Pasta > Links.
--    Links dentro de pasta herdam a categoria da pasta.
--    Exclusão é lógica: excluido_em preenchido = item na lixeira.
-- ---------------------------------------------------------------------
create table if not exists public.sistemas (
  id                   uuid primary key default gen_random_uuid(),
  tipo                 text not null default 'link',
  pasta_id             uuid references public.sistemas(id) on delete cascade,
  nome                 text not null check (char_length(nome) between 2 and 80),
  url                  text,
  descricao            text check (char_length(descricao) <= 240),
  categoria_id         uuid references public.categorias(id) on delete set null,
  icone                text not null default 'globe',
  cor                  text not null default '#034ea2' check (cor ~* '^#[0-9a-f]{6}$'),
  somente_rede_estado  boolean not null default false,
  responsavel_nome     text,
  responsavel_contato  text,
  acessos              bigint not null default 0,
  ordem                integer not null default 100,
  excluido_em          timestamptz,
  criado_em            timestamptz not null default now(),
  criado_por           text,
  atualizado_em        timestamptz not null default now(),
  atualizado_por       text,
  constraint sistemas_tipo_check check (
    (tipo = 'link'  and url ~* '^https?://') or
    (tipo = 'pasta' and url is null and pasta_id is null)
  )
);

create index if not exists sistemas_categoria_idx on public.sistemas(categoria_id);
create index if not exists sistemas_excluido_idx  on public.sistemas(excluido_em);
create index if not exists sistemas_pasta_idx     on public.sistemas(pasta_id);

create or replace function public.portal_tg_valida_pasta()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tipo_pai text;
begin
  if tg_op = 'UPDATE' and new.tipo <> old.tipo then
    raise exception 'Não é possível transformar link em pasta (ou o contrário).';
  end if;
  if new.pasta_id is not null then
    if new.tipo <> 'link' then
      raise exception 'Pasta não pode ficar dentro de outra pasta.';
    end if;
    select tipo into v_tipo_pai from public.sistemas where id = new.pasta_id;
    if v_tipo_pai is distinct from 'pasta' then
      raise exception 'O destino escolhido não é uma pasta.';
    end if;
    new.categoria_id := null;  -- herda a categoria da pasta
  end if;
  return new;
end;
$$;

drop trigger if exists valida_pasta on public.sistemas;
create trigger valida_pasta before insert or update on public.sistemas
  for each row execute function public.portal_tg_valida_pasta();

-- Item visível ao público: não excluído e, se estiver em pasta, a pasta
-- também não pode estar excluída (pasta na lixeira esconde seus links).
create or replace function public.portal_pasta_ativa(p_pasta uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_pasta is null or exists (
    select 1 from public.sistemas p where p.id = p_pasta and p.excluido_em is null
  );
$$;

-- Preenche quem criou / alterou e a data da alteração
create or replace function public.portal_tg_carimbo()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text := coalesce(auth.jwt() ->> 'email', 'sistema');
begin
  -- Atualização só do contador de acessos não mexe no carimbo
  if tg_op = 'UPDATE' and tg_table_name = 'sistemas'
     and (to_jsonb(new) - 'acessos') = (to_jsonb(old) - 'acessos') then
    return new;
  end if;

  new.atualizado_em := now();
  if tg_table_name = 'sistemas' then
    new.atualizado_por := v_email;
    if tg_op = 'INSERT' then
      new.criado_por := v_email;
      new.acessos := 0;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists carimbo_sistemas on public.sistemas;
create trigger carimbo_sistemas before insert or update on public.sistemas
  for each row execute function public.portal_tg_carimbo();

drop trigger if exists carimbo_categorias on public.categorias;
create trigger carimbo_categorias before insert or update on public.categorias
  for each row execute function public.portal_tg_carimbo();

-- ---------------------------------------------------------------------
-- 4. AUDITORIA
--    Toda inclusão, alteração, exclusão e restauração fica registrada,
--    com o estado anterior e o novo. Ninguém edita nem apaga este log
--    pelo Portal de Links.
-- ---------------------------------------------------------------------
create table if not exists public.auditoria (
  id            bigint generated always as identity primary key,
  em            timestamptz not null default now(),
  tabela        text not null,
  registro_id   uuid,
  acao          text not null,
  usuario_email text,
  antes         jsonb,
  depois        jsonb
);

create index if not exists auditoria_em_idx on public.auditoria(em desc);

create or replace function public.portal_tg_auditoria()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_acao text;
begin
  -- A contagem de acessos não gera log (seria ruído)
  if tg_op = 'UPDATE' and tg_table_name = 'sistemas'
     and (to_jsonb(new) - 'acessos' - 'atualizado_em' - 'atualizado_por')
       = (to_jsonb(old) - 'acessos' - 'atualizado_em' - 'atualizado_por') then
    return new;
  end if;

  if tg_op = 'INSERT' then
    v_acao := 'INCLUSAO';
  elsif tg_op = 'DELETE' then
    v_acao := 'EXCLUSAO_DEFINITIVA';
  elsif tg_table_name = 'sistemas' and old.excluido_em is null and new.excluido_em is not null then
    v_acao := 'EXCLUSAO';
  elsif tg_table_name = 'sistemas' and old.excluido_em is not null and new.excluido_em is null then
    v_acao := 'RESTAURACAO';
  else
    v_acao := 'ALTERACAO';
  end if;

  insert into public.auditoria (tabela, registro_id, acao, usuario_email, antes, depois)
  values (
    tg_table_name,
    coalesce(new.id, old.id),
    v_acao,
    coalesce(auth.jwt() ->> 'email', 'sistema'),
    case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end,
    case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) end
  );

  return coalesce(new, old);
end;
$$;

drop trigger if exists auditoria_sistemas on public.sistemas;
create trigger auditoria_sistemas after insert or update or delete on public.sistemas
  for each row execute function public.portal_tg_auditoria();

drop trigger if exists auditoria_categorias on public.categorias;
create trigger auditoria_categorias after insert or update or delete on public.categorias
  for each row execute function public.portal_tg_auditoria();

-- ---------------------------------------------------------------------
-- 5. CONTADOR DE ACESSOS
--    Função pública que só soma 1. Não dá a ninguém permissão de
--    alterar o resto do registro.
-- ---------------------------------------------------------------------
create or replace function public.portal_registrar_acesso(p_id uuid)
returns void
language sql
security definer
set search_path = public
as $$
  update public.sistemas
     set acessos = acessos + 1
   where id = p_id and excluido_em is null;
$$;

grant execute on function public.portal_registrar_acesso(uuid) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 6. SEGURANÇA (Row Level Security)
--    Visitante: só lê categorias, links e pastas ativos.
--    Administrador: lê tudo (inclusive lixeira e auditoria) e grava.
-- ---------------------------------------------------------------------
alter table public.administradores enable row level security;
alter table public.categorias      enable row level security;
alter table public.sistemas        enable row level security;
alter table public.auditoria       enable row level security;

-- administradores
drop policy if exists adm_le_proprio on public.administradores;
create policy adm_le_proprio on public.administradores
  for select to authenticated using (user_id = auth.uid() or public.portal_is_admin());

-- categorias
drop policy if exists cat_leitura on public.categorias;
create policy cat_leitura on public.categorias
  for select to anon, authenticated using (true);

drop policy if exists cat_gravacao on public.categorias;
create policy cat_gravacao on public.categorias
  for all to authenticated using (public.portal_is_admin()) with check (public.portal_is_admin());

-- sistemas
drop policy if exists sis_leitura_publica on public.sistemas;
create policy sis_leitura_publica on public.sistemas
  for select to anon, authenticated using (
    (excluido_em is null and public.portal_pasta_ativa(pasta_id)) or public.portal_is_admin()
  );

drop policy if exists sis_insert on public.sistemas;
create policy sis_insert on public.sistemas
  for insert to authenticated with check (public.portal_is_admin());

drop policy if exists sis_update on public.sistemas;
create policy sis_update on public.sistemas
  for update to authenticated using (public.portal_is_admin()) with check (public.portal_is_admin());

drop policy if exists sis_delete on public.sistemas;
create policy sis_delete on public.sistemas
  for delete to authenticated using (public.portal_is_admin());

-- auditoria: só leitura, só administradores. Inserção apenas via trigger.
drop policy if exists aud_leitura on public.auditoria;
create policy aud_leitura on public.auditoria
  for select to authenticated using (public.portal_is_admin());

-- ---------------------------------------------------------------------
-- 7. CATEGORIAS INICIAIS (pode editar depois pelo Portal de Links)
-- ---------------------------------------------------------------------
insert into public.categorias (nome, descricao, ordem) values
  ('Sistemas corporativos', 'Sistemas oficiais do Estado e da SEDUC usados no dia a dia', 10),
  ('Ferramentas da GMAP',   'Sistemas e painéis desenvolvidos para o setor', 20),
  ('Planilhas e painéis',   'Planilhas compartilhadas, relatórios e indicadores', 30),
  ('Portais externos',      'Portais de outros órgãos, fornecedores e consultas públicas', 40)
on conflict (nome) do nothing;
