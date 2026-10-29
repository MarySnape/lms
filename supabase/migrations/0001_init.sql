-- ============================================================================
-- LMS SCHEMA v1 (Supabase / PostgreSQL)
-- Каркас базы данных системы обучения. Запускать в Supabase SQL Editor
-- (или `supabase db push`).
--
-- Таблицы:
--   profiles        — профиль пользователя + роль (student/teacher/admin)
--   groups          — учебные группы
--   courses         — курсы
--   modules         — модули (разделы) внутри курса
--   lessons         — уроки: html / html_package (ZIP из Storage) / quiz
--   quizzes         — тесты
--   questions       — вопросы теста
--   answers         — варианты ответа (is_correct скрыт от студентов!)
--   attempts        — попытки прохождения тестов (автопроверка)
--   progress        — прогресс по урокам
--   lesson_events   — события из iframe HTML-пакетов (пишет lms-api.js)
--   comments        — обсуждение под уроками
--   enrollments     — записи студентов на курсы
--
-- Безопасность: RLS + политики по ролям.
-- ============================================================================

create extension if not exists "uuid-ossp";

-- Enums -----------------------------------------------------------------------
do $$ begin
  create type user_role as enum ('student', 'teacher', 'admin');
exception when duplicate_object then null; end $$;

do $$ begin
  create type lesson_content_type as enum ('html', 'html_package', 'quiz');
exception when duplicate_object then null; end $$;

do $$ begin
  create type lesson_event_type as enum ('COMPLETE', 'QUIZ_RESULT', 'PROGRESS_UPDATE', 'CUSTOM');
exception when duplicate_object then null; end $$;

-- Профили пользователей --------------------------------------------------------
-- Создаются триггером при регистрации в auth.users. Роль по умолчанию — student.
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text unique not null,
  full_name text default '',
  avatar_url text,
  role user_role not null default 'student',
  group_id uuid, -- FK добавим ниже (циклическая зависимость profiles<->groups)
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Учебные группы ----------------------------------------------------------------
create table if not exists public.groups (
  id uuid primary key default uuid_generate_v4(),
  name text not null,
  description text default '',
  created_at timestamptz not null default now()
);

alter table public.profiles
  drop constraint if exists profiles_group_id_fkey;
alter table public.profiles
  add constraint profiles_group_id_fkey
  foreign key (group_id) references public.groups(id) on delete set null;

