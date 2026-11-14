-- RILOYD schema rebuild: types, tables, grants, row security
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

CREATE TYPE public.app_role AS ENUM ('admin', 'moderator', 'user');

CREATE TABLE public.user_roles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role public.app_role NOT NULL,
  UNIQUE (user_id, role)
);
CREATE TABLE public.profiles (
  id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  display_name text NOT NULL DEFAULT '',
  avatar_url text NOT NULL DEFAULT '',
  preferences jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE TABLE public.coordinators (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  full_name text NOT NULL,
  referral_code text NOT NULL UNIQUE,
  phone text NOT NULL DEFAULT '',
  email text NOT NULL DEFAULT '',
  city text NOT NULL DEFAULT '',
  notes text NOT NULL DEFAULT '',
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.contact_submissions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  email text NOT NULL,
  phone text NOT NULL,
  service text NOT NULL,
  industry text NOT NULL,
  message text NOT NULL,
  status text NOT NULL DEFAULT 'new',
  admin_notes text NOT NULL DEFAULT '',
  coordinator_code text,
  coordinator_id uuid REFERENCES public.coordinators(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.registration_applications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  application_code text NOT NULL UNIQUE,
  category text NOT NULL CHECK (category IN ('startup','mentor','investor','business')),
  full_name text NOT NULL,
  email text NOT NULL,
  phone text NOT NULL,
  details jsonb NOT NULL DEFAULT '{}'::jsonb,
  document_path text,
  document_name text,
  status text NOT NULL DEFAULT 'new',
  admin_notes text NOT NULL DEFAULT '',
  coordinator_code text,
  coordinator_id uuid REFERENCES public.coordinators(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.foundation_submissions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind text NOT NULL,
  full_name text NOT NULL,
  email text NOT NULL,
  phone text NOT NULL,
  details jsonb NOT NULL DEFAULT '{}'::jsonb,
  status text NOT NULL DEFAULT 'new',
  admin_notes text NOT NULL DEFAULT '',
  coordinator_code text,
  coordinator_id uuid REFERENCES public.coordinators(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.programme_applications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  application_code text NOT NULL UNIQUE,
  programme text NOT NULL,
  full_name text NOT NULL,
  email text NOT NULL,
  phone text NOT NULL,
  amount_paise integer NOT NULL,
  details jsonb NOT NULL DEFAULT '{}'::jsonb,
  status text NOT NULL DEFAULT 'new',
  submission_status text NOT NULL DEFAULT 'lead',
  submitted_at timestamptz,
  admin_notes text NOT NULL DEFAULT '',
  coordinator_code text,
  coordinator_id uuid REFERENCES public.coordinators(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.programme_payments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  programme text NOT NULL DEFAULT '',
  application_id uuid,
  application_kind text,
  amount_paise integer NOT NULL,
  currency text NOT NULL DEFAULT 'INR',
  payer_name text NOT NULL,
  payer_email text NOT NULL,
  payer_phone text NOT NULL DEFAULT '',
  provider text NOT NULL DEFAULT 'zoho',
  provider_payment_id text,
  provider_reference text,
  razorpay_order_id text,
  razorpay_payment_id text,
  status text NOT NULL DEFAULT 'created',
  paid_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.payment_provider_tokens (
  provider text PRIMARY KEY,
  access_token text NOT NULL,
  refresh_token text,
  expires_at timestamptz NOT NULL
);
CREATE TABLE public.payment_options (
  key text PRIMARY KEY,
  programme text NOT NULL,
  label text NOT NULL,
  payment_link text,
  razorpay_button_id text,
  sort_order integer NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.young_innovators_registrations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  application_code text NOT NULL UNIQUE,
  student_name text NOT NULL,
  school_class integer NOT NULL CHECK (school_class BETWEEN 6 AND 12),
  city text NOT NULL,
  guardian_name text NOT NULL,
  guardian_email text NOT NULL,
  guardian_phone text NOT NULL,
  idea_title text NOT NULL,
  idea text NOT NULL,
  guardian_consent boolean NOT NULL,
  consent_at timestamptz NOT NULL DEFAULT now(),
  fee_amount integer NOT NULL,
  gst_percent integer NOT NULL DEFAULT 18,
  status text NOT NULL DEFAULT 'new',
  submission_status text NOT NULL DEFAULT 'lead',
  submitted_at timestamptz,
  coordinator_code text,
  coordinator_id uuid REFERENCES public.coordinators(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.employees (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id text NOT NULL UNIQUE,
  code_hash text NOT NULL,
  full_name text NOT NULL,
  photo_url text,
  designation text NOT NULL,
  department text NOT NULL,
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','inactive')),
  valid_until date,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.employee_verification_attempts (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  employee_id text NOT NULL,
  success boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX employee_verification_attempts_lookup ON public.employee_verification_attempts (employee_id, created_at);
CREATE TABLE public.form_submission_limits (
  key_hash text PRIMARY KEY,
  window_started_at timestamptz NOT NULL DEFAULT now(),
  attempts integer NOT NULL DEFAULT 0
);
CREATE TABLE public.people_profiles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  person_group text NOT NULL CHECK (person_group IN ('investors','mentors','team','startups','businesses')),
  slug text NOT NULL,
  name text NOT NULL,
  role text NOT NULL DEFAULT '',
  location text NOT NULL DEFAULT '',
  focus text[] NOT NULL DEFAULT '{}',
  summary text NOT NULL DEFAULT '',
  bio text NOT NULL DEFAULT '',
  photo_url text,
  sort_order integer NOT NULL DEFAULT 0,
  source_application_id uuid UNIQUE REFERENCES public.registration_applications(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (person_group, slug)
);
CREATE TABLE public.customer_reports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  report_number text NOT NULL UNIQUE,
  publish_date date NOT NULL,
  title text NOT NULL,
  category text NOT NULL DEFAULT 'business',
  file_path text NOT NULL,
  file_name text NOT NULL,
  file_size integer NOT NULL DEFAULT 0,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.country_logos (
  country text NOT NULL,
  theme text NOT NULL CHECK (theme IN ('light','dark')),
  file_path text NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (country, theme)
);
CREATE TABLE public.country_programme_fees (
  country text PRIMARY KEY,
  currency text NOT NULL,
  amount integer,
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.prototype_ai_access_state (
  model_id text PRIMARY KEY,
  status_code integer NOT NULL,
  message text NOT NULL DEFAULT '',
  blocked_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.prototype_submissions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  idea text NOT NULL,
  prototype text NOT NULL,
  funding_goal text NOT NULL DEFAULT '',
  eligibility_context text NOT NULL DEFAULT '',
  ai_output text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.education_district_codes (
  state_code text NOT NULL,
  district_key text NOT NULL,
  district_name text NOT NULL,
  code integer NOT NULL CHECK (code BETWEEN 1 AND 99),
  PRIMARY KEY (state_code, district_key)
);
CREATE TABLE public.education_staff_access (
  user_id uuid PRIMARY KEY,
  designation text NOT NULL CHECK (designation IN ('BDE','BDM')),
  manager_id uuid REFERENCES public.education_staff_access(user_id) ON DELETE SET NULL,
  referral_code text NOT NULL UNIQUE,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.education_support_registrations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ack_number text NOT NULL UNIQUE,
  student_category text NOT NULL,
  current_class text,
  course_name text,
  education_sector text,
  institution_name text NOT NULL,
  education jsonb NOT NULL DEFAULT '{}'::jsonb,
  student_name text NOT NULL,
  father_name text NOT NULL,
  mother_name text NOT NULL,
  date_of_birth date NOT NULL,
  gender text NOT NULL,
  nationality text NOT NULL,
  mobile text NOT NULL,
  whatsapp text,
  email text NOT NULL,
  permanent_address text NOT NULL,
  current_address text NOT NULL,
  state text NOT NULL,
  district text NOT NULL,
  city text NOT NULL,
  pin_code text NOT NULL,
  is_minor boolean NOT NULL DEFAULT false,
  guardian_name text,
  guardian_mobile text,
  guardian_email text,
  guardian_relationship text,
  guardian_consent_at timestamptz,
  without_coordinator boolean NOT NULL DEFAULT false,
  coordinator jsonb NOT NULL DEFAULT '{}'::jsonb,
  coordinator_code text,
  coordinator_id uuid REFERENCES public.coordinators(id) ON DELETE SET NULL,
  application_type text NOT NULL,
  registration_fee integer NOT NULL,
  payment_status text NOT NULL DEFAULT 'pending',
  payment_reference text,
  payment_reference_at timestamptz,
  receipt_token_hash text NOT NULL,
  status text NOT NULL DEFAULT 'submitted',
  status_reason text NOT NULL DEFAULT '',
  declarations jsonb NOT NULL DEFAULT '{}'::jsonb,
  form_status text NOT NULL DEFAULT 'started',
  completed_at timestamptz,
  approval_status text NOT NULL DEFAULT 'pending',
  approved_at timestamptz,
  approved_by uuid,
  private_details_ciphertext text,
  aadhaar_last_four text,
  review_flags jsonb NOT NULL DEFAULT '[]'::jsonb,
  ai_review text NOT NULL DEFAULT '',
  flags_checked_at timestamptz,
  flags_confirmed_at timestamptz,
  flags_confirmed_by uuid,
  flags_confirm_note text NOT NULL DEFAULT '',
  employee_verified_at timestamptz,
  employee_verified_by uuid,
  employee_verification_note text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX education_support_payment_reference_unique ON public.education_support_registrations (payment_reference) WHERE payment_reference IS NOT NULL AND payment_reference <> '';
CREATE INDEX education_support_coordinator_code ON public.education_support_registrations (coordinator_code);
CREATE INDEX education_support_created_at ON public.education_support_registrations (created_at);

-- CRM
CREATE TABLE public.crm_memberships (
  user_id uuid PRIMARY KEY,
  role text NOT NULL CHECK (role IN ('sales','support','BDE','BDM')),
  manager_id uuid REFERENCES public.crm_memberships(user_id) ON DELETE SET NULL,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.crm_employee_profiles (
  user_id uuid PRIMARY KEY REFERENCES public.crm_memberships(user_id) ON DELETE CASCADE,
  employee_code text NOT NULL UNIQUE,
  full_name text NOT NULL,
  phone text NOT NULL DEFAULT '',
  designation text NOT NULL DEFAULT '',
  photo_url text,
  joining_date date NOT NULL DEFAULT current_date
);
CREATE SEQUENCE public.crm_customer_code_seq;
CREATE SEQUENCE public.crm_ticket_code_seq;
CREATE TABLE public.crm_customers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_code text NOT NULL UNIQUE DEFAULT ('CUS-' || lpad(nextval('public.crm_customer_code_seq')::text, 6, '0')),
  full_name text NOT NULL,
  email text NOT NULL DEFAULT '',
  phone text NOT NULL DEFAULT '',
  company text NOT NULL DEFAULT '',
  acknowledgement text,
  owner_id uuid,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX crm_customers_email ON public.crm_customers (lower(email));
CREATE TABLE public.crm_leads (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id uuid NOT NULL REFERENCES public.crm_customers(id) ON DELETE CASCADE,
  title text NOT NULL,
  stage text NOT NULL DEFAULT 'new' CHECK (stage IN ('new','contacted','qualified','proposal','won','lost')),
  amount numeric NOT NULL DEFAULT 0,
  source text NOT NULL DEFAULT 'manual',
  source_id uuid,
  owner_id uuid,
  next_follow_up date,
  notes text NOT NULL DEFAULT '',
  referral_code text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX crm_leads_source_unique ON public.crm_leads (source, source_id) WHERE source_id IS NOT NULL;
CREATE INDEX crm_leads_owner ON public.crm_leads (owner_id);
CREATE TABLE public.crm_tasks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title text NOT NULL,
  owner_id uuid NOT NULL,
  customer_id uuid REFERENCES public.crm_customers(id) ON DELETE SET NULL,
  due_date date NOT NULL,
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open','done')),
  priority text NOT NULL DEFAULT 'normal' CHECK (priority IN ('normal','high','urgent')),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.crm_tickets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ticket_code text NOT NULL UNIQUE DEFAULT ('TKT-' || lpad(nextval('public.crm_ticket_code_seq')::text, 6, '0')),
  customer_id uuid NOT NULL REFERENCES public.crm_customers(id) ON DELETE CASCADE,
  owner_id uuid NOT NULL,
  subject text NOT NULL,
  description text NOT NULL DEFAULT '',
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open','in_progress','resolved')),
  priority text NOT NULL DEFAULT 'normal' CHECK (priority IN ('normal','high','urgent')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.crm_activities (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id uuid NOT NULL,
  actor_id uuid NOT NULL,
  lead_id uuid REFERENCES public.crm_leads(id) ON DELETE CASCADE,
  ticket_id uuid REFERENCES public.crm_tickets(id) ON DELETE CASCADE,
  kind text NOT NULL,
  body text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.crm_targets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id uuid NOT NULL,
  month date NOT NULL,
  revenue_target numeric NOT NULL DEFAULT 0,
  wins_target integer NOT NULL DEFAULT 0,
  calls_target integer NOT NULL DEFAULT 0,
  UNIQUE (owner_id, month)
);

-- Grants (row security below decides which rows)
GRANT SELECT ON public.user_roles TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.profiles TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.coordinators, public.contact_submissions, public.registration_applications,
  public.foundation_submissions, public.programme_applications, public.employees, public.people_profiles,
  public.customer_reports, public.country_logos, public.country_programme_fees, public.prototype_submissions,
  public.education_staff_access, public.education_support_registrations,
  public.crm_memberships, public.crm_employee_profiles, public.crm_customers, public.crm_leads, public.crm_tasks,
  public.crm_tickets, public.crm_activities, public.crm_targets TO authenticated;
GRANT SELECT, UPDATE ON public.payment_options TO authenticated;
GRANT SELECT ON public.programme_payments, public.education_district_codes TO authenticated;
-- Student review may change only the status column
GRANT SELECT, INSERT, DELETE ON public.young_innovators_registrations TO authenticated;
GRANT UPDATE (status) ON public.young_innovators_registrations TO authenticated;
GRANT SELECT ON public.payment_options, public.country_programme_fees, public.people_profiles TO anon;
GRANT USAGE ON SEQUENCE public.crm_customer_code_seq, public.crm_ticket_code_seq TO authenticated;
GRANT ALL ON ALL TABLES IN SCHEMA public TO service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO service_role;

ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.coordinators ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.contact_submissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.registration_applications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.foundation_submissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.programme_applications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.programme_payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payment_provider_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payment_options ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.young_innovators_registrations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.employees ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.employee_verification_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.form_submission_limits ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.people_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customer_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.country_logos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.country_programme_fees ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.prototype_ai_access_state ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.prototype_submissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.education_district_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.education_staff_access ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.education_support_registrations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.crm_memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.crm_employee_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.crm_customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.crm_leads ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.crm_tasks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.crm_tickets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.crm_activities ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.crm_targets ENABLE ROW LEVEL SECURITY;

-- Access helpers
CREATE OR REPLACE FUNCTION public.has_role(_user_id uuid, _role public.app_role)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = _user_id AND role = _role)
$$;

CREATE OR REPLACE FUNCTION public.crm_role()
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE
    WHEN auth.uid() IS NULL THEN NULL
    WHEN public.has_role(auth.uid(), 'admin') THEN 'admin'
    ELSE (SELECT m.role FROM public.crm_memberships m WHERE m.user_id = auth.uid() AND m.active)
  END
$$;

-- Admin: everyone. Active member: own records; BDM also active direct reports.
CREATE OR REPLACE FUNCTION public.crm_can_access(_owner uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE
    WHEN auth.uid() IS NULL THEN false
    WHEN public.has_role(auth.uid(), 'admin') THEN true
    WHEN _owner IS NULL THEN false
    ELSE EXISTS (
      SELECT 1 FROM public.crm_memberships me
      WHERE me.user_id = auth.uid() AND me.active
        AND (_owner = auth.uid()
          OR (me.role = 'BDM' AND EXISTS (
                SELECT 1 FROM public.crm_memberships r
                WHERE r.user_id = _owner AND r.manager_id = auth.uid() AND r.active)))
    )
  END
$$;

CREATE OR REPLACE FUNCTION public.crm_my_manager()
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT m.manager_id FROM public.crm_memberships m WHERE m.user_id = auth.uid() AND m.active
$$;

-- Admins, active staff/CRM members, and verified applicants whose application was approved.
CREATE OR REPLACE FUNCTION public.can_view_people_profiles()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT auth.uid() IS NOT NULL AND (
    public.has_role(auth.uid(), 'admin')
    OR EXISTS (SELECT 1 FROM public.crm_memberships WHERE user_id = auth.uid() AND active)
    OR EXISTS (SELECT 1 FROM public.education_staff_access WHERE user_id = auth.uid() AND active)
    OR EXISTS (
      SELECT 1 FROM auth.users u
      JOIN public.registration_applications a ON lower(a.email) = lower(u.email) AND a.status = 'approved'
      WHERE u.id = auth.uid() AND u.email_confirmed_at IS NOT NULL
    )
  )
$$;

-- Policies
CREATE POLICY "Users read own roles; admins read all" ON public.user_roles FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR public.has_role(auth.uid(), 'admin'));

CREATE POLICY "Own profile read" ON public.profiles FOR SELECT TO authenticated USING (id = auth.uid());
CREATE POLICY "Own profile insert" ON public.profiles FOR INSERT TO authenticated WITH CHECK (id = auth.uid());
CREATE POLICY "Own profile update" ON public.profiles FOR UPDATE TO authenticated USING (id = auth.uid()) WITH CHECK (id = auth.uid());

-- Admin-only tables
CREATE POLICY "Admins manage coordinators" ON public.coordinators FOR ALL TO authenticated USING (public.has_role(auth.uid(), 'admin')) WITH CHECK (public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Admins manage enquiries" ON public.contact_submissions FOR ALL TO authenticated USING (public.has_role(auth.uid(), 'admin')) WITH CHECK (public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Admins manage applications" ON public.registration_applications FOR ALL TO authenticated USING (public.has_role(auth.uid(), 'admin')) WITH CHECK (public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Admins manage foundation forms" ON public.foundation_submissions FOR ALL TO authenticated USING (public.has_role(auth.uid(), 'admin')) WITH CHECK (public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Admins manage programme applications" ON public.programme_applications FOR ALL TO authenticated USING (public.has_role(auth.uid(), 'admin')) WITH CHECK (public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Admins read programme payments" ON public.programme_payments FOR SELECT TO authenticated USING (public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Admins manage employees" ON public.employees FOR ALL TO authenticated USING (public.has_role(auth.uid(), 'admin')) WITH CHECK (public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Admins manage reports" ON public.customer_reports FOR ALL TO authenticated USING (public.has_role(auth.uid(), 'admin')) WITH CHECK (public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Admins manage country logos" ON public.country_logos FOR ALL TO authenticated USING (public.has_role(auth.uid(), 'admin')) WITH CHECK (public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Admins manage prototype submissions" ON public.prototype_submissions FOR ALL TO authenticated USING (public.has_role(auth.uid(), 'admin')) WITH CHECK (public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Admins read district codes" ON public.education_district_codes FOR SELECT TO authenticated USING (public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Admins manage education registrations" ON public.education_support_registrations FOR ALL TO authenticated USING (public.has_role(auth.uid(), 'admin')) WITH CHECK (public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Admins read student registrations" ON public.young_innovators_registrations FOR SELECT TO authenticated USING (public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Admins import student registrations" ON public.young_innovators_registrations FOR INSERT TO authenticated WITH CHECK (public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Admins review student registrations" ON public.young_innovators_registrations FOR UPDATE TO authenticated
  USING (public.has_role(auth.uid(), 'admin')) WITH CHECK (public.has_role(auth.uid(), 'admin') AND status IN ('new','reviewed','approved','rejected'));
CREATE POLICY "Admins delete student registrations" ON public.young_innovators_registrations FOR DELETE TO authenticated USING (public.has_role(auth.uid(), 'admin'));

-- Public-readable, admin-written
CREATE POLICY "Anyone reads programme fees" ON public.country_programme_fees FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY "Admins insert programme fees" ON public.country_programme_fees FOR INSERT TO authenticated WITH CHECK (public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Admins update programme fees" ON public.country_programme_fees FOR UPDATE TO authenticated USING (public.has_role(auth.uid(), 'admin')) WITH CHECK (public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Admins delete programme fees" ON public.country_programme_fees FOR DELETE TO authenticated USING (public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Anyone reads payment options" ON public.payment_options FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY "Admins update payment options" ON public.payment_options FOR UPDATE TO authenticated USING (public.has_role(auth.uid(), 'admin')) WITH CHECK (public.has_role(auth.uid(), 'admin'));

-- People profiles: restricted reads, admin writes
CREATE POLICY "Permitted viewers read people profiles" ON public.people_profiles FOR SELECT TO anon, authenticated USING (public.can_view_people_profiles());
CREATE POLICY "Admins insert people profiles" ON public.people_profiles FOR INSERT TO authenticated WITH CHECK (public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Admins update people profiles" ON public.people_profiles FOR UPDATE TO authenticated USING (public.has_role(auth.uid(), 'admin')) WITH CHECK (public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Admins delete people profiles" ON public.people_profiles FOR DELETE TO authenticated USING (public.has_role(auth.uid(), 'admin'));

-- Education staff
CREATE POLICY "Staff read own access; admins read all" ON public.education_staff_access FOR SELECT TO authenticated USING (user_id = auth.uid() OR public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Admins insert staff access" ON public.education_staff_access FOR INSERT TO authenticated WITH CHECK (public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Admins update staff access" ON public.education_staff_access FOR UPDATE TO authenticated USING (public.has_role(auth.uid(), 'admin')) WITH CHECK (public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Admins delete staff access" ON public.education_staff_access FOR DELETE TO authenticated USING (public.has_role(auth.uid(), 'admin'));

-- CRM
CREATE POLICY "CRM members read visible members" ON public.crm_memberships FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR public.crm_can_access(user_id)
    OR user_id = public.crm_my_manager());
CREATE POLICY "Admins manage CRM members" ON public.crm_memberships FOR ALL TO authenticated USING (public.has_role(auth.uid(), 'admin')) WITH CHECK (public.has_role(auth.uid(), 'admin'));
CREATE POLICY "CRM members read visible profiles" ON public.crm_employee_profiles FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR public.crm_can_access(user_id)
    OR user_id = public.crm_my_manager());
CREATE POLICY "Admins manage CRM profiles" ON public.crm_employee_profiles FOR ALL TO authenticated USING (public.has_role(auth.uid(), 'admin')) WITH CHECK (public.has_role(auth.uid(), 'admin'));

CREATE POLICY "CRM read visible customers" ON public.crm_customers FOR SELECT TO authenticated
  USING (public.crm_can_access(owner_id) OR EXISTS (SELECT 1 FROM public.crm_leads l WHERE l.customer_id = crm_customers.id AND public.crm_can_access(l.owner_id)));
CREATE POLICY "CRM sales create customers" ON public.crm_customers FOR INSERT TO authenticated
  WITH CHECK (public.crm_role() IN ('admin','sales','BDE','BDM') AND public.crm_can_access(owner_id));
CREATE POLICY "CRM update visible customers" ON public.crm_customers FOR UPDATE TO authenticated USING (public.crm_can_access(owner_id)) WITH CHECK (public.crm_can_access(owner_id));
CREATE POLICY "Admins delete customers" ON public.crm_customers FOR DELETE TO authenticated USING (public.has_role(auth.uid(), 'admin'));

CREATE POLICY "CRM read visible leads" ON public.crm_leads FOR SELECT TO authenticated USING (public.crm_can_access(owner_id));
CREATE POLICY "CRM sales create leads" ON public.crm_leads FOR INSERT TO authenticated
  WITH CHECK (public.crm_role() IN ('admin','sales','BDE','BDM') AND public.crm_can_access(owner_id));
CREATE POLICY "CRM update visible leads" ON public.crm_leads FOR UPDATE TO authenticated USING (public.crm_can_access(owner_id)) WITH CHECK (public.crm_can_access(owner_id));
CREATE POLICY "Admins delete leads" ON public.crm_leads FOR DELETE TO authenticated USING (public.has_role(auth.uid(), 'admin'));

CREATE POLICY "CRM read visible tasks" ON public.crm_tasks FOR SELECT TO authenticated USING (public.crm_can_access(owner_id));
CREATE POLICY "CRM create tasks" ON public.crm_tasks FOR INSERT TO authenticated WITH CHECK (public.crm_can_access(owner_id));
CREATE POLICY "CRM update visible tasks" ON public.crm_tasks FOR UPDATE TO authenticated USING (public.crm_can_access(owner_id)) WITH CHECK (public.crm_can_access(owner_id));
CREATE POLICY "CRM delete visible tasks" ON public.crm_tasks FOR DELETE TO authenticated USING (public.crm_can_access(owner_id));

CREATE POLICY "CRM read visible tickets" ON public.crm_tickets FOR SELECT TO authenticated USING (public.crm_can_access(owner_id));
CREATE POLICY "CRM create tickets" ON public.crm_tickets FOR INSERT TO authenticated WITH CHECK (public.crm_can_access(owner_id));
CREATE POLICY "CRM update visible tickets" ON public.crm_tickets FOR UPDATE TO authenticated USING (public.crm_can_access(owner_id)) WITH CHECK (public.crm_can_access(owner_id));
CREATE POLICY "Admins delete tickets" ON public.crm_tickets FOR DELETE TO authenticated USING (public.has_role(auth.uid(), 'admin'));

CREATE POLICY "CRM read visible activities" ON public.crm_activities FOR SELECT TO authenticated USING (public.crm_can_access(owner_id));
CREATE POLICY "CRM log own activities" ON public.crm_activities FOR INSERT TO authenticated
  WITH CHECK (actor_id = auth.uid() AND public.crm_can_access(owner_id) AND kind IN ('note','call','email','meeting'));

CREATE POLICY "CRM read visible targets" ON public.crm_targets FOR SELECT TO authenticated USING (public.crm_can_access(owner_id));
CREATE POLICY "Managers set targets" ON public.crm_targets FOR INSERT TO authenticated
  WITH CHECK (public.crm_role() IN ('admin','BDM') AND public.crm_can_access(owner_id));
CREATE POLICY "Managers update targets" ON public.crm_targets FOR UPDATE TO authenticated
  USING (public.crm_role() IN ('admin','BDM') AND public.crm_can_access(owner_id))
  WITH CHECK (public.crm_role() IN ('admin','BDM') AND public.crm_can_access(owner_id));