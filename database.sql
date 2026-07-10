-- =========================================================
-- NOVA — Supabase Schema
-- Run this in Supabase SQL Editor (Project > SQL Editor > New query)
-- =========================================================

-- ---------- USERS ----------
-- Extends Supabase's built-in auth.users with role info
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null,
  role text not null check (role in ('teacher', 'student')),
  created_at timestamptz default now()
);

-- ---------- CLASSROOMS ----------
create table public.classrooms (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  join_code text unique not null,
  teacher_id uuid references public.profiles(id) on delete cascade,
  created_at timestamptz default now()
);

create table public.classroom_members (
  classroom_id uuid references public.classrooms(id) on delete cascade,
  student_id uuid references public.profiles(id) on delete cascade,
  joined_at timestamptz default now(),
  primary key (classroom_id, student_id)
);

-- ---------- QUIZZES ----------
create table public.quizzes (
  id uuid primary key default gen_random_uuid(),
  classroom_id uuid references public.classrooms(id) on delete cascade,
  title text not null,
  time_limit_seconds int default 0,
  created_by uuid references public.profiles(id),
  created_at timestamptz default now()
);

create table public.questions (
  id uuid primary key default gen_random_uuid(),
  quiz_id uuid references public.quizzes(id) on delete cascade,
  question_text text not null,
  question_type text not null check (question_type in ('mcq', 'true_false')),
  options jsonb,              -- e.g. ["Paris","London","Rome","Berlin"]
  correct_answer text not null,
  order_index int not null default 0
);

create table public.quiz_attempts (
  id uuid primary key default gen_random_uuid(),
  quiz_id uuid references public.quizzes(id) on delete cascade,
  student_id uuid references public.profiles(id) on delete cascade,
  score int default 0,
  started_at timestamptz default now(),
  completed_at timestamptz
);

create table public.quiz_answers (
  id uuid primary key default gen_random_uuid(),
  attempt_id uuid references public.quiz_attempts(id) on delete cascade,
  question_id uuid references public.questions(id) on delete cascade,
  selected_answer text,
  is_correct boolean
);

-- ---------- FORMS (Google Forms-style builder) ----------
create table public.forms (
  id uuid primary key default gen_random_uuid(),
  classroom_id uuid references public.classrooms(id) on delete cascade,
  title text not null,
  created_by uuid references public.profiles(id),
  created_at timestamptz default now()
);

create table public.form_fields (
  id uuid primary key default gen_random_uuid(),
  form_id uuid references public.forms(id) on delete cascade,
  label text not null,
  field_type text not null check (field_type in ('short_text','long_text','mcq','checkbox','dropdown')),
  options jsonb,
  required boolean default false,
  order_index int not null default 0
);

create table public.form_responses (
  id uuid primary key default gen_random_uuid(),
  form_id uuid references public.forms(id) on delete cascade,
  student_id uuid references public.profiles(id) on delete cascade,
  submitted_at timestamptz default now()
);

create table public.form_response_answers (
  id uuid primary key default gen_random_uuid(),
  response_id uuid references public.form_responses(id) on delete cascade,
  field_id uuid references public.form_fields(id) on delete cascade,
  answer_value text
);

-- =========================================================
-- ROW LEVEL SECURITY
-- =========================================================
alter table public.profiles enable row level security;
alter table public.classrooms enable row level security;
alter table public.classroom_members enable row level security;
alter table public.quizzes enable row level security;
alter table public.questions enable row level security;
alter table public.quiz_attempts enable row level security;
alter table public.quiz_answers enable row level security;
alter table public.forms enable row level security;
alter table public.form_fields enable row level security;
alter table public.form_responses enable row level security;
alter table public.form_response_answers enable row level security;

-- Profiles: users can read all, edit only their own
create policy "Profiles are viewable by everyone" on public.profiles for select using (true);
create policy "Users can update own profile" on public.profiles for update using (auth.uid() = id);

-- Classrooms: teacher manages own, students can view classrooms they joined
create policy "Teachers manage own classrooms" on public.classrooms for all using (auth.uid() = teacher_id);
create policy "Members can view their classroom" on public.classrooms for select using (
  auth.uid() = teacher_id or
  exists (select 1 from public.classroom_members cm where cm.classroom_id = id and cm.student_id = auth.uid())
);

-- Classroom members
create policy "Students can join classrooms" on public.classroom_members for insert with check (auth.uid() = student_id);
create policy "Members visible to classroom participants" on public.classroom_members for select using (
  student_id = auth.uid() or
  exists (select 1 from public.classrooms c where c.id = classroom_id and c.teacher_id = auth.uid())
);

-- Quizzes & questions: teacher manages, students in classroom can read
create policy "Teachers manage quizzes" on public.quizzes for all using (auth.uid() = created_by);
create policy "Students view quizzes in their classroom" on public.quizzes for select using (
  exists (select 1 from public.classroom_members cm where cm.classroom_id = classroom_id and cm.student_id = auth.uid())
);
create policy "Questions follow quiz access" on public.questions for select using (
  exists (
    select 1 from public.quizzes q
    left join public.classroom_members cm on cm.classroom_id = q.classroom_id
    where q.id = quiz_id and (q.created_by = auth.uid() or cm.student_id = auth.uid())
  )
);
create policy "Teachers manage questions" on public.questions for insert with check (
  exists (select 1 from public.quizzes q where q.id = quiz_id and q.created_by = auth.uid())
);

-- Attempts & answers: students manage their own
create policy "Students manage own attempts" on public.quiz_attempts for all using (auth.uid() = student_id);
create policy "Students manage own answers" on public.quiz_answers for all using (
  exists (select 1 from public.quiz_attempts a where a.id = attempt_id and a.student_id = auth.uid())
);

-- Forms: same pattern as quizzes
create policy "Teachers manage forms" on public.forms for all using (auth.uid() = created_by);
create policy "Students view forms in their classroom" on public.forms for select using (
  exists (select 1 from public.classroom_members cm where cm.classroom_id = classroom_id and cm.student_id = auth.uid())
);
create policy "Form fields follow form access" on public.form_fields for select using (
  exists (
    select 1 from public.forms f
    left join public.classroom_members cm on cm.classroom_id = f.classroom_id
    where f.id = form_id and (f.created_by = auth.uid() or cm.student_id = auth.uid())
  )
);
create policy "Students manage own form responses" on public.form_responses for all using (auth.uid() = student_id);
create policy "Students manage own response answers" on public.form_response_answers for all using (
  exists (select 1 from public.form_responses r where r.id = response_id and r.student_id = auth.uid())
);

-- =========================================================
-- INDEXES for common lookups
-- =========================================================
create index idx_classrooms_join_code on public.classrooms(join_code);
create index idx_quizzes_classroom on public.quizzes(classroom_id);
create index idx_questions_quiz on public.questions(quiz_id);
create index idx_attempts_quiz on public.quiz_attempts(quiz_id, student_id);
create index idx_forms_classroom on public.forms(classroom_id);