-- Курсы -------------------------------------------------------------------------
create table if not exists public.courses (
  id uuid primary key default uuid_generate_v4(),
  title text not null,
  description text default '',
  cover_url text,
  is_published boolean not null default false,
  teacher_id uuid references public.profiles(id) on delete set null,
  group_id uuid references public.groups(id) on delete set null, -- курс привязан к группе
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Модули (разделы курса) ----------------------------------------------------------
create table if not exists public.modules (
  id uuid primary key default uuid_generate_v4(),
  course_id uuid not null references public.courses(id) on delete cascade,
  title text not null,
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);

-- Уроки ---------------------------------------------------------------------------
create table if not exists public.lessons (
  id uuid primary key default uuid_generate_v4(),
  module_id uuid not null references public.modules(id) on delete cascade,
  title text not null,
  content_type lesson_content_type not null default 'html',
  html_content text,                     -- для content_type='html' (sanitized TipTap HTML)
  package_path text,                     -- 'lms-packages/<lesson-id>' для ZIP-пакетов
  main_file text default 'index.html',   -- главный файл пакета
  quiz_id uuid,                          -- для content_type='quiz'
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);

-- Тесты / вопросы / ответы ---------------------------------------------------------
create table if not exists public.quizzes (
  id uuid primary key default uuid_generate_v4(),
  course_id uuid references public.courses(id) on delete cascade,
  title text not null,
  description text default '',
  passing_score integer not null default 70,  -- % для сдачи
  time_limit_min integer,                     -- NULL = без ограничения
  is_published boolean not null default false,
  created_at timestamptz not null default now()
);

alter table public.lessons
  drop constraint if exists lessons_quiz_id_fkey;
alter table public.lessons
  add constraint lessons_quiz_id_fkey
  foreign key (quiz_id) references public.quizzes(id) on delete set null;

create table if not exists public.questions (
  id uuid primary key default uuid_generate_v4(),
  quiz_id uuid not null references public.quizzes(id) on delete cascade,
  text text not null,
  type text not null default 'single_choice', -- пока одиночный выбор
  points integer not null default 1,
  sort_order integer not null default 0
);

create table if not exists public.answers (
  id uuid primary key default uuid_generate_v4(),
  question_id uuid not null references public.questions(id) on delete cascade,
  text text not null,
  is_correct boolean not null default false,
  sort_order integer not null default 0
);

-- Попытки прохождения тестов (автопроверка выполняется на сервере) ------------------
create table if not exists public.attempts (
  id uuid primary key default uuid_generate_v4(),
  quiz_id uuid not null references public.quizzes(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  score integer not null default 0,           -- набранные баллы
  max_score integer not null default 0,
  percent numeric(5,2) not null default 0,
  passed boolean not null default false,
  answers jsonb not null default '[]',        -- [{question_id, answer_id}]
  created_at timestamptz not null default now()
);

-- Прогресс по урокам ------------------------------------------------------------------
create table if not exists public.progress (
  id uuid primary key default uuid_generate_v4(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  lesson_id uuid not null references public.lessons(id) on delete cascade,
  course_id uuid not null references public.courses(id) on delete cascade,
  is_completed boolean not null default false,
  completed_at timestamptz,
  last_position jsonb,                        -- точка восстановления для пакетов
  unique (user_id, lesson_id)
);

-- События из iframe HTML-пакетов (пишет API-route через postMessage) -------------------
create table if not exists public.lesson_events (
  id uuid primary key default uuid_generate_v4(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  lesson_id uuid not null references public.lessons(id) on delete cascade,
  event_type lesson_event_type not null,
  event_data jsonb not null default '{}',
  created_at timestamptz not null default now()
);
create index if not exists lesson_events_user_lesson_idx
  on public.lesson_events (user_id, lesson_id, created_at desc);

-- Комментарии (обсуждение под уроком) -----------------------------------------------------
create table if not exists public.comments (
  id uuid primary key default uuid_generate_v4(),
  lesson_id uuid not null references public.lessons(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  parent_id uuid references public.comments(id) on delete cascade, -- ответы тредом
  body text not null check (char_length(body) between 1 and 5000),
  created_at timestamptz not null default now()
);

-- Записи на курсы --------------------------------------------------------------------------
create table if not exists public.enrollments (
  id uuid primary key default uuid_generate_v4(),
  course_id uuid not null references public.courses(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  enrolled_at timestamptz not null default now(),
  unique (course_id, user_id)
);

-- ============================================================================
-- Триггеры: авто-создание профиля при регистрации + updated_at
-- ============================================================================
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, email, full_name)
  values (new.id, new.email, coalesce(new.raw_user_meta_data->>'full_name', ''))
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end; $$;

drop trigger if exists trg_profiles_touch on public.profiles;
create trigger trg_profiles_touch before update on public.profiles
  for each row execute function public.touch_updated_at();

drop trigger if exists trg_courses_touch on public.courses;
create trigger trg_courses_touch before update on public.courses
  for each row execute function public.touch_updated_at();

-- Роль текущего пользователя (для политик RLS).
-- security definer нужен, чтобы политика на profiles могла читать profiles
-- без бесконечной рекурсии RLS.
create or replace function public.current_role()
returns user_role
language sql
security definer set search_path = public
stable
as $$
  select role from public.profiles where id = auth.uid();
$$;

-- ============================================================================
-- ROW LEVEL SECURITY — разграничение прав по ролям
-- ============================================================================
alter table public.profiles      enable row level security;
alter table public.groups        enable row level security;
alter table public.courses       enable row level security;
alter table public.modules       enable row level security;
alter table public.lessons       enable row level security;
alter table public.quizzes       enable row level security;
alter table public.questions     enable row level security;
alter table public.answers       enable row level security;
alter table public.attempts      enable row level security;
alter table public.progress      enable row level security;
alter table public.lesson_events enable row level security;
alter table public.comments      enable row level security;
alter table public.enrollments   enable row level security;

-- Профили: каждый видит себя; admin — всех; teacher — студентов своей группы
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select
  using (
    id = auth.uid()
    or public.current_role() = 'admin'
    or (public.current_role() = 'teacher'
        and group_id in (select group_id from public.profiles where id = auth.uid()))
  );

drop policy if exists profiles_update_self on public.profiles;
create policy profiles_update_self on public.profiles for update
  using (id = auth.uid())
  with check (id = auth.uid() and role = public.current_role()); -- нельзя самому повысить роль

-- Группы: чтение всем авторизованным, изменение — admin
drop policy if exists groups_read on public.groups;
create policy groups_read on public.groups for select using (auth.uid() is not null);
drop policy if exists groups_write on public.groups;
create policy groups_write on public.groups for all
  using (public.current_role() = 'admin')
  with check (public.current_role() = 'admin');

-- Курсы: опубликованные видят все; черновики — владелец/admin
drop policy if exists courses_select on public.courses;
create policy courses_select on public.courses for select
  using (is_published or teacher_id = auth.uid() or public.current_role() in ('admin','teacher'));
drop policy if exists courses_insert on public.courses;
create policy courses_insert on public.courses for insert
  with check (public.current_role() in ('teacher','admin'));
drop policy if exists courses_update on public.courses;
create policy courses_update on public.courses for update
  using (teacher_id = auth.uid() or public.current_role() = 'admin');
drop policy if exists courses_delete on public.courses;
create policy courses_delete on public.courses for delete
  using (teacher_id = auth.uid() or public.current_role() = 'admin');

-- Модули: читают участники курса, пишут владелец/admin
drop policy if exists modules_select on public.modules;
create policy modules_select on public.modules for select
  using (exists (select 1 from public.courses c where c.id = course_id
                 and (c.is_published or c.teacher_id = auth.uid() or public.current_role()='admin')));
drop policy if exists modules_write on public.modules;
create policy modules_write on public.modules for all
  using (exists (select 1 from public.courses c where c.id = course_id
                 and (c.teacher_id = auth.uid() or public.current_role()='admin')))
  with check (exists (select 1 from public.courses c where c.id = course_id
                 and (c.teacher_id = auth.uid() or public.current_role()='admin')));

-- Уроки
drop policy if exists lessons_select on public.lessons;
create policy lessons_select on public.lessons for select
  using (exists (select 1 from public.modules m join public.courses c on c.id = m.course_id
                 where m.id = module_id
                 and (c.is_published or c.teacher_id = auth.uid() or public.current_role()='admin')));
drop policy if exists lessons_write on public.lessons;
create policy lessons_write on public.lessons for all
  using (exists (select 1 from public.modules m join public.courses c on c.id = m.course_id
                 where m.id = module_id
                 and (c.teacher_id = auth.uid() or public.current_role()='admin')))
  with check (exists (select 1 from public.modules m join public.courses c on c.id = m.course_id
                 where m.id = module_id
                 and (c.teacher_id = auth.uid() or public.current_role()='admin')));

-- Тесты и вопросы
drop policy if exists quizzes_select on public.quizzes;
create policy quizzes_select on public.quizzes for select
  using (is_published or public.current_role() in ('teacher','admin'));
drop policy if exists quizzes_write on public.quizzes;
create policy quizzes_write on public.quizzes for all
  using (public.current_role() in ('teacher','admin'))
  with check (public.current_role() in ('teacher','admin'));

drop policy if exists questions_select on public.questions;
create policy questions_select on public.questions for select
  using (exists (select 1 from public.quizzes q where q.id = quiz_id
                 and (q.is_published or public.current_role() in ('teacher','admin'))));
drop policy if exists questions_write on public.questions;
create policy questions_write on public.questions for all
  using (public.current_role() in ('teacher','admin'))
  with check (public.current_role() in ('teacher','admin'));

-- ВАЖНО: студенты НЕ читают answers (там is_correct). Правильность проверяется
-- серверным action'ом со service-role ключом; студент получает только результат.
drop policy if exists answers_select on public.answers;
create policy answers_select on public.answers for select
  using (public.current_role() in ('teacher','admin'));
drop policy if exists answers_write on public.answers;
create policy answers_write on public.answers for all
  using (public.current_role() in ('teacher','admin'))
  with check (public.current_role() in ('teacher','admin'));

-- Попытки: студент видит свои; teacher/admin — все (для аналитики)
drop policy if exists attempts_select on public.attempts;
create policy attempts_select on public.attempts for select
  using (user_id = auth.uid() or public.current_role() in ('teacher','admin'));
drop policy if exists attempts_insert on public.attempts;
create policy attempts_insert on public.attempts for insert
  with check (user_id = auth.uid());

-- Прогресс: студент читает/пишет свой; teacher/admin читают (аналитика)
drop policy if exists progress_select on public.progress;
create policy progress_select on public.progress for select
  using (user_id = auth.uid() or public.current_role() in ('teacher','admin'));
drop policy if exists progress_write on public.progress;
create policy progress_write on public.progress for all
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- События уроков: пишет только сам студент (через API route), читают свои/teacher/admin
drop policy if exists events_select on public.lesson_events;
create policy events_select on public.lesson_events for select
  using (user_id = auth.uid() or public.current_role() in ('teacher','admin'));
drop policy if exists events_insert on public.lesson_events;
create policy events_insert on public.lesson_events for insert
  with check (user_id = auth.uid());

-- Комментарии: читают все авторизованные; пишет автор; удаляет автор/admin
drop policy if exists comments_select on public.comments;
create policy comments_select on public.comments for select using (auth.uid() is not null);
drop policy if exists comments_insert on public.comments;
create policy comments_insert on public.comments for insert
  with check (user_id = auth.uid());
drop policy if exists comments_delete on public.comments;
create policy comments_delete on public.comments for delete
  using (user_id = auth.uid() or public.current_role() = 'admin');

-- Enrollments: студент видит/создаёт свои; teacher/admin — управляют
drop policy if exists enrollments_select on public.enrollments;
create policy enrollments_select on public.enrollments for select
  using (user_id = auth.uid() or public.current_role() in ('teacher','admin'));
drop policy if exists enrollments_insert on public.enrollments;
create policy enrollments_insert on public.enrollments for insert
  with check (user_id = auth.uid() or public.current_role() in ('teacher','admin'));
drop policy if exists enrollments_delete on public.enrollments;
create policy enrollments_delete on public.enrollments for delete
  using (public.current_role() in ('teacher','admin'));

-- ============================================================================
-- STORAGE: публичный бакет lms-packages для распакованных HTML-пакетов уроков.
-- Чтение — публичное (iframe грузит ассеты), запись — только сервером
-- (service role), поэтому клиентские write-политики не создаём намеренно.
-- ============================================================================
insert into storage.buckets (id, name, public)
values ('lms-packages', 'lms-packages', true)
on conflict (id) do nothing;
